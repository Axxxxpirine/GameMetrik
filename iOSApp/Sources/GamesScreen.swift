import SwiftUI
import Charts
import GameMetrikCore

struct GamesScreen: View {
    @EnvironmentObject var store: MobileStore
    @State private var search = ""
    private var games: [Game] { store.games.filter { search.isEmpty || $0.name.localizedStandardContains(search) } }
    var body: some View {
        List {
            Section { WorkspaceCaption() }
            ForEach(games) { game in
                NavigationLink {
                    GameScreen(game: game)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.name).font(.headline)
                        Text(game.usesBallparkAnalytics ? "Aperçu, questions, séries, habitudes et qualité" : "Indicateurs, gameplay, joueurs et avis")
                            .font(.subheadline).foregroundStyle(Color.readableSecondary)
                    }.padding(.vertical, 8)
                }.accessibilityIdentifier("game-" + game.id)
            }
        }
        .navigationTitle("Jeux")
        .searchable(text: $search, prompt: "Rechercher un jeu")
        .overlay { if games.isEmpty { if search.isEmpty { SyncEmpty(gameID: nil, title: "Ton catalogue de jeux") } else { ContentUnavailableView.search(text: search) } } }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { store.synchronize(gameID: nil) } label: { Label("Synchroniser", systemImage: "arrow.clockwise") }.disabled(store.loading) } }
    }
}

struct GameScreen: View {
    @EnvironmentObject var store: MobileStore
    let game: Game
    var body: some View {
        List {
            Section {
                WorkspaceCaption()
                if let description = game.description { Text(description).foregroundStyle(Color.readableSecondary) }
                LabeledContent("Version", value: game.currentVersion)
                LabeledContent("Plateformes", value: game.platforms.map { $0 == "ios" ? "iOS" : $0.capitalized }.joined(separator: ", "))
            }
            Section("Consulter") {
                if game.usesBallparkAnalytics {
                    NavigationLink { BallparkScreen(game: game) } label: { Label("Analyse Ballpark", systemImage: "scope") }
                } else {
                    NavigationLink { DashboardScreen(gameID: game.id).navigationTitle("Indicateurs").navigationBarTitleDisplayMode(.inline) } label: { Label("Indicateurs", systemImage: "chart.xyaxis.line") }
                    NavigationLink { GameplayScreen(game: game) } label: { Label("Gameplay", systemImage: "gamecontroller") }
                    NavigationLink { PlayersScreen(game: game) } label: { Label("Joueurs", systemImage: "person.2") }
                    NavigationLink { ReviewsScreen(game: game) } label: { Label("Avis", systemImage: "text.bubble") }
                }
            }
            if !store.snapshot(game.id).errors.isEmpty { Section { SyncErrors(messages: store.snapshot(game.id).errors) } }
        }.navigationTitle(game.name)
            .toolbar { ContextToolbar(gameID: game.id) }
            .onAppear { store.localSelection(game.id) }
            .onChange(of: store.range) { _, _ in store.localSelection(game.id) }
    }
}

struct GameplayScreen: View {
    @EnvironmentObject var store: MobileStore
    var game: Game
    var body: some View {
        List {
            if let directory = store.snapshot(game.id).directory {
                Section { WorkspaceCaption(generatedAt: Dates.iso(directory.generatedAt)); SyncErrors(messages: store.snapshot(game.id).errors) }
                Section("Activité") { ForEach(directory.kpis) { MetricRow(metric: $0) } }
                Section { EngagementMobile(directory: directory) }
                Section("Modes de jeu") { ForEach(directory.modes) { row in LabeledContent(row.name, value: Display.number(row.value) + " · " + Display.percent(row.share)) } }
                Section("Difficultés") { ForEach(directory.difficulties) { row in LabeledContent(row.name, value: Display.number(row.value) + " · " + Display.percent(row.share)) } }
                Section("Parties terminées par jour") {
                    Chart(directory.trend) { day in BarMark(x: .value("Jour", day.id), y: .value("Parties", day.completions)).foregroundStyle(Color.metrik) }
                        .chartXAxis(.hidden).frame(height: 180)
                    ForEach(directory.trend.reversed()) { day in LabeledContent(day.id, value: "\(day.completions) · \(Display.number(day.minutes, digits: 1)) min") }
                }
                if let note = directory.dataNote { Section { Text(note).font(.callout) } }
            } else { SyncErrors(messages: store.snapshot(game.id).errors); SyncEmpty(gameID: game.id, title: "Gameplay à synchroniser") }
        }.navigationTitle("Gameplay").navigationBarTitleDisplayMode(.inline).toolbar { ContextToolbar(gameID: game.id) }
            .onChange(of: store.range) { _, _ in store.localSelection(game.id) }
    }
}

