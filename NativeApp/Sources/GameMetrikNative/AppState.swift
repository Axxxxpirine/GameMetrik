import SwiftUI
import AuthenticationServices
import Security
import UniformTypeIdentifiers
import GameMetrikCore

struct PersonalOrganization: Decodable, Identifiable { var id: String; var name: String? }

struct LocalViewSnapshot {
    var dashboard: Dashboard?
    var directory: PlayerDirectory?
    var reviews: [Review]
    var date: Date
    var ballpark: BallparkAnalyticsData? = nil
    var auroraJourney: AuroraJourneyBundle? = nil
    var auroraInsights: AuroraInsightsBundle? = nil
}

// Local restoration never fetches. Incremental and full are explicit user actions.
enum RefreshMode { case local, incremental, full }

enum Destination: String, CaseIterable, Identifiable {
    case dashboard, library, gameplay, players, reviews, ballpark, auroraJourney, auroraInsights
    var id: String { rawValue }
    var title: String {
        switch self { case .dashboard: "Vue d’ensemble"; case .library: "Bibliothèque"; case .gameplay: "Gameplay"; case .players: "Joueurs"; case .reviews: "Avis"; case .ballpark: "Analyse Ballpark"; case .auroraJourney: "Parcours"; case .auroraInsights: "Activité et jeu" }
    }
    var symbol: String {
        switch self { case .dashboard: "chart.xyaxis.line"; case .library: "square.grid.2x2"; case .gameplay: "gamecontroller"; case .players: "person.2"; case .reviews: "text.bubble"; case .ballpark: "scope"; case .auroraJourney: "point.topleft.down.to.point.bottomright.curvepath"; case .auroraInsights: "chart.bar.xaxis" }
    }
}

@MainActor final class BrowserAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
    func start(config: NativeConfiguration, pkce: PKCE) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            session = ASWebAuthenticationSession(url: pkce.authorizationURL(config: config), callbackURLScheme: config.callbackScheme) { [weak self] url, error in
                Task { @MainActor in self?.session = nil }
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? GameMetrikError.message("Connexion annulée.")) }
            }
            session?.presentationContextProvider = self
            session?.prefersEphemeralWebBrowserSession = true
            if session?.start() != true { session = nil; continuation.resume(throwing: GameMetrikError.message("La fenêtre de connexion n’a pas pu s’ouvrir.")) }
        }
    }
    func cancel() { session?.cancel(); session = nil }
}

@MainActor final class AppState: ObservableObject {
    @Published var isLocked = true
    @Published var unlocking = false
    @Published var lockMessage: String?
    private var unlockContext: UnlockContext?
    private var unlockTask: Task<Void, Never>?
    private var securityGeneration = 0
    private(set) var securityMonitor: SecurityMonitor?
    /// Set during the last 30 seconds before the automatic inactivity lock.
    @Published var idleLockDeadline: Date?
    @Published var destination: Destination? = .dashboard
    @Published var gameID = "all" { didSet { if gameID != oldValue { selectedPlayerID = nil; dashboard = nil; directory = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil } } }
    @Published var selectedPlayerID: String?
    @Published var range: Timeframe = .month
    @Published var demo = true
    @Published var games = Demo.games
    @Published var dashboard: Dashboard?
    @Published var directory: PlayerDirectory?
    @Published var reviews: [Review] = []
    @Published var ballparkAnalytics: BallparkAnalyticsData?
    @Published var auroraJourney: AuroraJourneyBundle?
    /// Complete collection (1.6.0+), loaded with the journey; its population is chosen in its own view.
    @Published var auroraInsights: AuroraInsightsBundle?
    @Published var auroraInsightsPopulation: AuroraInsightsPopulation = AuroraInsightsPopulation(rawValue: UserDefaults.standard.string(forKey: "aurora.insights.population") ?? "") ?? .production {
        didSet { if !headless, auroraInsightsPopulation != oldValue { UserDefaults.standard.set(auroraInsightsPopulation.rawValue, forKey: "aurora.insights.population") } }
    }
    @Published var loading = false
    @Published var syncProgress: String?
    @Published var studioSyncResults: [ExportCheck] = []
    @Published var studioSyncSummary: String?
    private var synchronizingViews = false
    @Published var cacheMessage: String?
    @Published var showingCachedDashboard = false
    var aggregateCache: AggregateCache?
    var aggregateCacheKey: Data?
    var aggregateCacheScope: String?
    private var aggregateStore: AggregateCacheStore {
        AggregateCacheStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameMetrik/AggregateCache", isDirectory: true))
    }
    var hasVisibleDashboard: Bool {
        destination == .dashboard && dashboard?.gameId == (gameID == "all" ? nil : gameID) && dashboard?.timeframe == range
    }
    var blocksContent: Bool { loading && !hasVisibleDashboard }

