import Foundation

public enum DashboardMetric: String, CaseIterable, Identifiable {
    case installs, newPlayers, players, revenue
    public var id: String { rawValue }
    public var label: String {
        switch self { case .installs: "Installations"; case .newPlayers: "Nouveaux joueurs"; case .players: "Joueurs actifs"; case .revenue: "Revenus" }
    }
    public func value(_ point: TrendPoint) -> Double? {
        switch self {
        case .installs: point.installsAvailable == false ? nil : Double(point.installs)
        case .newPlayers: point.newPlayers.map(Double.init)
        case .players: point.playersAvailable == false ? nil : Double(point.players)
        case .revenue: point.revenueAvailable == false ? nil : point.revenue
        }
    }
}
public enum ChartInspection {
    /// Arrow navigation continues from the visible marker, including a pinned inspector date.
    public static func movedIndex(hovered: Int?, highlighted: Int? = nil, offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current = hovered ?? highlighted else { return 0 }
        return max(0, min(count - 1, current + offset))
    }
    /// Calendar-spaced ticks stay legible even when observations cluster around long gaps.
    public static func axisPositions(_ positions: [Double], limit: Int = 5) -> [Double] {
        let finite = positions.filter(\.isFinite)
        guard limit > 0, let first = finite.min(), let last = finite.max() else { return [] }
        guard last > first, limit > 1 else { return [first] }
        return Array(Set((0..<limit).map { first + ((last - first) * Double($0) / Double(limit - 1)).rounded() })).sorted()
    }
    public static func nearestIndex(value: Double?, count: Int) -> Int? {
        guard count > 0, let value, value.isFinite else { return nil }
        return Int(min(Double(count - 1), max(0, value)).rounded())
    }

    /// Civil dates are plotted on a UTC calendar so DST cannot distort day spacing.
    public static func dayPositions(_ dates: [String]) -> [Double] {
        guard let first = dates.first.flatMap({ Dates.parse($0 + "T12:00:00Z") }) else { return [] }
        return dates.map { date in
            Dates.parse(date + "T12:00:00Z").map { $0.timeIntervalSince(first) / 86_400 } ?? .nan
        }
    }

    public static func nearestIndex(value: Double?, positions: [Double]) -> Int? {
        guard let value, value.isFinite else { return nil }
        return positions.indices.filter { positions[$0].isFinite }.min {
            abs(positions[$0] - value) < abs(positions[$1] - value)
        }
    }

    public static func segments(positions: [Double], values: [Double?]) -> [Int] {
        var segment = 0
        return values.indices.map { index in
            if values[index] == nil || (index > 0 && positions.indices.contains(index) && positions[index] - positions[index - 1] > 1.5) { segment += 1 }
            return segment
        }
    }
}

/// A selection is a date, not a row index: an updated report cannot silently
/// change the day being inspected. No player data or preferences are persisted.
public struct DashboardDaySelection: Equatable, Sendable {
    public private(set) var date: String?
    public init(date: String? = nil) { self.date = date }
    public func point(in points: [TrendPoint]) -> TrendPoint? { points.first { $0.date == date } }
    public mutating func select(_ date: String?, in points: [TrendPoint]) {
        self.date = points.first { $0.date == date }?.date
    }
    public mutating func move(_ offset: Int, in points: [TrendPoint]) {
        guard !points.isEmpty else { date = nil; return }
        let current = points.firstIndex { $0.date == date } ?? points.count - 1
        date = points[max(0, min(points.count - 1, current + offset))].date
    }
    public mutating func reconcile(with points: [TrendPoint]) { select(date, in: points) }
}