struct PlayersScreen: View {
    @EnvironmentObject var store: MobileStore
    var game: Game
    @State private var search = ""
    @State private var activeOnly = false
    private var players: [Player] {
        (store.snapshot(game.id).directory?.players ?? []).filter { (!activeOnly || $0.completions > 0) && (search.isEmpty || $0.name.localizedStandardContains(search)) }.sorted { $0.completions > $1.completions }
    }
    var body: some View {
        List {
            if let directory = store.snapshot(game.id).directory {
                Section {
                    WorkspaceCaption(generatedAt: Dates.iso(directory.generatedAt))
                    Toggle("Actifs sur la période", isOn: $activeOnly)
                    Text("\(players.count) joueur(s) · triés par parties terminées").font(.caption).foregroundStyle(Color.readableSecondary)
                    SyncErrors(messages: store.snapshot(game.id).errors)
                }
                ForEach(players) { player in
                    NavigationLink { PlayerScreen(player: player, range: store.range, game: game, generatedAt: directory.generatedAt, timezone: directory.timezone) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.name).font(.headline)
                            Text("\(player.completions) parties · \(Display.number(player.playMinutes, digits: 1)) min").font(.subheadline).foregroundStyle(Color.readableSecondary)
                        }.padding(.vertical, 4)
                    }
                }
                if players.isEmpty { ContentUnavailableView.search(text: search) }
                if let note = directory.entitlementNote { Section { Text(note).font(.caption).foregroundStyle(Color.readableSecondary) } }
                if let note = directory.dataNote { Section { Text(note).font(.caption).foregroundStyle(Color.readableSecondary) } }
            } else { SyncErrors(messages: store.snapshot(game.id).errors); SyncEmpty(gameID: game.id, title: "Joueurs à synchroniser") }
        }.navigationTitle("Joueurs").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Rechercher un joueur")
            .toolbar { ContextToolbar(gameID: game.id) }
            .onChange(of: store.range) { _, _ in store.localSelection(game.id) }
    }
}

struct PlayerScreen: View {
    var player: Player
    var range: Timeframe
    var game: Game
    var generatedAt: Date
    var timezone: String?
    var body: some View {
        List {
            Section { WorkspaceCaption(generatedAt: Dates.iso(generatedAt), gameName: game.name, period: range.label) }
            Section(range.label) {
                LabeledContent("Parties terminées", value: String(player.completions))
                LabeledContent("Temps de jeu", value: Display.number(player.playMinutes, digits: 1) + " min")
                LabeledContent("Durée moyenne", value: Display.number(player.averageMinutes, digits: 1) + " min")
                LabeledContent("Étape d’aventure", value: String(player.adventureStep))
                LabeledContent("Jours actifs", value: String(player.activeDays))
                LabeledContent("Parties par jour actif", value: Display.number(player.completionsPerActiveDay, digits: 1))
                LabeledContent("Série de jours consécutifs", value: String(player.longestStreak))
                LabeledContent("Retour un autre jour", value: player.returnedInPeriod ? "Oui" : "Non observé")
                LabeledContent("Première partie observée", value: player.firstPlayed?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                LabeledContent("Score relatif", value: Display.percent(player.scoreRatio))
                LabeledContent("Parties parfaites", value: Display.percent(player.perfectRate))
                if let last = player.lastPlayed { LabeledContent("Dernière partie", value: last.formatted(date: .abbreviated, time: .shortened)) }
                if let access = player.jardinPaisible { LabeledContent("Jardin paisible", value: access ? "Actif" : "Inactif") }
            }
            Section("Par partie") {
                LabeledContent("Coups", value: Display.number(player.moves, digits: 1))
                LabeledContent("Indices", value: Display.number(player.hints, digits: 1))
                LabeledContent("Erreurs", value: Display.number(player.mistakes, digits: 1))
                LabeledContent("Annulations", value: Display.number(player.undos, digits: 1))
            }
            Section("Modes de jeu") { ForEach(player.modes) { row in LabeledContent(row.name, value: Display.number(row.value)) } }
            Section("Difficultés") { ForEach(player.difficulties) { row in LabeledContent(row.name, value: Display.number(row.value)) } }
            Section("Activité quotidienne") { ForEach(player.trend.reversed()) { day in LabeledContent(day.id, value: "\(day.completions) parties · \(Display.number(day.minutes, digits: 1)) min") } }
            Section { CompletionHoursMobile(hours: player.completionHours, timezone: timezone) }
            Section { Text("Fiche temporaire, effacée au verrouillage. Les jours actifs et retours observés portent uniquement sur la période sélectionnée.").font(.caption).foregroundStyle(Color.readableSecondary) }
        }.navigationTitle(player.name).navigationBarTitleDisplayMode(.inline)
    }
}

struct ReviewsScreen: View {
    @EnvironmentObject var store: MobileStore
    var game: Game
    var body: some View {
        List {
            Section { WorkspaceCaption(); Text("Avis déjà collectés dans GameMetrik, sur \(store.range.label.lowercased()).").font(.caption).foregroundStyle(Color.readableSecondary); SyncErrors(messages: store.snapshot(game.id).errors) }
            if let reviews = store.snapshot(game.id).reviews {
                if reviews.isEmpty { ContentUnavailableView("Aucun avis sur cette période", systemImage: "text.bubble") }
                ForEach(reviews) { review in
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(review.rating)/5 · \(review.country)", systemImage: "star.fill").font(.subheadline).foregroundStyle(Color.readableSecondary)
                        if let title = review.title { Text(title).font(.headline) }
                        Text(review.body)
                        Text("\(review.provider) · \(Dates.parse(review.publishedAt)?.formatted(date: .abbreviated, time: .omitted) ?? review.publishedAt)").font(.caption).foregroundStyle(Color.readableSecondary)
                    }.padding(.vertical, 8)
                }
            } else { SyncEmpty(gameID: game.id, title: "Avis à synchroniser") }
        }.navigationTitle("Avis").navigationBarTitleDisplayMode(.inline).toolbar { ContextToolbar(gameID: game.id) }
            .onChange(of: store.range) { _, _ in store.localSelection(game.id) }
    }
}

