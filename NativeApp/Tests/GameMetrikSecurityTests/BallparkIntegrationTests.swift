import Foundation
import Testing
@testable import GameMetrikNative
@testable import GameMetrikCore

extension AppStateTests {
@Suite(.serialized) @MainActor struct BallparkIntegrationTests {
    @Test func selectingBallparkUsesItsDedicatedSurface() {
        let state = AppState()
        state.isLocked = false
        state.demo = true
        state.games = Demo.games
        state.selectGame(.ballpark)
        #expect(state.gameID == Game.ballpark.id)
        #expect(state.destination == .ballpark)
        state.range = .all
        state.ensureCompatibleDestination()
        #expect(state.range == .year)
        state.lock()
        #expect(state.sensitiveStateIsEmpty)
    }

    @Test func demoSynchronizationLoadsEveryBallparkReportWithoutNetwork() async throws {
        let state = AppState()
        state.isLocked = false
        state.demo = true
        state.games = Demo.games
        state.selectGame(.ballpark)
        state.range = .week
        await state.synchronizeSelection()?.value
        let data = try #require(state.ballparkAnalytics)
        #expect(data.loadedKinds == BallparkReportKind.allCases)
        #expect(data.questions?.rows.count == 2)
        #expect(data.questions?.rows.last?.factorMedian == nil)
        #expect(data.errors.isEmpty)
        #expect(state.loadedAt != nil)
        #expect(state.studioSyncResults.count == 1)
        #expect(state.studioSyncResults.first?.section == "Ballpark · Analyse Ballpark")
        #expect(state.studioSyncSummary?.contains("Ballpark") == true)
        state.lock()
        #expect(state.sensitiveStateIsEmpty)
    }

    @Test func personalCatalogAddsBallparkOnceAndMarksTheExplicitContract() {
        let first = Game.addingPersonalSources(to: [Demo.games[0]])
        let second = Game.addingPersonalSources(to: first)
        #expect(first.count == 2)
        #expect(second.count == first.count)
        #expect(second.first { $0.id == Game.ballpark.id }?.usesBallparkAnalytics == true)
        #expect(second.first { $0.id == Game.ballpark.id }?.integrations.supabaseProjectRef == Game.ballparkProjectRef)
    }
}
}
