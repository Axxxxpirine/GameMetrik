import Foundation
import AppKit
import Testing
@testable import GameMetrikNative
@testable import GameMetrikCore

extension AppStateTests {
@Suite(.serialized) @MainActor struct ExportTests {
    let now = Dates.parse("2026-09-09T12:00:00Z")!
    func state() -> AppState {
        let state = AppState(); state.isLocked = false; state.demo = true
        state.destination = .dashboard; state.gameID = "aurora-grove"; state.range = .week
        state.games = Demo.games; state.dashboard = Demo.dashboard(range: .week, gameID: "aurora-grove", now: now)
        state.loadedAt = now
        return state
    }
    @Test func exportIsReadOnlyAndBoundToDisplayedContext() throws {
        let state = state()
        let before = state.loadedAt
        #expect(state.canExport)
        let export = try state.makeExport(scope: .current, now: now)
        #expect(export.tables.contains { $0.id == "studio_indicateurs" })
        #expect(!export.tables.contains { $0.id == "catalogue" })
        #expect(state.loadedAt == before); #expect(!state.loading)
        state.range = .month
        #expect(!state.canExport)
        #expect(throws: GameMetrikError.self) { try state.makeExport(scope: .available) }
        state.range = .week; state.loading = true
        #expect(!state.canExport)
        state.loading = false; state.showingExport = true; state.lock()
        #expect(!state.canExport); #expect(!state.showingExport)
        #expect(throws: GameMetrikError.self) { try state.makeExport(scope: .current) }
    }
    @Test func availableExportUsesOnlyMatchingCachedViewsAndMarksMissingSources() throws {
        let state = state(); state.demo = false; state.loadedAt = now
        let directory = try Demo.directory(range: .week, game: Demo.games[0], now: now)
        state.localViews[state.localViewKey(for: .players)] = .init(dashboard: nil, directory: directory, reviews: [], date: now)
        state.localViews[state.localViewKey(for: .reviews)] = .init(dashboard: nil, directory: nil, reviews: Demo.reviews(), date: now)
        let export = try state.makeExport(scope: .available)
        #expect(export.tables.contains { $0.id == "joueurs" })
        #expect(export.tables.first { $0.id == "avis" }?.rows.count == Demo.reviews().filter { $0.gameId == "aurora-grove" }.count)
        state.gameID = "orbit-tactics"; state.dashboard = Demo.dashboard(range: .week, gameID: "orbit-tactics", now: now); state.loadedAt = now
        let other = try state.makeExport(scope: .available)
        #expect(!other.tables.contains { $0.id == "joueurs" || $0.id == "avis" })
        #expect(other.notes.contains { $0.contains("Gameplay et joueurs absents") })
        state.gameID = "aurora-grove"; state.personalOrganization = "another-space"; state.loadedAt = now
        #expect(!(try state.makeExport(scope: .available)).tables.contains { $0.id == "joueurs" })
    }
    @Test func libraryAndReviewsDoNotClaimAPeriodFilter() throws {
        let state = state(); state.destination = .library; state.loadedAt = now
        let library = try state.makeExport(scope: .current)
        #expect(library.gameID == nil); #expect(library.timeframe.contains("Sans période"))
        #expect(library.tables.first?.rows.count == Demo.games.count)
        state.destination = .reviews; state.reviews = Demo.reviews(); state.loadedAt = now
        let reviews = try state.makeExport(scope: .current)
        #expect(reviews.timeframe.contains("Toutes les dates"))
        #expect(Set(reviews.tables.map(\.id)) == ["avis", "export_bilan"])
    }
    @Test func preparationLoadsAllViewsWithoutNavigation() async throws {
        let state = state(); state.loadedAt = nil; state.dashboard = nil
        #expect(state.canPrepareExport); #expect(state.canPresentExport)
        let task = try #require(state.refresh(forExport: true))
        #expect(state.preparingExport)
        await task.value
        #expect(state.destination == .dashboard)
        #expect(!state.preparingExport); #expect(!state.loading); #expect(state.canExport)
        #expect(state.exportSyncResults.count == 4)
        #expect(state.exportSyncResults.allSatisfy { $0.status == "loaded" })
        let export = try state.makeExport(scope: .available)
        #expect(export.missingViews.isEmpty)
        #expect(export.tables.contains { $0.id == "joueurs" })
        #expect(export.tables.contains { $0.id == "avis" })
        #expect(export.tables.contains { $0.id == "export_bilan" })
        #expect(state.dashboard?.generatedAt == state.directory.map { Dates.iso($0.generatedAt) })
    }
    @Test func cancellingOrLockingCannotResurrectExportData() async throws {
        for lock in [false, true] {
            let state = state(); state.loadedAt = nil; state.dashboard = nil
            let task = try #require(state.refresh(forExport: true))
            if lock { state.lock() } else { state.cancelRefresh() }
            await task.value
            #expect(!state.preparingExport); #expect(!state.loading)
            #expect(state.dashboard == nil); #expect(state.directory == nil)
            #expect(!state.canExport)
            if lock { #expect(state.sensitiveStateIsEmpty) }
            else { #expect(state.exportSyncResults.allSatisfy { $0.status == "cancelled" }) }
        }
    }
    @Test func cachedDemoViewsNeverBelongToRealExport() throws {
        let state = state()
        state.localViews[state.localViewKey(for: .players)] = .init(dashboard: nil, directory: try Demo.directory(range: .week, game: Demo.games[0], now: now), reviews: [], date: now)
        let demoKey = state.localViewKey(for: .players)
        state.demo = false; state.loadedAt = now
        #expect(state.localViewKey(for: .players) != demoKey)
        #expect(!(try state.makeExport(scope: .available)).tables.contains { $0.id == "joueurs" })
        #expect(state.refresh(mode: .local, forExport: true) == nil)
        #expect(!state.preparingExport)
    }
    @Test func ballparkExportContainsEveryAggregateReportWithoutPlayerData() async throws {
        let state = state()
        state.gameID = Game.ballpark.id; state.destination = .ballpark
        state.dashboard = nil; state.loadedAt = nil
        await state.refresh()?.value
        let report = try state.makeExport(scope: .available, now: now)
        #expect(report.schemaVersion == 6)
        #expect(report.missingViews.isEmpty)
        #expect(Set(report.tables.map(\.id)).isSuperset(of: [
            "catalogue", "ballpark_apercu", "ballpark_questions", "ballpark_series", "ballpark_series_questions",
            "ballpark_habitudes_jours", "ballpark_habitudes_semaines", "ballpark_habitudes_heures",
            "ballpark_qualite", "ballpark_couverture", "export_bilan"
        ]))
        #expect(!report.tables.filter { $0.id.hasPrefix("ballpark_") }.contains { table in
            table.columns.contains { ["user_id", "email", "name", "group_code", "estimate", "result", "explanation", "source_url"].contains($0) }
        })
        let questions = try #require(report.tables.first { $0.id == "ballpark_questions" })
        let sampleIndex = try #require(questions.columns.firstIndex(of: "sample_status"))
        let medianIndex = try #require(questions.columns.firstIndex(of: "factor_median"))
        let masked = try #require(questions.rows.first { $0[sampleIndex] == .text("insufficient_sample") })
        #expect(masked[medianIndex] == .null)
    }
    @Test func ballparkExportPreparationLoadsOnlyItsDedicatedAnalysis() async throws {
        let state = state()
        state.gameID = Game.ballpark.id; state.destination = .ballpark
        state.dashboard = nil; state.loadedAt = nil
        let task = try #require(state.refresh(forExport: true))
        await task.value
        #expect(state.destination == .ballpark)
        #expect(state.exportSyncResults.map(\.section) == ["Analyse Ballpark"])
        #expect(state.exportSyncResults.allSatisfy { $0.status == "loaded" })
        let report = try state.makeExport(scope: .available, now: now)
        #expect(report.missingViews.isEmpty)
        #expect(report.tables.contains { $0.id == "ballpark_questions" })
        #expect(!report.tables.contains { $0.id == "studio_indicateurs" || $0.id == "joueurs" || $0.id == "avis" })
    }
    @Test func dismissingExportClearsAStaleFolderPicker() {
        let state = state()
        state.exportPanel = NSOpenPanel()
        state.cancelExportFolderSelection()
        #expect(state.exportPanel == nil)
    }

}

}

