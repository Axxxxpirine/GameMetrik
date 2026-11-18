import Foundation
import CryptoKit

/// Only catalog metadata, provider daily totals and computed dashboards can be persisted.
/// No player identifier, profile, event, credential or raw provider response belongs here.
public struct AggregateCache: Codable, Sendable {
    var version = 2
    public var games: [Game] = []
    public var catalogSyncedAt: Date?
    public var lastSynchronizedAt: Date? { snapshots.values.compactMap { Dates.parse($0.generatedAt) }.max() }
    var snapshots: [String: Dashboard] = [:]
    var reports: [String: [String: CachedFinancialDay]] = [:]
    var engagement: [String: CachedEngagement] = [:]
    /// Provider accounts behind the cached reports (publisher, vendor, bucket, projects).
    /// Nil in caches written before 0.14, which were scoped to the exact connections.
    var sources: [String: String]?
    public init() {}
    static func snapshotID(gameID: String?, range: Timeframe) -> String {
        (gameID.map { "game:" + $0 } ?? "portfolio") + "/" + range.rawValue
    }
    public func snapshot(gameID: String?, range: Timeframe) -> Dashboard? {
        snapshots[Self.snapshotID(gameID: gameID, range: range)]
    }
    public static func isFresh(_ snapshot: Dashboard, now: Date = Date()) -> Bool {
        guard let date = Dates.parse(snapshot.generatedAt), now >= date,
              now.timeIntervalSince(date) < 900 else { return false }
        let zone = TimeZone(identifier: "Europe/Zurich")!
        return Dates.day(date, timezone: zone) == Dates.day(now, timezone: zone)
    }
    /// Only what a catalog change really affects is dropped: a new version number or name
    /// keeps every provider day; changed store identifiers drop that game's reports only.
    public mutating func reconcile(games: [Game]) {
        guard self.games != games else { return }
        let previous = Dictionary(self.games.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Set(games.map(\.id))
        var changed = Set(previous.keys).subtracting(current)
        for game in games {
            guard let old = previous[game.id] else { continue }
            if old.integrations != game.integrations { changed.insert(game.id) }
        }
        for id in changed {
            reports = reports.filter { !$0.key.hasPrefix(id + "/") }
            engagement = engagement.filter { !$0.key.hasPrefix("game:" + id + "/") }
        }
        // Dashboards embed names, statuses and the list of active games: recompute them from kept days.
        snapshots = [:]
        self.games = games
    }
    public static func sourceIdentities(_ connections: PersonalConnections) -> [String: String] {
        ["admob": connections.admob?.publisherID ?? "",
         "apple": connections.apple?.vendor ?? "",
         "google": (connections.googlePlayReportBucket ?? "") + "|" + (connections.googlePlay?.client_email ?? ""),
         "supabase": connections.supabase.map { $0.ref + "=" + $0.url.absoluteString }.sorted().joined(separator: ",")]
    }
    /// A different provider account invalidates only that provider's days.
    public mutating func adopt(sources new: [String: String]) {
        guard let old = sources else { sources = new; return }
        guard old != new else { return }
        let providers: [String: [String]] = ["admob": ["admob"], "apple": ["apple"], "google": ["google-installs", "google-earnings"]]
        for (source, names) in providers where old[source] != new[source] {
            reports = reports.filter { key, _ in !names.contains { key.hasSuffix("/" + $0) } }
        }
        if old["supabase"] != new["supabase"] { engagement = [:] }
        snapshots = [:]
        sources = new
    }
    /// Dashboards of a game and the studio are recomputed after a change of expected sources.
    public mutating func invalidateSnapshots(gameID: String) {
        snapshots = snapshots.filter { $0.key.hasPrefix("game:") && !$0.key.hasPrefix("game:" + gameID + "/") }
    }
    mutating func save(_ snapshot: Dashboard, now: Date) {
        snapshots[Self.snapshotID(gameID: snapshot.gameId, range: snapshot.timeframe)] = snapshot
        snapshots = snapshots.filter { Dates.parse($0.value.generatedAt).map { now.timeIntervalSince($0) < 30 * 86400 } == true }
        let snapshotLimit = max(40, (games.count + 1) * Timeframe.allCases.count)
        if snapshots.count > snapshotLimit {
            snapshots = Dictionary(uniqueKeysWithValues: snapshots.sorted { $0.value.generatedAt > $1.value.generatedAt }.prefix(snapshotLimit).map { ($0.key, $0.value) })
        }
        let cutoff = Dates.day(now.addingTimeInterval(-400 * 86400), timezone: .gmt)
        engagement = engagement.filter { now.timeIntervalSince($0.value.fetchedAt) < 30 * 86400 }
        if engagement.count > 200 {
            engagement = Dictionary(uniqueKeysWithValues: engagement.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(200).map { ($0.key, $0.value) })
        }
        engagement = engagement.mapValues { cached in
            var copy = cached
            copy.value.daily = copy.value.daily.filter { $0.key >= cutoff }
            copy.value.newPlayersDaily = copy.value.newPlayersDaily?.filter { $0.key >= cutoff }
            return copy
        }
        reports = reports.mapValues { $0.filter { $0.key >= cutoff } }.filter { !$0.value.isEmpty }
    }
    /// Month-end closing and publisher corrections are past by then (AdMob, Apple, Google monthly exports).
    static let settledAfter: TimeInterval = 45 * 86400
    func requestedWindow(_ window: SyncWindow, gameID: String, providers: [String], force: Bool, refreshRecent: Bool = false) -> SyncWindow {
        var request = window
        request.days = window.days.filter { day in
            providers.contains { provider in
                guard !force, let entry = reports[gameID + "/" + provider]?[day] else { return true }
                if provider == "apple", entry.value.appleIAPNetUnits == nil { return true }
                if provider == "admob", entry.value.adImpressions == nil { return true }
                if provider != "google-installs", entry.value.allocations == nil { return true }
                let age = window.now.timeIntervalSince(entry.fetchedAt)
                // Recheck recent reports every 15 min and historical corrections weekly.
                let recent = day >= Dates.day(window.now.addingTimeInterval(-7 * 86400), timezone: .gmt)
                // A day read at least 45 days after it occurred is settled: only a full refresh reads it again.
                if !recent, age >= 0, let date = try? SyncWindow.date(day), entry.fetchedAt.timeIntervalSince(date) >= Self.settledAfter { return false }
                return (refreshRecent && recent) || age < 0 || age >= (recent ? 900 : 7 * 86400)
            }
        }
        return request
    }
    mutating func merge(_ fresh: ProviderReport, window: SyncWindow) -> ProviderReport {
        let id = fresh.gameID + "/" + fresh.provider
        for (day, value) in fresh.days { reports[id, default: [:]][day] = .init(value: value, fetchedAt: window.now, timezone: fresh.timezone) }
        var result = fresh
        for day in fresh.days.keys { result.readAt[day] = Dates.iso(window.now) }
        var reused = 0
        for day in window.days where result.days[day] == nil {
            if let cached = reports[id]?[day] {
                result.days[day] = cached.value; reused += 1
                if result.timezone == nil { result.timezone = cached.timezone }
                result.reusedDays.insert(day); result.readAt[day] = Dates.iso(cached.fetchedAt)
            }
        }
        if result.provider == "admob", let timezone = result.timezone, let zone = TimeZone(identifier: timezone) {
            let today = Dates.day(window.now, timezone: zone)
            result.pendingDays.formUnion(window.days.filter { $0 >= today })
        }
        if reused > 0 {
            result.note += " \(reused) jour(s) réutilisé(s) du cache local."
            if result.hasError { result.note += " Les derniers montants connus sont conservés malgré l’erreur de collecte." }
        }
        return result
    }
}
struct CachedEngagement: Codable, Sendable {
    var value: Engagement
    var fetchedAt: Date
}
struct CachedFinancialDay: Codable, Sendable {
    var value: FinancialDay
    var fetchedAt: Date
    var timezone: String?
}

/// AES-256-GCM authenticates both the payload and its private account/source scope.
public struct AggregateCacheStore: Sendable {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }
    public static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    /// Stable workspace identity: editing a key, vendor or source never moves the cache.
    public static func scope(projectID: String, organization: String, key: Data) -> String {
        let data = Data(("gamemetrik-cache-scope-v2\n" + projectID + "\n" + organization).utf8)
        return HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
    }
    /// Scope used before 0.14, kept only to adopt an existing cache once.
    public static func legacyScope(connections: PersonalConnections, organization: String, googlePlay: [String: Bool], key: Data) throws -> String {
        struct Scope: Encodable { var connections: PersonalConnections; var organization: String; var googlePlay: [String: Bool] }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(Scope(connections: connections, organization: organization, googlePlay: googlePlay))
        defer { data.resetBytes(in: 0..<data.count) }
        return HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
    }
    func file(_ scope: String) throws -> URL {
        guard scope.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw ReportFormats.invalid() }
        return directory.appendingPathComponent(scope + ".gmc")
    }
    public func read(scope: String, key: Data) throws -> AggregateCache? {
        guard key.count == 32 else { throw ReportFormats.invalid() }
        let url = try file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16 * 1024 * 1024 else { throw ReportFormats.invalid() }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        var data = try AES.GCM.open(sealed, using: SymmetricKey(data: key), authenticating: Data(("gamemetrik-aggregates-v1/" + scope).utf8))
        defer { data.resetBytes(in: 0..<data.count) }
        var cache = try JSONDecoder().decode(AggregateCache.self, from: data)
        guard cache.version == 1 || cache.version == 2 else { throw ReportFormats.invalid() }
        if cache.version == 1 {
            // Recompute coverage after the Apple no-sales/zero-currency fix, preserving valid daily totals.
            cache.version = 2; cache.snapshots = [:]
        }
        return cache
    }
    public func write(_ cache: AggregateCache, scope: String, key: Data) throws {
        guard key.count == 32 else { throw ReportFormats.invalid() }
        var data = try JSONEncoder().encode(cache)
        defer { data.resetBytes(in: 0..<data.count) }
        guard data.count < 16 * 1024 * 1024 - 28 else { throw ReportFormats.invalid() }
        let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: key), authenticating: Data(("gamemetrik-aggregates-v1/" + scope).utf8))
        guard let bytes = sealed.combined else { throw ReportFormats.invalid() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var folder = directory; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try folder.setResourceValues(flags)
        let url = try file(scope)
        // Persist only authenticated ciphertext. Access to its key requires Keychain user presence.
        // FileProtectionComplete can reject file creation on macOS; AES-GCM provides protection at rest.
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func remove(scope: String) throws {
        let url = try file(scope)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.range(of: #"^[a-f0-9]{64}\.gmc$"#, options: .regularExpression) != nil {
            try FileManager.default.removeItem(at: url)
        }
    }
}
