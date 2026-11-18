import Foundation

public enum AuroraJourneyReportKind: String, Codable, CaseIterable, Sendable {
    case funnel, retentionOpen = "retention_open", retentionCompleted = "retention_completed", runs, quality
    public var title: String {
        switch self {
        case .funnel: "Entonnoir"
        case .retentionOpen: "Retours · ouverture"
        case .retentionCompleted: "Retours · partie"
        case .runs: "Parties"
        case .quality: "Qualité"
        }
    }
}
public enum AuroraJourneyPopulation: String, Codable, Sendable { case all, newInstalls = "new_installs" }
public enum AuroraJourneyUnavailableReason: String, Codable, Sendable {
    case immatureCohort = "immature_cohort", emptyCohort = "empty_cohort", notCollected = "not_collected"
    public var label: String {
        switch self {
        case .immatureCohort: "En attente de maturité"
        case .emptyCohort: "Cohorte vide"
        case .notCollected: "Non collecté"
        }
    }
}
public enum AuroraJourneyError: Error, LocalizedError, Equatable {
    case invalidRequest, unreadableReport
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "Période ou filtres du parcours Aurora Grove invalides."
        case .unreadableReport: "Rapport Aurora Grove illisible : la réponse ne respecte pas le contrat v1."
        }
    }
}

public struct AuroraJourneyFilters: Codable, Equatable, Sendable {
    public var fromDay: String
    public var toDayExclusive: String
    public var appVersion: String?
    public var population: AuroraJourneyPopulation
    enum CodingKeys: String, CodingKey { case fromDay = "from_day", toDayExclusive = "to_day_exclusive", appVersion = "app_version", population }
    public init(fromDay: String, toDayExclusive: String, appVersion: String? = nil, population: AuroraJourneyPopulation = .all) {
        self.fromDay = fromDay; self.toDayExclusive = toDayExclusive; self.appVersion = appVersion; self.population = population
    }
    /// Calendar arithmetic in Zurich, including leap years and daylight saving transitions.
    public func windows() throws -> [Self] {
        guard let start = AuroraJourneyContract.day(fromDay), let end = AuroraJourneyContract.day(toDayExclusive),
              start < end, appVersion.map(AuroraJourneyContract.version) ?? true else { throw AuroraJourneyError.invalidRequest }
        var result: [Self] = [], cursor = start
        while cursor < end {
            let next = min(AuroraJourneyContract.calendar.date(byAdding: .day, value: 366, to: cursor)!, end)
            result.append(Self(fromDay: Dates.day(cursor, timezone: AuroraJourneyContract.zone),
                               toDayExclusive: Dates.day(next, timezone: AuroraJourneyContract.zone),
                               appVersion: appVersion, population: population))
            cursor = next
        }
        return result
    }
}

public struct AuroraJourneyRatio: Codable, Equatable, Sendable {
    public var numerator: Int?
    public var denominator: Int?
    public var value: Double?
    public var reason: AuroraJourneyUnavailableReason?
    public init(numerator: Int?, denominator: Int?, value: Double?, reason: AuroraJourneyUnavailableReason? = nil) {
        self.numerator = numerator; self.denominator = denominator; self.value = value; self.reason = reason
    }
    public static let immature = Self(numerator: nil, denominator: nil, value: nil, reason: .immatureCohort)
    public var formatted: String {
        guard let value else { return reason?.label ?? "Non disponible" }
        return value.formatted(.percent.precision(.fractionLength(1)).locale(Locale(identifier: "fr_CH")))
    }
    public var sample: String {
        if reason == .notCollected { return "Dénominateur non collecté" }
        guard let numerator, let denominator else { return "Effectif mûr non disponible" }
        return "\(numerator) / \(denominator)"
    }
    func validate(share: Bool = false) throws {
        if let value {
            guard reason == nil, let n = numerator, let d = denominator,
                  AuroraJourneyContract.count(n), AuroraJourneyContract.count(d), d > 0,
                  value.isFinite, value >= 0, share || n <= d,
                  abs(value - Double(n) / Double(d)) <= 0.000051 else { throw AuroraJourneyError.unreadableReport }
        } else {
            switch reason {
            case .immatureCohort:
                guard !share, numerator == nil, denominator == nil else { throw AuroraJourneyError.unreadableReport }
            case .emptyCohort:
                guard !share, numerator == 0, denominator == 0 else { throw AuroraJourneyError.unreadableReport }
            case .notCollected:
                guard share, let numerator, AuroraJourneyContract.count(numerator), denominator == 0 else { throw AuroraJourneyError.unreadableReport }
            case nil: throw AuroraJourneyError.unreadableReport
            }
        }
    }
}

