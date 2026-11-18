import SwiftUI
import GameMetrikCore

@main struct GameMetrikApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    var body: some Scene {
        Window("GameMetrik Native", id: "main") {
            SecureRootView().environmentObject(state)
                .tint(.metrik).preferredColorScheme(state.colorScheme)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Exporter les données…") { state.showingExport = true }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!state.canPresentExport)
                Button("Verrouiller GameMetrik") { state.lock() }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(state.isLocked)
                Button("Synchroniser la sélection") { state.synchronizeSelection() }.keyboardShortcut("r").disabled(state.loading || state.isLocked)
                Button("Relire tous les rapports de la sélection") { state.synchronizeSelection(mode: .full) }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(state.loading || state.isLocked)
            }
            CommandMenu("Navigation") {
                ForEach(Array(Destination.allCases.enumerated()), id: \.element.id) { index, page in
                    Button(page.title) { state.destination = page }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                        .disabled(state.isLocked || !state.canNavigate(to: page))
                }
                Divider()
                Button("Tout le studio") { state.gameID = "all"; state.destination = .dashboard }.disabled(state.isLocked)
            }
            SidebarCommands()
        }
        Settings {
            SecureSettingsView().environmentObject(state).preferredColorScheme(state.colorScheme).tint(.metrik)
        }
    }
}

struct LockedView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("GameMetrik est verrouillé").font(.title2.weight(.semibold))
            Text("Déverrouille tes connexions avec Touch ID ou le mot de passe de ton Mac.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 390)
            Button(state.unlocking ? "Authentification…" : "Déverrouiller") { state.unlock() }.buttonStyle(.borderedProminent).disabled(state.unlocking)
            if let message = state.lockMessage { Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420) }
            Text("Verrouillage automatique à la veille, au verrouillage du Mac et après 5 minutes d’inactivité.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 390)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
    }
}
struct SecureRootView: View {
    @EnvironmentObject var state: AppState
    var body: some View { if state.isLocked { LockedView() } else { RootView() } }
}
struct SecureSettingsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Group { if state.isLocked { LockedView() } else { SettingsView() } }.frame(width: 650, height: 650)
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        NavigationSplitView {
            List(selection: $state.destination) {
                Section("Studio") {
                    ForEach([Destination.dashboard, .library]) { page in
                        Label(page.title, systemImage: page.symbol).tag(page)
                    }
                }
                if state.game?.usesBallparkAnalytics == true {
                    Section("Ballpark") {
                        Label(Destination.ballpark.title, systemImage: Destination.ballpark.symbol).tag(Destination.ballpark)
                    }
                } else {
                    Section("Comprendre les joueurs") {
                        ForEach([Destination.gameplay, .players, .reviews] + (state.canNavigate(to: .auroraJourney) ? [.auroraJourney, .auroraInsights] : [])) { page in
                            Label(page.title, systemImage: page.symbol).tag(page)
                        }
                    }
                }
                Section("Mes jeux") {
                    ForEach(state.games) { game in
                        Button { state.selectGame(game) } label: {
                            HStack(spacing: 9) {
                                GameIcon(game: game, size: 28)
                                Text(game.name).lineLimit(1)
                                Spacer(minLength: 0)
                                if state.gameID == game.id { Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical, 3)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("GameMetrik")
            .navigationSplitViewColumnWidth(min: 190, ideal: 222, max: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(state.demo ? "Démonstration" : "Espace réel", systemImage: state.demo ? "sparkle.magnifyingglass" : "person.crop.circle.badge.checkmark")
                        .font(.subheadline.weight(.medium))
                    Text(state.demo ? "Explore avec des données fictives." : state.identityLabel)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    SettingsLink { Label("Réglages", systemImage: "gearshape") }.buttonStyle(.borderless)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.bar)
            }
        } detail: {
            WorkspaceDetailView()
            .navigationTitle(state.destination?.title ?? "Vue d’ensemble")
            .navigationSubtitle(state.game?.name ?? "Tout le studio")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if state.destination != .library {
                        Picker("Jeu", selection: $state.gameID) {
                            Text("Tout le studio").tag("all")
                            ForEach(state.games) { Text($0.name).tag($0.id) }
                        }.frame(maxWidth: 180).help("Choisir le jeu à analyser")
                    }
                    if state.destination != .library && state.destination != .reviews {
                        Picker("Période", selection: $state.range) { ForEach(Timeframe.allCases) { Text($0.label).tag($0).disabled($0 == .all && !state.supportsAllTime) } }
                            .frame(width: 115).help("Période d’analyse")
                    }
                    Button { state.synchronizeSelection() } label: { Label("Synchroniser", systemImage: "arrow.clockwise") }
                        .disabled(state.loading || state.isLocked).help(state.synchronizationHelp)
                        .contextMenu {
                            Button("Relire tous les rapports de la sélection") { state.synchronizeSelection(mode: .full) }
                                .disabled(state.loading || state.isLocked)
                        }
                    Button { state.showingExport = true } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
                        .disabled(!state.canPresentExport).help("Préparer et exporter les données en CSV et JSON (⇧⌘E)")
                }
            }
        }
        .onChange(of: state.gameID) { _, _ in state.ensureCompatibleDestination() }
        .onChange(of: state.destination) { _, _ in state.ensureCompatibleGame() }
        .task(id: state.refreshKey) { state.refresh(mode: .local) }
        .sheet(isPresented: $state.showingExport) { ExportView().environmentObject(state) }
    }
}

