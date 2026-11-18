import SwiftUI
import GameMetrikCore

struct PlayersView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    @State private var activeOnly = false
    @State private var activityGroup: ActivityGroup? = nil
    @State private var sortOrder = [KeyPathComparator(\Player.completions, order: .reverse)]
    var players: [Player] {
        (state.directory?.players ?? []).filter {
            (!activeOnly || $0.completions > 0) && (activityGroup == nil || $0.activityGroup == activityGroup) && (search.isEmpty || $0.name.localizedStandardContains(search) || $0.id.localizedStandardContains(search))
        }.sorted(using: sortOrder)
    }
    var selected: Player? { state.directory?.players.first { $0.id == state.selectedPlayerID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Les joueurs de \(state.game?.name ?? "ce jeu")").font(.title2.weight(.semibold))
                    Text("\(state.directory?.players.count ?? 0) profils · \(state.directory?.activePlayers ?? 0) actifs · \(state.directory?.completions ?? 0) parties terminées")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let note = state.connectedAccountsNote {
                        Label(note, systemImage: "person.crop.circle.badge.checkmark").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Avec activité", isOn: $activeOnly).toggleStyle(.checkbox)
            }.padding(22)
            Picker("Jours actifs sur la période", selection: $activityGroup) {
                Text("Tous les profils").tag(nil as ActivityGroup?)
                ForEach(ActivityGroup.allCases) { Text($0.label).tag(Optional($0)) }
            }.fixedSize().padding(.horizontal, 22).padding(.bottom, 12)
            if let note = state.directory?.entitlementNote {
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.bottom, 12)
            }
            if let note = state.directory?.dataNote {
                Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(.horizontal, 22).padding(.bottom, 12)
            }
            Table(players, selection: $state.selectedPlayerID, sortOrder: $sortOrder) {
                TableColumn("Joueur", value: \.name) { player in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.name).fontWeight(.medium).foregroundStyle(player.hasName ? .primary : .secondary)
                        Text(String(player.id.suffix(12))).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.width(min: 160, ideal: 190)
                TableColumn("Aventure", value: \.adventureStep) { player in Text("Étape \(player.adventureStep)").monospacedDigit() }.width(min: 75, ideal: 85)
                TableColumn("Parties", value: \.completions) { player in Text(player.completions.formatted()).monospacedDigit() }.width(min: 65, ideal: 70)
                TableColumn("Jours actifs", value: \.activeDays) { player in Text(player.activeDays.formatted()).monospacedDigit() }.width(min: 65, ideal: 80)
                TableColumn("Temps de jeu", value: \.playMinutes) { player in Text(Display.duration(player.playMinutes)).monospacedDigit() }.width(min: 90, ideal: 105)
                TableColumn("Score") { player in Text(Display.percent(player.scoreRatio)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 70, ideal: 85)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first {
                    Button("Afficher la fiche") { state.selectedPlayerID = id }
                    Button("Copier l’identifiant public") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string) }
                }
            } primaryAction: { ids in state.selectedPlayerID = ids.first }
            .overlay {
                if players.isEmpty {
                    ContentUnavailableView {
                        Label(search.isEmpty ? "Aucun joueur" : "Aucun résultat", systemImage: "person.crop.circle.badge.questionmark")
                    } description: { Text(search.isEmpty ? "Aucun profil ne correspond aux filtres actuels." : "Essaie un autre pseudonyme ou identifiant public.") } actions: {
                        if !search.isEmpty || activeOnly || activityGroup != nil { Button("Effacer les filtres") { search = ""; activeOnly = false; activityGroup = nil } }
                    }
                }
            }
            HStack {
                Text("\(players.count) profil(s) affiché(s)")
                Spacer()
                Text("Sélectionne une ligne pour consulter sa fiche.")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .searchable(text: $search, prompt: "Pseudonyme ou identifiant public")
        .inspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { state.selectedPlayerID = nil } })) {
            if let player = selected {
                PlayerInspector(player: player, jardin: state.game?.hasJardinPaisible == true, timezone: state.directory?.timezone) { state.selectedPlayerID = nil }
                    .inspectorColumnWidth(min: 290, ideal: 325, max: 390)
            }
        }
        .onChange(of: search) { _, _ in if !players.contains(where: { $0.id == state.selectedPlayerID }) { state.selectedPlayerID = nil } }
        .onChange(of: activityGroup) { _, _ in if !players.contains(where: { $0.id == state.selectedPlayerID }) { state.selectedPlayerID = nil } }
        .onChange(of: activeOnly) { _, _ in if !players.contains(where: { $0.id == state.selectedPlayerID }) { state.selectedPlayerID = nil } }
    }
}

struct PlayerInspector: View {
    let player: Player
    let jardin: Bool
    var timezone: String? = nil
    let close: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Fiche joueur").font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Fermer la fiche")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 42)).foregroundStyle(.metrik.opacity(0.7))
                    Text(player.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(player.id).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Aventure · étape \(player.adventureStep)").font(.subheadline)
                }
                if jardin {
                    HStack {
                        Label("Jardin paisible", systemImage: "leaf")
                        Spacer()
                        Text(player.jardinPaisible.map { $0 ? "Actif" : "Inactif" } ?? "Inconnu")
                            .foregroundStyle(player.jardinPaisible == true ? .metrik : .secondary)
                    }.font(.subheadline).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(spacing: 12) {
                    detail("Parties terminées", player.completions.formatted())
                    detail("Jours actifs", player.activeDays.formatted())
                    detail("Parties / jour actif", Display.number(player.completionsPerActiveDay, digits: 1))
                    detail("Série de jours consécutifs", player.longestStreak.formatted())
                    detail("Retour sur un autre jour", player.returnedInPeriod ? "Oui" : "Non observé")
                    detail("Temps de jeu", Display.duration(player.playMinutes))
                    detail("Durée moyenne", Display.duration(player.averageMinutes))
                    detail("Score pondéré", Display.percent(player.scoreRatio))
                    detail("Parties parfaites", Display.percent(player.perfectRate))
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Activité sur la période").font(.headline)
                    ActivityChart(days: player.trend).frame(height: 140)
                    detail("Première partie", player.firstPlayed?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                    detail("Dernière partie", player.lastPlayed?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                }
                VStack(spacing: 12) {
                    Text("Par partie terminée").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    detail("Mouvements", Display.number(player.moves, digits: 1))
                    detail("Indices", Display.number(player.hints, digits: 1))
                    detail("Erreurs", Display.number(player.mistakes, digits: 1))
                    detail("Annulations", Display.number(player.undos, digits: 1))
                }
                CompletionHoursView(hours: player.completionHours, timezone: timezone)
                BreakdownView(title: "Modes préférés", rows: player.modes)
                BreakdownView(title: "Difficultés", rows: player.difficulties)
                Text("Cette fiche porte sur la période sélectionnée. Première et dernière parties désignent les bornes observées dans cette période, pas la date d’arrivée du joueur. Un retour est une activité sur plusieurs jours, pas une rétention J7. Une donnée absente est représentée par « — ».")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit().multilineTextAlignment(.trailing) }.font(.subheadline)
    }
}