/// Each metric selects its own mature observations. A withheld ratio contributes neither count.
public struct AuroraJourneyRatioTotal: Equatable, Sendable {
    public var ratio: AuroraJourneyRatio
    public var includedRows: Int
    public var excludedRows: Int
    public static func sum(_ ratios: [AuroraJourneyRatio]) -> Self {
        let included = ratios.filter { $0.value != nil }
        let numerator = included.compactMap(\.numerator).reduce(0, +)
        let denominator = included.compactMap(\.denominator).reduce(0, +)
        let reason: AuroraJourneyUnavailableReason = ratios.contains { $0.reason == .immatureCohort } ? .immatureCohort
            : ratios.contains { $0.reason == .notCollected } ? .notCollected : .emptyCohort
        let ratio = denominator > 0
            ? AuroraJourneyRatio(numerator: numerator, denominator: denominator, value: Double(numerator) / Double(denominator))
            : AuroraJourneyRatio(numerator: reason == .immatureCohort ? nil : 0,
                                denominator: reason == .immatureCohort ? nil : 0, value: nil, reason: reason)
        return Self(ratio: ratio, includedRows: included.count, excludedRows: ratios.count - included.count)
    }
}

public struct AuroraJourneyFirstOpens: Codable, Equatable, Sendable {
    public var newInstall: Int
    public var newInstallLateConsent: Int
    public var newInstallKnownAccount: Int
    public var excludedSuspicious: Int
    public var existingPlayer: Int
    public var unknown: Int
    enum CodingKeys: String, CodingKey, CaseIterable {
        case newInstall = "new_install"
        case newInstallLateConsent = "new_install_late_consent"
        case newInstallKnownAccount = "new_install_known_account"
        case excludedSuspicious = "excluded_suspicious"
        case existingPlayer = "existing_player"
        case unknown
    }
}

public struct AuroraJourneyAnonymous: Codable, Equatable, Sendable {
    public var firstLaunchNewInstall: Int
    public var firstLaunchExistingPlayer: Int
    public var consentAccepted: Int
    public var consentDeclined: Int
    enum CodingKeys: String, CodingKey, CaseIterable {
        case firstLaunchNewInstall = "first_launch_new_install"
        case firstLaunchExistingPlayer = "first_launch_existing_player"
        case consentAccepted = "consent_accepted"
        case consentDeclined = "consent_declined"
    }
}

public struct AuroraJourneyCoverage: Codable, Equatable, Sendable {
    public var collectionFirstReceivedAt: String?
    public var archivedDaysInWindow: Int
    public var graceDays: Int
    public var consentRequired: Bool
    public var attribution: String
    public var cohortDefinition: String
    public var firstOpenInWindow: AuroraJourneyFirstOpens
    public var anonymousInWindow: AuroraJourneyAnonymous
    public var rejectionsInWindow: [String: Int]
    enum CodingKeys: String, CodingKey, CaseIterable {
        case collectionFirstReceivedAt = "collection_first_received_at"
        case archivedDaysInWindow = "archived_days_in_window"
        case graceDays = "grace_days"
        case consentRequired = "consent_required"
        case attribution
        case cohortDefinition = "cohort_definition"
        case firstOpenInWindow = "first_open_in_window"
        case anonymousInWindow = "anonymous_in_window"
        case rejectionsInWindow = "rejections_in_window"
    }
}

