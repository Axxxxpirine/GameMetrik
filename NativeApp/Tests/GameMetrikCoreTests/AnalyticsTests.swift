import Testing
import Foundation
@testable import GameMetrikCore

struct AnalyticsTests {
    let zone = TimeZone(identifier: "Europe/Zurich")!
    let now = Dates.parse("2026-09-06T12:00:00Z")!
    let user = "00000000-0000-4000-8000-000000000001"
    let publicID = "20000000-0000-4000-8000-000000000001"
    func event(_ index: Int, score: Double = 800, max: Double = 1000, date: Date? = nil) -> Completion {
        Completion(userID: user, runID: String(format: "10000000-0000-4000-8000-%012d", index), score: score, maximumScore: max, date: date ?? now)
    }
    func directory(_ events: [Completion], entitlements: Set<String>? = nil) throws -> PlayerDirectory {
        try Analytics.directory(profiles: [.init(userID: user, publicID: publicID, name: "Test", step: 1)], events: events, activeEntitlements: entitlements, range: .month, timezone: zone, now: now)
    }
    @Test func scoreUsesTotalsInsteadOfMeanPercentages() throws {
        let data = try directory([event(1, score: 10, max: 10), event(2, score: 10, max: 100)])
        #expect(data.players[0].scoreRatio == 18.18)
        #expect(data.players[0].averageMinutes == 3)
    }
    @Test func duplicateRunsCountOnce() throws {
        let e = event(1)
        let data = try directory([e, e])
        #expect(data.completions == 1); #expect(data.players[0].playMinutes == 3)
    }
    @Test func runIDIsScopedToUser() throws {
        let a = event(1); var b = a; b.user_id = "00000000-0000-4000-8000-000000000002"
        #expect(Analytics.unique([a, b], interval: Timeframe.today.interval(now: now, timezone: zone)).events.count == 2)
    }
    @Test func noEventsDoNotInventRatiosOrEntitlements() throws {
        let player = try directory([]).players[0]
        #expect(player.scoreRatio == nil); #expect(player.perfectRate == nil)
        #expect(player.averageMinutes == nil); #expect(player.lastPlayed == nil)
        #expect(player.jardinPaisible == nil); #expect(player.completions == 0)
    }
    @Test func knownEmptyEntitlementsMeansInactive() throws {
        #expect(try directory([], entitlements: []).players[0].jardinPaisible == false)
        #expect(try directory([], entitlements: [user]).players[0].jardinPaisible == true)
    }
    @Test func springAndAutumnDaysRespectDST() {
        let spring = Timeframe.today.interval(now: Dates.parse("2026-03-29T12:00:00Z")!, timezone: zone)
        let fall = Timeframe.today.interval(now: Dates.parse("2026-10-25T12:00:00Z")!, timezone: zone)
        #expect(spring.duration == 23 * 3600); #expect(fall.duration == 25 * 3600)
        let week = Timeframe.week.interval(now: Dates.parse("2026-03-29T12:00:00Z")!, timezone: zone)
        #expect(week.duration == 167 * 3600)
    }
    @Test func midnightEndIsExclusive() throws {
        let interval = Timeframe.today.interval(now: now, timezone: zone)
        #expect(Analytics.unique([event(1, date: interval.start), event(2, date: interval.end)], interval: interval).events.count == 1)
    }
    @Test func dayGroupingUsesProjectTimezone() throws {
        let date = Dates.parse("2026-09-05T23:30:00Z")!
        #expect(try directory([event(1, date: date)]).trend[0].id == "2026-09-06")
    }
    @Test func invalidRowsAreSetAsideAndDisclosedWithoutHidingOtherPlayers() throws {
        var negative = event(1); negative.elapsed_ms = -1
        var undated = event(2); undated.completed_at = "not-a-date"
        let result = try directory([negative, undated, event(3)])
        #expect(result.completions == 1)
        #expect(result.dataNote?.hasPrefix("2 partie(s) ignorée(s)") == true)
        #expect(try directory([event(4)]).dataNote == nil)
    }
    @Test func newModesAndDifficultiesAreCountedUnderTheirOwnName() throws {
        var zen = event(1); zen.mode = "zen"; zen.difficulty = 7
        let result = try directory([zen, event(2)])
        #expect(result.completions == 2); #expect(result.dataNote == nil)
        #expect(result.modes.contains { $0.name == "zen" && $0.value == 1 })
        #expect(result.difficulties.contains { $0.name == "Niveau 7" })
    }
    @Test func zeroMaximumScoreIsUnknown() throws {
        #expect(try directory([event(1, score: 0, max: 0)]).players[0].scoreRatio == nil)
    }
    @Test func moneyArithmeticUsesDecimalAndMatchingDays() {
        #expect(Analytics.arpdau(revenue: [Decimal(string: "0.1")!, Decimal(string: "0.2")!], active: [1, 2]) == Decimal(string: "0.1"))
        #expect(Analytics.arpdau(revenue: [1], active: []) == nil)
        #expect(Analytics.arpdau(revenue: [1], active: [0]) == nil)
    }
    @Test func demoTotalsEqualDailyTrendForEveryRange() {
        for range in Timeframe.allCases {
            let data = Demo.dashboard(range: range, gameID: nil, now: now)
            let total = data.trend.reduce(0) { $0 + $1.revenue }
            #expect(abs((data.kpis.first { $0.id == "revenue" }?.value ?? -1) - total) < 0.000001)
            #expect(abs(data.rankings.reduce(0) { $0 + $1.revenue } - total) < 0.000001)
        }
    }
    @Test func demoPortfolioMatchesIndividualGames() {
        let portfolio = Demo.dashboard(range: .month, gameID: nil, now: now)
        for ranking in portfolio.rankings {
            let game = Demo.dashboard(range: .month, gameID: ranking.gameId, now: now)
            #expect(ranking.revenue == game.kpis.first { $0.id == "revenue" }?.value)
        }
        #expect(Demo.dashboard(range: .month, gameID: "orbit-tactics", now: now).platformBreakdown.map(\.name) == ["Android"])
    }
    @Test func decodeExistingWebContracts() throws {
        let base = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        let dashboard = try JSONDecoder().decode(Dashboard.self, from: Data(contentsOf: base.appendingPathComponent("web-dashboard.json")))
        let games = try JSONDecoder().decode([Game].self, from: Data(contentsOf: base.appendingPathComponent("web-games.json")))
        #expect(dashboard.timeframe == .month); #expect(dashboard.kpis.count == 8)
        #expect(games.count == 3); #expect(games[0].name == "Aurora Grove")
    }
    @Test func duplicateProfilesAreRejected() {
        let p = Profile(userID: user, publicID: publicID, name: nil, step: 1)
        #expect(throws: GameMetrikError.self) { try Analytics.directory(profiles: [p, p], events: [], activeEntitlements: nil, range: .month, timezone: zone) }
    }
}
