import Foundation
import Testing
@testable import GameMetrikNative
@testable import GameMetrikCore

extension AppStateTests {
@Suite(.serialized) @MainActor struct WorkspaceContinuityTests {
    private func connections() -> PersonalConnections {
        let account = ServiceAccount(project_id: "test-project", client_email: "test@test-project.iam.gserviceaccount.com", private_key: "test-only")
        return PersonalConnections(projectID: "test-project", firebase: account, supabase: [], importedAt: Date(), notes: [])
    }

    @Test(arguments: [(true, "personal"), (true, "member"), (false, "member")])
    func unlockKeepsTheWorkspaceChosenBeforeTheLock(demo: Bool, access: String) {
        let state = AppState(); state.demo = demo; state.accessMode = access
        state.completeUnlock(connections: connections(), session: nil)
        #expect(!state.isLocked)
        #expect(state.demo == demo)
        #expect(state.accessMode == access)
        #expect(state.personalReady)
        state.cancelRefresh(); state.lock()
    }

    @Test func liveLaunchRestoresTheLiveSelectionNotTheDemoOne() {
        let defaults = UserDefaults.standard
        let keys = ["personal.live", "live.game", "live.range", "demo.game", "demo.range"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(true, forKey: "personal.live")
        defaults.set("live-game", forKey: "live.game"); defaults.set("7d", forKey: "live.range")
        defaults.set("demo-game", forKey: "demo.game"); defaults.set("90d", forKey: "demo.range")
        let state = AppState()
        #expect(!state.demo)
        #expect(state.gameID == "live-game")
        #expect(state.range == .week)
    }

    @Test func returningFromAllTimePlayersUsesABoundedDashboardWithoutReadingNetwork() async throws {
        let state = try await ExportPreparationTests().setup()
        state.accessMode = "personal"; state.destination = .players; state.range = .all
        state.refresh(mode: .local)
        #expect(state.range == .all)
        #expect(state.supportsAllTime)
        state.destination = .dashboard
        state.ensureCompatibleGame()
        #expect(state.range == .year)
        #expect(!state.supportsAllTime)
        state.refresh(mode: .local)
        #expect(!state.loading)
        #expect(state.currentViewError == nil)
        #expect(await ExportHTTPStub.shared.requests.isEmpty)
        state.lock()
    }

    @Test func refreshRepairsRestoredUnsupportedRangeBeforeComputingItsContext() async throws {
        let state = try await ExportPreparationTests().setup()
        state.accessMode = "personal"; state.destination = .dashboard; state.range = .all
        state.refresh(mode: .local)
        #expect(state.range == .year)
        #expect(UserDefaults.standard.string(forKey: "live.range") == Timeframe.year.rawValue)
        #expect(await ExportHTTPStub.shared.requests.isEmpty)
        state.lock()
    }

    @Test func liveLaunchRepairsAnAllTimeDashboardPreference() {
        let defaults = UserDefaults.standard
        let keys = ["personal.live", "access.mode", "live.range"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(true, forKey: "personal.live")
        defaults.set("personal", forKey: "access.mode"); defaults.set("all", forKey: "live.range")
        let state = AppState()
        #expect(state.range == .year)
    }

    @Test(arguments: [(true, "personal"), (false, "member")])
    func allTimeRemainsAvailableForOtherDashboardModes(demo: Bool, access: String) {
        let state = AppState(); state.demo = demo; state.accessMode = access
        state.destination = .dashboard; state.range = .all
        state.ensureCompatibleGame()
        #expect(state.range == .all)
        #expect(state.supportsAllTime)
    }

    @Test func enteringBallparkFromAllTimePlayersRepairsTheRangeImmediately() {
        let state = AppState(); state.games = Demo.games; state.gameID = "aurora-grove"
        state.range = .all; state.destination = .ballpark
        state.ensureCompatibleGame()
        #expect(state.gameID == Game.ballpark.id)
        #expect(state.range == .year)
    }

    @Test func allTimePlayerSyncDoesNotScheduleUnsupportedProviderReports() {
        let state = AppState(); state.demo = false; state.accessMode = "personal"
        #expect(state.synchronizationPages(for: Demo.games[0], range: .all) == [.players, .reviews, .auroraJourney])
        #expect(state.synchronizationPages(for: nil, range: .all) == [.reviews])
        #expect(state.synchronizationPages(for: Demo.games[0], range: .year) == [.dashboard, .players, .reviews, .auroraJourney])
        state.accessMode = "member"
        #expect(state.synchronizationPages(for: Demo.games[0], range: .all) == [.dashboard, .players, .reviews])
    }

    @Test func inactivityWarnsThirtySecondsBeforeLockingAndActivityCancelsTheWarning() throws {
        let state = AppState(); state.isLocked = false; state.games = Demo.games
        let monitor = try #require(state.securityMonitor)
        let start = Date()
        monitor.activity(at: start)
        monitor.evaluate(now: start.addingTimeInterval(269))
        #expect(state.idleLockDeadline == nil)
        monitor.evaluate(now: start.addingTimeInterval(271))
        #expect(state.idleLockDeadline == start.addingTimeInterval(300))
        #expect(!state.isLocked)
        state.stayUnlocked()
        #expect(state.idleLockDeadline == nil)
        #expect(!state.isLocked)
        monitor.activity(at: start)
        monitor.evaluate(now: start.addingTimeInterval(275))
        #expect(state.idleLockDeadline != nil)
        monitor.evaluate(now: start.addingTimeInterval(301))
        #expect(state.isLocked)
        #expect(state.idleLockDeadline == nil)
        #expect(state.sensitiveStateIsEmpty)
    }

    @Test func menuCommandsOnlyOfferPagesCompatibleWithTheSelectedGame() {
        let state = AppState(); state.isLocked = false; state.games = Demo.games
        state.gameID = "aurora-grove"
        #expect(state.canNavigate(to: .gameplay)); #expect(state.canNavigate(to: .ballpark))
        state.gameID = Game.ballpark.id
        for page in [Destination.gameplay, .players, .reviews] { #expect(!state.canNavigate(to: page)) }
        #expect(state.canNavigate(to: .dashboard)); #expect(state.canNavigate(to: .library))
        state.games = Demo.games.filter { !$0.usesBallparkAnalytics }; state.gameID = "aurora-grove"
        #expect(!state.canNavigate(to: .ballpark))
        state.lock()
    }

    @Test func choosingAPageAdaptsTheGameInsteadOfShowingAnEmptyView() {
        let state = AppState(); state.isLocked = false; state.games = Demo.games
        state.gameID = "aurora-grove"; state.destination = .ballpark
        state.ensureCompatibleGame()
        #expect(state.gameID == Game.ballpark.id); #expect(state.destination == .ballpark)

        state.destination = .players
        state.ensureCompatibleGame()
        #expect(state.destination == .ballpark)

        state.destination = .dashboard
        state.ensureCompatibleGame()
        #expect(state.gameID == "all"); #expect(state.destination == .dashboard)

        state.games = Demo.games.filter { !$0.usesBallparkAnalytics }
        state.gameID = "aurora-grove"; state.destination = .ballpark
        state.ensureCompatibleGame()
        #expect(state.gameID == "aurora-grove"); #expect(state.destination == .gameplay)
        state.lock()
    }
}
}