public struct AuroraJourneyFunnelRow: Codable, Equatable, Sendable {
    public var cohortDay: String
    public var appVersion: String
    public var cohortSize: Int
    public var window: String
    public var mature: Bool
    public var tutorialStarted: AuroraJourneyRatio
    public var tutorialCompleted: AuroraJourneyRatio
    public var firstRunCompleted: AuroraJourneyRatio
    public var anonymousFirstLaunches: Int
    public var consentAccepted: Int
    public var consentDeclined: Int
    public var measuredShare: AuroraJourneyRatio
    enum CodingKeys: String, CodingKey, CaseIterable {
        case cohortDay = "cohort_day"
        case appVersion = "app_version"
        case cohortSize = "cohort_size"
        case window
        case mature
        case tutorialStarted = "tutorial_started"
        case tutorialCompleted = "tutorial_completed"
        case firstRunCompleted = "first_run_completed"
        case anonymousFirstLaunches = "anonymous_first_launches"
        case consentAccepted = "consent_accepted"
        case consentDeclined = "consent_declined"
        case measuredShare = "measured_share"
    }
}

public struct AuroraJourneyRetentionRow: Codable, Equatable, Sendable {
    public var cohortDay: String
    public var appVersion: String
    public var cohortSize: Int
    public var returnD1: AuroraJourneyRatio
    public var returnD7: AuroraJourneyRatio
    public var returnD7D13: AuroraJourneyRatio
    enum CodingKeys: String, CodingKey, CaseIterable {
        case cohortDay = "cohort_day"
        case appVersion = "app_version"
        case cohortSize = "cohort_size"
        case returnD1 = "return_d1"
        case returnD7 = "return_d7"
        case returnD7D13 = "return_d7_d13"
    }
}

public struct AuroraJourneyRunRow: Codable, Equatable, Sendable {
    public var appVersion: String
    public var mode: AuroraJourneyMode
    public var level: Int
    public var games: Int
    public var startObserved: Int
    public var solved: Int
    public var abandonedRestart: Int
    public var abandonedNewPuzzle: Int
    public var openRecent: Int
    public var leftNotResumed: Int
    public var appStoppedWhilePlaying: Int
    public var leftAppReturned: Int
    public var leftAppNotReturned: Int
    public var noEndObserved: Int
    enum CodingKeys: String, CodingKey, CaseIterable {
        case appVersion = "app_version"
        case mode
        case level
        case games
        case startObserved = "start_observed"
        case solved
        case abandonedRestart = "abandoned_restart"
        case abandonedNewPuzzle = "abandoned_new_puzzle"
        case openRecent = "open_recent"
        case leftNotResumed = "left_not_resumed"
        case appStoppedWhilePlaying = "app_stopped_while_playing"
        case leftAppReturned = "left_app_returned"
        case leftAppNotReturned = "left_app_not_returned"
        case noEndObserved = "no_end_observed"
    }
}

public struct AuroraJourneyQualityRow: Codable, Equatable, Sendable {
    public var day: String
    public var appVersion: String
    public var platform: AuroraJourneyPlatform
    public var installations: Int
    public var events: Int
    public var byEvent: [String: Int]
    public var firstOpenNewInstall: Int
    public var firstOpenExistingPlayer: Int
    public var firstOpenUnknown: Int
    public var firstOpenLateConsent: Int
    public var installationsReportingLosses: Int
    public var lostEventsReported: Int
    public var launchesAfterForegroundStop: Int
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day
        case appVersion = "app_version"
        case platform
        case installations
        case events
        case byEvent = "by_event"
        case firstOpenNewInstall = "first_open_new_install"
        case firstOpenExistingPlayer = "first_open_existing_player"
        case firstOpenUnknown = "first_open_unknown"
        case firstOpenLateConsent = "first_open_late_consent"
        case installationsReportingLosses = "installations_reporting_losses"
        case lostEventsReported = "lost_events_reported"
        case launchesAfterForegroundStop = "launches_after_foreground_stop"
    }
}

