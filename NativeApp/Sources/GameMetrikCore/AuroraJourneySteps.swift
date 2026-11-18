import Foundation

/// Anonymous steps of new installations (game 1.5.1+), read from `gamemetrik_aurora_journey_steps_v1`.
/// A report separate from the closed v1 journey contract: no identifier, one count per installation and step.
public struct AuroraJourneyStepsFilters: Codable, Equatable, Sendable {
    public var fromDay: String
    public var toDayExclusive: String
    public var appVersion: String?
    enum CodingKeys: String, CodingKey, CaseIterable { case fromDay = "from_day", toDayExclusive = "to_day_exclusive", appVersion = "app_version" }
    public init(fromDay: String, toDayExclusive: String, appVersion: String? = nil) {
        self.fromDay = fromDay; self.toDayExclusive = toDayExclusive; self.appVersion = appVersion
    }
    init(_ filters: AuroraJourneyFilters) { self.init(fromDay: filters.fromDay, toDayExclusive: filters.toDayExclusive, appVersion: filters.appVersion) }
    // Synthesized encoding would omit a nil version; the wire shape always carries the key.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fromDay, forKey: .fromDay); try container.encode(toDayExclusive, forKey: .toDayExclusive)
        try container.encode(appVersion, forKey: .appVersion)
    }
}

public struct AuroraJourneyStepsCoverage: Codable, Equatable, Sendable {
    public var stepsFirstDay: String?
    public var graceDays: Int
    public var identifier: String
    public var regionRule: String
    public var cohortDefinition: String
    enum CodingKeys: String, CodingKey, CaseIterable {
        case stepsFirstDay = "steps_first_day"
        case graceDays = "grace_days"
        case identifier
        case regionRule = "region_rule"
        case cohortDefinition = "cohort_definition"
    }
    func validate() throws {
        guard stepsFirstDay.map({ AuroraJourneyContract.day($0) != nil }) ?? true, graceDays == 3, identifier == "none",
              [regionRule, cohortDefinition].allSatisfy({ !$0.isEmpty && $0.count <= 1_000 }) else { throw AuroraJourneyError.unreadableReport }
    }
    /// `steps_first_day` is the first collected day overall, so windows keep the earliest one.
    mutating func append(_ other: Self) throws {
        guard other.graceDays == graceDays, other.identifier == identifier, other.regionRule == regionRule,
              other.cohortDefinition == cohortDefinition else { throw AuroraJourneyError.unreadableReport }
        if let next = other.stepsFirstDay, stepsFirstDay == nil || next < stepsFirstDay! { stepsFirstDay = next }
    }
}

public struct AuroraJourneyStepsRow: Codable, Equatable, Sendable {
    public var cohortDay: String
    public var appVersion: String
    public var firstLaunches: Int
    public var stepsOpen: Int
    public var measuredShare: AuroraJourneyRatio
    public var tutorialStarted: AuroraJourneyRatio
    public var tutorialCompleted: AuroraJourneyRatio
    public var solved1: AuroraJourneyRatio
    public var solved3: AuroraJourneyRatio
    public var solved10: AuroraJourneyRatio
    public var returnD1: AuroraJourneyRatio
    public var returnD7D13: AuroraJourneyRatio
    enum CodingKeys: String, CodingKey, CaseIterable {
        case cohortDay = "cohort_day"
        case appVersion = "app_version"
        case firstLaunches = "first_launches"
        case stepsOpen = "steps_open"
        case measuredShare = "measured_share"
        case tutorialStarted = "tutorial_started"
        case tutorialCompleted = "tutorial_completed"
        case solved1 = "solved_1"
        case solved3 = "solved_3"
        case solved10 = "solved_10"
        case returnD1 = "return_d1"
        case returnD7D13 = "return_d7_d13"
    }
    public init(cohortDay: String, appVersion: String, firstLaunches: Int, stepsOpen: Int, measuredShare: AuroraJourneyRatio,
                tutorialStarted: AuroraJourneyRatio, tutorialCompleted: AuroraJourneyRatio, solved1: AuroraJourneyRatio,
                solved3: AuroraJourneyRatio, solved10: AuroraJourneyRatio, returnD1: AuroraJourneyRatio, returnD7D13: AuroraJourneyRatio) {
        self.cohortDay = cohortDay; self.appVersion = appVersion; self.firstLaunches = firstLaunches; self.stepsOpen = stepsOpen
        self.measuredShare = measuredShare; self.tutorialStarted = tutorialStarted; self.tutorialCompleted = tutorialCompleted
        self.solved1 = solved1; self.solved3 = solved3; self.solved10 = solved10; self.returnD1 = returnD1; self.returnD7D13 = returnD7D13
    }
    /// Every step over `steps_open` of the same row, in display and export order.
    public static var steps: [(key: String, title: String, path: KeyPath<Self, AuroraJourneyRatio>)] { [
        ("tutorial_started", "Tutoriel commencé", \.tutorialStarted),
        ("tutorial_completed", "Tutoriel terminé", \.tutorialCompleted),
        ("solved_1", "1 jardin", \.solved1),
        ("solved_3", "3 jardins", \.solved3),
        ("solved_10", "10 jardins", \.solved10),
        ("return_d1", "Retour J1", \.returnD1),
        ("return_d7_d13", "Retour J7–J13", \.returnD7D13)
    ] }
}

