import SwiftUI
import AppKit
import GameMetrikCore

enum ExportScope: String, CaseIterable, Identifiable {
    case available, current
    var id: String { rawValue }
    var label: String { self == .available ? "Toutes les données disponibles" : "Vue actuelle" }
}

extension AppState {
    var exportContextKey: String { String(demo) + "|" + localViewKey(for: game?.usesBallparkAnalytics == true ? .ballpark : .dashboard) }
    var exportSectionLabels: [String] {
        game?.usesBallparkAnalytics == true
            ? ["Analyse Ballpark"]
            : ["Vue d’ensemble", "Gameplay et joueurs", "Avis"] + (canNavigate(to: .auroraJourney) ? ["Parcours"] : [])
    }
    var canPrepareExport: Bool {
        !isLocked && !loading && game != nil && (demo || hasLiveIdentity) && (demo || accessMode != "personal" || range != .all)
    }
    var canPresentExport: Bool { canExport || canPrepareExport }
    var exportHasUnreadViews: Bool {
        (try? makeExport(scope: .available).missingViews.isEmpty) != true
    }
    /// A source that is not connected (Aurora journey function absent, 404) cannot be fixed by another sync.
    var exportReadFailures: [ExportCheck] {
        matchingExportSyncResults.filter { ["failed", "cancelled", "pending"].contains($0.status) }
    }
    /// Only invoked by the user's export action; opening the sheet remains read-only.
    func prepareRequestedExport(scope: ExportScope, allowIncomplete: Bool = false) async throws {
        let context = refreshKey
        if scope == .available, !allowIncomplete, exportHasUnreadViews || !exportReadFailures.isEmpty {
            guard let task = refresh(forExport: true) else {
                throw GameMetrikError.message("Sélectionne un jeu et une période de 1 jour à 1 an, puis synchronise les vues avant l’export complet.")
            }
            await task.value
            try Task.checkCancellation()
            guard refreshKey == context, !isLocked else { throw CancellationError() }
            if let error { throw GameMetrikError.message(error) }
            if matchingExportSyncResults.contains(where: { $0.status == "cancelled" }) { throw CancellationError() }
        }
        guard canExport else { throw GameMetrikError.message(error ?? "Les données ne sont pas prêtes pour l’export.") }
        if scope == .available, !allowIncomplete, exportHasUnreadViews || !exportReadFailures.isEmpty {
            throw GameMetrikError.message("Export complet interrompu : certaines vues n’ont pas pu être chargées. Consulte les erreurs ci-dessus, puis réessaie ou choisis explicitement un export partiel.")
        }
    }
    var matchingExportSyncResults: [ExportCheck] { exportSyncContext == exportContextKey ? exportSyncResults : [] }
    func recordExportSync(_ section: String, status: String, detail: String, date: Date?) {
        guard preparingExport, exportSyncContext == exportContextKey,
              let index = exportSyncResults.firstIndex(where: { $0.section == section }) else { return }
        exportSyncResults[index] = ExportCheck(section: section, status: status, detail: detail, updatedAt: date.map(Dates.iso))
    }
    func finishExportPreparation(status: String, detail: String) {
        guard preparingExport else { return }
        exportSyncResults = exportSyncResults.map { $0.status == "pending" ? ExportCheck(section: $0.section, status: status, detail: detail) : $0 }
        preparingExport = false
    }
    var canExport: Bool {
        let prepared = matchingExportSyncResults.contains { ["loaded", "partial", "empty"].contains($0.status) }
        return !isLocked && !loading && error == nil && ((loadedAt != nil && loadedContextKey == refreshKey) || prepared) && (!needsGame || game != nil)
    }
    /// `target` exports another synchronized game of the same period from the saved views only (AI folder).
    func makeExport(scope: ExportScope, now: Date = Date(), target: String? = nil) throws -> DataExport {
        guard target != nil || canExport else { throw GameMetrikError.message("Attends la fin de la synchronisation et ouvre une vue contenant des données pour exporter.") }
        let selected = target == nil || target == self.gameID
        let gameID = target ?? self.gameID, game = games.first { $0.id == gameID }
        let page = selected ? destination ?? .dashboard : .dashboard, all = scope == .available || target != nil
        let libraryOnly = !all && page == .library
        let reviewsOnly = !all && page == .reviews
        let ballparkSelection = game?.usesBallparkAnalytics == true
        var result = DataExport(now: now, mode: demo ? "Démonstration" : accessMode == "personal" ? "Administration personnelle" : "Membre", gameID: libraryOnly ? nil : game?.id, gameName: libraryOnly ? "Tout le studio" : game?.name ?? "Tout le studio", timeframe: libraryOnly ? "Sans période · catalogue actuel" : reviewsOnly ? "Toutes les dates des avis chargés" : range.label + " (" + range.rawValue + ")", scope: all ? scope.label : page.title)
        result.notes = ["Données chargées au moment de la création du fichier. La préparation de l’export complet charge les vues manquantes ; l’option d’export partiel conserve uniquement les données déjà chargées.", "Les tableaux incluent toutes les lignes et les détails disponibles, indépendamment de la recherche, du tri ou des panneaux repliés."]
        if all || page == .library {
            result.addGames(libraryOnly || gameID == "all" ? games : games.filter { $0.id == gameID }, generatedAt: aggregateCache?.catalogSyncedAt ?? loadedAt)
        }
        if !ballparkSelection, all || page == .dashboard {
            let value = (selected ? dashboard : nil) ?? localViews[localViewKey(for: .dashboard, gameID: gameID)]?.dashboard ?? aggregateCache?.snapshot(gameID: game?.id, range: range)
            if let value, value.gameId == (gameID == "all" ? nil : gameID), value.timeframe == range {
                result.addDashboard(value)
            } else { result.missingViews.append("Vue d’ensemble"); result.notes.append("Vue d’ensemble absente pour cette sélection : utilise Synchroniser toutes les vues dans la fenêtre d’export pour l’inclure.") }
        }
        if !ballparkSelection, all || page == .gameplay || page == .players {
            let cached = localViews[localViewKey(for: .players, gameID: gameID)]?.directory
            let value = selected && (needsGame || demo) ? directory ?? cached : cached
            if let value, game != nil {
                result.addDirectory(value, includePlayers: target == nil && (all || page == .players), jardin: game?.hasJardinPaisible == true, timezone: playerTimezone(for: game), connectedAccountsOnly: game?.usesAuroraJourney == true)
            } else { result.missingViews.append("Gameplay et joueurs"); result.notes.append("Gameplay et joueurs absents : sélectionne un jeu puis utilise Synchroniser toutes les vues dans la fenêtre d’export pour les inclure.") }
        }
        if !ballparkSelection, all || page == .reviews {
            let cached = localViews[localViewKey(for: .reviews, gameID: gameID)]
            let current = selected && (page == .reviews || demo)
            if (selected && page == .reviews && loadedAt != nil && loadedContextKey == refreshKey) || (selected && demo) || cached != nil {
                let values = current ? reviews : cached?.reviews ?? []
                result.addReviews(values.filter { gameID == "all" || $0.gameId == gameID }, generatedAt: current ? loadedAt : cached?.date)
            } else { result.missingViews.append("Avis"); result.notes.append("Avis absents pour cette sélection : utilise Synchroniser toutes les vues dans la fenêtre d’export pour les inclure.") }
        }
        if ballparkSelection, all || page == .ballpark {
            let value = (selected ? ballparkAnalytics : nil) ?? localViews[localViewKey(for: .ballpark, gameID: gameID)]?.ballpark
            if let value, !value.isEmpty {
                result.addBallpark(
                    overview: value.overview,
                    questions: value.questions,
                    series: value.series,
                    habits: value.habits,
                    quality: value.quality
                )
                for kind in BallparkReportKind.allCases where value.report(for: kind) == nil {
                    result.missingViews.append("Ballpark · " + kind.frenchTitle)
                }
                for (kind, detail) in value.errors.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    result.checks.append(.init(section: "Ballpark · " + kind.frenchTitle, status: "failed", detail: detail))
                }
            } else {
                result.missingViews.append("Analyse Ballpark")
                result.notes.append("Analyse Ballpark absente : utilise Synchroniser toutes les vues dans la fenêtre d’export pour inclure les cinq rapports agrégés.")
            }
        }
        let journey = (selected ? auroraJourney : nil) ?? localViews[localViewKey(for: .auroraJourney, gameID: gameID)]?.auroraJourney
        if game?.usesAuroraJourney == true, all || page == .auroraJourney {
            if demo || accessMode == "personal" {
                if let journey {
                    result.addAuroraJourney(journey)
                    for kind in AuroraJourneyReportKind.allCases where journey.coverage(for: kind) == nil && journey.errors[kind]?.status != .notConnected {
                        result.missingViews.append("Parcours · " + kind.title)
                    }
                    // A failed or undeployed steps report is described by its own check, never as a view to reload.
                    if journey.steps == nil && journey.stepsError == nil { result.missingViews.append("Parcours · Étapes anonymes") }
                    // Measured monetization: aggregates only, its own checks; a failure is never a view to reload.
                    result.addAuroraMonetization(journey.monetization)
                    for kind in AuroraMonetizationReportKind.allCases where journey.monetization.state(for: kind) == .notLoaded {
                        result.missingViews.append("Parcours · Monétisation mesurée · " + kind.title)
                    }
                } else { result.missingViews.append("Parcours") }
            }
            result.checks.append(.init(section: "Attribution des campagnes", status: "not_collected", detail: "Attribution : non collectée. Aucun lien entre campagnes et parcours individuels."))
        }
        // Complete collection (1.6.0+): loaded with the journey, aggregates only; each family carries its own check.
        if game?.usesAuroraJourney == true, demo || accessMode == "personal", all || page == .auroraJourney || page == .auroraInsights {
            if let insights = (selected ? auroraInsights : nil) ?? localViews[localViewKey(for: .auroraInsights, gameID: gameID)]?.auroraInsights {
                result.addAuroraInsights(insights)
                for kind in AuroraInsightsKind.allCases where insights.state(for: kind) == .notLoaded {
                    result.missingViews.append("Activité et jeu · " + kind.title)
                }
            } else { result.missingViews.append("Activité et jeu") }
        }
        if game?.usesAuroraJourney == true, all || page == .auroraJourney || page == .players || page == .gameplay {
            let status = journey?.availability(for: journey?.filters ?? .period(range, now: now)) ?? (accessMode == "personal" || demo ? .notLoaded : .notConnected)
            result.checks.append(.init(section: "Abandons et parcours par niveau", status: status.rawValue,
                detail: journey?.coverage.map { "Première réception : \($0.collectionFirstReceivedAt ?? "aucune"). Avant la collecte : not_collected. Jours archivés : \($0.archivedDaysInWindow). Les interruptions ne décrivent aucune intention du joueur." }
                    ?? "Rapport dédié non chargé ou non connecté. Réservé à l’Administration personnelle ; aucune donnée historique reconstituée.",
                updatedAt: journey?.latestGeneration.map(Dates.iso)))
        }
        if !demo {
            if !ballparkSelection, all || page == .dashboard {
                if accessMode == "personal", !result.tables.contains(where: { $0.id == "studio_revenus_detail" }) {
                    for (id, title) in [("studio_pays", "Revenus par pays"), ("studio_plateformes", "Revenus par plateforme")] where result.tables.first(where: { $0.id == id })?.rows.isEmpty != false {
                        result.checks.append(ExportCheck(section: title, status: "not_loaded", detail: "Ce bilan est antérieur à la collecte des ventilations. Synchronise la vue d’ensemble pour recevoir les revenus par pays et plateforme."))
                    }
                }
                if game?.usesAuroraJourney != true || !all { result.checks.append(ExportCheck(section: "Attribution des campagnes", status: "not_collected", detail: "Aucun lien campagne → joueur → première partie → retour J7 → revenus n’est collecté. Les exports GameMetrik et EZads ne permettent pas cette jointure.")) }
            }
            if !ballparkSelection, all || page == .gameplay || page == .players {
                result.checks.append(ExportCheck(section: "Sessions et publicité par joueur", status: "not_collected", detail: game?.usesAuroraJourney == true
                    ? "Aucune session ni publicité n’est lue joueur par joueur. Depuis Aurora Grove 1.6.0, les sessions sont mesurées en agrégats anonymes par jour et par version (collecte_sessions, Administration personnelle) ; les impressions et revenus AdMob restent agrégés et ne sont pas répartis entre joueurs."
                    : "Aucun début/fin de session ni événement publicitaire individuel n’est lu. Les impressions et revenus AdMob sont agrégés ; ils ne sont pas répartis artificiellement entre joueurs."))
                if game?.usesAuroraJourney != true {
                    result.checks.append(ExportCheck(section: "Abandons et parcours par niveau", status: "not_collected", detail: "GameMetrik lit les parties terminées et l’étape d’aventure actuelle. Les débuts et transitions entre niveaux ne sont pas disponibles dans les sources actuelles."))
                }
            }
        }
        if all, target == nil {
            result.checks += matchingExportSyncResults.map { ExportCheck(section: "Synchronisation · " + $0.section, status: $0.status, detail: $0.detail, updatedAt: $0.updatedAt) }
            if !matchingExportSyncResults.isEmpty { result.notes.append("Une synchronisation des vues a été demandée avant cet export. Son bilan distingue les réussites, les données partielles et les échecs ; il ne garantit pas que les fournisseurs ont publié tous leurs rapports.") }
        }
        result.finishChecks()
        return result
    }

    func cancelExportFolderSelection() {
        let panel = exportPanel
        exportPanel = nil
        panel?.cancel(nil)
    }

    /// Called only by the explicit Export button. Never opens or focuses a window during background work.
    func chooseExportFolder(scope: ExportScope, completion: @escaping @MainActor (String?) -> Void) {
        guard canExport else { completion("Les données ne sont plus disponibles pour cet export. Ferme cette fenêtre puis réessaie depuis les données à exporter."); return }
        // A picker can outlive a prior SwiftUI export sheet when that sheet is
        // dismissed by a context change. It must not block the next explicit export.
        cancelExportFolderSelection()
        let context = refreshKey, date = loadedAt
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.prompt = "Exporter ici"
        panel.message = "Choisis où créer le dossier GameMetrik contenant les CSV, le JSON et le guide de lecture."
        exportPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            guard self.exportPanel === panel else { return }
            self.exportPanel = nil
            guard response == .OK, let parent = panel.url else { completion(nil); return }
            guard self.canExport, self.refreshKey == context, self.loadedAt == date else {
                completion("La sélection ou les données ont changé. Relance l’export depuis la vue à exporter."); return
            }
            let scoped = parent.startAccessingSecurityScopedResource()
            defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
            do {
                let report = try self.makeExport(scope: scope)
                let wrapper = try report.fileWrapper()
                let slug = (self.game?.slug ?? "studio").lowercased().replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
                let name = "GameMetrik-" + String(slug.prefix(50)) + "-" + self.range.rawValue + "-" + (self.demo ? "demo-" : "") + Dates.day(Date(), timezone: .current) + "-" + UUID().uuidString.prefix(8)
                let destination = parent.appendingPathComponent(name, isDirectory: true)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw GameMetrikError.message("Un dossier porte déjà ce nom. Réessaie l’export.") }
                try wrapper.write(to: destination, options: .atomic, originalContentsURL: nil)
                completion("Export terminé : " + destination.path)
            } catch {
                completion("Export impossible : " + error.localizedDescription)
            }
        }
    }
}