public enum AuroraJourneyMode: String, Codable, Sendable {
    case campaign, quick, daily, lightpaths
    public var title: String {
        switch self { case .campaign: "Aventure"; case .quick: "Partie rapide"; case .daily: "Défi quotidien"; case .lightpaths: "Chemins de lumière" }
    }
}
public enum AuroraJourneyPlatform: String, Codable, Sendable { case ios, android, editor, other }

public struct AuroraJourneyReport<Row: Codable & Sendable>: Codable, Sendable {
    public var contractVersion: Int
    public var report: AuroraJourneyReportKind
    public var generatedAt: String
    public var asOf: String
    public var timezone: String
    public var filters: AuroraJourneyFilters
    public var coverage: AuroraJourneyCoverage
    public var rows: [Row]
    enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion = "contract_version", report, generatedAt = "generated_at", asOf = "as_of", timezone, filters, coverage, rows
    }
}

protocol AuroraJourneyRow: Codable, Sendable {
    var appVersion: String { get }
    var stableKey: String { get }
    func validate(filters: AuroraJourneyFilters) throws
    static func combine(_ rows: [Self]) throws -> [Self]
}
extension AuroraJourneyRow {
    static func combine(_ rows: [Self]) throws -> [Self] {
        guard Set(rows.map(\.stableKey)).count == rows.count else { throw AuroraJourneyError.unreadableReport }
        return rows.sorted { $0.stableKey < $1.stableKey }
    }
    func validateVersion(_ filters: AuroraJourneyFilters) throws {
        guard AuroraJourneyContract.version(appVersion), filters.appVersion == nil || appVersion == filters.appVersion else {
            throw AuroraJourneyError.unreadableReport
        }
    }
}
extension AuroraJourneyFunnelRow: AuroraJourneyRow {
    public var stableKey: String { cohortDay + "|" + appVersion }
    func validate(filters: AuroraJourneyFilters) throws {
        try validateVersion(filters)
        try AuroraJourneyContract.validateDay(cohortDay, filters)
        guard [cohortSize, anonymousFirstLaunches, consentAccepted, consentDeclined].allSatisfy(AuroraJourneyContract.count),
              window == "J0-J6" else { throw AuroraJourneyError.unreadableReport }
        for ratio in [tutorialStarted, tutorialCompleted, firstRunCompleted] {
            try ratio.validate()
            guard mature ? ratio.denominator == cohortSize : ratio.reason == .immatureCohort else { throw AuroraJourneyError.unreadableReport }
        }
        try measuredShare.validate(share: true)
        guard measuredShare.numerator == cohortSize, measuredShare.denominator == anonymousFirstLaunches else { throw AuroraJourneyError.unreadableReport }
    }
}
extension AuroraJourneyRetentionRow: AuroraJourneyRow {
    public var stableKey: String { cohortDay + "|" + appVersion }
    func validate(filters: AuroraJourneyFilters) throws {
        try validateVersion(filters)
        try AuroraJourneyContract.validateDay(cohortDay, filters)
        guard AuroraJourneyContract.count(cohortSize) else { throw AuroraJourneyError.unreadableReport }
        for ratio in [returnD1, returnD7, returnD7D13] {
            try ratio.validate()
            guard ratio.reason == .immatureCohort || ratio.denominator == cohortSize else { throw AuroraJourneyError.unreadableReport }
        }
    }
}
extension AuroraJourneyRunRow: AuroraJourneyRow {
    public var stableKey: String { appVersion + "|" + mode.rawValue + "|" + String(format: "%08d", level) }
    static var countPaths: [WritableKeyPath<Self, Int>] { [
        \.games, \.startObserved, \.solved, \.abandonedRestart, \.abandonedNewPuzzle, \.openRecent,
        \.leftNotResumed, \.appStoppedWhilePlaying, \.leftAppReturned, \.leftAppNotReturned, \.noEndObserved
    ] }
    func validate(filters: AuroraJourneyFilters) throws {
        try validateVersion(filters)
        guard Self.countPaths.allSatisfy({ AuroraJourneyContract.count(self[keyPath: $0]) }),
              (0...1_000_000).contains(level), startObserved <= games,
              (mode == .quick || mode == .daily) ? level == 0 : level > 0,
              Self.countPaths.dropFirst(2).reduce(0, { $0 + self[keyPath: $1] }) == games else {
            throw AuroraJourneyError.unreadableReport
        }
    }
    /// Each response groups first-event days by version/mode/level. Disjoint request windows are additive.
    static func combine(_ rows: [Self]) throws -> [Self] {
        var result: [String: Self] = [:]
        for row in rows {
            if var previous = result[row.stableKey] {
                for path in countPaths { previous[keyPath: path] = try AuroraJourneyContract.add(previous[keyPath: path], row[keyPath: path]) }
                result[row.stableKey] = previous
            } else { result[row.stableKey] = row }
        }
        return result.values.sorted { $0.stableKey < $1.stableKey }
    }
}
extension AuroraJourneyQualityRow: AuroraJourneyRow {
    public var stableKey: String { day + "|" + appVersion + "|" + platform.rawValue }
    func validate(filters: AuroraJourneyFilters) throws {
        try validateVersion(filters)
        try AuroraJourneyContract.validateDay(day, filters)
        let counts = [installations, events, firstOpenNewInstall, firstOpenExistingPlayer, firstOpenUnknown,
                      firstOpenLateConsent, installationsReportingLosses, lostEventsReported, launchesAfterForegroundStop]
        guard counts.allSatisfy(AuroraJourneyContract.count), byEvent.values.allSatisfy(AuroraJourneyContract.count),
              Set(byEvent.keys).isSubset(of: AuroraJourneyContract.eventNames),
              byEvent.values.reduce(0, +) == events, installations <= events,
              installationsReportingLosses <= installations, firstOpenLateConsent <= firstOpenNewInstall,
              firstOpenNewInstall + firstOpenExistingPlayer + firstOpenUnknown == byEvent["first_open", default: 0],
              launchesAfterForegroundStop <= byEvent["app_opened", default: 0] else { throw AuroraJourneyError.unreadableReport }
    }
}