/// Fills the detail column even when it contains only an empty or failed state.
struct WorkspaceDetailView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            if let deadline = state.idleLockDeadline {
                IdleLockWarning(deadline: deadline, syncing: state.loading) { state.stayUnlocked() }
            }
            if !state.demo {
                HStack {
                    Text(state.lastSyncText).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 2)
            }
            ZStack {
            Group {
            if let error = state.currentViewError {
                ContentUnavailableView {
                    Label("Données indisponibles", systemImage: "wifi.exclamationmark")
                } description: { Text(error).frame(maxWidth: 480) } actions: {
                    Button("Réessayer") { state.synchronizeSelection() }
                    SettingsLink { Text("Ouvrir les réglages") }
                }
            } else if state.needsGame && state.game == nil && !state.loading {
                ContentUnavailableView {
                    Label("Choisir un jeu", systemImage: "gamecontroller")
                } description: { Text("Le gameplay et les joueurs se consultent jeu par jeu.") } actions: {
                    Menu("Sélectionner un jeu") { ForEach(state.games) { game in Button(game.name) { state.gameID = game.id } } }
                }
            } else if !state.demo && state.loadedAt == nil && !state.loading {
                ContentUnavailableView {
                    Label("Données à synchroniser", systemImage: "arrow.clockwise")
                } description: {
                    Text(state.synchronizationEmptyDescription)
                } actions: {
                    Button("Synchroniser") { state.synchronizeSelection() }
                }
            } else {
                switch state.destination ?? .dashboard {
                case .dashboard: DashboardView()
                case .library: LibraryView()
                case .gameplay: GameplayView()
                case .players: PlayersView().id(state.gameID + String(state.demo))
                case .reviews: ReviewsView()
                case .ballpark: BallparkAnalyticsView()
                case .auroraJourney: AuroraJourneyView()
                case .auroraInsights: AuroraInsightsView()
                }
            }
            }
            .opacity(state.blocksContent ? 0 : 1)
            .allowsHitTesting(!state.blocksContent)
            if state.blocksContent {
                VStack(spacing: 14) {
                    ProgressView(state.syncProgress ?? "Lecture des données…")
                    if state.syncProgress != nil { Text("Récupération des rapports à actualiser").font(.caption).foregroundStyle(.secondary) }
                    Button("Annuler") { state.cancelRefresh() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = state.cacheMessage, state.destination == .dashboard {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if let summary = state.studioSyncSummary, !state.loading {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary).font(.caption)
                    let issues = state.studioSyncResults.filter { ["failed", "partial", "not_connected"].contains($0.status) }
                    if !issues.isEmpty {
                        DisclosureGroup("Disponibilité des données (\(issues.count))") {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                        Text(issue.section + " : " + issue.detail).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }.frame(maxHeight: 120)
                        }.font(.caption)
                    }
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 8)
            }
            Divider()
            HStack(spacing: 8) {
                Circle().fill(state.demo ? Color.orange : !state.hasLiveIdentity ? Color.secondary : Color.metrik).frame(width: 6, height: 6)
                Text(state.statusText)
                Spacer()
                if state.loading && state.hasVisibleDashboard {
                    ProgressView().controlSize(.small)
                    Text(state.syncProgress ?? "Mise à jour…").lineLimit(1)
                    Button("Annuler") { state.cancelRefresh() }
                }

            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 8).background(.bar)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Shown during the last 30 seconds before the inactivity lock, so a watched sync is not lost.
struct IdleLockWarning: View {
    let deadline: Date
    let syncing: Bool
    let stay: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock").foregroundStyle(.orange)
            Text("Verrouillage automatique par inactivité dans")
            Text(timerInterval: min(Date(), deadline)...deadline, countsDown: true).monospacedDigit()
            if syncing { Text("· la synchronisation en cours serait annulée.").foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Button("Rester déverrouillé", action: stay).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .font(.callout).padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("GameMetrik va se verrouiller par inactivité")
    }
}

struct GameIcon: View {
    let game: Game
    var size: CGFloat = 44
    var color: Color { game.slug == "aurora-grove" ? .metrik : game.slug == "orbit-tactics" ? .indigo : .orange }
    var body: some View {
        Text(game.icon.count <= 3 ? game.icon : String(game.name.prefix(2)).uppercased())
            .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
            .foregroundStyle(color).frame(width: size, height: size)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

enum Display {
    static func number(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0...digits)).locale(Locale(identifier: "fr_CH")))
    }
    static func money(_ value: Double?, currency: String = "CHF", precise: Bool = false) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.currency(code: currency).precision(.fractionLength(precise ? 4 : 2)).locale(Locale(identifier: "fr_CH")))
    }
    static func percent(_ value: Double?) -> String { value.map { number($0, digits: 1) + " %" } ?? "—" }
    static func duration(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 60 { return number(value, digits: 1) + " min" }
        return "\(Int(value / 60)) h \(Int(value.truncatingRemainder(dividingBy: 60)))"
    }
    static func currencyLines(_ amounts: [String: Double], precise: Bool = false) -> [String] {
        let nonzero = amounts.filter { $0.value != 0 }
        return (nonzero.isEmpty ? amounts : nonzero).sorted { $0.key < $1.key }.map {
            $0.key + " " + $0.value.formatted(.number.precision(.fractionLength(precise ? 4 : 2)).locale(Locale(identifier: "fr_CH")))
        }
    }
    static func metricLines(_ kpi: KPI, currency: String) -> [String] {
        if let amounts = kpi.amountsByCurrency, !amounts.isEmpty {
            return currencyLines(amounts, precise: kpi.id == "arpdau")
        }
        return [self.kpi(kpi, currency: currency)]
    }
    static func revenue(_ point: TrendPoint, currency: String) -> String {
        if let amounts = point.revenueByCurrency, !amounts.isEmpty { return currencyLines(amounts).joined(separator: " · ") }
        return DashboardMetric.revenue.value(point).map { money($0, currency: currency) } ?? "Non disponible"
    }
    static func coverage(_ coverage: KPI.Coverage) -> String {
        switch coverage.status {
        case "pending": return "Rapports récents en attente · \(coverage.availableDays)/\(coverage.expectedDays) jours complets"
        case "not_configured": return "Source à configurer"
        case "missing": return "Aucune donnée reçue"
        default: return "Données partielles · \(coverage.availableDays)/\(coverage.expectedDays) jours complets"
        }
    }
    static func kpi(_ kpi: KPI, currency: String) -> String {
        guard kpi.state == "available" else { return "—" }
        if let amounts = kpi.amountsByCurrency, !amounts.isEmpty {
            return currencyLines(amounts, precise: kpi.id == "arpdau").joined(separator: " · ")
        }
        switch kpi.unit {
        case "currency": return money(kpi.value, currency: currency, precise: kpi.id == "arpdau")
        case "percent": return percent(kpi.value)
        case "duration": return duration(kpi.value)
        default: return number(kpi.value)
        }
    }
}