extension AuroraJourneyStepsRow: AuroraJourneyRow {
    public var stableKey: String { cohortDay + "|" + appVersion }
    func validate(filters: AuroraJourneyFilters) throws {
        try validateVersion(filters)
        try AuroraJourneyContract.validateDay(cohortDay, filters)
        guard AuroraJourneyContract.count(firstLaunches), AuroraJourneyContract.count(stepsOpen) else { throw AuroraJourneyError.unreadableReport }
        // A share above 1 means lost first-launch counts; it stays visible instead of invalidating the report.
        try measuredShare.validate(share: true)
        guard measuredShare.numerator == stepsOpen, measuredShare.denominator == firstLaunches else { throw AuroraJourneyError.unreadableReport }
        for step in Self.steps { try self[keyPath: step.path].validateStep(stepsOpen: stepsOpen) }
        // J1 matures before J0–J6, which matures before J7–J13: never the reverse within one row.
        let week = [tutorialStarted, tutorialCompleted, solved1, solved3, solved10].map { $0.reason == .immatureCohort }
        guard Set(week).count == 1, !(returnD1.reason == .immatureCohort && !week[0]),
              !(week[0] && returnD7D13.reason != .immatureCohort && stepsOpen > 0) else { throw AuroraJourneyError.unreadableReport }
    }
}

extension AuroraJourneyRatio {
    /// Step ratios: published over `steps_open` once mature, `not_collected` (0/0) without any reporting installation.
    /// A step can outnumber `steps_open` when that count was lost, so the value is not capped at 1.
    func validateStep(stepsOpen: Int) throws {
        if let value {
            guard reason == nil, stepsOpen > 0, let n = numerator, AuroraJourneyContract.count(n), denominator == stepsOpen,
                  value.isFinite, value >= 0, abs(value - Double(n) / Double(stepsOpen)) <= 0.000051 else { throw AuroraJourneyError.unreadableReport }
        } else {
            switch reason {
            case .immatureCohort: guard stepsOpen > 0, numerator == nil, denominator == nil else { throw AuroraJourneyError.unreadableReport }
            case .notCollected: guard stepsOpen == 0, numerator == 0, denominator == 0 else { throw AuroraJourneyError.unreadableReport }
            case .emptyCohort, nil: throw AuroraJourneyError.unreadableReport
            }
        }
    }
}

