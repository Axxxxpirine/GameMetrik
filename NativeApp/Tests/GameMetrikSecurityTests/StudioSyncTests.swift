import Foundation
import Testing
@testable import GameMetrikNative
@testable import GameMetrikCore

extension AppStateTests {
@Suite(.serialized) @MainActor struct StudioSyncTests {
    func setup(playerStatus: Int = 200) async throws -> AppState {
        let fixtures = ExportPreparationTests()
        let state = try await fixtures.setup(playerStatus: playerStatus)
        var second = Demo.games[1]
        second.integrations.supabaseProjectRef = "aurora-grove"
        let catalog = [Demo.games[0], second]
        await ExportHTTPStub.shared.setResponse("/games", data: try JSONSerialization.data(withJSONObject: ["documents": catalog.map { try fixtures.encodedDocument($0) }]))
        for gameID in ["all"] + catalog.map(\.id) {
            let path = gameID == "all" ? "/portfolioSnapshots/7d" : "/games/\(gameID)/dashboardSnapshots/7d"
            let dashboard = Demo.dashboard(range: .week, gameID: gameID == "all" ? nil : gameID)
            await ExportHTTPStub.shared.setResponse(path, data: try JSONSerialization.data(withJSONObject: fixtures.encodedDocument(dashboard)))
        }
        return state
    }