struct MetricGrid: View {
    var kpis: [KPI]
    var currency = "CHF"
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: kpis.count == 6 ? 250 : 190), spacing: 12)], spacing: 12) {
            ForEach(kpis) { kpi in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(kpi.label).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 0)
                        if let hint = kpi.hint { Image(systemName: "info.circle").foregroundStyle(.tertiary).help(hint) }
                    }
                    ForEach(Display.metricLines(kpi, currency: currency), id: \.self) { line in
                        Text(line).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                    }
                    if let change = kpi.change, kpi.state == "available" {
                        let favorable = kpi.changeDirection == "lower-is-better" ? change < 0 : change > 0
                        Text("\(change > 0 ? "+" : "")\(Display.percent(change)) · période précédente")
                            .font(.caption).foregroundStyle(kpi.changeDirection == "neutral" || change == 0 ? Color.secondary : favorable ? .metrik : .orange)
                    } else {
                        Text(kpi.state == "available" ? kpi.source : "Donnée non disponible").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let coverage = kpi.coverage, coverage.status != "complete" {
                        Text(Display.coverage(coverage))
                            .font(.caption).foregroundStyle(coverage.status == "pending" ? Color.secondary : Color.orange)
                            .help("Un jour complet dispose de données pour toutes les sources de cet indicateur. Les valeurs reçues des autres jours restent incluses dans le total partiel.")
                    }
                }.padding(16).frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                    .accessibilityElement(children: .combine)
            }
        }
    }
}


extension ShapeStyle where Self == Color {
    static var metrik: Color {
        Color(nsColor: NSColor(name: NSColor.Name("GameMetrikAccent")) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.51, green: 0.83, blue: 0.70, alpha: 1)
            }
            return NSColor(srgbRed: 0.078, green: 0.408, blue: 0.306, alpha: 1)
        })
    }
}
