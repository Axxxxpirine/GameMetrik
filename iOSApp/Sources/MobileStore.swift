import Foundation
import SwiftUI
import LocalAuthentication
import GameMetrikCore

struct MobileContext: Hashable { var gameID: String?; var range: Timeframe }
struct MobileSnapshot {
    var dashboard: Dashboard?
    var directory: PlayerDirectory?
    var reviews: [Review]?
    var ballpark: BallparkAnalyticsData?
    var errors: [String] = []
}

@MainActor final class MobileStore: ObservableObject {
    @Published private(set) var demo = false
    @Published private(set) var unlocked = false
    @Published private(set) var authenticating = false
    @Published private(set) var games: [Game] = []
    @Published private(set) var snapshots: [MobileContext: MobileSnapshot] = [:]
    @Published private(set) var loading = false
    @Published private(set) var progress = ""
    @Published var message: String?
    @Published var range: Timeframe = .month
    @Published private(set) var hasConnection = UserDefaults.standard.bool(forKey: "owner.configured")
    private var stored: MobileStoredConnection?
    private var authentication: LAContext?
    private var tokens = ServiceAccountTokens()
    private var cache = AggregateCache()
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let http: HTTPClient
    private let session: URLSession
    private let cacheStore: AggregateCacheStore

    init(http: HTTPClient? = nil, cacheDirectory: URL? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config)
        self.session = session; self.http = http ?? HTTPClient(session: session)
        let folder = cacheDirectory ?? URL.applicationSupportDirectory.appendingPathComponent("GameMetrik/Aggregates", isDirectory: true)
        cacheStore = AggregateCacheStore(directory: folder)
    }
    var workspaceLabel: String { demo ? "Démonstration · données fictives" : "Administration personnelle" }
    func snapshot(_ gameID: String?) -> MobileSnapshot {
        let key = MobileContext(gameID: gameID, range: range)
        var value = snapshots[key] ?? MobileSnapshot()
        if !demo, value.dashboard == nil { value.dashboard = cache.snapshot(gameID: gameID, range: range) }
        return value
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; loading = false; progress = ""
    }
    func lock() {
        cancel(); authentication?.invalidate(); authentication = nil
        stored = nil; snapshots = [:]; cache = .init(); games = []; unlocked = false; message = nil
        let old = tokens; tokens = .init(); Task { await old.clear() }
    }
    func exploreDemo() {
        lock(); demo = true; unlocked = true; games = Demo.games
        loadDemo(gameID: nil)
    }
    func exitDemo() { lock(); demo = false }
    func localSelection(_ gameID: String?) {
        cancel()
        if demo { loadDemo(gameID: gameID) }
    }
    private func loadDemo(gameID: String?) {
        let context = MobileContext(gameID: gameID, range: range)
        let game = games.first { $0.id == gameID }
        var value = MobileSnapshot()
        if game?.usesBallparkAnalytics == true { value.ballpark = .init(bundle: BallparkDemo.bundle) }
        else {
            value.dashboard = Demo.dashboard(range: range, gameID: gameID)
            if let game { value.directory = try? Demo.directory(range: range, game: game) }
            value.reviews = Demo.reviews().filter { gameID == nil || $0.gameId == gameID }
        }
        snapshots[context] = value
    }
    func unlock() async {
        guard !authenticating else { return }
        authenticating = true; message = nil
        let current = generation
        let context = LAContext(); authentication = context
        context.localizedCancelTitle = "Annuler"
        defer { authenticating = false }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "consulter les données privées de ton studio")
            guard current == generation else { return }
            guard let data = try MobileVault.read(context: context) else {
                hasConnection = false; UserDefaults.standard.set(false, forKey: "owner.configured")
                throw GameMetrikError.message("Importe une connexion préparée depuis GameMetrik sur le Mac.")
            }
            let saved = try JSONDecoder().decode(MobileStoredConnection.self, from: data)
            try saved.payload.connections.validate()
            stored = saved; demo = false; unlocked = true
            cache = (try? cacheStore.read(scope: scope(saved), key: saved.cacheKey)) ?? .init()
            games = cache.games
        } catch { if current == generation { message = error.localizedDescription } }
    }
    func importConnection(data: Data, code: String) async -> Bool {
        guard !authenticating else { return false }
        authenticating = true; message = nil
        let current = generation
        let context = LAContext(); authentication = context
        defer { authenticating = false }
        do {
            let payload = try MobileConnectionTransfer.open(data, code: code)
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "enregistrer les connexions personnelles de GameMetrik sur cet iPhone")
            guard current == generation else { return false }
            let saved = MobileStoredConnection(payload: payload, cacheKey: AggregateCacheStore.newKey())
            try MobileVault.save(JSONEncoder().encode(saved), context: context)
            cancel(); snapshots = [:]; cache = .init(); games = []; tokens = .init()
            stored = saved; demo = false; unlocked = true; hasConnection = true
            UserDefaults.standard.set(true, forKey: "owner.configured")
            try? cacheStore.removeAll()
            return true
        } catch { if current == generation { message = error.localizedDescription }; return false }
    }
    func removeConnection() {
        guard let authentication, !demo, unlocked else { return }
        do {
            try MobileVault.remove(context: authentication)
            try? cacheStore.removeAll(); lock(); demo = false; hasConnection = false
            UserDefaults.standard.set(false, forKey: "owner.configured")
        } catch { message = error.localizedDescription }
    }
    private func scope(_ saved: MobileStoredConnection) -> String {
        AggregateCacheStore.scope(projectID: saved.payload.connections.projectID, organization: saved.payload.organization, key: saved.cacheKey)
    }
    private func persist() {
        guard let stored else { return }
        do {
            try cacheStore.write(cache, scope: scope(stored), key: stored.cacheKey)
            let files = try FileManager.default.contentsOfDirectory(at: cacheStore.directory, includingPropertiesForKeys: nil)
            for file in files { try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path) }
        } catch { message = "Données reçues, mais leur cache local n’a pas pu être enregistré." }
    }
    @discardableResult func synchronize(gameID: String?) -> Task<Void, Never>? {
        guard unlocked, !loading else { return nil }
        if demo { loadDemo(gameID: gameID); return nil }
        guard let stored else { return nil }
        let current = generation; let context = MobileContext(gameID: gameID, range: range)
        loading = true; progress = "Lecture du catalogue…"; message = nil
        task = Task {
            defer { if current == generation { loading = false; progress = ""; task = nil } }
            do {
                let connections = stored.payload.connections
                let token = try await tokens.token(account: connections.firebase, scopes: ["https://www.googleapis.com/auth/datastore"], http: http)
                let firestore = Firestore(project: connections.projectID, token: token, http: http)
                let root = ["organizations", stored.payload.organization]
                let remote: [Game] = try await firestore.list(root + ["games"])
                try Task.checkCancellation(); guard current == generation else { return }
                let catalog = Game.addingPersonalSources(to: remote)
                games = catalog; cache.reconcile(games: catalog); cache.adopt(sources: AggregateCache.sourceIdentities(connections))
                cache.catalogSyncedAt = Date()
                guard gameID == nil || catalog.contains(where: { $0.id == gameID }) else { throw GameMetrikError.message("Ce jeu n’est plus disponible dans le catalogue. Reviens à la liste des jeux.") }
                let game = catalog.first { $0.id == gameID }
                var value = snapshot(gameID); value.errors = []
                if game?.usesBallparkAnalytics == true {
                    progress = "Ballpark · cinq rapports…"
                    guard let ref = game?.integrations.supabaseProjectRef, let project = connections.supabase.first(where: { $0.ref == ref }) else {
                        throw GameMetrikError.message("Ajoute la connexion Ballpark sur le Mac, puis prépare un nouveau transfert.")
                    }
                    value.ballpark = try await loadBallpark(project: project, range: context.range)
                } else {
                    do {
                        var working = cache
                        let playIDs = Set(catalog.filter { stored.payload.googlePlayOverrides[$0.slug] ?? ($0.integrations.googlePackageName != nil || $0.platforms.contains("android")) }.map(\.id))
                        value.dashboard = try await NativeDashboardSync(http: http, tokens: tokens).runCached(games: catalog, gameID: gameID, range: context.range, connections: connections, cache: &working, refreshRecent: true, googlePlayGameIDs: playIDs) { [weak self = self] text in
                            await self?.updateProgress(text, generation: current)
                        }
                        try Task.checkCancellation(); guard current == generation else { return }; cache = working
                    } catch { try rethrowAccess(error); value.errors.append("Indicateurs : " + error.localizedDescription) }
                    if let game, let ref = game.integrations.supabaseProjectRef {
                        do {
                            progress = "Gameplay et joueurs…"
                            guard let project = connections.supabase.first(where: { $0.ref == ref }) else { throw GameMetrikError.message("Connexion Supabase absente du transfert.") }
                            value.directory = try await SupabaseReader(personal: project, http: http).directory(game: game, range: context.range)
                        } catch { try rethrowAccess(error); value.errors.append("Joueurs : " + error.localizedDescription) }
                    }
                    do {
                        progress = "Lecture des avis…"
                        let reviews: [Review] = try await firestore.list(root + ["reviews"], order: "publishedAt desc")
                        let interval = context.range.interval(now: Date(), timezone: TimeZone(identifier: "Europe/Zurich")!)
                        value.reviews = reviews.filter { review in
                            (gameID == nil || review.gameId == gameID) && Dates.parse(review.publishedAt).map { interval.contains($0) } == true
                        }
                    } catch { try rethrowAccess(error); value.errors.append("Avis : " + error.localizedDescription) }
                }
                try Task.checkCancellation(); guard current == generation else { return }
                snapshots[context] = value; persist()
            } catch is CancellationError { }
            catch {
                guard current == generation else { return }
                if error as? GameMetrikError == .http(401) || error as? GameMetrikError == .http(403) {
                    try? cacheStore.removeAll(); lock()
                    message = "Accès refusé. Les données locales ont été retirées. Vérifie les droits des connexions sur le Mac."
                } else {
                    var value = snapshots[context] ?? MobileSnapshot()
                    value.errors = [error.localizedDescription]; snapshots[context] = value
                }
            }
        }
        return task
    }
    private func rethrowAccess(_ error: Error) throws {
        if error is CancellationError || error as? GameMetrikError == .http(401) || error as? GameMetrikError == .http(403) { throw error }
    }
    private func updateProgress(_ text: String, generation: UUID) {
        if self.generation == generation { progress = text }
    }
    private func loadBallpark(project: PersonalSupabase, range: Timeframe) async throws -> BallparkAnalyticsData {
        let zone = TimeZone(identifier: "Europe/Zurich")!
        let interval = range.interval(now: Date(), timezone: zone)
        let filters = BallparkReportFilters(fromDay: Dates.day(interval.start, timezone: zone), toDayExclusive: Dates.day(interval.end, timezone: zone))
        let reader = BallparkReportReader(personal: project, http: http)
        async let a = Self.attempt { try await reader.overview(filters: filters) }
        async let b = Self.attempt { try await reader.questions(filters: filters) }
        async let c = Self.attempt { try await reader.series(filters: filters) }
        async let d = Self.attempt { try await reader.habits(filters: filters) }
        async let e = Self.attempt { try await reader.quality(filters: filters) }
        let results = await (a, b, c, d, e)
        try Task.checkCancellation()
        var data = BallparkAnalyticsData()
        func take<T>(_ result: Result<T, Error>, _ kind: BallparkReportKind) throws -> T? {
            switch result {
            case .success(let value): return value
            case .failure(let error): try rethrowAccess(error); data.errors[kind] = error.localizedDescription; return nil
            }
        }
        data.overview = try take(results.0, .overview); data.questions = try take(results.1, .questions)
        data.series = try take(results.2, .series); data.habits = try take(results.3, .habits); data.quality = try take(results.4, .quality)
        return data
    }
    nonisolated private static func attempt<T: Sendable>(_ op: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await op()) } catch { return .failure(error) }
    }
}
