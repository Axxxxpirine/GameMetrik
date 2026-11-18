import Foundation

public struct CompletionHour: Identifiable, Sendable {
    public var hour: Int
    public var completions: Int
    public var id: Int { hour }
}
public enum ActivityGroup: String, CaseIterable, Identifiable, Sendable {
    case inactive, oneDay, twoOrThreeDays, fourOrMoreDays
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .inactive: "Aucun jour actif"
        case .oneDay: "1 jour actif"
        case .twoOrThreeDays: "2 à 3 jours actifs"
        case .fourOrMoreDays: "4 jours actifs ou plus"
        }
    }
}
public struct ActivityGroupSummary: Identifiable, Sendable {
    public var group: ActivityGroup
    public var players: Int
    public var completions: Int
    public var minutes: Double
    public var averageMinutes: Double?
    public var hints: Double?
    public var mistakes: Double?
    public var id: String { group.id }
}
extension Player {
    public var activeDays: Int { trend.filter { $0.completions > 0 }.count }
    public var returnedInPeriod: Bool { activeDays >= 2 }
    public var completionsPerActiveDay: Double? { activeDays > 0 ? Double(completions) / Double(activeDays) : nil }
    public var activityGroup: ActivityGroup {
        switch activeDays { case 0: .inactive; case 1: .oneDay; case 2...3: .twoOrThreeDays; default: .fourOrMoreDays }
    }
    public var longestStreak: Int {
        // The IDs are already local calendar dates. Compare consecutive date labels in UTC,
        // so daylight-saving days of 23/25 hours do not break a streak.
        let dates = trend.filter { $0.completions > 0 }.compactMap { Dates.parse($0.id + "T12:00:00Z") }.sorted()
        var best = 0, current = 0, previous: Date?
        for date in dates {
            current = previous.map { date.timeIntervalSince($0) == 86400 } == true ? current + 1 : 1
            best = max(best, current); previous = date
        }
        return best
    }
}
extension PlayerDirectory {
    public var profiledCompletions: Int { players.reduce(0) { $0 + $1.completions } }
    public var profiledActivePlayers: Int { players.filter { $0.completions > 0 }.count }
    public var returningPlayers: Int { players.filter(\.returnedInPeriod).count }
    public var topThreeShare: Double? {
        Analytics.ratio(Double(players.sorted { $0.completions > $1.completions }.prefix(3).reduce(0) { $0 + $1.completions }), Double(profiledCompletions))
    }
    public var activityGroups: [ActivityGroupSummary] {
        ActivityGroup.allCases.map { group in
            let members = players.filter { $0.activityGroup == group }
            let count = members.reduce(0) { $0 + $1.completions }, minutes = members.reduce(0) { $0 + $1.playMinutes }
            func weighted(_ key: KeyPath<Player, Double?>) -> Double? {
                let active = members.filter { $0.completions > 0 }
                guard count > 0, active.allSatisfy({ $0[keyPath: key] != nil }) else { return nil }
                return active.reduce(0) { $0 + $1[keyPath: key]! * Double($1.completions) } / Double(count)
            }
            return ActivityGroupSummary(group: group, players: members.count, completions: count, minutes: minutes,
                averageMinutes: count > 0 ? minutes / Double(count) : nil, hints: weighted(\.hints), mistakes: weighted(\.mistakes))
        }
    }
}
