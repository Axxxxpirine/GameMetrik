import Foundation

/// Daily aggregates only; no order IDs, account identifiers or player profiles.
struct RevenueAllocation: Codable, Sendable {
    var country: String
    var platform: String
    var currency: String
    var amount: Decimal
}
public enum RevenueDimension: String, CaseIterable, Identifiable, Sendable {
    case country, platform
    public var id: String { rawValue }
    public var title: String { self == .country ? "Pays" : "Plateformes" }
    public func label(_ code: String) -> String {
        if code == "unknown" { return "Non attribué" }
        if self == .country { return Locale(identifier: "fr_CH").localizedString(forRegionCode: code) ?? code }
        return ["ios": "iOS", "android": "Android", "macos": "macOS", "tvos": "tvOS", "visionos": "visionOS"][code] ?? code
    }
}
public struct RevenueBreakdownRow: Sendable, Identifiable {
    public var code: String
    public var name: String
    public var value: Double
    public var share: Double?
    public var id: String { code }
}
public struct RevenueDetail: Codable, Sendable {
    public var gameID: String
    public var provider: String
    public var date: String
    public var country: String
    public var platform: String
    public var currency: String
    public var amount: Decimal
    public var readAt: String?
    public var cached: Bool
}
public struct RevenueDetails: Codable, Sendable {
    public var rows: [RevenueDetail]
    public var receivedSourceDays: Int
    public var expectedSourceDays: Int
    public var legacySourceDays: Int
    public var sourceHasError: Bool
    public var currencies: [String] { let values = Set(rows.map(\.currency)); return values.isEmpty ? ["CHF"] : values.sorted() }
    public var status: String {
        if receivedSourceDays == 0 { return "missing" }
        if receivedSourceDays < expectedSourceDays || legacySourceDays > 0 || sourceHasError || rows.contains(where: { $0.country == "unknown" || $0.platform == "unknown" }) { return "partial" }
        return "loaded"
    }
    public var note: String {
        var text = "\(receivedSourceDays)/\(expectedSourceDays) journées de sources reçues. Publicité estimée et recettes boutiques, dans les devises des rapports ; aucune conversion."
        if legacySourceDays > 0 { text += " \(legacySourceDays) journée(s) d’ancien cache sans ventilation : synchronise pour les compléter." }
        if rows.contains(where: { $0.country == "unknown" || $0.platform == "unknown" }) { text += " Les dimensions absentes sont classées Non attribué." }
        if sourceHasError { text += " Certaines sources signalent une erreur ; les derniers montants disponibles sont conservés." }
        return text
    }
    public func breakdown(_ dimension: RevenueDimension, currency: String) -> [RevenueBreakdownRow] {
        var totals: [String: Decimal] = [:]
        for row in rows where row.currency == currency {
            totals[dimension == .country ? row.country : row.platform, default: 0] += row.amount
        }
        let total = totals.values.reduce(Decimal.zero, +)
        let percentages = total > 0 && totals.values.allSatisfy { $0 >= 0 }
        return totals.map { code, amount in
            RevenueBreakdownRow(code: code, name: dimension.label(code), value: NSDecimalNumber(decimal: amount).doubleValue,
                share: percentages ? NSDecimalNumber(decimal: amount / total * 100).doubleValue : nil)
        }.sorted { $0.value == $1.value ? $0.code < $1.code : $0.value > $1.value }
    }
    static func build(reports: [ProviderReport], window: SyncWindow) -> Self {
        let sources = reports.filter(\.supportsMoney)
        var rows: [RevenueDetail] = [], received = 0, legacy = 0
        for report in sources {
            for day in window.days {
                guard let value = report.days[day] else { continue }
                received += 1
                if value.allocations == nil { legacy += 1 }
                let allocations = value.allocations ?? value.money.sorted { $0.key < $1.key }.map { RevenueAllocation(country: "unknown", platform: "unknown", currency: $0.key, amount: $0.value) }
                rows += allocations.map { RevenueDetail(gameID: report.gameID, provider: report.provider, date: day, country: $0.country, platform: $0.platform, currency: $0.currency, amount: $0.amount, readAt: report.readAt[day], cached: report.reusedDays.contains(day)) }
            }
        }
        rows.sort { [$0.gameID, $0.provider, $0.date, $0.country, $0.platform, $0.currency].lexicographicallyPrecedes([$1.gameID, $1.provider, $1.date, $1.country, $1.platform, $1.currency]) }
        return Self(rows: rows, receivedSourceDays: received, expectedSourceDays: sources.count * window.days.count, legacySourceDays: legacy, sourceHasError: sources.contains(where: \.hasError))
    }
}
extension FinancialDay {
    mutating func allocate(_ amount: Decimal, currency: String, country: String?, platform: String?) {
        let region = Self.country(country), system = Self.platform(platform)
        if allocations == nil { allocations = [] }
        if let index = allocations!.firstIndex(where: { $0.country == region && $0.platform == system && $0.currency == currency }) {
            allocations![index].amount += amount
        } else { allocations!.append(RevenueAllocation(country: region, platform: system, currency: currency, amount: amount)) }
    }
    static func country(_ value: String?) -> String {
        let code = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        if code == "UK" { return "GB" }
        return code.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil && !["ZZ", "XX"].contains(code) ? code : "unknown"
    }
    static func platform(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ios", "iphone", "ipad", "ipod touch": "ios"
        case "android": "android"
        case "macos", "desktop": "macos"
        case "tvos", "apple tv": "tvos"
        case "visionos", "apple vision": "visionos"
        default: "unknown"
        }
    }
}