struct RevenueMobile: View {
    let details: RevenueDetails
    @State private var dimension: RevenueDimension = .country
    @State private var currency = ""
    var body: some View {
        DisclosureGroup("Répartition des revenus") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Répartition", selection: $dimension) { ForEach(RevenueDimension.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                if details.currencies.count > 1 { Picker("Devise", selection: $currency) { ForEach(details.currencies, id: \.self) { Text($0).tag($0) } } }
                ForEach(details.breakdown(dimension, currency: resolvedCurrency)) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.subheadline)
                        Text(Display.amount(row.value, currency: resolvedCurrency)).monospacedDigit()
                        if let share = row.share { Text(Display.percent(share)).font(.caption).foregroundStyle(Color.readableSecondary) }
                    }
                }
                Text(details.note).font(.caption).foregroundStyle(Color.readableSecondary)
            }.padding(.top, 12)
        }
    }
    private var resolvedCurrency: String { details.currencies.contains(currency) ? currency : details.currencies[0] }
}

struct EngagementMobile: View {
    let directory: PlayerDirectory
    var body: some View {
        DisclosureGroup("Régularité et retours") {
            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("Profils revenus un autre jour", value: String(directory.returningPlayers))
                LabeledContent("Profils actifs", value: String(directory.profiledActivePlayers))
                LabeledContent("Part des trois plus actifs", value: Display.percent(directory.topThreeShare))
                Text("Un retour signifie une partie terminée sur au moins deux jours distincts de la période, pas une rétention J7. La concentration porte sur les parties reliées aux profils disponibles.")
                    .font(.caption).foregroundStyle(Color.readableSecondary)
                ForEach(directory.activityGroups) { group in
                    DisclosureGroup(group.group.label) {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Profils", value: String(group.players))
                            LabeledContent("Parties", value: String(group.completions))
                            LabeledContent("Temps de jeu", value: Display.number(group.minutes, digits: 1) + " min")
                            LabeledContent("Durée moyenne", value: Display.number(group.averageMinutes, digits: 1) + " min")
                            LabeledContent("Indices par partie", value: Display.number(group.hints, digits: 1))
                            LabeledContent("Erreurs par partie", value: Display.number(group.mistakes, digits: 1))
                        }.padding(.vertical, 8)
                    }
                }
                Text("\(directory.profiledCompletions)/\(directory.completions) parties reliées aux profils. Les groupes décrivent la fréquence dans cette période, pas l’ancienneté.")
                    .font(.caption).foregroundStyle(Color.readableSecondary)
                CompletionHoursMobile(hours: directory.completionHours, timezone: directory.timezone)
            }.padding(.vertical, 12)
        }.accessibilityIdentifier("engagement")
    }
}

struct CompletionHoursMobile: View {
    let hours: [CompletionHour]
    let timezone: String?
    var body: some View {
        DisclosureGroup("Heures de fin des parties") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Heure locale de fin · \(timezone ?? "fuseau non disponible"). Ce relevé ne mesure ni les ouvertures de session ni le temps passé dans chaque heure.")
                    .font(.caption).foregroundStyle(Color.readableSecondary)
                if hours.contains(where: { $0.completions > 0 }) {
                    ForEach(hours) { hour in LabeledContent("\(hour.hour) h", value: "\(hour.completions) parties") }
                } else { Text("Aucune partie terminée à répartir.").foregroundStyle(Color.readableSecondary) }
            }.padding(.vertical, 8)
        }
    }
}