extension AuroraJourneyCoverage {
    /// Presentation only: an unknown server code remains visible and never invalidates a report.
    public static func rejectionLabel(for code: String) -> String {
        switch code {
        case "unknown_field": "Champ inconnu"
        case "missing_field": "Champ manquant"
        case "invalid_value": "Valeur invalide"
        case "invalid_run": "Partie invalide"
        case "too_old": "Événement trop ancien"
        case "clock_ahead": "Horloge en avance"
        case "unknown_event": "Événement inconnu"
        case "unsupported_schema": "Version du schéma non prise en charge"
        case "conflict": "Événement en conflit"
        case "rate_limited": "Limite d’envoi atteinte"
        case "invalid_event": "Événement invalide"
        case "invalid_event_id": "Identifiant d’événement invalide"
        case "invalid_session": "Session invalide"
        case "invalid_time": "Horodatage invalide"
        case "invalid_sequence": "Séquence invalide"
        case "invalid_version": "Version de l’app invalide"
        case "invalid_platform": "Plateforme invalide"
        case "anonymous_rate_limited": "Limite d’envoi des premiers lancements anonymes atteinte"
        case "anonymous_out_of_range": "Signal anonyme hors de la période autorisée"
        default: code
        }
    }

    func validate(filters: AuroraJourneyFilters) throws {
        let span = AuroraJourneyContract.calendar.dateComponents([.day], from: AuroraJourneyContract.day(filters.fromDay)!, to: AuroraJourneyContract.day(filters.toDayExclusive)!).day!
        guard collectionFirstReceivedAt.map({ Dates.parse($0) != nil }) ?? true,
              (0...span).contains(archivedDaysInWindow), graceDays == 3, consentRequired,
              attribution == "not_collected", cohortDefinition == AuroraJourneyContract.cohortDefinition,
              firstOpenInWindow.counts.allSatisfy(AuroraJourneyContract.count),
              anonymousInWindow.counts.allSatisfy(AuroraJourneyContract.count),
              rejectionsInWindow.values.allSatisfy(AuroraJourneyContract.count),
              rejectionsInWindow.keys.allSatisfy(AuroraJourneyContract.rejectionCode) else { throw AuroraJourneyError.unreadableReport }
    }
    mutating func append(_ other: Self) throws {
        if let next = other.collectionFirstReceivedAt,
           collectionFirstReceivedAt == nil || Dates.parse(next)! < Dates.parse(collectionFirstReceivedAt!)! {
            collectionFirstReceivedAt = next
        }
        archivedDaysInWindow = try AuroraJourneyContract.add(archivedDaysInWindow, other.archivedDaysInWindow)
        for path in AuroraJourneyFirstOpens.paths { firstOpenInWindow[keyPath: path] = try AuroraJourneyContract.add(firstOpenInWindow[keyPath: path], other.firstOpenInWindow[keyPath: path]) }
        for path in AuroraJourneyAnonymous.paths { anonymousInWindow[keyPath: path] = try AuroraJourneyContract.add(anonymousInWindow[keyPath: path], other.anonymousInWindow[keyPath: path]) }
        for (code, count) in other.rejectionsInWindow { rejectionsInWindow[code] = try AuroraJourneyContract.add(rejectionsInWindow[code, default: 0], count) }
    }
}
extension AuroraJourneyFirstOpens {
    static var paths: [WritableKeyPath<Self, Int>] { [\.newInstall, \.newInstallLateConsent, \.newInstallKnownAccount, \.excludedSuspicious, \.existingPlayer, \.unknown] }
    var counts: [Int] { Self.paths.map { self[keyPath: $0] } }
}
extension AuroraJourneyAnonymous {
    static var paths: [WritableKeyPath<Self, Int>] { [\.firstLaunchNewInstall, \.firstLaunchExistingPlayer, \.consentAccepted, \.consentDeclined] }
    var counts: [Int] { Self.paths.map { self[keyPath: $0] } }
}