    @Test(arguments: [Destination.dashboard, .library, .players, .gameplay, .reviews])
    func oneClickPreparesEveryGameAndNavigationDoesNotReadAgain(start: Destination) async throws {
        let state = try await setup(); state.destination = start
        await state.synchronizeAll()?.value
        #expect(state.destination == start); #expect(state.gameID == "aurora-grove")
        #expect(state.error == nil); #expect(!state.loading)
        #expect(state.studioSyncResults.count == 6)
        #expect(!state.studioSyncResults.contains { $0.status == "failed" })
        let requests = await ExportHTTPStub.shared.requests
        #expect(requests.filter { $0.url?.path.hasSuffix("/profiles") == true }.count == 2)
        #expect(requests.filter { $0.url?.path.hasSuffix("/completion_events") == true }.count == 2)
        #expect(requests.filter { $0.url?.path.hasSuffix("/reviews") == true }.count == 1)
        for game in state.games {
            state.gameID = game.id
            for page in Destination.allCases where page != .ballpark && page != .auroraJourney {
                state.destination = page
                state.refresh(mode: .local)
                #expect(state.loadedAt != nil, "\(game.name) / \(page.title) must already be loaded")
                #expect(state.error == nil); #expect(!state.loading)
                if page == .players || page == .gameplay { #expect(state.directory != nil) }
                if page == .dashboard { #expect(state.dashboard?.gameId == game.id) }
            }
        }
        state.gameID = "all"; state.destination = .dashboard; state.refresh(mode: .local)
        #expect(state.dashboard?.scope == "portfolio"); #expect(state.loadedAt != nil)
        #expect(await ExportHTTPStub.shared.requests.count == requests.count)
        state.range = .month; state.destination = .players; state.gameID = "aurora-grove"
        state.refresh(mode: .local)
        #expect(state.directory == nil); #expect(state.loadedAt == nil)
        #expect(await ExportHTTPStub.shared.requests.count == requests.count)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func selectedGameSyncDoesNotReadOrPopulateOtherGames() async throws {
        let state = try await setup()
        let fixtures = ExportPreparationTests()
        await ExportHTTPStub.shared.setResponse(
            "/reviews",
            data: try JSONSerialization.data(withJSONObject: ["documents": Demo.reviews().map { try fixtures.encodedDocument($0) }])
        )
        state.gameID = "aurora-grove"; state.destination = .dashboard
        await state.synchronizeSelection()?.value

        #expect(state.error == nil); #expect(!state.loading)
        #expect(state.studioSyncResults.count == 3)
        #expect(state.studioSyncResults.allSatisfy { $0.section.hasPrefix("Aurora Grove · ") })
        #expect(state.studioSyncSummary?.contains("Aurora Grove") == true)
        #expect(state.localViews[state.localViewKey(for: .dashboard, gameID: "aurora-grove")] != nil)
        #expect(state.localViews[state.localViewKey(for: .players, gameID: "aurora-grove")] != nil)
        #expect(state.localViews[state.localViewKey(for: .reviews, gameID: "aurora-grove")] != nil)
        #expect(state.localViews[state.localViewKey(for: .reviews, gameID: "aurora-grove")]?.reviews.map(\.gameId) == ["aurora-grove"])
        #expect(state.localViews[state.localViewKey(for: .dashboard, gameID: "orbit-tactics")] == nil)
        #expect(state.localViews[state.localViewKey(for: .players, gameID: "orbit-tactics")] == nil)

        let requests = await ExportHTTPStub.shared.requests
        #expect(requests.filter { $0.url?.path.hasSuffix("/profiles") == true }.count == 1)
        #expect(requests.filter { $0.url?.path.hasSuffix("/completion_events") == true }.count == 1)
        #expect(requests.filter { $0.url?.path.hasSuffix("/reviews") == true }.count == 1)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func failuresPreserveTheirPreviousDateAndDoNotBlockOtherViews() async throws {
        let state = try await setup(playerStatus: 500)
        let old = Date().addingTimeInterval(-86400)
        state.localViews[state.localViewKey(for: .players)] = .init(dashboard: nil, directory: try Demo.directory(range: .week, game: Demo.games[0], now: old), reviews: [], date: old)
        await state.synchronizeAll()?.value
        #expect(state.error == nil)
        #expect(state.studioSyncResults.filter { $0.status == "failed" }.count == 2)
        #expect(state.studioSyncSummary?.contains("partielle") == true)
        state.destination = .players; state.refresh(mode: .local)
        #expect(state.loadedAt == old); #expect(state.directory != nil)
        state.destination = .reviews; state.refresh(mode: .local)
        #expect(state.loadedAt != nil); #expect(state.reviews.isEmpty)
        state.lock()
    }

    @Test func failedSelectedViewShowsItsErrorAndRetryClearsIt() async throws {
        let state = try await setup()
        await ExportHTTPStub.shared.setResponse("/games/aurora-grove/dashboardSnapshots/7d", status: 500, data: Data())
        await state.synchronizeSelection()?.value
        #expect(state.loadedAt == nil)
        #expect(state.currentViewError != nil)
        #expect(state.localViews[state.localViewKey(for: .players)] != nil)
        // The failure survives local navigation, but never appears for another page or period.
        state.destination = .players; state.refresh(mode: .local)
        #expect(state.currentViewError == nil)
        state.destination = .dashboard; state.range = .month; state.refresh(mode: .local)
        #expect(state.currentViewError == nil)
        state.range = .week; state.refresh(mode: .local)
        #expect(state.currentViewError != nil)
        let fixtures = ExportPreparationTests()
        await ExportHTTPStub.shared.setResponse("/games/aurora-grove/dashboardSnapshots/7d", data: try JSONSerialization.data(withJSONObject: fixtures.encodedDocument(Demo.dashboard(range: .week, gameID: "aurora-grove"))))
        await state.synchronizeSelection()?.value
        #expect(state.loadedAt != nil)
        #expect(state.currentViewError == nil)
        #expect(state.localViewFailures.isEmpty)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func failedRefreshKeepsTheExistingDashboardVisible() async throws {
        let state = try await setup()
        await state.synchronizeSelection()?.value
        let oldDate = state.loadedAt
        await ExportHTTPStub.shared.setResponse("/games/aurora-grove/dashboardSnapshots/7d", status: 500, data: Data())
        await state.synchronizeSelection()?.value
        #expect(state.dashboard != nil)
        #expect(state.loadedAt == oldDate)
        #expect(state.currentViewError == nil)
        #expect(!state.localViewFailures.isEmpty)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func accessRefusalStopsGlobalReadsAndPurgesTheirResults() async throws {
        let state = try await setup(playerStatus: 403)
        await state.synchronizeAll()?.value
        #expect(state.error != nil); #expect(state.localViews.isEmpty)
        #expect(state.studioSyncResults.isEmpty); #expect(state.dashboard == nil)
        #expect(!(await ExportHTTPStub.shared.requests).contains { $0.url?.path.hasSuffix("/reviews") == true })
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func cancellationCannotFinishOrRepopulateViews() async throws {
        let state = try await setup()
        await ExportHTTPStub.shared.setDelay(100_000_000)
        let task = try #require(state.synchronizeAll())
        while await ExportHTTPStub.shared.requests.isEmpty { await Task.yield() }
        state.cancelRefresh()
        await task.value
        #expect(!state.loading); #expect(state.localViews.isEmpty)
        #expect(state.studioSyncSummary?.contains("interrompue") == true)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func memberSyncNeverRestoresAPersonalCacheOrReadsRestrictedPlayers() async throws {
        let state = try await setup()
        // Simulate switching from a personal workspace with a larger cached catalog.
        state.aggregateCache = AggregateCache(); state.aggregateCache?.games = Demo.games
        let fixtures = ExportPreparationTests()
        await ExportHTTPStub.shared.setResponse("/members/user", data: try JSONSerialization.data(withJSONObject: fixtures.document(["role": "viewer"])))
        await state.synchronizeAll()?.value
        #expect(state.error == nil); #expect(state.membership?.role == "viewer")
        #expect(state.games.count == 2)
        #expect(state.dashboard?.gameId == "aurora-grove")
        #expect(state.studioSyncResults.filter { $0.status == "failed" }.count == 2)
        #expect(!(await ExportHTTPStub.shared.requests).contains { $0.url?.host == "fixture.supabase.co" })
        #expect(state.localViews[state.localViewKey(for: .reviews)] != nil)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }
}
}
