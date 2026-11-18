import SwiftUI
import Charts
import GameMetrikCore

struct BreakdownView: View {
    let title: String
    let rows: [Breakdown]
    var currency: String? = nil
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 15) {
                Text(title).font(.headline)
                if rows.isEmpty { Text("Aucune donnée disponible").foregroundStyle(.secondary).padding(.vertical, 20) }
                ForEach(rows) { row in
                    VStack(spacing: 6) {
                        HStack {
                            Text(row.name)
                            Spacer()
                            Text(currency.map { Display.money(row.value, currency: $0) } ?? Display.number(row.value)).monospacedDigit()
                            Text(Display.percent(row.share)).foregroundStyle(.secondary).frame(width: 55, alignment: .trailing).monospacedDigit()
                        }
                        ProgressView(value: min(max(row.share, 0), 100), total: 100).tint(.metrik).accessibilityLabel(row.name)
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, alignment: .top)
    }
}

struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    var filtered: [Game] { state.games.filter { search.isEmpty || $0.name.localizedStandardContains(search) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tes jeux, au même endroit").font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(state.games.count) jeux").foregroundStyle(.secondary)
                }
                ForEach(filtered) { game in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 16) {
                                GameIcon(game: game, size: 56)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(game.name).font(.title3.weight(.semibold))
                                    Text(game.description ?? "").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 12)
                                Text(game.statusLabel).font(.caption.weight(.medium)).foregroundStyle(game.status == "active" ? .metrik : .secondary)
                                    .padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary, in: Capsule())
                            }
                            HStack {
                                Text(game.platforms.map { $0 == "ios" ? "iOS" : "Android" }.joined(separator: " + ") + "  ·  Version " + game.currentVersion).font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                if game.usesBallparkAnalytics {
                                    Button("Analyser les données produit") { state.selectGame(game) }.buttonStyle(.borderedProminent)
                                } else {
                                    Button("Joueurs") { state.selectGame(game, page: .players) }
                                    Button("Gameplay") { state.selectGame(game, page: .gameplay) }
                                    Button("Voir les performances") { state.selectGame(game) }.buttonStyle(.borderedProminent)
                                }
                            }
                        }.padding(16)
                    }
                }
                if filtered.isEmpty { ContentUnavailableView.search(text: search) }
                Text("Le catalogue réel est lu depuis ton espace GameMetrik. L’ajout et la configuration des jeux restent gérés dans l’application existante.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.searchable(text: $search, prompt: "Rechercher un jeu")
    }
}

struct GameplayView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let directory = state.directory {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack { Text("Comment on joue à \(state.game?.name ?? "ce jeu")").font(.title2.weight(.semibold)); Spacer() }
                    if let note = state.connectedAccountsNote {
                        Label(note, systemImage: "person.crop.circle.badge.checkmark").font(.callout).foregroundStyle(.secondary)
                    }
                    if let note = directory.dataNote {
                        Label(note, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    }
                    MetricGrid(kpis: directory.kpis)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Parties terminées").font(.headline)
                            ActivityChart(days: directory.trend).frame(height: 240)
                        }.padding(12)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        BreakdownView(title: "Modes de jeu", rows: directory.modes)
                        BreakdownView(title: "Difficultés", rows: directory.difficulties)
                    }
                    PlayerEngagementView(directory: directory)
                    Button("Explorer les \(directory.players.count) profils") { state.destination = .players }
                    Text("Une activité correspond à une partie terminée. Les sessions sans partie terminée ne sont pas mesurées ici.").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
        } else { ContentUnavailableView("Aucune activité disponible", systemImage: "gamecontroller") }
    }
}
struct ActivityChart: View {
    let days: [PlayerDay]
    var body: some View {
        if days.isEmpty {
            ContentUnavailableView("Aucune partie sur cette période", systemImage: "chart.bar")
        } else {
            InteractiveActivityChart(days: days)
        }
    }
}

struct ReviewsView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    var filtered: [Review] { state.reviews.filter { (state.gameID == "all" || $0.gameId == state.gameID) && (search.isEmpty || ($0.body + ($0.title ?? "") + $0.gameName).localizedStandardContains(search)) } }
    var body: some View {
        List(filtered) { review in
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(review.title ?? review.gameName).font(.headline)
                    Spacer()
                    HStack(spacing: 2) { ForEach(0..<5) { i in Image(systemName: i < review.rating ? "star.fill" : "star").foregroundStyle(.orange) } }
                        .accessibilityLabel("\(review.rating) étoiles sur 5")
                }
                Text(review.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("\(review.gameName) · \(review.provider == "apple" ? "App Store" : "Google Play") · \(review.country) · \(Dates.parse(review.publishedAt)?.formatted(date: .abbreviated, time: .omitted) ?? review.publishedAt)")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
        .overlay { if filtered.isEmpty { ContentUnavailableView("Aucun avis", systemImage: "text.bubble", description: Text("Aucun avis ne correspond à cette sélection.")) } }
        .searchable(text: $search, prompt: "Rechercher dans les avis")
    }
}