enum AuroraJourneyContract {
    static let zone = TimeZone(identifier: "Europe/Zurich")!
    static var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = zone; return value }
    static let cohortDefinition = "first_open with install_status = new_install and observed_from_launch = true, minus suspicious installations and known accounts"
    static let eventNames: Set<String> = ["first_open", "app_opened", "app_backgrounded", "tutorial_started", "tutorial_step_reached", "tutorial_completed", "run_started", "run_resumed", "run_completed", "run_exited",
        // Monetization events (Aurora Grove migration 20261015120000), counted by the quality report like any other.
        "ad_opportunity", "ad_load", "ad_display", "ad_reward", "ad_paid", "premium_step", "experiment_assigned"]
    static func rejectionCode(_ value: String) -> Bool {
        // Match the whole string, including rejecting a trailing newline that `$` can precede.
        value.range(of: #"^[a-z_]{1,40}$"#, options: .regularExpression) == (value.startIndex..<value.endIndex)
    }
    static func count(_ value: Int) -> Bool { (0...1_000_000_000_000).contains(value) }
    static func add(_ a: Int, _ b: Int) throws -> Int {
        let sum = a.addingReportingOverflow(b)
        guard !sum.overflow else { throw AuroraJourneyError.unreadableReport }
        return sum.partialValue
    }
    static func version(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.range(of: #"^[A-Za-z0-9_.\-]+$"#, options: .regularExpression) != nil
    }
    static func day(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]),
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Dates.day(date, timezone: zone) == value else { return nil }
        return date
    }
    static func validateDay(_ day: String, _ filters: AuroraJourneyFilters) throws {
        guard self.day(day) != nil, day >= filters.fromDay, day < filters.toDayExclusive else { throw AuroraJourneyError.unreadableReport }
    }
    static func object(_ value: Any?, keys: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let object = value as? [String: Any], keys.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: keys.union(optional)) else { throw AuroraJourneyError.unreadableReport }
        return object
    }
    static func keys<K: RawRepresentable>(_ cases: [K]) -> Set<String> where K.RawValue == String { Set(cases.map(\.rawValue)) }
    /// Closed wire shapes also prevent an unexpected identifier or raw payload entering memory/export.
    static func validateShape(_ data: Data, kind: AuroraJourneyReportKind) throws {
        let root = try object(JSONSerialization.jsonObject(with: data), keys: ["contract_version", "report", "generated_at", "as_of", "timezone", "filters", "coverage", "rows"])
        _ = try object(root["filters"], keys: ["from_day", "to_day_exclusive", "app_version", "population"])
        let coverage = try object(root["coverage"], keys: keys(AuroraJourneyCoverage.CodingKeys.allCases))
        _ = try object(coverage["first_open_in_window"], keys: keys(AuroraJourneyFirstOpens.CodingKeys.allCases))
        _ = try object(coverage["anonymous_in_window"], keys: keys(AuroraJourneyAnonymous.CodingKeys.allCases))
        guard let rows = root["rows"] as? [[String: Any]], rows.count <= 100_000 else { throw AuroraJourneyError.unreadableReport }
        let rowKeys: Set<String>
        let ratios: [String]
        switch kind {
        case .funnel:
            rowKeys = keys(AuroraJourneyFunnelRow.CodingKeys.allCases)
            ratios = ["tutorial_started", "tutorial_completed", "first_run_completed", "measured_share"]
        case .retentionOpen, .retentionCompleted:
            rowKeys = keys(AuroraJourneyRetentionRow.CodingKeys.allCases); ratios = ["return_d1", "return_d7", "return_d7_d13"]
        case .runs: rowKeys = keys(AuroraJourneyRunRow.CodingKeys.allCases); ratios = []
        case .quality: rowKeys = keys(AuroraJourneyQualityRow.CodingKeys.allCases); ratios = []
        }
        for row in rows {
            _ = try object(row, keys: rowKeys)
            for key in ratios { _ = try object(row[key], keys: ["numerator", "denominator", "value"], optional: ["reason"]) }
        }
    }
}