struct ExportView: View {
    @EnvironmentObject var state: AppState
    @State private var scope: ExportScope = .available
    @State private var saving = false
    @State private var message: String?
    @State private var allowIncomplete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Exporter les données").font(.title2.weight(.semibold))
            Text("CSV pour Excel et Numbers, JSON pour tes analyses et rapports.").foregroundStyle(.secondary)
            Picker("Périmètre", selection: $scope) {
                ForEach(ExportScope.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).disabled(saving || state.preparingExport)
            if scope == .available {
                HStack {
                    Button("Synchroniser toutes les vues") { message = nil; state.refresh(forExport: true) }.disabled(saving || !state.canPrepareExport)
                    Text(state.game?.usesBallparkAnalytics == true ? "Aperçu, Questions, Séries, Habitudes et Qualité" : "Vue d’ensemble, Gameplay/Joueurs, Avis" + (state.canNavigate(to: .auroraJourney) ? " et Parcours" : "")).font(.caption).foregroundStyle(.secondary)
                }
                if state.game == nil { Text("Sélectionne un jeu pour synchroniser aussi ses données détaillées.").font(.callout).foregroundStyle(.secondary) }
                else if !state.demo && state.accessMode == "personal" && state.range == .all { Text("Choisis une période de 1 jour à 1 an pour synchroniser les rapports fournisseurs.").font(.callout).foregroundStyle(.secondary) }
            }
            if state.preparingExport {
                HStack { ProgressView().controlSize(.small); Text(state.syncProgress ?? "Synchronisation des vues…"); Spacer(); Button("Annuler") { state.cancelRefresh() } }.font(.callout)
            } else if scope == .available, !state.matchingExportSyncResults.isEmpty {
                let results = state.matchingExportSyncResults
                let received = results.filter { ["loaded", "partial", "empty"].contains($0.status) }.count
                Text("\(received)/\(results.count) vues actualisées · consulte le bilan de disponibilité dans l’export.").font(.callout).foregroundStyle(.secondary)
                ForEach(state.exportReadFailures, id: \.section) { failure in
                    Label(failure.section + " : " + failure.detail, systemImage: "exclamationmark.triangle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = state.error { Text(error).font(.callout).foregroundStyle(.secondary) }
            if let report = try? state.makeExport(scope: scope) {
                Text(report.gameName + " · " + report.timeframe + " · " + report.mode).font(.callout.weight(.medium))
                Text("Toutes les lignes des données chargées sont incluses, avec leurs détails.").font(.callout).foregroundStyle(.secondary)
                if !report.missingViews.isEmpty {
                    Label("À charger pour compléter : " + report.missingViews.joined(separator: ", ") + ".", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(report.tables, id: \.id) { table in
                            HStack { Text(table.title); Spacer(); Text("\(table.rows.count) " + (table.rows.count == 1 ? "ligne" : "lignes")).foregroundStyle(.secondary).monospacedDigit() }
                        }
                        Divider()
                        ForEach(report.notes, id: \.self) { Text($0).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }.font(.callout)
                }.frame(maxHeight: 260)
            }
            if let message { Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if scope == .available, !state.preparingExport, state.exportHasUnreadViews || !state.exportReadFailures.isEmpty {
                Toggle("Exporter seulement les données chargées (export partiel)", isOn: $allowIncomplete)
                    .font(.callout).disabled(saving)
                if !allowIncomplete {
                    Text("L’export chargera les vues manquantes avant le choix du dossier.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Fermer") { if state.preparingExport { state.cancelRefresh() }; state.showingExport = false }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(state.preparingExport ? "Chargement des vues…" : saving ? "Choix du dossier…" : scope == .available && !allowIncomplete && (state.exportHasUnreadViews || !state.exportReadFailures.isEmpty) ? "Charger les vues et exporter…" : allowIncomplete ? "Exporter les données chargées…" : "Choisir le dossier et exporter…") {
                    saving = true; message = nil
                    Task { @MainActor in
                        do {
                            try await state.prepareRequestedExport(scope: scope, allowIncomplete: allowIncomplete)
                            guard state.showingExport else { saving = false; return }
                            state.chooseExportFolder(scope: scope) { result in saving = false; message = result }
                        } catch is CancellationError {
                            saving = false; message = "Export annulé. Aucun fichier créé."
                        } catch {
                            saving = false; message = error.localizedDescription
                        }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || state.loading || !(state.canExport || (scope == .available && !allowIncomplete && state.canPrepareExport)))
            }
        }.padding(24).frame(width: 560)
        .onChange(of: state.refreshKey) { _, _ in state.cancelExportFolderSelection(); if state.preparingExport { state.cancelRefresh() }; state.showingExport = false }
        .onChange(of: scope) { _, _ in message = nil; allowIncomplete = false }
        .onDisappear { state.cancelExportFolderSelection() }
    }
}