extension AppStateTests {
@Suite(.serialized) @MainActor struct AIFolderExportTests {
    let now = Dates.parse("2026-10-15T08:00:00Z")!
    /// The AI folder reads another synchronized game from saved views, never from the displayed one.
    @Test func targetExportUsesSavedViewsOfThatGameWithoutPlayers() throws {
        let state = AppState(); state.isLocked = false; state.demo = true
        state.destination = .dashboard; state.gameID = "aurora-grove"; state.range = .week; state.games = Demo.games
        state.dashboard = Demo.dashboard(range: .week, gameID: "aurora-grove", now: now); state.loadedAt = now
        let other = try #require(Demo.games.first { $0.id != "aurora-grove" && !$0.usesBallparkAnalytics })
        let missing = try state.makeExport(scope: .available, now: now, target: other.id)
        #expect(missing.gameID == other.id)
        #expect(missing.missingViews.contains("Vue d’ensemble"))
        state.localViews[state.localViewKey(for: .dashboard, gameID: other.id)] = .init(dashboard: Demo.dashboard(range: .week, gameID: other.id, now: now), directory: nil, reviews: [], date: now)
        state.localViews[state.localViewKey(for: .players, gameID: other.id)] = .init(dashboard: nil, directory: try Demo.directory(range: .week, game: other, now: now), reviews: [], date: now)
        let export = try state.makeExport(scope: .available, now: now, target: other.id)
        #expect(export.tables.contains { $0.id == "studio_indicateurs" })
        #expect(export.tables.contains { $0.id == "gameplay_historique" })
        #expect(!export.tables.contains { $0.id.hasPrefix("joueurs") })
        state.loading = true
        #expect(!state.canExport)
        #expect(throws: Never.self) { try state.makeExport(scope: .available, now: now, target: other.id) }
    }
}
}

extension AppStateTests {
@Suite(.serialized) @MainActor struct AIHeadlessTests {
    /// The background instance never changes the window's remembered selection, and a normal instance cannot become one.
    @Test func headlessInstanceKeepsTheWindowSelection() async throws {
        let defaults = UserDefaults.standard
        let saved = (defaults.string(forKey: "live.game"), defaults.string(forKey: "live.range"))
        defer { defaults.set(saved.0, forKey: "live.game"); defaults.set(saved.1, forKey: "live.range") }
        defaults.set("orbit-tactics", forKey: "live.game"); defaults.set("90d", forKey: "live.range")
        let worker = AppState(headless: true)
        worker.isLocked = false; worker.demo = false; worker.accessMode = "personal"; worker.gameID = "aurora-grove"; worker.range = .week
        await worker.refresh(mode: .incremental)?.value
        #expect(defaults.string(forKey: "live.game") == "orbit-tactics"); #expect(defaults.string(forKey: "live.range") == "90d")
        #expect(!AppState().headless)
    }
}
}