public struct AuroraJourneyReportReader: Sendable {
    let personal: PersonalSupabase
    public var http: HTTPClient
    public init(personal: PersonalSupabase, http: HTTPClient = .init()) { self.personal = personal; self.http = http }
    public func funnel(filters: AuroraJourneyFilters, asOf: String? = nil) async throws -> AuroraJourneyReport<AuroraJourneyFunnelRow> { try await read(.funnel, filters: filters, asOf: asOf) }
    public func retentionOpen(filters: AuroraJourneyFilters, asOf: String? = nil) async throws -> AuroraJourneyReport<AuroraJourneyRetentionRow> { try await read(.retentionOpen, filters: filters, asOf: asOf) }
    public func retentionCompleted(filters: AuroraJourneyFilters, asOf: String? = nil) async throws -> AuroraJourneyReport<AuroraJourneyRetentionRow> { try await read(.retentionCompleted, filters: filters, asOf: asOf) }
    public func runs(filters: AuroraJourneyFilters, asOf: String? = nil) async throws -> AuroraJourneyReport<AuroraJourneyRunRow> { try await read(.runs, filters: filters, asOf: asOf) }
    public func quality(filters: AuroraJourneyFilters, asOf: String? = nil) async throws -> AuroraJourneyReport<AuroraJourneyQualityRow> { try await read(.quality, filters: filters, asOf: asOf) }

