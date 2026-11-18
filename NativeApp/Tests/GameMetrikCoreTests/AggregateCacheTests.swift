import Foundation
import Testing
@testable import GameMetrikCore

struct AggregateCacheTests {
    let now = Dates.parse("2026-09-07T12:00:00Z")!
    func report(_ window: SyncWindow) -> ProviderReport {
        ProviderReport(gameID: "game", provider: "apple", title: "Apple", days: Dictionary(uniqueKeysWithValues: window.days.map { ($0, FinancialDay(money: ["CHF": 2], installs: 3, appleIAPNetUnits: 1)) }), note: "Test")
    }
    @Test func encryptedRoundTripRejectsTamperingWrongKeyAndWrongScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AggregateCacheStore(directory: directory), key = AggregateCacheStore.newKey(), scope = String(repeating: "a", count: 64)
        var cache = AggregateCache(); cache.games = Demo.games
        cache.save(Demo.dashboard(range: .month, gameID: nil), now: Date())
        try store.write(cache, scope: scope, key: key)
        let file = try store.file(scope), encrypted = try Data(contentsOf: file)
        #expect(!String(decoding: encrypted, as: UTF8.self).contains(Demo.games[0].name))
        #expect(try store.read(scope: scope, key: key)?.games == Demo.games)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(throws: (any Error).self) { try store.read(scope: scope, key: AggregateCacheStore.newKey()) }
        let otherScope = String(repeating: "b", count: 64)
        try encrypted.write(to: store.file(otherScope))
        #expect(throws: (any Error).self) { try store.read(scope: otherScope, key: key) }
        var corrupted = encrypted; corrupted[corrupted.count - 1] ^= 1; try corrupted.write(to: file)
        #expect(throws: (any Error).self) { try store.read(scope: scope, key: key) }
        try store.remove(scope: scope)
        #expect(try store.read(scope: scope, key: key) == nil)
        try store.removeAll()
        #expect(try store.read(scope: otherScope, key: key) == nil)
    }
    @Test func onlyMissingRecentOrExpiredDaysAreRequested() throws {
        var cache = AggregateCache()
        let window = try SyncWindow(range: .month, now: now)
        var current = report(window)
        for day in current.days.keys { current.days[day]?.allocate(2, currency: "CHF", country: "CH", platform: "ios") }
        _ = cache.merge(current, window: window)
        #expect(cache.requestedWindow(window, gameID: "game", providers: ["apple"], force: false).days.isEmpty)
        #expect(cache.requestedWindow(window, gameID: "game", providers: ["apple"], force: true).days == window.days)
        cache.reports["game/apple"]?.removeValue(forKey: "2026-08-12")
        var later = window; later.now = now.addingTimeInterval(901)
        let needed = cache.requestedWindow(later, gameID: "game", providers: ["apple"], force: false).days
        #expect(needed.contains("2026-08-12"))
        #expect(needed.contains("2026-09-06"))
        #expect(!needed.contains("2026-08-13"))
        later.now = now.addingTimeInterval(8 * 86400)
        #expect(cache.requestedWindow(later, gameID: "game", providers: ["apple"], force: false).days == window.days)
    }
    @Test func settledDaysOfAYearAreNotReadAgainWeekly() throws {
        var cache = AggregateCache()
        let window = try SyncWindow(range: .year, now: now)
        var current = report(window)
        for day in current.days.keys { current.days[day]?.allocate(2, currency: "CHF", country: "CH", platform: "ios") }
        _ = cache.merge(current, window: window)
        var later = window; later.now = now.addingTimeInterval(30 * 86400)
        let needed = cache.requestedWindow(later, gameID: "game", providers: ["apple"], force: false, refreshRecent: true).days
        // Only days younger than 45 days when they were read are rechecked; the rest of the year is reused.
        #expect(needed.count == 45)
        #expect(!needed.contains(window.start)); #expect(!needed.contains("2026-07-24"))
        #expect(needed.contains("2026-07-25")); #expect(needed.contains(window.end))
        #expect(cache.requestedWindow(later, gameID: "game", providers: ["apple"], force: true).days == window.days)
        // A day read too early is settled after its weekly recheck once 45 days have passed.
        var recheck = current; recheck.days = current.days.filter { needed.contains($0.key) }
        _ = cache.merge(recheck, window: later)
        var next = later; next.now = later.now.addingTimeInterval(8 * 86400)
        let following = cache.requestedWindow(next, gameID: "game", providers: ["apple"], force: false).days
        #expect(!following.contains("2026-07-25")); #expect(following.contains("2026-09-01"))
    }
    @Test func studioClickAlwaysRechecksRecentDaysWithoutReloadingAllHistory() throws {
        var cache = AggregateCache()
        let window = try SyncWindow(range: .month, now: now)
        var current = report(window)
        for day in current.days.keys { current.days[day]?.allocate(2, currency: "CHF", country: "CH", platform: "ios") }
        _ = cache.merge(current, window: window)
        let days = cache.requestedWindow(window, gameID: "game", providers: ["apple"], force: false, refreshRecent: true).days
        #expect(days.contains(window.end)); #expect(days.contains("2026-09-06"))
        #expect(!days.contains(window.start)); #expect(days.count < window.days.count)
    }
    @Test func oldCoverageIsRecomputedWithoutDiscardingReceivedReports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AggregateCacheStore(directory: directory), key = AggregateCacheStore.newKey(), scope = String(repeating: "c", count: 64)
        var old = AggregateCache(); old.version = 1
        let window = try SyncWindow(range: .week, now: now)
        _ = old.merge(report(window), window: window)
        old.save(Demo.dashboard(range: .week, gameID: "game"), now: Date())
        try store.write(old, scope: scope, key: key)
        let migrated = try #require(try store.read(scope: scope, key: key))
        #expect(migrated.version == 2)
        #expect(migrated.snapshots.isEmpty)
        #expect(migrated.reports["game/apple"]?.count == 7)
    }
    @Test func correctionsReplaceTotalsAndFailuresKeepLastKnownValues() throws {
        var cache = AggregateCache(); let window = try SyncWindow(range: .week, now: now)
        _ = cache.merge(report(window), window: window)
        let corrected = ProviderReport(gameID: "game", provider: "apple", title: "Apple", days: ["2026-09-03": FinancialDay(money: ["CHF": 0], installs: 0)], note: "Network error on remaining dates")
        let merged = cache.merge(corrected, window: window)
        #expect(merged.days["2026-09-03"]?.money["CHF"] == 0)
        #expect(merged.days["2026-09-04"]?.money["CHF"] == 2)
        #expect(merged.days.count == 7)
        #expect(merged.note.contains("Network error"))
        #expect(merged.note.contains("6 jour(s)"))
        #expect(cache.reports["game/apple"]?["2026-09-03"]?.value.installs == 0)
    }
    @Test func freshnessIsBoundedAndSnapshotsNeverCrossGamesOrPeriods() throws {
        var snapshot = Demo.dashboard(range: .month, gameID: "game")
        snapshot.generatedAt = Dates.iso(now)
        var cache = AggregateCache(); cache.save(snapshot, now: now)
        #expect(cache.snapshot(gameID: "game", range: .month) != nil)
        #expect(cache.snapshot(gameID: "other", range: .month) == nil)
        #expect(cache.snapshot(gameID: "game", range: .week) == nil)
        #expect(cache.snapshot(gameID: nil, range: .month) == nil)
        #expect(AggregateCache.isFresh(snapshot, now: now.addingTimeInterval(899)))
        #expect(!AggregateCache.isFresh(snapshot, now: now.addingTimeInterval(900)))
        #expect(!AggregateCache.isFresh(snapshot, now: now.addingTimeInterval(-1)))
        snapshot.generatedAt = "2026-09-07T21:59:00Z"
        #expect(!AggregateCache.isFresh(snapshot, now: Dates.parse("2026-09-07T22:01:00Z")!))
        cache.reconcile(games: Demo.games)
        #expect(cache.snapshot(gameID: "game", range: .month) == nil)
    }
    @Test func sparseAdMobDaysNeverRequestGapsAsIfTheyWereAbsent() throws {
        #expect(try NativeReports.contiguousChunks(["2026-08-01", "2026-08-02", "2026-08-04", "2026-08-07"]) == [["2026-08-01", "2026-08-02"], ["2026-08-04"], ["2026-08-07"]])
        let window = try SyncWindow(range: .month, now: now)
        #expect(try NativeReports.contiguousChunks(window.days).map(\.count) == [28, 2])
    }
    @Test func cacheScopeFollowsTheWorkspaceNotEditableSettings() throws {
        let key = AggregateCacheStore.newKey()
        let original = AggregateCacheStore.scope(projectID: "test", organization: "one", key: key)
        #expect(original.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil)
        #expect(original == AggregateCacheStore.scope(projectID: "test", organization: "one", key: key))
        #expect(original != AggregateCacheStore.scope(projectID: "test", organization: "two", key: key))
        #expect(original != AggregateCacheStore.scope(projectID: "other", organization: "one", key: key))
        #expect(original != AggregateCacheStore.scope(projectID: "test", organization: "one", key: AggregateCacheStore.newKey()))
        // The legacy name still depends on every credential; it is only used to adopt an old file.
        let (account, _) = try PersonalConnectionsTests().keyPair()
        var connections = PersonalConnections(projectID: "test", firebase: account, supabase: [], importedAt: now, notes: [])
        let legacy = try AggregateCacheStore.legacyScope(connections: connections, organization: "one", googlePlay: [:], key: key)
        connections.apple = PersonalApple(issuerID: "issuer", keyID: "key", vendor: "123")
        #expect(legacy != (try AggregateCacheStore.legacyScope(connections: connections, organization: "one", googlePlay: [:], key: key)))
    }
    private func filledCache() throws -> (AggregateCache, SyncWindow) {
        let window = try SyncWindow(range: .week, now: now)
        var cache = AggregateCache(); cache.games = Demo.games
        for game in ["aurora-grove", "orbit-tactics"] {
            for provider in ["admob", "apple", "google-installs", "google-earnings"] {
                var fresh = report(window); fresh.gameID = game; fresh.provider = provider
                _ = cache.merge(fresh, window: window)
            }
            cache.engagement[AggregateCache.snapshotID(gameID: game, range: .week)] = .init(value: Engagement(daily: [:], monthly: 1, retained: 0, eligible: 0), fetchedAt: now)
            var snapshot = Demo.dashboard(range: .week, gameID: game); snapshot.generatedAt = Dates.iso(now)
            cache.save(snapshot, now: now)
        }
        var studio = Demo.dashboard(range: .week, gameID: nil); studio.generatedAt = Dates.iso(now); cache.save(studio, now: now)
        return (cache, window)
    }
    @Test func catalogEditsKeepProviderDaysAndStoreChangesDropOnlyThatGame() throws {
        var (cache, _) = try filledCache()
        var games = Demo.games
        games[0].currentVersion = "9.9.9"; games[0].name = "Aurora Grove+"; games[0].description = "Nouvelle description"
        cache.reconcile(games: games)
        #expect(cache.reports.count == 8); #expect(cache.engagement.count == 2)
        #expect(cache.snapshot(gameID: nil, range: .week) == nil)
        games[1].integrations.appleAppId = "999"
        cache.reconcile(games: games)
        #expect(cache.reports.keys.filter { $0.hasPrefix("orbit-tactics/") }.isEmpty)
        #expect(cache.reports.keys.filter { $0.hasPrefix("aurora-grove/") }.count == 4)
        #expect(cache.engagement.keys.allSatisfy { $0.hasPrefix("game:aurora-grove/") })
        cache.reconcile(games: games.filter { $0.id != "aurora-grove" })
        #expect(cache.reports.isEmpty)
    }
    @Test func anotherProviderAccountDropsOnlyThatProvider() throws {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        var connections = PersonalConnections(projectID: "test", firebase: account, supabase: [], admob: PersonalAdMob(clientID: "c", clientSecret: "s", refreshToken: "r", publisherID: "pub-1"), apple: PersonalApple(issuerID: "issuer", keyID: "KEY", vendor: "123"), googlePlayReportBucket: "bucket", importedAt: now, notes: [])
        var (cache, _) = try filledCache()
        cache.adopt(sources: AggregateCache.sourceIdentities(connections))
        #expect(cache.reports.count == 8); #expect(cache.snapshot(gameID: nil, range: .week) != nil)
        // A new key for the same vendor, an Ballpark project or a new import date change nothing.
        connections.apple = PersonalApple(issuerID: "issuer", keyID: "OTHERKEY01", privateKey: "new", vendor: "123")
        connections.importedAt = now.addingTimeInterval(60); connections.notes = ["Note"]
        cache.adopt(sources: AggregateCache.sourceIdentities(connections))
        #expect(cache.reports.count == 8); #expect(cache.snapshot(gameID: nil, range: .week) != nil)
        connections.apple?.vendor = "456"
        cache.adopt(sources: AggregateCache.sourceIdentities(connections))
        #expect(cache.reports.keys.allSatisfy { !$0.hasSuffix("/apple") }); #expect(cache.reports.count == 6)
        #expect(cache.engagement.count == 2); #expect(cache.snapshot(gameID: nil, range: .week) == nil)
        connections.googlePlayReportBucket = "other"
        cache.adopt(sources: AggregateCache.sourceIdentities(connections))
        #expect(cache.reports.keys.sorted() == ["aurora-grove/admob", "orbit-tactics/admob"])
        connections.supabase = [PersonalSupabase(ref: "p", name: "P", url: URL(string: "https://p.supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_test_only_value")]
        cache.adopt(sources: AggregateCache.sourceIdentities(connections))
        #expect(cache.engagement.isEmpty); #expect(cache.reports.count == 2)
    }
    @Test func sourceToggleRecomputesOnlyTheAffectedDashboards() throws {
        var (cache, _) = try filledCache()
        cache.invalidateSnapshots(gameID: "aurora-grove")
        #expect(cache.snapshot(gameID: "aurora-grove", range: .week) == nil)
        #expect(cache.snapshot(gameID: nil, range: .week) == nil)
        #expect(cache.snapshot(gameID: "orbit-tactics", range: .week) != nil)
        #expect(cache.reports.count == 8)
    }
    @Test func existingCacheIsAdoptedOnceUnderTheStableName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AggregateCacheStore(directory: directory), key = AggregateCacheStore.newKey()
        let (account, _) = try PersonalConnectionsTests().keyPair()
        let connections = PersonalConnections(projectID: "test", firebase: account, supabase: [], importedAt: now, notes: [])
        let legacy = try AggregateCacheStore.legacyScope(connections: connections, organization: "org", googlePlay: [:], key: key)
        let (cache, _) = try filledCache()
        try store.write(cache, scope: legacy, key: key)
        let restored = try #require(try store.read(scope: legacy, key: key))
        #expect(restored.sources == nil)
        var adopted = restored; adopted.adopt(sources: AggregateCache.sourceIdentities(connections))
        #expect(adopted.reports.count == 8); #expect(adopted.snapshot(gameID: nil, range: .week) != nil)
    }
    @Test func cachedDaysKeepTimezoneAndOriginalReadDateAfterRestart() throws {
        let window = try SyncWindow(range: .week, now: now)
        var cache = AggregateCache()
        var ads = report(window); ads.provider = "admob"; ads.timezone = "America/Los_Angeles"
        _ = cache.merge(ads, window: window)
        cache = try JSONDecoder().decode(AggregateCache.self, from: JSONEncoder().encode(cache))
        var later = window; later.now = now.addingTimeInterval(60)
        let reused = cache.merge(ProviderReport(gameID: "game", provider: "admob", title: "AdMob", note: ""), window: later)
        #expect(reused.timezone == "America/Los_Angeles")
        #expect(reused.reusedDays.count == 7)
        #expect(Set(reused.readAt.values) == [Dates.iso(now)])
        // Caches written before timezone persistence remain readable.
        let legacy = try JSONDecoder().decode(CachedFinancialDay.self, from: Data(#"{"value":{"money":{},"iap":{},"installs":0},"fetchedAt":0}"#.utf8))
        #expect(legacy.timezone == nil)
    }
    @Test func missingDaysAreFilledAndCorrectionsAreAppliedWhenDueOrForced() throws {
        let window = try SyncWindow(range: .month, now: now)
        var cache = AggregateCache()
        var original = report(window)
        for day in original.days.keys { original.days[day]?.allocate(2, currency: "CHF", country: "CH", platform: "ios") }
        _ = cache.merge(original, window: window)
        let missing = window.days[1], corrected = window.days[2]
        cache.reports["game/apple"]?.removeValue(forKey: missing)
        func collect(_ at: Date, force: Bool) -> ProviderReport {
            var request = window; request.now = at
            let days = cache.requestedWindow(request, gameID: "game", providers: ["apple"], force: force).days
            var source = original; source.days = source.days.filter { days.contains($0.key) }
            if days.contains(corrected) { source.days[corrected] = FinancialDay(money: ["CHF": 0], installs: 0, allocations: []) }
            return cache.merge(source, window: request)
        }
        let partial = collect(now.addingTimeInterval(60), force: false)
        #expect(partial.days.count == 30)
        #expect(partial.days[corrected]?.installs == 3) // Historical correction is not yet due.
        #expect(!partial.reusedDays.contains(missing))
        let forced = collect(now.addingTimeInterval(120), force: true)
        #expect(forced.days[corrected]?.installs == 0)
        _ = cache.merge(original, window: window)
        let expired = collect(now.addingTimeInterval(7 * 86400), force: false)
        #expect(expired.days[corrected]?.installs == 0)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(expired.days) == encoder.encode(forced.days))
    }

}
