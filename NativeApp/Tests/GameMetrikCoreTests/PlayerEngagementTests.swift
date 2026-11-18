import Foundation
import Testing
@testable import GameMetrikCore

struct PlayerEngagementTests {
    let zone = TimeZone(identifier: "Europe/Zurich")!
    let uid = "00000000-0000-4000-8000-000000000001"
    let pid = "20000000-0000-4000-8000-000000000001"
    func event(_ index: Int, _ date: String, user: String? = nil, minutes: Double = 3, hints: Double = 1) -> Completion {
        Completion(userID: user ?? uid, runID: String(format: "10000000-0000-4000-8000-%012d", index), elapsedMS: minutes * 60000, hints: hints, date: Dates.parse(date)!)
    }
    func directory(_ events: [Completion], now: String = "2026-03-30T12:00:00Z", profiles: [Profile]? = nil) throws -> PlayerDirectory {
        try Analytics.directory(profiles: profiles ?? [.init(userID: uid, publicID: pid, name: "Test", step: 2)], events: events, activeEntitlements: nil, range: .week, timezone: zone, now: Dates.parse(now)!)
    }
    @Test func activeDatesAndStreakSurviveDaylightSavingAndDuplicateEvents() throws {
        let first = event(1, "2026-03-28T12:00:00Z")
        let result = try directory([first, first, event(2, "2026-03-29T11:00:00Z"), event(3, "2026-03-29T12:00:00Z"), event(4, "2026-03-30T11:00:00Z")])
        let player = result.players[0]
        #expect(player.completions == 4); #expect(player.activeDays == 3); #expect(player.longestStreak == 3)
        #expect(player.returnedInPeriod); #expect(player.activityGroup == .twoOrThreeDays)
        #expect(player.completionsPerActiveDay == 4.0 / 3)
        #expect(result.completionHours.reduce(0) { $0 + $1.completions } == 4)
        #expect(result.timezone == "Europe/Zurich")
    }
    @Test func sameDayDoesNotCountAsReturnAndFutureEventsAreExcluded() throws {
        let result = try directory([event(1, "2026-03-30T08:00:00Z"), event(2, "2026-03-30T10:00:00Z"), event(3, "2026-03-30T13:00:00Z")])
        #expect(result.players[0].activeDays == 1); #expect(!result.players[0].returnedInPeriod)
        #expect(result.completions == 2); #expect(result.returningPlayers == 0)
        #expect(result.players[0].activityGroup == .oneDay)
        let empty = try directory([])
        #expect(empty.players[0].activityGroup == .inactive); #expect(empty.players[0].longestStreak == 0)
        #expect(empty.players[0].completionsPerActiveDay == nil); #expect(empty.topThreeShare == nil)
    }
    @Test func repeatedAutumnHourIsCountedTwiceInSameLocalHour() throws {
        let result = try directory([event(1, "2026-10-25T00:30:00Z"), event(2, "2026-10-25T01:30:00Z")], now: "2026-10-25T12:00:00Z")
        #expect(result.completionHours.first { $0.hour == 2 }?.completions == 2)
        #expect(result.players[0].activeDays == 1)
        #expect(result.players[0].completionHours.reduce(0) { $0 + $1.completions } == 2)
    }
    @Test func groupsWeightPerGameAndDiscloseUnmatchedProfiles() throws {
        let other = "00000000-0000-4000-8000-000000000002", orphan = "00000000-0000-4000-8000-000000000003"
        let profiles = [Profile(userID: uid, publicID: pid, name: "One", step: 1), Profile(userID: other, publicID: "20000000-0000-4000-8000-000000000002", name: "Two", step: 1)]
        let events = [event(1, "2026-03-30T08:00:00Z", minutes: 1, hints: 0)] + (2...4).map { event($0, "2026-03-30T08:00:00Z", user: other, minutes: 9, hints: 4) } + [event(5, "2026-03-30T08:00:00Z", user: orphan)]
        let result = try directory(events, profiles: profiles)
        let group = try #require(result.activityGroups.first { $0.group == .oneDay })
        #expect(group.players == 2); #expect(group.completions == 4); #expect(group.averageMinutes == 7); #expect(group.hints == 3)
        #expect(result.profiledCompletions == 4); #expect(result.completions == 5)
        #expect(result.topThreeShare == 100)
    }
    @Test func gapsBreakStreakAndFourDaysRemainAnExplicitPeriodGroup() throws {
        let result = try directory([event(1, "2026-03-24T12:00:00Z"), event(2, "2026-03-25T12:00:00Z"), event(3, "2026-03-27T12:00:00Z"), event(4, "2026-03-30T11:00:00Z")])
        #expect(result.players[0].activeDays == 4); #expect(result.players[0].longestStreak == 2)
        #expect(result.players[0].activityGroup == .fourOrMoreDays)
    }
    @Test func exportsExposeDefinitionsAndOnlyPublicPlayerIdentifiers() throws {
        let result = try directory([event(1, "2026-03-29T11:00:00Z"), event(2, "2026-03-30T11:00:00Z")])
        var report = DataExport(mode: "test", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "7 jours", scope: "all")
        report.addDirectory(result, includePlayers: true, jardin: true, timezone: nil); report.finishChecks()
        let table = try #require(report.tables.first { $0.id == "joueurs" })
        #expect(table.columns.contains("active_days")); #expect(table.columns.contains("returned_in_period"))
        #expect(table.timezone == "Europe/Zurich")
        let hours = try #require(report.tables.first { $0.id == "joueurs_heures" })
        #expect(hours.rows.count == 24)
        let json = try #require(String(data: report.jsonData(), encoding: .utf8))
        #expect(json.contains(pid)); #expect(!json.contains(uid))
        #expect(report.notes.contains { $0.contains("pas une rétention J7") && $0.contains("fin des parties") })
        var gameplay = DataExport(mode: "test", gameID: nil, gameName: "test", timeframe: "7 jours", scope: "gameplay")
        gameplay.addDirectory(result, includePlayers: false, jardin: true, timezone: nil)
        #expect(gameplay.tables.contains { $0.id == "gameplay_groupes_activite" })
        #expect(!gameplay.tables.contains { $0.id == "joueurs_heures" })
    }
}
