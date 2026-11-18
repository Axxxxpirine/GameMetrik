import Foundation
import Testing
@testable import GameMetrikCore

struct AcquisitionTests {
    let now = Dates.parse("2026-09-07T12:00:00Z")!
    func event(_ user: String, _ date: String) -> ActivityEvent {
        .init(user_id: user, run_id: UUID().uuidString, completed_at: date)
    }
    @Test func firstObservedGameCountsOnceAcrossHistoryAndLocalMidnight() throws {
        let window = try SyncWindow(range: .week, now: now)
        let old = UUID().uuidString, new = UUID().uuidString, other = UUID().uuidString
        let first = event(new, "2026-08-31T22:30:00Z") // 1 September in Zurich.
        let events = [event(old, "2026-09-05T10:00:00Z"), event(new.lowercased(), "2026-09-03T10:00:00Z"), first, first,
                      event(old, "2026-08-01T10:00:00Z"), event(other, "2026-09-07T11:00:00Z"),
                      event(UUID().uuidString, "2026-09-08T10:00:00Z")]
        let value = try Engagement.build(events, window: window, timezone: TimeZone(identifier: "Europe/Zurich")!)
        #expect(value.newPlayersDaily == ["2026-08-01": 1, "2026-09-01": 1, "2026-09-07": 1])
        let game = Demo.games[0]
        let result = NativeDashboardSync.dashboard(games: [game], gameID: game.id, range: .week, window: window, reports: [], engagement: [game.id: value], alerts: [])
        #expect(result.kpis.first { $0.id == "newPlayers" }?.value == 2)
        #expect(result.trend.compactMap(\.newPlayers).reduce(0,+) == 2)
        #expect(result.trend.first?.newPlayers == 1)
        #expect(result.trend[1].newPlayers == 0)
        #expect(result.kpis.first { $0.id == "installs" }?.value == nil)
        let stored = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        for item in events { #expect(!stored.contains(item.user_id)); #expect(!stored.contains(item.run_id)) }
    }
    @Test func legacyAggregatesAndMissingGamesStayUnknownWhileEmptyHistoryIsZero() throws {
        let legacy = try JSONDecoder().decode(Engagement.self, from: Data(#"{"daily":{},"monthly":0,"retained":0,"eligible":0}"#.utf8))
        #expect(legacy.newPlayersDaily == nil)
        let point = try JSONDecoder().decode(TrendPoint.self, from: Data(#"{"date":"2026-09-01","players":0,"installs":0,"revenue":0}"#.utf8))
        #expect(DashboardMetric.newPlayers.value(point) == nil)
        let window = try SyncWindow(range: .week, now: now), game = Demo.games[0]
        func dashboard(_ games: [Game], _ value: Engagement) -> Dashboard {
            NativeDashboardSync.dashboard(games: games, gameID: game.id, range: .week, window: window, reports: [], engagement: [game.id: value], alerts: [])
        }
        #expect(dashboard([game], legacy).kpis.first { $0.id == "newPlayers" }?.value == nil)
        let empty = try Engagement.build([], window: window, timezone: .gmt)
        #expect(dashboard([game], empty).kpis.first { $0.id == "newPlayers" }?.value == 0)
        #expect(dashboard(Array(Demo.games.prefix(2)), empty).trend.allSatisfy { $0.newPlayers == nil })
    }
    @Test func demoTotalsMatchDailyValuesAndPortfolio() {
        let dashboard = Demo.dashboard(range: .month, gameID: nil, now: now)
        let total = dashboard.kpis.first { $0.id == "newPlayers" }?.value
        #expect(total == Double(dashboard.trend.compactMap(\.newPlayers).reduce(0,+)))
        let children = Demo.games.map { Demo.dashboard(range: .month, gameID: $0.id, now: now) }
        #expect(total == children.reduce(0) { $0 + ($1.kpis.first { $0.id == "newPlayers" }?.value ?? 0) })
    }
    @Test func hoverFindsNearestDayAndPreservesUnknownVersusZero() {
        #expect(ChartInspection.nearestIndex(value: 1.49, count: 7) == 1)
        #expect(ChartInspection.nearestIndex(value: 1.51, count: 7) == 2)
        #expect(ChartInspection.nearestIndex(value: -10, count: 7) == 0)
        #expect(ChartInspection.nearestIndex(value: 100, count: 7) == 6)
        #expect(ChartInspection.nearestIndex(value: 0.2, count: 1) == 0)
        #expect(ChartInspection.nearestIndex(value: 0, count: 0) == nil)
        #expect(ChartInspection.nearestIndex(value: .nan, count: 7) == nil)
        #expect(ChartInspection.nearestIndex(value: .infinity, count: 7) == nil)
        #expect(ChartInspection.nearestIndex(value: nil, count: 7) == nil)
        var point = TrendPoint(date: "2026-09-01", revenue: 0, players: 0, installs: 0, newPlayers: 0)
        for metric in DashboardMetric.allCases { #expect(metric.value(point) == 0) }
        point.revenueAvailable = false; point.playersAvailable = false; point.installsAvailable = false; point.newPlayers = nil
        for metric in DashboardMetric.allCases { #expect(metric.value(point) == nil) }
    }
}
