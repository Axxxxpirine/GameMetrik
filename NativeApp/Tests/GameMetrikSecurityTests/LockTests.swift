import Foundation
import AppKit
import Testing
@testable import GameMetrikNative
@testable import GameMetrikCore

// AppState instances observe global sleep notifications; keep these suites sequential.
@Suite(.serialized) @MainActor struct AppStateTests {}

extension AppStateTests {
@Suite(.serialized) @MainActor struct LockTests {
    @Test func vaultRejectsUnauthenticatedAndInvalidatedContexts() {
        let context = UnlockContext()
        #expect(throws: GameMetrikError.self) { try context.checkAuthorized() }
        #expect(throws: GameMetrikError.self) { try Vault.read("personal.connections", context: context) }
        context.invalidate()
        #expect(throws: GameMetrikError.self) { try Vault.write(Data(), account: "test", context: context) }
    }
    @Test(arguments: [RefreshMode.local, .incremental, .full])
    func startsLockedAndRefreshDoesNotRead(mode: RefreshMode) {
        let state = AppState()
        #expect(state.isLocked); #expect(state.sensitiveStateIsEmpty)
        state.refresh(mode: mode)
        #expect(!state.loading); #expect(state.sensitiveStateIsEmpty)
    }
    @Test func lockingClearsViewsAndCancelsLoading() {
        let state = AppState(); state.isLocked = false
        state.games = Demo.games
        state.dashboard = Demo.dashboard(range: .month, gameID: nil)
        state.reviews = Demo.reviews(); state.selectedPlayerID = "test"
        state.syncProgress = "Test game · provider"; state.reportBucket = "test-bucket"; state.appleVendor = "123"; state.appleIssuerID = "issuer"; state.appleKeyID = "key"
        state.aggregateCache = AggregateCache(); state.aggregateCache?.games = Demo.games
        state.aggregateCacheKey = AggregateCacheStore.newKey(); state.aggregateCacheScope = String(repeating: "a", count: 64)
        state.showingCachedDashboard = true; state.cacheMessage = "Cached statistics"
        state.localViews["test"] = LocalViewSnapshot(dashboard: nil, directory: nil, reviews: Demo.reviews(), date: Date())
        state.loading = true; state.authenticating = true; state.checkingConnections = true
        state.lock()
        #expect(state.isLocked); #expect(state.sensitiveStateIsEmpty)
        state.refresh()
        #expect(state.sensitiveStateIsEmpty)
    }
    @Test func backgroundRefreshKeepsOnlyTheMatchingDashboardVisible() {
        let state = AppState(); state.isLocked = false; state.loading = true; state.destination = .dashboard
        state.gameID = "all"; state.range = .month
        state.dashboard = Demo.dashboard(range: .month, gameID: nil)
        #expect(!state.blocksContent)
        state.range = .week
        #expect(state.blocksContent)
        state.range = .month; state.destination = .players
        #expect(state.blocksContent)
        state.lock()
    }
    @Test func workspaceSleepUsesSamePurge() async throws {
        let state = AppState(); state.isLocked = false; state.games = Demo.games
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(state.isLocked); #expect(state.sensitiveStateIsEmpty)
    }
    @Test func automaticNavigationNeverStartsALiveReadButManualRefreshStillCan() async {
        let state = AppState(); state.isLocked = false; state.demo = false
        for mode in ["personal", "member"] {
            state.accessMode = mode
            for page in Destination.allCases {
                state.destination = page
                state.refresh(mode: .local)
                #expect(!state.loading)
                #expect(state.error == nil)
                await Task.yield()
                #expect(!state.loading)
                #expect(state.error == nil)
            }
        }
        state.refresh()
        #expect(state.loading)
        // Another window restoring the same context must not cancel an explicit sync.
        state.refresh(mode: .local)
        #expect(state.loading)
        state.cancelRefresh(); state.lock()
    }
    @Test func oldLocalDashboardKeepsItsSyncDateAndNeverLeaksAcrossPeriods() {
        let state = AppState(); state.isLocked = false; state.demo = false
        state.destination = .dashboard; state.gameID = "all"; state.range = .month
        let date = Date().addingTimeInterval(-2 * 86400)
        var snapshot = Demo.dashboard(range: .month, gameID: nil)
        snapshot.generatedAt = Dates.iso(date)
        var cache = AggregateCache(); cache.games = Demo.games; cache.save(snapshot, now: Date())
        state.displayLocalView(cache: cache)
        let label = state.lastSyncText
        #expect(state.dashboard != nil)
        #expect(state.loadedAt == Dates.parse(snapshot.generatedAt))
        #expect(!state.loading)
        state.displayLocalView(cache: cache)
        #expect(state.lastSyncText == label)
        state.range = .week; state.displayLocalView(cache: cache)
        #expect(state.dashboard == nil); #expect(state.loadedAt == nil)
        state.range = .month; state.gameID = Demo.games[0].id; state.displayLocalView(cache: cache)
        #expect(state.dashboard == nil); #expect(state.loadedAt == nil)
        state.lock()
    }

}

}