    @Published var reportBucket = ""
    @Published var appleVendor = ""
    @Published var appleIssuerID = ""
    @Published var appleKeyID = ""
    @Published var googlePlayOverrides: [String: Bool] = [:]
    @Published var error: String?
    @Published var settingsMessage: String?
    @Published var webConfigurationAudit: WebConfigurationAudit?
    @Published var config: NativeConfiguration?
    @Published var supabaseProjects: [SupabaseConfiguration] = []
    @Published var session: AuthSession?
    @Published var membership: Membership?
    @Published var connectionChecks: [ConnectionCheck] = []
    @Published var checkingConnections = false
    @Published var hasAppleConfiguration = false
    private var checkTask: Task<Void, Never>?
    private var checkGeneration = 0
    @Published var personalReady = false
    @Published var personalProject = ""
    @Published var personalSummary: [String] = []
    @Published var personalOrganizations: [PersonalOrganization] = []
    @Published var personalOrganization = ""
    @Published var accessMode = "personal"
    @Published var authenticating = false
    @Published var organization = ""
    @Published var theme = "system" {
        didSet { UserDefaults.standard.set(theme, forKey: "appearance") }
    }
    var loadedContextKey: String?
    @Published var loadedAt: Date? { didSet { loadedContextKey = loadedAt == nil ? nil : refreshKey } }
    @Published var showingExport = false
    /// Root of the opt-in AI folder, nil when disabled; see AIFolderState.swift.
    @Published var aiFolderPath: String?
    @Published var aiFolderMessage: String?
    /// Whether an assistant may request synchronizations (AI copy of the connections in the Keychain).
    @Published var aiSyncEnabled = UserDefaults.standard.bool(forKey: "ai.sync.enabled") {
        didSet { if !headless { UserDefaults.standard.set(aiSyncEnabled, forKey: "ai.sync.enabled") } }
    }
    /// The last AI folder write, awaited by the background synchronization before reporting.
    var aiFolderWrite: Task<Void, Never>?
    var exportPanel: NSOpenPanel?
    @Published var preparingExport = false
    @Published var exportSyncResults: [ExportCheck] = []
    var exportSyncContext: String?
    private var personal: PersonalConnections?
    var exportPlayerTimezone: String? { playerTimezone(for: game) }
    func playerTimezone(for game: Game?) -> String? {
        if demo { return Demo.timezone.identifier }
        guard let ref = game?.integrations.supabaseProjectRef else { return nil }
        return accessMode == "personal" ? personal?.supabase.first { $0.ref == ref }?.timezone : supabaseProjects.first { $0.ref == ref }?.timezone
    }
    private var personalTokens = ServiceAccountTokens()
    private let authentication = BrowserAuthentication()
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var activeRefreshKey: String?
    @Published var localViewFailures: [String: String] = [:]
    var localViews: [String: LocalViewSnapshot] = [:]
    var currentViewError: String? {
        if let error { return error }
        guard !loading, loadedContextKey != refreshKey else { return nil }
        return localViewFailures[localViewKey]
    }
    var supportsAllTime: Bool {
        destination != .ballpark && !(!demo && accessMode == "personal" && (destination ?? .dashboard) == .dashboard)
    }
    /// A disabled Picker option can still be restored from preferences or another page.
    func ensureCompatibleRange() {
        if range == .all && !supportsAllTime { range = .year }
    }
    private var localViewKey: String { localViewKey(for: destination ?? .dashboard) }
    func localViewKey(for destination: Destination, gameID: String? = nil) -> String {
        let page = destination == .players || destination == .gameplay ? "players-and-gameplay" : destination.rawValue
        return [String(demo), accessMode, personalOrganization, personal?.projectID ?? "", session?.uid ?? "", config?.projectID ?? "", gameID ?? self.gameID, range.rawValue, page].joined(separator: "|")
    }
    var lastSyncText: String {
        loadedAt.map { "Dernière synchronisation : " + $0.formatted(date: .abbreviated, time: .shortened) }
            ?? "Aucune synchronisation pour cette vue"
    }
    private var authGeneration = 0
    private var http: HTTPClient
    var game: Game? { games.first { $0.id == gameID } }
    var synchronizationHelp: String {
        if !demo, accessMode == "personal", range == .all {
            if let game { return "Synchroniser Gameplay, Joueurs, Avis" + (game.usesAuroraJourney ? " et Parcours" : "") + " de \(game.name) sur tout l’historique (⌘R)" }
            return "Synchroniser les Avis de Tout le studio (⌘R). La vue d’ensemble nécessite une période de 1 jour à 1 an."
        }
        if let game { return "Synchroniser toutes les rubriques de \(game.name) sur la période choisie (⌘R)" }
        return "Synchroniser la vue agrégée Tout le studio sur la période choisie (⌘R)"
    }
    var synchronizationEmptyDescription: String {
        if !demo, accessMode == "personal", range == .all {
            if let game { return "Synchronise Gameplay, Joueurs, Avis" + (game.usesAuroraJourney ? " et Parcours" : "") + " de \(game.name) sur tout l’historique. La vue d’ensemble nécessite une période de 1 jour à 1 an." }
            return "Synchronise les Avis de Tout le studio. La vue d’ensemble nécessite une période de 1 jour à 1 an."
        }
        if let game { return "Synchronise \(game.name) pour charger toutes ses rubriques sur la période choisie." }
        return "Synchronise Tout le studio pour charger sa vue agrégée sur la période choisie."
    }
    var hasBallparkConnection: Bool { personal?.supabase.contains { $0.ref == Game.ballparkProjectRef } == true }
    var refreshKey: String { "\(accessMode)-\(personalOrganization)-\(demo)-\(gameID)-\(range.rawValue)-\(destination?.rawValue ?? "")" }
    var colorScheme: ColorScheme? { theme == "dark" ? .dark : theme == "light" ? .light : nil }
    /// Profiles and completed games come from signed-in accounts only; since 1.3.0 most Aurora Grove players are guests.
    var connectedAccountsNote: String? {
        guard game?.usesAuroraJourney == true else { return nil }
        return "Comptes connectés uniquement (Apple ou Google) — " + (canNavigate(to: .auroraJourney)
            ? "les invités sont mesurés dans Parcours." : "les invités n’y figurent pas ; ils sont mesurés dans Parcours en Administration personnelle.")
    }
    var needsGame: Bool { destination == .players || destination == .gameplay || destination == .ballpark || destination == .auroraJourney || destination == .auroraInsights }
    var hasLiveIdentity: Bool { accessMode == "personal" ? !personalOrganization.isEmpty && personalReady : membership != nil }
    var identityLabel: String { accessMode == "personal" ? (personalReady ? "Administration personnelle" : "Connexions à importer") : session?.email ?? "Aucun compte connecté" }
    var statusText: String {
        if demo { return "Démonstration · données fictives" }
        if accessMode == "personal" { return personalReady ? "Administration personnelle · " + (personalOrganizations.first(where: { $0.id == personalOrganization })?.name ?? personalProject) : "Espace réel · connexions à importer" }
        return membership.map { "Espace réel · \($0.organization)" } ?? "Espace réel · connexion requise"
    }
    /// A background instance for an assistant's request: never shown, never saves the window's selection.
    let headless: Bool
    init(http: HTTPClient? = nil, headless: Bool = false) {
        self.http = http ?? Self.privateHTTP()
        self.headless = headless
        // Owner confirmed on 7 September 2026 that Aurora Grove is published only on iOS.
        googlePlayOverrides = UserDefaults.standard.dictionary(forKey: "sources.googlePlay") as? [String: Bool] ?? ["aurora-grove": false]
        theme = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        loadAIFolderPreference()
        config = UserDefaults.standard.data(forKey: "firebase.native").flatMap { try? JSONDecoder().decode(NativeConfiguration.self, from: $0) }
        organization = config?.organizationID ?? ""
        supabaseProjects = UserDefaults.standard.data(forKey: "supabase.public").flatMap { try? SupabaseConfiguration.read($0) } ?? []
        accessMode = UserDefaults.standard.string(forKey: "access.mode") ?? "personal"
        personalOrganization = UserDefaults.standard.string(forKey: "personal.organization") ?? ""
        demo = !UserDefaults.standard.bool(forKey: "personal.live")
        // Each mode keeps its own navigation; a live launch must not reuse the demo selection.
        gameID = UserDefaults.standard.string(forKey: demo ? "demo.game" : "live.game") ?? "all"
        range = Timeframe(rawValue: UserDefaults.standard.string(forKey: demo ? "demo.range" : "live.range") ?? "30d") ?? .month
        games = []
        ensureCompatibleRange()
        securityMonitor = SecurityMonitor(lock: { [weak self] in self?.lock() }, warn: { [weak self] deadline in
            guard let self else { return }
            self.idleLockDeadline = self.isLocked ? nil : deadline
        }, idleLocks: !headless)
    }
    /// Opens the background instance with the owner's AI copy of the connections; the window stays locked.
    func startHeadless(_ bundle: AISyncBundle) {
        guard headless else { return }
        demo = false; accessMode = "personal"; personalOrganization = bundle.organization
        applyPersonal(bundle.connections)
        aggregateCacheKey = bundle.cacheKey
        isLocked = false
    }
    /// Keeps the AI copy aligned with the connections and organization in use, without asking for Touch ID.
    func updateAISyncBundle() {
        guard !headless, let personal, !personalOrganization.isEmpty, var bundle = try? AIVault.read() else { return }
        guard bundle.organization != personalOrganization || (try? JSONEncoder().encode(bundle.connections)) != (try? JSONEncoder().encode(personal)) else { return }
        bundle.connections = personal; bundle.organization = personalOrganization
        try? AIVault.write(bundle)
    }
    /// Settings action, after a fresh owner confirmation: lets an assistant request synchronizations.
    func enableAISync(confirmOwner: () async throws -> Void = OwnerConfirmation.aiSync) async throws {
        guard accessMode == "personal", !demo, personal != nil, !personalOrganization.isEmpty else {
            throw GameMetrikError.message("Choisis l’Espace réel en Administration personnelle, avec une organisation, avant d’activer la synchronisation par l’IA.")
        }
        guard let chosen = resolveAIFolder() else { throw GameMetrikError.message("Choisis d’abord le dossier pour l’IA.") }
        try await confirmOwner()
        guard !isLocked, let personal else { throw GameMetrikError.message("GameMetrik s’est verrouillé pendant la confirmation. Recommence.") }
        try prepareAggregateCache(personal)
        guard let key = aggregateCacheKey else { throw GameMetrikError.message("Clé du cache indisponible.") }
        let token = AISyncRequest.newToken()
        try AIVault.write(AISyncBundle(connections: personal, organization: personalOrganization, cacheKey: key, token: token))
        guard try AIVault.read()?.token == token else { throw GameMetrikError.message("L’enregistrement n’a pas pu être vérifié.") }
        let scoped = chosen.startAccessingSecurityScopedResource()
        defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }
        try AIFolder(root: AIFolder.root(forChosen: chosen)).writeToken(token, appPath: Bundle.main.bundlePath)
        aiSyncEnabled = true
    }
    func disableAISync() {
        try? AIVault.remove()
        if let chosen = resolveAIFolder() {
            let scoped = chosen.startAccessingSecurityScopedResource()
            defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }
            try? AIFolder(root: AIFolder.root(forChosen: chosen)).removeToken()
        }
        aiSyncEnabled = false
    }
    private static func privateHTTP() -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        return HTTPClient(session: URLSession(configuration: configuration))
    }
    func unlock() {
        guard isLocked, !unlocking else { return }
        securityGeneration += 1; let revision = securityGeneration
        let context = UnlockContext(); unlockContext = context
        unlocking = true; lockMessage = nil
        let memberProject = config?.projectID
        unlockTask = Task {
            do {
                try await context.authenticate()
                guard revision == securityGeneration, !Task.isCancelled else { return }
                let result = try await Task.detached { () -> (PersonalConnections?, AuthSession?) in
                    // A demonstration build has no provisioned keychain group, hence nothing stored: open the demonstration only.
                    guard Vault.isConfigured else { return (nil, nil) }
                    try Vault.migrateLegacy(context: context)
                    var personalData = try Vault.read("personal.connections", context: context)
                    defer { let count = personalData?.count ?? 0; personalData?.resetBytes(in: 0..<count) }
                    let connections = try personalData.map { try JSONDecoder().decode(PersonalConnections.self, from: $0) }
                    try connections?.validate()
                    var session: AuthSession?
                    if let memberProject {
                        var data = try Vault.read("firebase." + memberProject, context: context)
                        defer { let count = data?.count ?? 0; data?.resetBytes(in: 0..<count) }
                        session = try data.map { try JSONDecoder().decode(AuthSession.self, from: $0) }
                    }
                    return (connections, session)
                }.value
                guard revision == securityGeneration, !Task.isCancelled else { return }
                completeUnlock(connections: result.0, session: result.1)
            } catch {
                guard revision == securityGeneration else { return }
                context.invalidate(); unlockContext = nil; unlocking = false
                lockMessage = (error as? GameMetrikError)?.localizedDescription ?? "Déverrouillage annulé ou refusé par macOS."
            }
        }
    }
    /// Restores the protected identities without changing the workspace chosen before the lock.
    func completeUnlock(connections: PersonalConnections?, session: AuthSession?) {
        if let connections { applyPersonal(connections) }
        self.session = session; isLocked = false; unlocking = false
        securityMonitor?.activity(); refresh(mode: .local)
    }
    func stayUnlocked() { securityMonitor?.activity() }
    func lock() {
        guard !isLocked || unlocking else { return }
        idleLockDeadline = nil
        isLocked = true; unlocking = false; securityGeneration += 1
        showingExport = false; exportPanel?.cancel(nil); exportPanel = nil
        preparingExport = false; exportSyncResults = []; exportSyncContext = nil
        studioSyncResults = []; studioSyncSummary = nil; synchronizingViews = false
        unlockContext?.invalidate(); unlockContext = nil; unlockTask?.cancel(); unlockTask = nil
        authGeneration += 1; authentication.cancel(); authenticating = false
        refreshTask?.cancel(); refreshTask = nil; generation += 1
        checkTask?.cancel(); checkTask = nil; checkGeneration += 1
        http.session.invalidateAndCancel(); http = Self.privateHTTP()
        let previousTokens = personalTokens; personalTokens = ServiceAccountTokens()
        Task { await previousTokens.clear() }
        localViews = [:]; localViewFailures = [:]; activeRefreshKey = nil
        aggregateCache = nil; aggregateCacheScope = nil
        if let count = aggregateCacheKey?.count { aggregateCacheKey?.resetBytes(in: 0..<count) }
        aggregateCacheKey = nil; cacheMessage = nil; showingCachedDashboard = false
        personal = nil; session = nil; membership = nil
        personalReady = false; personalProject = ""; personalSummary = []; personalOrganizations = []; hasAppleConfiguration = false
        connectionChecks = []; webConfigurationAudit = nil; settingsMessage = nil; error = nil
        games = []; directory = nil; dashboard = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil; selectedPlayerID = nil; loadedAt = nil
        loading = false; checkingConnections = false; syncProgress = nil; reportBucket = ""; appleVendor = ""; appleIssuerID = ""; appleKeyID = ""
    }
    var sensitiveStateIsEmpty: Bool {
        studioSyncResults.isEmpty && studioSyncSummary == nil && !synchronizingViews && localViewFailures.isEmpty && localViews.isEmpty && !preparingExport && exportSyncResults.isEmpty && exportSyncContext == nil && activeRefreshKey == nil && aggregateCache == nil && aggregateCacheKey == nil && aggregateCacheScope == nil && cacheMessage == nil && !showingCachedDashboard && personal == nil && session == nil && membership == nil && directory == nil && dashboard == nil && reviews.isEmpty && ballparkAnalytics == nil && auroraJourney == nil && auroraInsights == nil && games.isEmpty && selectedPlayerID == nil && unlockContext == nil && !authenticating && !checkingConnections && !loading && syncProgress == nil && reportBucket.isEmpty && appleVendor.isEmpty && appleIssuerID.isEmpty && appleKeyID.isEmpty
    }
    private func requireUnlocked() throws -> UnlockContext {
        guard !isLocked, let unlockContext else { throw GameMetrikError.message("Déverrouille GameMetrik pour accéder aux connexions.") }
        return unlockContext
    }
    func cancelRefresh() {
        if synchronizingViews { studioSyncSummary = "Synchronisation interrompue ; les vues déjà reçues restent disponibles."; synchronizingViews = false }
        finishExportPreparation(status: "cancelled", detail: "Synchronisation annulée ; les vues déjà reçues restent disponibles.")
        refreshTask?.cancel(); refreshTask = nil; generation += 1
        loading = false; syncProgress = nil; activeRefreshKey = nil
    }
    private func prepareAggregateCache(_ connections: PersonalConnections) throws {
        if aggregateCacheKey == nil {
            // A key already in memory comes from an unlock, or from the AI copy for the background instance.
            let context = try requireUnlocked()
            if let existing = try Vault.read("aggregate-cache.key", context: context) { aggregateCacheKey = existing }
            else {
                let key = AggregateCacheStore.newKey()
                try Vault.write(key, account: "aggregate-cache.key", context: context)
                guard try Vault.read("aggregate-cache.key", context: context) == key else {
                    throw GameMetrikError.message("La clé du cache n’a pas pu être vérifiée.")
                }
                aggregateCacheKey = key
            }
        }
        guard let key = aggregateCacheKey, key.count == 32 else { throw GameMetrikError.message("Clé du cache invalide.") }
        let scope = AggregateCacheStore.scope(projectID: connections.projectID, organization: personalOrganization, key: key)
        if aggregateCacheScope != scope || aggregateCache == nil {
            aggregateCacheScope = scope
            do { aggregateCache = try aggregateStore.read(scope: scope, key: key) ?? adoptLegacyCache(connections, scope: scope, key: key) ?? AggregateCache() }
            catch {
                // A damaged/obsolete cache never prevents an authenticated online collection.
                aggregateCache = AggregateCache()
                cacheMessage = "Cache illisible. Clique sur Synchroniser pour le reconstruire."
            }
        }
        // Another publisher, vendor, bucket or project drops only that provider's days.
        aggregateCache?.adopt(sources: AggregateCache.sourceIdentities(connections))
    }
    /// Before 0.14 the file name depended on every credential; move a matching cache once.
    private func adoptLegacyCache(_ connections: PersonalConnections, scope: String, key: Data) -> AggregateCache? {
        guard let legacy = try? AggregateCacheStore.legacyScope(connections: connections, organization: personalOrganization, googlePlay: googlePlayOverrides, key: key),
              let cache = try? aggregateStore.read(scope: legacy, key: key) else { return nil }
        do { try aggregateStore.write(cache, scope: scope, key: key); try aggregateStore.remove(scope: legacy) } catch {}
        return cache
    }
    private func persistAggregateCache(_ cache: AggregateCache) {
        guard !isLocked, let key = aggregateCacheKey, let scope = aggregateCacheScope else { return }
        aggregateCache = cache
        do { try aggregateStore.write(cache, scope: scope, key: key) }
        catch { cacheMessage = "Données mises à jour en mémoire ; le cache local n’a pas pu être enregistré." }
    }
    func clearAggregateCache() {
        guard !isLocked else { return }
        cancelRefresh()
        do {
            try aggregateStore.removeAll()
            aggregateCache = nil; aggregateCacheScope = nil; localViews = [:]; localViewFailures = [:]
            dashboard = nil; showingCachedDashboard = false; cacheMessage = nil
            settingsMessage = "Cache des statistiques vidé. Actualise la vue d’ensemble pour le reconstruire."
        } catch { settingsMessage = "Le cache local n’a pas pu être supprimé." }
    }
    func collectsGooglePlay(_ game: Game) -> Bool {
        googlePlayOverrides[game.slug] ?? (game.integrations.googlePackageName != nil || game.platforms.contains("android"))
    }
    func setGooglePlay(_ enabled: Bool, game: Game) {
        guard !isLocked else { return }
        cancelRefresh()
        googlePlayOverrides[game.slug] = enabled
        UserDefaults.standard.set(googlePlayOverrides, forKey: "sources.googlePlay")
        // Received reports stay valid; only the dashboards of this game and of the studio change. The cache file is
        // read first when it is not in memory (after a refused access), or the toggle would leave old dashboards on disk.
        if aggregateCache == nil, let personal { try? prepareAggregateCache(personal) }
        if var cache = aggregateCache { cache.invalidateSnapshots(gameID: game.id); persistAggregateCache(cache) }
        localViews = localViews.filter { !$0.key.hasSuffix("|" + Destination.dashboard.rawValue) }
        dashboard = nil; showingCachedDashboard = false
        settingsMessage = "Sources mises à jour sur ce Mac. Synchronise \(game.name) pour recalculer sa vue d’ensemble ; les rapports déjà reçus sont conservés."
    }
    func saveReportConfiguration() {
        do {
            guard var connections = personal else { return }
            let bucket = reportBucket.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "gs://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let vendor = appleVendor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard bucket.isEmpty || bucket.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
                  vendor.isEmpty || vendor.allSatisfy(\.isNumber) else { throw GameMetrikError.message("Indique le nom du bucket sans chemin et le numéro vendeur Apple numérique.") }
            connections.googlePlayReportBucket = bucket.isEmpty ? nil : bucket
            let issuer = appleIssuerID.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = appleKeyID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !issuer.isEmpty || !key.isEmpty {
                connections.apple = try PersonalApple.configured(issuerID: issuer, keyID: key, vendor: vendor.isEmpty ? nil : vendor, previous: connections.apple)
            } else { connections.apple?.vendor = vendor.isEmpty ? nil : vendor }
            let context = try requireUnlocked(), data = try JSONEncoder().encode(connections)
            try Vault.write(data, account: "personal.connections", context: context)
            guard try Vault.read("personal.connections", context: context) == data else { throw GameMetrikError.message("L’enregistrement n’a pas pu être vérifié.") }
            cancelRefresh(); applyPersonal(connections)
            settingsMessage = "Configuration des rapports enregistrée. Actualise la vue d’ensemble pour lancer la collecte."
        } catch { settingsMessage = error.localizedDescription }
    }
    func selectGame(_ game: Game, page: Destination? = nil) {
        gameID = game.id
        destination = page ?? (game.usesBallparkAnalytics ? .ballpark : .dashboard)
    }
    /// Menu commands only offer pages that make sense for the selected game.
    func canNavigate(to page: Destination) -> Bool {
        switch page {
        case .auroraJourney, .auroraInsights: game?.usesAuroraJourney == true && (demo || accessMode == "personal")
        case .ballpark: games.contains(where: \.usesBallparkAnalytics)
        case .gameplay, .players, .reviews: game?.usesBallparkAnalytics != true
        case .dashboard, .library: true
        }
    }
    /// After a game change, keep the game and adapt the page.
    func ensureCompatibleDestination() {
        defer { ensureCompatibleRange() }
        if game?.usesBallparkAnalytics == true {
            if destination != .ballpark && destination != .library { destination = .ballpark }
            if range == .all { range = .year }
        } else if (destination == .auroraJourney || destination == .auroraInsights) && (game?.usesAuroraJourney != true || (!demo && accessMode != "personal")) {
            destination = gameID == "all" ? .dashboard : .gameplay
        } else if destination == .ballpark {
            destination = gameID == "all" ? .dashboard : .gameplay
        }
    }
    /// After a page change, keep the page and adapt the game.
    func ensureCompatibleGame() {
        defer { ensureCompatibleRange() }
        guard let destination else { return }
        let ballparkSelected = game?.usesBallparkAnalytics == true
        switch destination {
        case .dashboard:
            // Ballpark has no provider dashboard: the overview becomes the studio overview.
            if ballparkSelected { gameID = "all" }
        case .ballpark:
            guard !ballparkSelected else { return }
            if let ballpark = games.first(where: \.usesBallparkAnalytics) { gameID = ballpark.id } else { ensureCompatibleDestination() }
        case .gameplay, .players, .reviews:
            if ballparkSelected { self.destination = .ballpark }
        case .auroraJourney, .auroraInsights: ensureCompatibleDestination()
        case .library: break
        }
    }
    func setMode(_ isDemo: Bool) {
        guard demo != isDemo else { return }
        cancelRefresh(); localViews.removeAll(); localViewFailures.removeAll(); exportSyncResults = []; exportSyncContext = nil
        studioSyncResults = []; studioSyncSummary = nil
        // Store each mode's navigation separately; never retain data from the other mode.
        UserDefaults.standard.set(gameID, forKey: demo ? "demo.game" : "live.game")
        UserDefaults.standard.set(range.rawValue, forKey: demo ? "demo.range" : "live.range")
        demo = isDemo; UserDefaults.standard.set(!isDemo && accessMode == "personal", forKey: "personal.live"); selectedPlayerID = nil; games = isDemo ? Demo.games : []; dashboard = nil; directory = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil
        gameID = UserDefaults.standard.string(forKey: isDemo ? "demo.game" : "live.game") ?? "all"
        range = Timeframe(rawValue: UserDefaults.standard.string(forKey: isDemo ? "demo.range" : "live.range") ?? "30d") ?? .month
        error = nil; loadedAt = nil; syncProgress = nil
        refresh(mode: .local)
    }
    // Navigation, new windows and unlocks only restore local data, regardless of its age.
    func displayLocalView(cache: AggregateCache?) {
        dashboard = nil; directory = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil; loadedAt = nil; showingCachedDashboard = false
        if let cache { games = cache.games }
        if let saved = localViews[localViewKey] {
            dashboard = saved.dashboard; directory = saved.directory; reviews = saved.reviews; ballparkAnalytics = saved.ballpark; auroraJourney = saved.auroraJourney; auroraInsights = saved.auroraInsights; loadedAt = saved.date
        }
        if destination == .dashboard, let cached = cache?.snapshot(gameID: gameID == "all" ? nil : gameID, range: range) {
            dashboard = cached; loadedAt = Dates.parse(cached.generatedAt); showingCachedDashboard = true
        } else if destination == .library, loadedAt == nil { loadedAt = cache?.catalogSyncedAt ?? cache?.lastSynchronizedAt }
    }
    func loadAuroraJourney(project: PersonalSupabase, range: Timeframe, now: Date) async throws -> AuroraJourneyBundle {
        guard accessMode == "personal" else { throw GameMetrikError.http(403) }
        syncProgress = "Aurora Grove · parcours des joueurs"
        return try await AuroraJourneyReportReader(personal: project, http: http).bundle(filters: .period(range, now: now))
    }
    /// Read after the journey with its boundary when given; the population is the one chosen in Activité et jeu.
    func loadAuroraInsights(project: PersonalSupabase, range: Timeframe, now: Date, population: AuroraInsightsPopulation, asOf: String?) async throws -> AuroraInsightsBundle {
        guard accessMode == "personal" else { throw GameMetrikError.http(403) }
        syncProgress = "Aurora Grove · activité et jeu"
        return try await AuroraJourneyReportReader(personal: project, http: http).insightsBundle(filters: .period(range, now: now), population: population, asOf: asOf)
    }
    private func ballparkFilters(range: Timeframe, now: Date) throws -> BallparkReportFilters {
        guard range != .all, let zone = TimeZone(identifier: "Europe/Zurich") else {
            throw GameMetrikError.message("Les rapports Ballpark acceptent une période maximale d’un an.")
        }
        let interval = range.interval(now: now, timezone: zone)
        return BallparkReportFilters(
            fromDay: Dates.day(interval.start, timezone: zone),
            toDayExclusive: Dates.day(interval.end, timezone: zone)
        )
    }
    private func loadBallparkReports(project: PersonalSupabase, range: Timeframe, now: Date) async throws -> BallparkAnalyticsData {
        let filters = try ballparkFilters(range: range, now: now)
        let reader = BallparkReportReader(personal: project, http: http)
        syncProgress = "Ballpark · cinq rapports"
        // The five reports are independent reads of one versioned contract.
        async let overview = Self.attempt { try await reader.overview(filters: filters) }
        async let questions = Self.attempt { try await reader.questions(filters: filters) }
        async let series = Self.attempt { try await reader.series(filters: filters) }
        async let habits = Self.attempt { try await reader.habits(filters: filters) }
        async let quality = Self.attempt { try await reader.quality(filters: filters) }
        var result = BallparkAnalyticsData()
        let outcomes = await (overview, questions, series, habits, quality)
        try Task.checkCancellation()
        func take<T>(_ kind: BallparkReportKind, _ outcome: Result<T, Error>) throws -> T? {
            switch outcome {
            case .success(let value): return value
            case .failure(let error as GameMetrikError) where error == .http(401) || error == .http(403): throw error
            case .failure(is CancellationError): throw CancellationError()
            case .failure(let error): result.errors[kind] = error.localizedDescription; return nil
            }
        }
        result.overview = try take(.overview, outcomes.0)
        result.questions = try take(.questions, outcomes.1)
        result.series = try take(.series, outcomes.2)
        result.habits = try take(.habits, outcomes.3)
        result.quality = try take(.quality, outcomes.4)
        guard !result.isEmpty else {
            throw GameMetrikError.message(BallparkReportKind.allCases.compactMap { result.errors[$0] }.first ?? "Aucun rapport Ballpark n’a pu être lu.")
        }
        return result
    }
    private nonisolated static func attempt<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
    func synchronizationPages(for game: Game?, range: Timeframe) -> [Destination] {
        if game?.usesBallparkAnalytics == true { return [.ballpark] }
        var pages: [Destination] = game == nil ? [.dashboard, .reviews] : [.dashboard, .players, .reviews]
        if game?.usesAuroraJourney == true && (demo || accessMode == "personal") { pages.append(.auroraJourney) }
        // All-time player history has no corresponding provider report window.
        if !demo, accessMode == "personal", range == .all { pages.removeAll { $0 == .dashboard } }
        return pages
    }
    /// The toolbar and ordinary manual controls collect every relevant view for the selected game.
    @discardableResult func synchronizeSelection(mode: RefreshMode = .incremental) -> Task<Void, Never>? {
        refresh(mode: mode, selectedGameWide: true)
    }
    /// Kept for explicit studio-wide workflows and their regression coverage.
    @discardableResult func synchronizeAll(mode: RefreshMode = .incremental) -> Task<Void, Never>? {
        refresh(mode: mode, applicationWide: true)
    }
    @discardableResult func refresh(mode: RefreshMode = .incremental, forExport: Bool = false, applicationWide: Bool = false, selectedGameWide: Bool = false) -> Task<Void, Never>? {
        guard !isLocked, !forExport || (mode != .local && canPrepareExport) else { return nil }
        // Also leaves the journey page when the mode no longer allows it, rather than reading it as a refused access.
        ensureCompatibleDestination()
        if mode == .local, loading, activeRefreshKey == refreshKey { return refreshTask }
        let summarizesViews = applicationWide || selectedGameWide
        if synchronizingViews { studioSyncSummary = "Synchronisation interrompue ; les vues déjà reçues restent disponibles." }
        synchronizingViews = summarizesViews && mode != .local
        if synchronizingViews {
            studioSyncResults = []; studioSyncSummary = nil
            exportSyncResults = []; exportSyncContext = nil
        }
        finishExportPreparation(status: "cancelled", detail: "Synchronisation interrompue par un changement de contexte.")
        if forExport {
            preparingExport = true; exportSyncContext = exportContextKey
            exportSyncResults = exportSectionLabels.map { ExportCheck(section: $0, status: "pending", detail: "À synchroniser.") }
        }
        refreshTask?.cancel(); generation += 1; let current = generation
        activeRefreshKey = nil
        error = nil; loadedAt = nil; syncProgress = nil; showingCachedDashboard = false; cacheMessage = nil
        if !headless {
            UserDefaults.standard.set(gameID, forKey: demo ? "demo.game" : "live.game")
            UserDefaults.standard.set(range.rawValue, forKey: demo ? "demo.range" : "live.range")
        }
        if !demo, accessMode == "personal", let personal {
            do {
                try prepareAggregateCache(personal)
                displayLocalView(cache: accessMode == "personal" ? aggregateCache : nil)
            } catch {
                aggregateCache = nil; aggregateCacheScope = nil
                displayLocalView(cache: nil)
                cacheMessage = "Cache indisponible. Clique sur Synchroniser pour charger les données."
            }
        }
        if !demo {
            if accessMode != "personal" { displayLocalView(cache: nil) }
            if mode == .local { loading = false; return nil }
        }
        loading = true; activeRefreshKey = refreshKey
        let isDemo = demo, requestedGame = gameID, requestedRange = range, requestedPage = destination ?? .dashboard, requestedPopulation = auroraInsightsPopulation
        let syncNow = Date()
        refreshTask = Task {
            defer { if generation == current {
                loading = false; syncProgress = nil; activeRefreshKey = nil; synchronizingViews = false
                finishExportPreparation(status: "failed", detail: "Cette vue n’a pas pu être synchronisée.")
            } }
            do {
                try Task.checkCancellation()
                guard generation == current, !isLocked else { return }
                if isDemo {
                    games = Demo.games
                    dashboard = Demo.dashboard(range: requestedRange, gameID: requestedGame == "all" ? nil : requestedGame, now: syncNow)
                    if let game, !game.usesBallparkAnalytics { directory = try Demo.directory(range: requestedRange, game: game, now: syncNow) }
                    let demoReviews = Demo.reviews()
                    reviews = (selectedGameWide || forExport) && requestedGame != "all"
                        ? demoReviews.filter { $0.gameId == requestedGame }
                        : demoReviews
                    auroraJourney = game?.usesAuroraJourney == true ? AuroraJourneyDemo.bundle(filters: .period(requestedRange, now: syncNow), now: syncNow) : nil
                    auroraInsights = game?.usesAuroraJourney == true ? AuroraInsightsDemo.bundle(filters: .period(requestedRange, now: syncNow), population: requestedPopulation, now: syncNow) : nil
                    ballparkAnalytics = requestedGame == Game.ballpark.id ? BallparkAnalyticsData(bundle: BallparkDemo.bundle) : nil
                    loadedAt = syncNow
                    if let auroraJourney {
                        localViews[localViewKey(for: .auroraJourney)] = .init(dashboard: nil, directory: nil, reviews: [], date: syncNow, auroraJourney: auroraJourney)
                    }
                    if let auroraInsights {
                        localViews[localViewKey(for: .auroraInsights)] = .init(dashboard: nil, directory: nil, reviews: [], date: syncNow, auroraInsights: auroraInsights)
                    }
                    if forExport || selectedGameWide {
                        if game?.usesBallparkAnalytics == true {
                            localViews[localViewKey(for: .ballpark)] = LocalViewSnapshot(dashboard: nil, directory: nil, reviews: [], date: syncNow, ballpark: ballparkAnalytics)
                        } else if requestedGame == "all" {
                            localViews[localViewKey(for: .dashboard)] = LocalViewSnapshot(dashboard: dashboard, directory: nil, reviews: [], date: syncNow)
                            localViews[localViewKey(for: .reviews)] = LocalViewSnapshot(dashboard: nil, directory: nil, reviews: reviews, date: syncNow)
                        } else {
                            localViews[localViewKey(for: .dashboard)] = LocalViewSnapshot(dashboard: dashboard, directory: nil, reviews: [], date: syncNow)
                            localViews[localViewKey(for: .players)] = LocalViewSnapshot(dashboard: nil, directory: directory, reviews: [], date: syncNow)
                            localViews[localViewKey(for: .reviews)] = LocalViewSnapshot(dashboard: nil, directory: nil, reviews: reviews, date: syncNow)
                        }
                    }
                    if forExport {
                        for section in exportSectionLabels { recordExportSync(section, status: "loaded", detail: "Données fictives actualisées.", date: syncNow) }
                    }
                    if selectedGameWide {
                        let synchronizedGame = games.first(where: { $0.id == requestedGame })
                        let scope = synchronizedGame?.name ?? "Tout le studio"
                        let sections = synchronizationPages(for: synchronizedGame, range: requestedRange).map { $0 == .players ? "Gameplay et joueurs" : $0.title }
                        studioSyncResults = sections.map { .init(section: scope + " · " + $0, status: "loaded", detail: "Données fictives actualisées.", updatedAt: Dates.iso(syncNow)) }
                        displayLocalView(cache: nil)
                        studioSyncSummary = "Synchronisation terminée · " + scope + " · " + requestedRange.label
                    }
                    if applicationWide {
                        for id in ["all"] + games.map(\.id) {
                            localViews[localViewKey(for: .dashboard, gameID: id)] = .init(dashboard: Demo.dashboard(range: requestedRange, gameID: id == "all" ? nil : id, now: syncNow), directory: nil, reviews: [], date: syncNow)
                            if let game = games.first(where: { $0.id == id }) {
                                if !game.usesBallparkAnalytics {
                                    localViews[localViewKey(for: .players, gameID: id)] = .init(dashboard: nil, directory: try Demo.directory(range: requestedRange, game: game, now: syncNow), reviews: [], date: syncNow)
                                }
                                if game.usesAuroraJourney {
                                    localViews[localViewKey(for: .auroraJourney, gameID: id)] = .init(dashboard: nil, directory: nil, reviews: [], date: syncNow, auroraJourney: AuroraJourneyDemo.bundle(filters: .period(requestedRange, now: syncNow), now: syncNow))
                                    localViews[localViewKey(for: .auroraInsights, gameID: id)] = .init(dashboard: nil, directory: nil, reviews: [], date: syncNow, auroraInsights: AuroraInsightsDemo.bundle(filters: .period(requestedRange, now: syncNow), population: requestedPopulation, now: syncNow))
                                }
                                if game.usesBallparkAnalytics {
                                    localViews[localViewKey(for: .ballpark, gameID: id)] = .init(dashboard: nil, directory: nil, reviews: [], date: syncNow, ballpark: .init(bundle: BallparkDemo.bundle))
                                }
                            }
                            localViews[localViewKey(for: .reviews, gameID: id)] = .init(dashboard: nil, directory: nil, reviews: Demo.reviews(), date: syncNow)
                            localViews[localViewKey(for: .library, gameID: id)] = .init(dashboard: nil, directory: nil, reviews: [], date: syncNow)
                        }
                        displayLocalView(cache: nil)
                        studioSyncSummary = "Démonstration actualisée · tous les jeux · " + requestedRange.label
                    }
                    if selectedGameWide || forExport || applicationWide, range == requestedRange {
                        publishAIFolder(gameIDs: applicationWide ? ["all"] + games.map(\.id) : [requestedGame])
                    }
                    return
                }
                // Ballpark is a personal, explicitly configured Supabase source. Its
                // reports do not depend on Firebase catalog or provider credentials.
                if accessMode == "personal", requestedGame == Game.ballpark.id,
                   !applicationWide, selectedGameWide || forExport || requestedPage == .ballpark {
                    guard !personalOrganization.isEmpty,
                          let project = personal?.supabase.first(where: { $0.ref == Game.ballparkProjectRef }) else {
                        throw GameMetrikError.message("Ajoute la connexion administrative Ballpark dans Réglages → Connexions.")
                    }
                    let reports = try await loadBallparkReports(project: project, range: requestedRange, now: syncNow)
                    try Task.checkCancellation(); guard current == generation, !isLocked else { return }
                    games = Game.addingPersonalSources(to: games)
                    ensureCompatibleDestination()
                    let key = localViewKey(for: .ballpark, gameID: requestedGame)
                    let date = reports.latestGeneration ?? syncNow
                    localViews[key] = .init(dashboard: nil, directory: nil, reviews: [], date: date, ballpark: reports)
                    localViewFailures[key] = nil
                    let partial = !reports.errors.isEmpty
                    let detail = partial ? "Rapports Ballpark partiels : " + reports.errors.values.sorted().joined(separator: " · ") : "Les cinq rapports Ballpark sont actualisés."
                    if forExport { recordExportSync(Destination.ballpark.title, status: partial ? "partial" : "loaded", detail: detail, date: date) }
                    if summarizesViews {
                        studioSyncResults = [.init(section: "Ballpark · Analyse Ballpark", status: partial ? "partial" : "loaded", detail: detail, updatedAt: Dates.iso(date))]
                        studioSyncSummary = (partial ? "Synchronisation partielle · Ballpark · " : "Synchronisation terminée · Ballpark · ") + requestedRange.label
                    }
                    displayLocalView(cache: nil)
                    if summarizesViews || forExport { publishAIFolder(gameIDs: [requestedGame]) }
                    return
                }
                let firestore: Firestore
                let root: [String]
                var member: Membership?
                var memberToken: String?
                if accessMode == "personal" {
                    guard let personal else { throw GameMetrikError.message("Dans Réglages → Connexions, importe le dossier de la web app pour retrouver tes données.") }
                    let token = try await personalTokens.token(account: personal.firebase, scopes: ["https://www.googleapis.com/auth/datastore"], http: http)
                    firestore = Firestore(project: personal.projectID, token: token, http: http)
                    let organizations: [PersonalOrganization] = try await firestore.list(["organizations"], order: "__name__")
                    try Task.checkCancellation(); guard current == generation else { return }
                    personalOrganizations = organizations
                    if !organizations.contains(where: { $0.id == personalOrganization }) {
                        guard organizations.count == 1, let only = organizations.first else {
                            throw GameMetrikError.message(organizations.isEmpty ? "Aucune organisation trouvée dans ce projet Firebase." : "Choisis ton organisation dans Réglages → Connexions.")
                        }
                        personalOrganization = only.id
                        activeRefreshKey = refreshKey
                        if !headless { UserDefaults.standard.set(only.id, forKey: "personal.organization"); updateAISyncBundle() }
                    }
                    root = ["organizations", personalOrganization]
                    membership = nil
                } else {
                    guard let config, var session else { throw GameMetrikError.message("Connecte ton compte Google dans les réglages pour ouvrir ton espace membre.") }
                    if session.expiresAt.timeIntervalSinceNow < 120 {
                        session = try await FirebaseAuth(config: config, http: http).refresh(session)
                        try Task.checkCancellation(); guard current == generation else { return }
                        try saveSession(session); self.session = session
                    }
                    firestore = Firestore(project: config.projectID, token: session.idToken, http: http)
                    member = try await firestore.membership(uid: session.uid, preferredOrganization: config.organizationID)
                    root = ["organizations", member!.organization]; memberToken = session.idToken
                }
                let remoteCatalog: [Game] = try await firestore.list(root + ["games"])
                let catalog = accessMode == "personal" ? Game.addingPersonalSources(to: remoteCatalog) : remoteCatalog
                try Task.checkCancellation(); guard current == generation else { return }
                membership = member; games = catalog
                if accessMode == "personal", let personal {
                    do {
                        try prepareAggregateCache(personal)
                        var cache = aggregateCache ?? AggregateCache()
                        cache.reconcile(games: catalog); cache.catalogSyncedAt = Date()
                        persistAggregateCache(cache)
                    } catch { cacheMessage = "Catalogue lu ; cache local indisponible." }
                }
                if !applicationWide, requestedGame != "all", !catalog.contains(where: { $0.id == requestedGame }) { gameID = "all"; return }
                let contexts = ["all"] + catalog.map(\.id)
                // Catalog and reviews are shared across views. Player details stay only in memory.
                for id in applicationWide ? contexts : [requestedGame] {
                    localViews[localViewKey(for: .library, gameID: id)] = .init(dashboard: nil, directory: nil, reviews: [], date: syncNow)
                }
                let legacyGames = catalog.filter { !$0.usesBallparkAnalytics }
                let ballparkGames = catalog.filter(\.usesBallparkAnalytics)
                let selectedPages = synchronizationPages(for: catalog.first { $0.id == requestedGame }, range: requestedRange)
                var targets: [(String, Destination)] = []
                if applicationWide {
                    targets.append(("all", .dashboard))
                    targets += legacyGames.map { ($0.id, Destination.dashboard) }
                    targets += legacyGames.map { ($0.id, Destination.players) }
                    targets += ballparkGames.map { ($0.id, Destination.ballpark) }
                    if accessMode == "personal" {
                        targets += catalog.filter(\.usesAuroraJourney).map { ($0.id, Destination.auroraJourney) }
                    }
                    targets.append(("all", .reviews))
                } else {
                    targets = ((selectedGameWide || forExport) ? selectedPages : [requestedPage]).map { (requestedGame, $0) }
                }
                var studioDashboards: AggregateCache?
                for (targetGame, page) in targets {
                    try Task.checkCancellation(); guard current == generation, !isLocked else { return }
                    let section = page == .players || page == .gameplay ? "Gameplay et joueurs" : page.title
                    let label = (catalog.first { $0.id == targetGame }?.name ?? "Tout le studio") + " · " + section
                    if applicationWide || selectedGameWide { syncProgress = label }
                    else if forExport { syncProgress = "Export · " + section }
                    do {
                        var view = LocalViewSnapshot(dashboard: nil, directory: nil, reviews: [], date: syncNow)
                        switch page {
                        case .dashboard:
                            let snapshot: Dashboard
                            if accessMode == "personal", let personal {
                                if applicationWide, targetGame != "all" {
                                    guard let saved = studioDashboards?.snapshot(gameID: targetGame, range: requestedRange) else {
                                        throw GameMetrikError.message("Tableau de bord non reçu pour ce jeu.")
                                    }
                                    snapshot = saved
                                } else {
                                    do { try prepareAggregateCache(personal) }
                                    catch { aggregateCache = nil; aggregateCacheScope = nil }
                                    var cache = aggregateCache ?? AggregateCache()
                                    snapshot = try await NativeDashboardSync(http: http, tokens: personalTokens).runCached(games: catalog, gameID: targetGame == "all" ? nil : targetGame, range: requestedRange, connections: personal, cache: &cache, force: mode == .full, entireStudio: applicationWide, refreshRecent: selectedGameWide, now: syncNow, googlePlayGameIDs: Set(catalog.filter { collectsGooglePlay($0) }.map(\.id))) { [weak self = self] message in
                                        await MainActor.run {
                                            guard let self, self.generation == current, !self.isLocked else { return }
                                            self.syncProgress = message
                                        }
                                    }
                                    try Task.checkCancellation(); guard current == generation, !isLocked else { return }
                                    persistAggregateCache(cache)
                                    if applicationWide { studioDashboards = cache }
                                }
                            } else {
                                let path = targetGame == "all" ? root + ["portfolioSnapshots", requestedRange.rawValue] : root + ["games", targetGame, "dashboardSnapshots", requestedRange.rawValue]
                                snapshot = try await firestore.document(path)
                            }
                            guard snapshot.timeframe == requestedRange, snapshot.gameId == (targetGame == "all" ? nil : targetGame) else { throw GameMetrikError.message("Le tableau reçu ne correspond pas au jeu ou à la période demandée.") }
                            view.dashboard = snapshot; view.date = Dates.parse(snapshot.generatedAt) ?? syncNow
                        case .players, .gameplay:
                            guard let game = catalog.first(where: { $0.id == targetGame }) else { continue }
                            let reader: SupabaseReader
                            if accessMode == "personal" {
                                guard let ref = game.integrations.supabaseProjectRef, let project = personal?.supabase.first(where: { $0.ref == ref }) else { throw GameMetrikError.message("Aucune connexion Supabase importée pour ce jeu. Réimporte le dossier du projet dans les réglages.") }
                                reader = SupabaseReader(personal: project, http: http)
                            } else {
                                if applicationWide, member?.canReadPlayers != true {
                                    throw GameMetrikError.message("Les droits de ce membre ne permettent pas la lecture des joueurs.")
                                }
                                guard member?.canReadPlayers == true, let memberToken else { throw GameMetrikError.http(403) }
                                guard let ref = game.integrations.supabaseProjectRef, let project = supabaseProjects.first(where: { $0.ref == ref }) else { throw GameMetrikError.message("Importe la configuration publique Supabase pour ce jeu dans les réglages membre.") }
                                reader = SupabaseReader(config: project, token: memberToken, http: http)
                            }
                            view.directory = try await reader.directory(game: game, range: requestedRange, now: syncNow)
                            view.date = view.directory?.generatedAt ?? syncNow
                        case .reviews:
                            let availableReviews: [Review] = try await firestore.list(root + ["reviews"], order: "publishedAt desc")
                            view.reviews = targetGame == "all" ? availableReviews : availableReviews.filter { $0.gameId == targetGame }
                        case .auroraJourney:
                            guard accessMode == "personal" else { throw GameMetrikError.http(403) }
                            guard let game = catalog.first(where: { $0.id == targetGame }), game.usesAuroraJourney,
                                  let ref = game.integrations.supabaseProjectRef,
                                  let project = personal?.supabase.first(where: { $0.ref == ref }) else {
                                var missing = AuroraJourneyBundle()
                                for kind in AuroraJourneyReportKind.allCases {
                                    missing.errors[kind] = .init(status: .notConnected, detail: "Connexion administrative Aurora Grove absente. Importe les connexions dans les Réglages.")
                                }
                                missing.stepsError = .init(status: .notConnected, detail: "Connexion administrative Aurora Grove absente. Importe les connexions dans les Réglages.")
                                missing.monetization = .notConnected("Connexion administrative Aurora Grove absente. Importe les connexions dans les Réglages.")
                                view.auroraJourney = missing
                                localViews[localViewKey(for: .auroraInsights, gameID: targetGame)] = .init(dashboard: nil, directory: nil, reviews: [], date: syncNow,
                                    auroraInsights: .notConnected("Connexion administrative Aurora Grove absente. Importe les connexions dans les Réglages.", population: requestedPopulation, filters: .period(requestedRange, now: syncNow)))
                                break
                            }
                            let journey = try await loadAuroraJourney(project: project, range: requestedRange, now: syncNow)
                            // Nothing read (network, unreadable reports): keep the previous journey rather than replace it with errors.
                            if journey.readNothing {
                                throw GameMetrikError.message(AuroraJourneyReportKind.allCases.compactMap { journey.errors[$0]?.detail }.first ?? "Parcours indisponible. Vérifie le réseau et réessaie la synchronisation.")
                            }
                            view.auroraJourney = journey
                            view.date = view.auroraJourney?.latestGeneration ?? syncNow
                            // The complete collection follows the journey, under its boundary; its state never changes the journey's.
                            let insights = try await loadAuroraInsights(project: project, range: requestedRange, now: syncNow, population: requestedPopulation, asOf: journey.boundary)
                            try Task.checkCancellation(); guard current == generation, !isLocked else { return }
                            let insightsKey = localViewKey(for: .auroraInsights, gameID: targetGame)
                            if insights.readNothing {
                                localViewFailures[insightsKey] = insights.firstFailureDetail ?? "Activité et jeu indisponible. Vérifie le réseau et réessaie la synchronisation."
                            } else {
                                localViews[insightsKey] = .init(dashboard: nil, directory: nil, reviews: [], date: insights.latestGeneration ?? syncNow, auroraInsights: insights)
                                localViewFailures[insightsKey] = nil
                            }
                            if summarizesViews {
                                studioSyncResults.append(.init(section: game.name + " · " + Destination.auroraInsights.title,
                                                               status: insights.readNothing ? "failed" : insights.status.rawValue,
                                                               detail: insights.readNothing || insights.status != .loaded ? (insights.firstFailureDetail ?? "Activité et jeu partiellement lue.") : "Collecte complète actualisée ; couverture et masquage indiqués dans la vue.",
                                                               updatedAt: Dates.iso(insights.latestGeneration ?? syncNow)))
                            }
                        case .auroraInsights:
                            guard accessMode == "personal" else { throw GameMetrikError.http(403) }
                            guard let game = catalog.first(where: { $0.id == targetGame }), game.usesAuroraJourney,
                                  let ref = game.integrations.supabaseProjectRef,
                                  let project = personal?.supabase.first(where: { $0.ref == ref }) else {
                                view.auroraInsights = .notConnected("Connexion administrative Aurora Grove absente. Importe les connexions dans les Réglages.", population: requestedPopulation, filters: .period(requestedRange, now: syncNow))
                                break
                            }
                            let insights = try await loadAuroraInsights(project: project, range: requestedRange, now: syncNow, population: requestedPopulation, asOf: nil)
                            if insights.readNothing {
                                throw GameMetrikError.message(insights.firstFailureDetail ?? "Activité et jeu indisponible. Vérifie le réseau et réessaie la synchronisation.")
                            }
                            view.auroraInsights = insights
                            view.date = insights.latestGeneration ?? syncNow
                        case .ballpark:
                            guard accessMode == "personal" else {
                                throw GameMetrikError.message("Les rapports Ballpark sont réservés à l’Administration personnelle.")
                            }
                            guard let game = catalog.first(where: { $0.id == targetGame }), game.usesBallparkAnalytics,
                                  let ref = game.integrations.supabaseProjectRef,
                                  let project = personal?.supabase.first(where: { $0.ref == ref }) else {
                                throw GameMetrikError.message("Ajoute la connexion administrative Ballpark dans Réglages → Connexions.")
                            }
                            view.ballpark = try await loadBallparkReports(project: project, range: requestedRange, now: syncNow)
                            view.date = view.ballpark?.latestGeneration ?? syncNow
                        case .library: break
                        }
                        try Task.checkCancellation(); guard current == generation, !isLocked else { return }
                        let key = localViewKey(for: page, gameID: targetGame)
                        localViews[key] = view
                        localViewFailures[key] = nil
                        if applicationWide, page == .reviews {
                            for id in contexts {
                                let reviewKey = localViewKey(for: .reviews, gameID: id)
                                localViews[reviewKey] = view; localViewFailures[reviewKey] = nil
                            }
                        }
                        if key == localViewKey || (applicationWide && page == .reviews && requestedPage == .reviews) {
                            displayLocalView(cache: accessMode == "personal" ? aggregateCache : nil)
                        }
                        let partial = (page == .dashboard && (view.dashboard?.kpis.contains { $0.coverage.map { $0.status != "complete" } ?? false } == true || view.dashboard?.sourceDays?.contains { $0.sourceHasError || $0.status == "missing" || $0.status == "pending" } == true))
                            || (page == .ballpark && view.ballpark?.errors.isEmpty == false)
                            || (page == .auroraJourney && view.auroraJourney?.status != .loaded)
                            || (page == .auroraInsights && view.auroraInsights?.status != .loaded)
                        let viewStatus = page == .auroraJourney ? (view.auroraJourney?.status.rawValue ?? "partial")
                            : page == .auroraInsights ? (view.auroraInsights?.status.rawValue ?? "partial") : (partial ? "partial" : "loaded")
                        let detail = page == .auroraInsights
                            ? (view.auroraInsights?.status == .loaded ? "Collecte complète actualisée." : view.auroraInsights?.firstFailureDetail ?? "Activité et jeu partiellement lue.")
                            : page == .auroraJourney
                            ? (view.auroraJourney?.errors.values.first?.detail
                                ?? (view.auroraJourney?.stepsError == nil && view.auroraJourney?.monetization.errors.isEmpty != false
                                    ? "Rapports du parcours actualisés ; maturité et couverture indiquées dans la vue."
                                    : "Rapports du parcours actualisés ; étapes anonymes ou monétisation mesurée indisponibles, détail dans la vue."))
                            : page == .reviews
                            ? "Avis relus dans GameMetrik ; aucune collecte directe des boutiques."
                            : page == .ballpark && partial
                                ? "Rapports Ballpark partiels ; les volets en échec sont indiqués dans la vue."
                                : partial ? "Vue actualisée ; certaines sources restent incomplètes. Consulte Sources et qualité." : "Vue actualisée."
                        if forExport { recordExportSync(section, status: viewStatus, detail: detail, date: view.date) }
                        if summarizesViews { studioSyncResults.append(.init(section: label, status: viewStatus, detail: detail, updatedAt: Dates.iso(view.date))) }
                    } catch {
                        try Task.checkCancellation(); guard current == generation, !isLocked else { return }
                        if (!forExport && !summarizesViews) || (error as? GameMetrikError) == .http(401) || (error as? GameMetrikError) == .http(403) { throw error }
                        let detail = (error as? GameMetrikError)?.localizedDescription ?? "Lecture impossible. Vérifie le réseau et les connexions."
                        localViewFailures[localViewKey(for: page, gameID: targetGame)] = detail
                        if forExport { recordExportSync(section, status: "failed", detail: detail, date: nil) }
                        if summarizesViews { studioSyncResults.append(.init(section: label, status: "failed", detail: detail)) }
                    }
                }
                // Restore exactly the selected view; another game's results never become its contents.
                if applicationWide, !contexts.contains(gameID) { gameID = "all" }
                displayLocalView(cache: accessMode == "personal" ? aggregateCache : nil)
                if let selectedPlayerID, directory?.players.contains(where: { $0.id == selectedPlayerID }) != true { self.selectedPlayerID = nil }
                if summarizesViews {
                    let failures = studioSyncResults.filter { $0.status == "failed" || $0.status == "not_connected" }.count
                    let scope = applicationWide ? "tous les jeux" : (catalog.first(where: { $0.id == requestedGame })?.name ?? "Tout le studio")
                    studioSyncSummary = failures == 0
                        ? "Synchronisation terminée · " + scope + " · " + requestedRange.label
                        : "Synchronisation partielle · \(requestedRange.label) · \(failures) rubrique(s) non actualisée(s)"
                }
                if summarizesViews || forExport, range == requestedRange {
                    publishAIFolder(gameIDs: applicationWide ? contexts : [requestedGame])
                }
                if accessMode == "personal", requestedPage == .library { settingsMessage = "Bibliothèque connectée · \(catalog.count) jeu(x) lus dans Firebase." }
            } catch is CancellationError { }
            catch {
                guard current == generation, !Task.isCancelled else { return }
                let accessDenied = (error as? GameMetrikError) == .http(401) || (error as? GameMetrikError) == .http(403)
                if requestedPage == .dashboard, !forExport, !applicationWide, showingCachedDashboard, dashboard != nil, !accessDenied {
                    cacheMessage = "Mise à jour impossible. Les dernières données en cache restent affichées."
                    return
                }
                // A refusal purges protected data from memory. The encrypted file stays: it is unreadable
                // without the Keychain key, and one refused source must not erase other providers' history.
                if accessDenied { aggregateCache = nil; aggregateCacheScope = nil; showingCachedDashboard = false; localViews = [:]; localViewFailures = [:]; studioSyncResults = [] }
                if summarizesViews { studioSyncSummary = "Synchronisation interrompue. " + ((error as? GameMetrikError)?.localizedDescription ?? "Vérifie le réseau et les connexions.") }
                if forExport { finishExportPreparation(status: "failed", detail: (error as? GameMetrikError)?.localizedDescription ?? "Synchronisation impossible.") }
                if accessMode == "personal", let service = error as? GameMetrikError, service == .http(401) || service == .http(403) {
                    self.error = "Accès administrateur refusé. Vérifie les connexions dans les réglages, puis les droits du compte chez le fournisseur."
                } else { self.error = error.localizedDescription }
                dashboard = nil; directory = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil; selectedPlayerID = nil
                if let service = error as? GameMetrikError, service == .http(401) || service == .http(403) { membership = nil; games = []; dashboard = nil; directory = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil }
            }
        }
        return refreshTask
    }
    private func applyPersonal(_ connections: PersonalConnections) {
        // No cache wipe here: the next preparation adopts the new sources and drops only what they invalidate.
        // Views kept in memory, though, were computed from the previous sources: never show them as the latest sync.
        if let previous = personal, previous.projectID != connections.projectID ||
            AggregateCache.sourceIdentities(previous) != AggregateCache.sourceIdentities(connections) {
            cancelRefresh()
            localViews = [:]; localViewFailures = [:]; studioSyncResults = []; studioSyncSummary = nil
            dashboard = nil; directory = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil
            showingCachedDashboard = false
        }
        personal = connections; personalReady = true; personalProject = connections.projectID
        hasAppleConfiguration = connections.apple != nil
        reportBucket = connections.googlePlayReportBucket ?? ""; appleVendor = connections.apple?.vendor ?? ""
        appleIssuerID = connections.apple?.issuerID ?? ""; appleKeyID = connections.apple?.keyID ?? ""
        checkTask?.cancel(); checkGeneration += 1; checkingConnections = false; connectionChecks = []
        updateAISyncBundle()
        personalSummary = ["Firebase : compte de service importé", "Supabase : \(connections.supabase.count) connexion(s) importée(s)", connections.admob == nil ? "AdMob : identifiants absents" : "AdMob : identifiants importés, accès à vérifier", connections.apple?.hasKey == true ? "Apple : clé importée, accès à vérifier" : "Apple : clé .p8 manquante", connections.googlePlay == nil ? "Google Play : compte absent" : "Google Play : compte importé, droits à vérifier"] + connections.notes
    }
    func saveBallparkConnection(secret: String) {
        do {
            guard var connections = personal else { throw GameMetrikError.message("Importe d’abord les connexions GameMetrik existantes.") }
            let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            let project = PersonalSupabase(
                ref: Game.ballparkProjectRef,
                name: "Ballpark",
                url: URL(string: "https://\(Game.ballparkProjectRef).supabase.co")!,
                timezone: "Europe/Zurich",
                secret: value
            )
            try project.validate()
            connections.supabase.removeAll { $0.ref == project.ref }
            connections.supabase.append(project)
            let data = try JSONEncoder().encode(connections)
            let context = try requireUnlocked()
            try Vault.write(data, account: "personal.connections", context: context)
            guard try Vault.read("personal.connections", context: context) == data else {
                throw GameMetrikError.message("La connexion Ballpark n’a pas pu être relue dans le trousseau.")
            }
            cancelRefresh()
            applyPersonal(connections)
            games = Game.addingPersonalSources(to: games)
            settingsMessage = "Connexion Ballpark enregistrée dans le trousseau. La prochaine synchronisation lira les rapports administratifs dédiés."
        } catch {
            settingsMessage = "Connexion Ballpark impossible : " + error.localizedDescription
        }
    }
    func changeAccess(_ mode: String) {
        refreshTask?.cancel(); generation += 1
        localViews = [:]; localViewFailures = [:]; studioSyncResults = []; studioSyncSummary = nil; synchronizingViews = false
        accessMode = mode; UserDefaults.standard.set(mode, forKey: "access.mode")
        UserDefaults.standard.set(!demo && mode == "personal", forKey: "personal.live")
        games = demo ? Demo.games : []; membership = nil; directory = nil; dashboard = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil; selectedPlayerID = nil; loadedAt = nil
        refresh(mode: .local)
    }
    func selectPersonalOrganization(_ id: String) {
        cancelRefresh(); studioSyncResults = []; studioSyncSummary = nil
        personalOrganization = id; UserDefaults.standard.set(id, forKey: "personal.organization")
        updateAISyncBundle()
        gameID = "all"; games = []; directory = nil; dashboard = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil; selectedPlayerID = nil
        refresh(mode: .local)
    }
    /// Exports every personal administration key: only from that mode, and only after a fresh owner authentication,
    /// never covered by the session unlock (a Mac left unlocked must not hand the keys over in two clicks).
    func prepareMobileTransfer(confirmOwner: () async throws -> Void = OwnerConfirmation.transfer) async throws -> (data: Data, code: String) {
        guard accessMode == "personal", !demo else {
            throw GameMetrikError.message("Le transfert vers l’iPhone n’est disponible qu’en Administration personnelle.")
        }
        let context = try requireUnlocked()
        try context.checkAuthorized()
        guard personal != nil else { throw GameMetrikError.message("Importe tes connexions et synchronise ton organisation avant de préparer l’iPhone.") }
        try await confirmOwner()
        guard accessMode == "personal", !demo, !isLocked, let personal else {
            throw GameMetrikError.message("GameMetrik a changé de mode ou s’est verrouillé pendant la confirmation. Recommence.")
        }
        let payload = MobileConnectionPayload(connections: personal, organization: personalOrganization, googlePlayOverrides: googlePlayOverrides)
        let code = MobileConnectionTransfer.newCode()
        return (try MobileConnectionTransfer.seal(payload, code: code), code)
    }

    func importPersonalConnections() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choisis le dossier contenant .env.local. Les identifiants seront conservés uniquement dans le trousseau de ce Mac."
        guard panel.runModal() == .OK, let url = panel.url, !isLocked else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let (connections, preserved) = try PersonalConnections.read(directory: url).preservingManualSettings(from: personal)
            let context = try requireUnlocked(), data = try JSONEncoder().encode(connections)
            try Vault.write(data, account: "personal.connections", context: context)
            guard try Vault.read("personal.connections", context: context) == data else {
                throw GameMetrikError.message("L’enregistrement des connexions n’a pas pu être vérifié.")
            }
            refreshTask?.cancel(); generation += 1; personalTokens = ServiceAccountTokens()
            if personalProject != connections.projectID { personalOrganization = ""; personalOrganizations = []; UserDefaults.standard.removeObject(forKey: "personal.organization") }
            authGeneration += 1; authentication.cancel(); authenticating = false
            applyPersonal(connections)
            accessMode = "personal"; UserDefaults.standard.set(accessMode, forKey: "access.mode")
            settingsMessage = "Connexions enregistrées dans le trousseau."
                + (preserved.isEmpty ? "" : " Conservé depuis GameMetrik : " + preserved.joined(separator: ", ") + ".")
                + " Ouverture de ta bibliothèque…"
            destination = .library; gameID = "all"; games = []; dashboard = nil; directory = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil; selectedPlayerID = nil
            if demo { setMode(false) } else { refresh(mode: .local) }
        } catch { settingsMessage = "Import impossible : " + error.localizedDescription }
    }
    func forgetPersonalConnections() {
        do {
            clearAggregateCache()
            try Vault.remove("personal.connections", context: requireUnlocked())
            refreshTask?.cancel(); generation += 1; personalTokens = ServiceAccountTokens()
            checkTask?.cancel(); checkGeneration += 1; checkingConnections = false; connectionChecks = []; hasAppleConfiguration = false
            personal = nil; personalReady = false; personalProject = ""; personalSummary = []; personalOrganizations = []; personalOrganization = ""
            UserDefaults.standard.removeObject(forKey: "personal.organization"); UserDefaults.standard.set(false, forKey: "personal.live")
            settingsMessage = "Identifiants personnels retirés du trousseau. Le projet d’origine est conservé."
            // The AI copy and the AI folder hold the same access and statistics: they go with the connections.
            disableAISync()
            if let failure = removeAIFolderContents() { settingsMessage = (settingsMessage ?? "") + " " + failure }
            if accessMode == "personal" { games = []; directory = nil; dashboard = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil; selectedPlayerID = nil; refresh(mode: .local) }
        } catch { settingsMessage = error.localizedDescription }
    }
    func verifyPersonalConnections() {
        guard !isLocked, let personal, !checkingConnections else { return }
        checkGeneration += 1; let current = checkGeneration
        checkingConnections = true; connectionChecks = []
        checkTask = Task {
            let results = await ConnectionChecks.run(personal, http: http, auroraProjectRefs: Set(games.filter(\.usesAuroraJourney).compactMap { $0.integrations.supabaseProjectRef }))
            guard current == checkGeneration, !Task.isCancelled else { return }
            connectionChecks = results; checkingConnections = false
            settingsMessage = "Vérification terminée. Chaque résultat précise la lecture testée ; aucune synchronisation fournisseur n’a été lancée."
        }
    }
    func importAppleKey() {
        guard var connections = personal, !isLocked else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choisis le fichier AuthKey_….p8 téléchargé depuis App Store Connect. Son Key ID sera repris automatiquement."
        guard panel.runModal() == .OK, let url = panel.url, !isLocked else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 20_000 else { throw GameMetrikError.message("Le fichier est trop volumineux pour une clé Apple.") }
            connections.apple = try PersonalApple.importingKey(Data(contentsOf: url), fileName: url.lastPathComponent,
                issuerID: appleIssuerID, keyID: appleKeyID, vendor: appleVendor)
            connections.notes.removeAll { $0.hasPrefix("Apple :") }
            let context = try requireUnlocked(), data = try JSONEncoder().encode(connections)
            try Vault.write(data, account: "personal.connections", context: context)
            guard try Vault.read("personal.connections", context: context) == data else {
                throw GameMetrikError.message("L’enregistrement de la clé Apple n’a pas pu être vérifié.")
            }
            cancelRefresh(); dashboard = nil
            applyPersonal(connections); settingsMessage = "Clé Apple enregistrée dans le trousseau. Vérification de l’accès…"
            verifyPersonalConnections()
        } catch { settingsMessage = error.localizedDescription }
    }
    func secureOriginalFiles() {
        guard let personal, !isLocked else { return }
        let revision = securityGeneration
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choisis le dossier de la web app. Après sauvegarde protégée et vérification, ses identifiants en clair seront retirés. La web app passera en démonstration."
        guard panel.runModal() == .OK, let directory = panel.url, revision == securityGeneration else { return }
        let scoped = directory.startAccessingSecurityScopedResource()
        var additional: [URL] = []
        defer {
            if scoped { directory.stopAccessingSecurityScopedResource() }
            additional.forEach { $0.stopAccessingSecurityScopedResource() }
        }
        do {
            // The sandbox grants no automatic access to a key referenced outside the selected directory.
            for url in try SourceCleanup.referencedKeys(directory: directory) where !url.path.hasPrefix(directory.path + "/") {
                if url.pathExtension == "p8", personal.apple?.hasKey != true { continue }
                let keyPanel = NSOpenPanel(); keyPanel.canChooseDirectories = false; keyPanel.allowsMultipleSelection = false
                keyPanel.directoryURL = url.deletingLastPathComponent()
                keyPanel.message = "Sélectionne \(url.lastPathComponent) pour autoriser sa sauvegarde protégée et son retrait."
                guard keyPanel.runModal() == .OK, let selected = keyPanel.url,
                      selected.standardizedFileURL == url.standardizedFileURL, revision == securityGeneration else { return }
                if selected.startAccessingSecurityScopedResource() { additional.append(selected) }
            }
            let plan = try SourceCleanup.prepare(directory: directory, connections: personal)
            let context = try requireUnlocked()
            // Keep every recovery generation: a repeated cleanup must not replace an earlier backup.
            let account = "source-backup." + UUID().uuidString
            var backup = try plan.encodedBackup()
            defer { backup.resetBytes(in: 0..<backup.count) }
            try Vault.write(backup, account: account, context: context)
            guard var confirmed = try Vault.read(account, context: context), confirmed == backup else { throw GameMetrikError.message("La sauvegarde du trousseau n’a pas pu être vérifiée.") }
            defer { confirmed.resetBytes(in: 0..<confirmed.count) }
            guard revision == securityGeneration else { throw CancellationError() }
            let removed = try plan.commit(verifiedBackup: confirmed)
            settingsMessage = "Fichiers sécurisés : \(removed.joined(separator: ", ")). Une sauvegarde authentifiée est conservée dans le trousseau. L’ancienne web app n’a plus ses accès de production."
            UserDefaults.standard.set(Date(), forKey: "sources.securedAt")
        } catch { settingsMessage = "Nettoyage interrompu : " + error.localizedDescription + " Les originaux déjà sauvegardés restent récupérables dans le trousseau." }
    }
    private func saveSession(_ session: AuthSession) throws {
        guard let config else { return }
        try Vault.write(JSONEncoder().encode(session), account: "firebase." + config.projectID, context: requireUnlocked())
    }
    func inspectWebConfiguration() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choisis le dossier de la web app contenant .env.local. Ce diagnostic ne copie aucun secret et ne modifie aucun fichier."
        guard panel.runModal() == .OK, let directory = panel.url, !isLocked else { return }
        let scoped = directory.startAccessingSecurityScopedResource(); defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        do {
            webConfigurationAudit = try WebConfigurationAudit.inspect(directory: directory)
            settingsMessage = "Diagnostic terminé. La présence d’un identifiant ne confirme pas sa validité auprès du fournisseur."
        } catch {
            webConfigurationAudit = nil
            settingsMessage = error.localizedDescription
        }
    }
    func importFirebase() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.propertyList]; panel.canChooseDirectories = false
        panel.message = "Sélectionne GoogleService-Info.plist pour ch.gamemetrik.native."
        guard panel.runModal() == .OK, let url = panel.url, !isLocked else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            var imported = try NativeConfiguration.readPlist(Data(contentsOf: url))
            imported.organizationID = organization.isEmpty ? nil : organization.trimmingCharacters(in: .whitespacesAndNewlines)
            if config != nil { try logout() }
            config = imported; try persistConfiguration()
            settingsMessage = "Configuration de \(imported.projectID) importée. Tu peux te connecter avec Google."
        } catch { settingsMessage = error.localizedDescription }
    }
    func importSupabase() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.message = "Configurations publiques uniquement : ref, url, publishableKey, timezone."
        guard panel.runModal() == .OK, let url = panel.url, !isLocked else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url); supabaseProjects = try SupabaseConfiguration.read(data)
            UserDefaults.standard.set(try JSONEncoder().encode(supabaseProjects), forKey: "supabase.public")
            settingsMessage = "\(supabaseProjects.count) connexion(s) publique(s) importée(s). Les règles Supabase restent responsables de l’autorisation."
            if !demo { refresh(mode: .local) }
        } catch { settingsMessage = error.localizedDescription }
    }
    func persistConfiguration() throws {
        guard var config else { return }
        let org = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard org.isEmpty || NativeConfiguration.validID(org) else { throw GameMetrikError.message("Identifiant d’organisation invalide.") }
        config.organizationID = org.isEmpty ? nil : org
        self.config = config; UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "firebase.native")
    }
    func saveOrganization() {
        do { try persistConfiguration(); membership = nil; if !demo { refresh(mode: .local) }; settingsMessage = "Organisation enregistrée." }
        catch { settingsMessage = error.localizedDescription }
    }
    func connect() {
        guard !isLocked, let config, !authenticating else { return }
        authenticating = true; authGeneration += 1; let revision = authGeneration
        settingsMessage = nil
        Task {
            defer { if revision == authGeneration { authenticating = false } }
            do {
                let pkce = PKCE(); let callback = try await authentication.start(config: config, pkce: pkce)
                guard revision == authGeneration, !isLocked else { return }
                let code = try pkce.code(callback: callback, config: config)
                let result = try await FirebaseAuth(config: config, http: http).exchange(code: code, pkce: pkce)
                guard revision == authGeneration else { return }
                let member = try await Firestore(project: config.projectID, token: result.idToken, http: http).membership(uid: result.uid, preferredOrganization: config.organizationID)
                guard revision == authGeneration else { return }
                try saveSession(result); session = result; membership = member
                settingsMessage = "Connecté à \(member.organization)."; changeAccess("member"); setMode(false); refresh(mode: .local)
            } catch {
                guard revision == authGeneration else { return }
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { settingsMessage = "Connexion annulée." }
                else { settingsMessage = error.localizedDescription }
            }
        }
    }
    func logout() throws {
        if let config { try Vault.remove("firebase." + config.projectID, context: requireUnlocked()) }
        authGeneration += 1; authentication.cancel(); authenticating = false
        refreshTask?.cancel(); generation += 1
        localViews = [:]; localViewFailures = [:]; activeRefreshKey = nil; studioSyncResults = []; studioSyncSummary = nil; synchronizingViews = false
        selectedPlayerID = nil; session = nil; membership = nil; games = []; dashboard = nil; directory = nil; reviews = []; ballparkAnalytics = nil; auroraJourney = nil; auroraInsights = nil; loadedAt = nil
        if demo { games = Demo.games; refresh(mode: .local) } else { error = "Compte déconnecté. Reconnecte-toi dans les réglages."; loading = false }
    }
}