    private func read<Row: AuroraJourneyRow>(_ kind: AuroraJourneyReportKind, filters: AuroraJourneyFilters, asOf: String?) async throws -> AuroraJourneyReport<Row> {
        try personal.validate()
        guard kind == .runs || filters.population == .all, asOf.map({ Dates.parse($0) != nil }) ?? true else { throw AuroraJourneyError.invalidRequest }
        let windows = try filters.windows()
        var result: AuroraJourneyReport<Row>?
        var boundary = asOf
        for window in windows {
            try Task.checkCancellation()
            var payload: [String: Any] = ["contract_version": 1, "report": kind.rawValue, "from_day": window.fromDay, "to_day_exclusive": window.toDayExclusive]
            if let version = filters.appVersion { payload["app_version"] = version }
            if kind == .runs { payload["population"] = filters.population.rawValue }
            if let boundary { payload["as_of"] = boundary }
            let data = try await rpc("gamemetrik_aurora_journey_report_v1", payload: payload)
            do {
                try AuroraJourneyContract.validateShape(data, kind: kind)
                let page = try JSONDecoder().decode(AuroraJourneyReport<Row>.self, from: data)
                guard page.contractVersion == 1, page.report == kind, page.filters == window, page.timezone == "Europe/Zurich",
                      Dates.parse(page.generatedAt) != nil, let instant = Dates.parse(page.asOf),
                      boundary.map({ Dates.parse($0) == instant }) ?? true else { throw AuroraJourneyError.unreadableReport }
                try page.coverage.validate(filters: window)
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
        result.rows = try Row.combine(result.rows)
        result.filters = filters
        return result
    }

    /// Administrative POST shared by the journey reports: same client, transport and service identity.
    func rpc(_ function: String, payload: [String: Any]) async throws -> Data {
        var request = URLRequest(url: personal.url.appendingPathComponent("rest/v1/rpc/" + function))
        request.httpMethod = "POST"
        personal.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["p_request": payload])
        return try await http.send(request).0
    }
}

public extension AuroraJourneyFilters {
    static func period(_ range: Timeframe, now: Date = Date()) -> Self {
        let interval = range.interval(now: now, timezone: AuroraJourneyContract.zone)
        // The v1 collection was introduced in 2026; no earlier journey events exist.
        // Avoid Timeframe.all's distantPast while retaining every possible v1 day and future archive.
        return Self(fromDay: range == .all ? "2026-01-01" : Dates.day(interval.start, timezone: AuroraJourneyContract.zone),
                    toDayExclusive: Dates.day(interval.end, timezone: AuroraJourneyContract.zone))
    }
}

public struct AuroraJourneyOutcome: Sendable {
    public var key: String
    public var label: String
    public var count: Int
}
public extension AuroraJourneyRunRow {
    var outcomes: [AuroraJourneyOutcome] { [
        .init(key: "solved", label: "Partie résolue", count: solved),
        .init(key: "abandoned_restart", label: "Recommencée explicitement", count: abandonedRestart),
        .init(key: "abandoned_new_puzzle", label: "Remplacée par une nouvelle grille", count: abandonedNewPuzzle),
        .init(key: "open_recent", label: "Encore récente, reprise possible", count: openRecent),
        .init(key: "left_not_resumed", label: "Sortie explicite, partie non reprise sous 7 jours", count: leftNotResumed),
        .init(key: "app_stopped_while_playing", label: "App arrêtée affichée pendant la partie (plantage ou arrêt forcé)", count: appStoppedWhilePlaying),
        .init(key: "left_app_returned", label: "App quittée pendant la partie, retour sous 7 jours sans la reprendre", count: leftAppReturned),
        .init(key: "left_app_not_returned", label: "App quittée pendant la partie, pas de retour sous 7 jours", count: leftAppNotReturned),
        .init(key: "no_end_observed", label: "Aucune fin observée", count: noEndObserved)
    ] }
}