public struct AuroraJourneyStepsReport: Codable, Sendable {
    public var contractVersion: Int
    public var report: String
    public var generatedAt: String
    public var asOf: String
    public var timezone: String
    public var filters: AuroraJourneyStepsFilters
    public var coverage: AuroraJourneyStepsCoverage
    public var rows: [AuroraJourneyStepsRow]
    enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion = "contract_version", report, generatedAt = "generated_at", asOf = "as_of", timezone, filters, coverage, rows
    }
    public init(contractVersion: Int = 1, report: String = "steps", generatedAt: String, asOf: String, timezone: String = "Europe/Zurich",
                filters: AuroraJourneyStepsFilters, coverage: AuroraJourneyStepsCoverage, rows: [AuroraJourneyStepsRow]) {
        self.contractVersion = contractVersion; self.report = report; self.generatedAt = generatedAt; self.asOf = asOf
        self.timezone = timezone; self.filters = filters; self.coverage = coverage; self.rows = rows
    }
    /// Only rows whose ratio is published contribute; counts of withheld rows are never mixed in.
    public func total(_ path: KeyPath<AuroraJourneyStepsRow, AuroraJourneyRatio>) -> AuroraJourneyRatioTotal { .sum(rows.map { $0[keyPath: path] }) }
    public var firstLaunches: Int { rows.reduce(0) { $0 + $1.firstLaunches } }
    public var stepsOpen: Int { rows.reduce(0) { $0 + $1.stepsOpen } }
}

extension AuroraJourneyContract {
    static let stepsReport = "steps"
    /// Closed wire shape: an unexpected identifier or raw payload never enters memory or the export.
    static func validateStepsShape(_ data: Data) throws {
        let root = try object(JSONSerialization.jsonObject(with: data), keys: keys(AuroraJourneyStepsReport.CodingKeys.allCases))
        _ = try object(root["filters"], keys: keys(AuroraJourneyStepsFilters.CodingKeys.allCases))
        _ = try object(root["coverage"], keys: keys(AuroraJourneyStepsCoverage.CodingKeys.allCases))
        guard let rows = root["rows"] as? [[String: Any]], rows.count <= 100_000 else { throw AuroraJourneyError.unreadableReport }
        let ratios = ["measured_share"] + AuroraJourneyStepsRow.steps.map(\.key)
        for row in rows {
            _ = try object(row, keys: keys(AuroraJourneyStepsRow.CodingKeys.allCases))
            for key in ratios { _ = try object(row[key], keys: ["numerator", "denominator", "value"], optional: ["reason"]) }
        }
    }
}

public extension AuroraJourneyReportReader {
    /// Same administrative identity and 366-day windows as the journey v1 reports; rows of disjoint windows are concatenated.
    func steps(filters: AuroraJourneyFilters, asOf: String? = nil) async throws -> AuroraJourneyStepsReport {
        try personal.validate()
        guard filters.population == .all, asOf.map({ Dates.parse($0) != nil }) ?? true else { throw AuroraJourneyError.invalidRequest }
        let windows = try filters.windows()
        var result: AuroraJourneyStepsReport?
        var boundary = asOf
        for window in windows {
            try Task.checkCancellation()
            var payload: [String: Any] = ["contract_version": 1, "from_day": window.fromDay, "to_day_exclusive": window.toDayExclusive,
                                          "app_version": filters.appVersion as Any? ?? NSNull()]
            if let boundary { payload["as_of"] = boundary }
            let data = try await rpc("gamemetrik_aurora_journey_steps_v1", payload: payload)
            do {
                try AuroraJourneyContract.validateStepsShape(data)
                let page = try JSONDecoder().decode(AuroraJourneyStepsReport.self, from: data)
                guard page.contractVersion == 1, page.report == AuroraJourneyContract.stepsReport, page.filters == .init(window),
                      page.timezone == "Europe/Zurich", Dates.parse(page.generatedAt) != nil, let instant = Dates.parse(page.asOf),
                      boundary.map({ Dates.parse($0) == instant }) ?? true else { throw AuroraJourneyError.unreadableReport }
                try page.coverage.validate()
                guard Set(page.rows.map(\.stableKey)).count == page.rows.count else { throw AuroraJourneyError.unreadableReport }
                for row in page.rows { try row.validate(filters: window) }
                if result == nil { result = page; boundary = page.asOf }
                else {
                    result!.rows += page.rows
                    try result!.coverage.append(page.coverage)
                    if Dates.parse(page.generatedAt)! > Dates.parse(result!.generatedAt)! { result!.generatedAt = page.generatedAt }
                }
                guard result!.rows.count <= 100_000 else { throw AuroraJourneyError.unreadableReport }
            } catch { throw AuroraJourneyError.unreadableReport }
        }
        guard var result else { throw AuroraJourneyError.unreadableReport }
        result.rows = try AuroraJourneyStepsRow.combine(result.rows)
        result.filters = .init(filters)
        return result
    }
}
