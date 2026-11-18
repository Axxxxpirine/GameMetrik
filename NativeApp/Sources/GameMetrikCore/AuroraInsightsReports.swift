import Foundation

/// Complete collection of Aurora Grove 1.6.0+, read from `gamemetrik_aurora_insights_report_v1` and
/// `gamemetrik_aurora_presence_report_v1` with the administrative identity of the journey reports.
/// Unlike the journey and monetization contracts, these families are decoded forward-compatibly: every documented
/// key must be present with its type, unknown keys are ignored (never kept nor exported) and codes are free strings.
/// Numbers are optional: an archived group of fewer than 5 installations is masked (`suppressed`, numbers null),
/// and null is never shown or exported as 0. No identifier is part of any row.
public enum AuroraInsightsPopulation: String, Codable, CaseIterable, Sendable {
    case production, internalBuilds = "internal", all
    public var title: String {
        switch self {
        case .production: "Production"
        case .internalBuilds: "Interne"
        case .all: "Tous"
        }
    }
    public var detail: String {
        switch self {
        case .production: "installations jamais vues sur un build TestFlight ou de développement"
        case .internalBuilds: "installations vues sur un build TestFlight ou de développement"
        case .all: "production et builds internes ensemble"
        }
    }
}

public enum AuroraInsightsKind: String, Codable, CaseIterable, Sendable {
    case activity, sessions, screens, dialogs, actions, gameplay, timeline, progress, settings
    case stability, diagnostics, performance, cloud, privacy, consents, context, notifications, server
    public var title: String {
        switch self {
        case .activity: "Fréquentation"
        case .sessions: "Sessions"
        case .screens: "Écrans"
        case .dialogs: "Fenêtres"
        case .actions: "Actions"
        case .gameplay: "Parties"
        case .timeline: "Chronologies des coups"
        case .progress: "Progression"
        case .settings: "Réglages"
        case .stability: "Stabilité"
        case .diagnostics: "Erreurs"
        case .performance: "Performance"
        case .cloud: "Réseau et cloud"
        case .privacy: "Confidentialité"
        case .consents: "Accords et retraits"
        case .context: "Contexte des appareils"
        case .notifications: "Rappels"
        case .server: "Serveur"
        }
    }
    /// Keys kept in an archived row whose numbers are masked (private.insights_dimensions).
    public var dimensions: [String] {
        switch self {
        case .activity, .server: ["day"]
        case .sessions, .stability: ["day", "app_version"]
        case .screens: ["day", "app_version", "screen"]
        case .dialogs: ["day", "app_version", "dialog"]
        case .actions: ["day", "app_version", "action"]
        case .gameplay: ["day", "app_version", "mode", "level", "difficulty", "board_size", "outcome"]
        case .timeline: ["day", "app_version", "mode", "level", "difficulty"]
        case .progress: ["day", "app_version", "kind", "code"]
        case .settings: ["day", "app_version", "setting", "value"]
        case .diagnostics: ["day", "app_version", "kind", "exception_type", "fingerprint"]
        case .performance: ["day", "app_version", "device_model", "os_major"]
        case .cloud: ["day", "app_version", "op", "outcome"]
        case .privacy: ["day", "app_version", "statistics_basis", "statistics_source", "region_class", "att_status"]
        case .consents: ["day", "app_version", "purpose", "state", "source"]
        case .context: ["day", "app_version", "dimension", "value"]
        case .notifications: ["day", "app_version", "kind", "destination"]
        }
    }
}

public struct AuroraInsightsFilters: Codable, Equatable, Sendable {
    public var fromDay: String
    public var toDayExclusive: String
    public var appVersion: String?
    public var population: AuroraInsightsPopulation
    enum CodingKeys: String, CodingKey, CaseIterable { case fromDay = "from_day", toDayExclusive = "to_day_exclusive", appVersion = "app_version", population }
    public init(fromDay: String, toDayExclusive: String, appVersion: String? = nil, population: AuroraInsightsPopulation = .production) {
        self.fromDay = fromDay; self.toDayExclusive = toDayExclusive; self.appVersion = appVersion; self.population = population
    }
    public init(_ window: AuroraJourneyFilters, population: AuroraInsightsPopulation) {
        self.init(fromDay: window.fromDay, toDayExclusive: window.toDayExclusive, appVersion: window.appVersion, population: population)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fromDay, forKey: .fromDay); try container.encode(toDayExclusive, forKey: .toDayExclusive)
        try container.encode(appVersion, forKey: .appVersion); try container.encode(population, forKey: .population)
    }
}

// MARK: Coverage

public protocol AuroraInsightsCoverageContract: Codable, Equatable, Sendable {
    /// Checks the documented keys of the raw coverage object (extra keys are allowed).
    static func shape(_ object: [String: Any]) throws
    func validate(window: AuroraJourneyFilters) throws
    /// Disjoint windows of one period.
    mutating func append(_ other: Self) throws
    var firstReceivedAt: String? { get }
    var archivedDays: Int { get }
}

public struct AuroraInsightsCoverage: AuroraInsightsCoverageContract {
    public var collectionFirstReceivedAt: String?
    public var archivedDaysInWindow: Int
    public var archiveAvailableForPopulation: Bool
    public var rawRetentionDays: Int?
    public var smallGroupThreshold: Int
    public var smallGroupsMaskedIn: String
    public var collection: String
    public var collectionRule: String
    public var installationsArePeople: Bool
    public var attribution: String
    public var productionDefinition: String
    enum CodingKeys: String, CodingKey, CaseIterable {
        case collectionFirstReceivedAt = "collection_first_received_at"
        case archivedDaysInWindow = "archived_days_in_window"
        case archiveAvailableForPopulation = "archive_available_for_population"
        case rawRetentionDays = "raw_retention_days"
        case smallGroupThreshold = "small_group_threshold"
        case smallGroupsMaskedIn = "small_groups_masked_in"
        case collection
        case collectionRule = "collection_rule"
        case installationsArePeople = "installations_are_people"
        case attribution
        case productionDefinition = "production_definition"
    }
    public init(collectionFirstReceivedAt: String?, archivedDaysInWindow: Int = 0, archiveAvailableForPopulation: Bool = true, rawRetentionDays: Int? = 396) {
        self.collectionFirstReceivedAt = collectionFirstReceivedAt; self.archivedDaysInWindow = archivedDaysInWindow
        self.archiveAvailableForPopulation = archiveAvailableForPopulation; self.rawRetentionDays = rawRetentionDays
        smallGroupThreshold = 5; smallGroupsMaskedIn = "archived_days_only"; collection = "usage_data_setting_extended"
        collectionRule = "sent by 1.6.0+ installations whose statistics are allowed for the extended purposes"
        installationsArePeople = false; attribution = "not_collected"
        productionDefinition = "installations never seen on a TestFlight or development build"
    }
    public var firstReceivedAt: String? { collectionFirstReceivedAt }
    public var archivedDays: Int { archivedDaysInWindow }
    public static func shape(_ object: [String: Any]) throws {
        try AuroraInsightsContract.require(object, CodingKeys.allCases.map(\.rawValue))
    }
    public func validate(window: AuroraJourneyFilters) throws {
        // Privacy statements shown beside the numbers: a change of meaning rejects the report.
        guard collectionFirstReceivedAt.map({ Dates.parse($0) != nil }) ?? true,
              (0...AuroraInsightsContract.span(window)).contains(archivedDaysInWindow),
              smallGroupThreshold > 0, !installationsArePeople, attribution == "not_collected",
              collectionRule.count <= 2_000, productionDefinition.count <= 1_000 else { throw AuroraJourneyError.unreadableReport }
    }
    public mutating func append(_ other: Self) throws {
        if let next = other.collectionFirstReceivedAt,
           collectionFirstReceivedAt == nil || Dates.parse(next)! < Dates.parse(collectionFirstReceivedAt!)! { collectionFirstReceivedAt = next }
        archivedDaysInWindow = try AuroraJourneyContract.add(archivedDaysInWindow, other.archivedDaysInWindow)
    }
}

/// Coverage of the `server` report: live sizes and, when readable, call statistics of the game's functions.
public struct AuroraInsightsServerCoverage: AuroraInsightsCoverageContract {
    public struct Storage: Codable, Equatable, Sendable {
        public var databaseBytes: Int?
        public var journeyEventsBytes: Int?
        /// Postgres planner estimate; -1 means the table was never analysed (unknown).
        public var journeyEventsRowsEstimate: Int?
        public var reportArchiveBytes: Int?
        public var presenceMinutesBytes: Int?
        public var presenceLiveRows: Int?
        enum CodingKeys: String, CodingKey, CaseIterable {
            case databaseBytes = "database_bytes", journeyEventsBytes = "journey_events_bytes"
            case journeyEventsRowsEstimate = "journey_events_rows_estimate", reportArchiveBytes = "report_archive_bytes"
            case presenceMinutesBytes = "presence_minutes_bytes", presenceLiveRows = "presence_live_rows"
        }
        public init(databaseBytes: Int?, journeyEventsBytes: Int?, journeyEventsRowsEstimate: Int?, reportArchiveBytes: Int?, presenceMinutesBytes: Int?, presenceLiveRows: Int?) {
            self.databaseBytes = databaseBytes; self.journeyEventsBytes = journeyEventsBytes; self.journeyEventsRowsEstimate = journeyEventsRowsEstimate
            self.reportArchiveBytes = reportArchiveBytes; self.presenceMinutesBytes = presenceMinutesBytes; self.presenceLiveRows = presenceLiveRows
        }
        public static var fields: [(key: String, title: String, path: KeyPath<Self, Int?>, bytes: Bool)] { [
            ("database_bytes", "Base de données entière", \.databaseBytes, true),
            ("journey_events_bytes", "Événements du parcours", \.journeyEventsBytes, true),
            ("journey_events_rows_estimate", "Événements conservés (estimation)", \.journeyEventsRowsEstimate, false),
            ("report_archive_bytes", "Archive anonyme des rapports", \.reportArchiveBytes, true),
            ("presence_minutes_bytes", "Présence minute par minute", \.presenceMinutesBytes, true),
            ("presence_live_rows", "Signaux de présence en mémoire", \.presenceLiveRows, false)
        ] }
    }
    public struct FunctionStat: Codable, Equatable, Sendable {
        public var function: String
        public var calls: Int?
        public var meanMs: Double?
        enum CodingKeys: String, CodingKey, CaseIterable { case function, calls, meanMs = "mean_ms" }
        public init(function: String, calls: Int?, meanMs: Double?) { self.function = function; self.calls = calls; self.meanMs = meanMs }
    }
    public var storage: Storage
    public var functions: [FunctionStat]?
    public var functionsAvailable: Bool
    public var requestLogs: String
    enum CodingKeys: String, CodingKey, CaseIterable { case storage, functions, functionsAvailable = "functions_available", requestLogs = "request_logs" }
    public init(storage: Storage, functions: [FunctionStat]?, requestLogs: String) {
        self.storage = storage; self.functions = functions; functionsAvailable = functions != nil; self.requestLogs = requestLogs
    }
    public var firstReceivedAt: String? { nil }
    public var archivedDays: Int { 0 }
    public static func shape(_ object: [String: Any]) throws {
        try AuroraInsightsContract.require(object, CodingKeys.allCases.map(\.rawValue))
        guard let storage = object["storage"] as? [String: Any] else { throw AuroraJourneyError.unreadableReport }
        try AuroraInsightsContract.require(storage, Storage.CodingKeys.allCases.map(\.rawValue))
        if let functions = object["functions"] as? [Any] {
            for item in functions {
                guard let item = item as? [String: Any] else { throw AuroraJourneyError.unreadableReport }
                try AuroraInsightsContract.require(item, FunctionStat.CodingKeys.allCases.map(\.rawValue))
            }
        } else if !(object["functions"] is NSNull) { throw AuroraJourneyError.unreadableReport }
    }
    public func validate(window: AuroraJourneyFilters) throws {
        guard functionsAvailable == (functions != nil), requestLogs.count <= 1_000,
              (functions ?? []).allSatisfy({ $0.function.count <= 100 }) else { throw AuroraJourneyError.unreadableReport }
    }
    /// Sizes are live values: the latest window wins.
    public mutating func append(_ other: Self) throws { self = other }
}

// MARK: Rows

public protocol AuroraInsightsRow: Codable, Equatable, Sendable {
    associatedtype Coverage: AuroraInsightsCoverageContract = AuroraInsightsCoverage
    static var kind: AuroraInsightsKind { get }
    /// Every documented key, in column order. All must be present (possibly null) in each row.
    static var documentedKeys: [String] { get }
    /// Keys whose value is a map code → count (exported as long tables).
    static var mapKeys: [String] { get }
    var day: String { get }
    var rowVersion: String? { get }
    var stableKey: String { get }
    var masked: Bool { get }
}
public extension AuroraInsightsRow {
    static var mapKeys: [String] { [] }
    var rowVersion: String? { nil }
    var masked: Bool { false }
}

public struct AuroraActivityRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.activity
    public var day: String
    public var installations: Int?
    public var dau: Int?
    public var wau: Int?
    public var mau: Int?
    public var newInstallations: Int?
    public var returningInstallations: Int?
    public var sessions: Int?
    public var accounts: Int?
    public var installationsWithContext: Int?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, installations, dau, wau, mau, newInstallations = "new_installations", returningInstallations = "returning_installations"
        case sessions, accounts, installationsWithContext = "installations_with_context", suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public var stableKey: String { day }
    public var masked: Bool { suppressed }
    public init(day: String, dau: Int?, wau: Int?, mau: Int?, newInstallations: Int?, returningInstallations: Int?, sessions: Int?, accounts: Int?, installationsWithContext: Int?, suppressed: Bool = false) {
        self.day = day; installations = dau; self.dau = dau; self.wau = wau; self.mau = mau; self.newInstallations = newInstallations
        self.returningInstallations = returningInstallations; self.sessions = sessions; self.accounts = accounts
        self.installationsWithContext = installationsWithContext; self.suppressed = suppressed
    }
}

public struct AuroraSessionsRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.sessions
    public var day: String
    public var appVersion: String
    public var installations: Int?
    public var sessionsStarted: Int?
    public var sessionsMeasured: Int?
    public var segments: Int?
    public var foregroundSeconds: Int?
    public var adSeconds: Int?
    public var idleSeconds: Int?
    public var gridSeconds: Int?
    public var activeSeconds: Int?
    public var endedByQuit: Int?
    public var medianSessionSeconds: Double?
    public var p90SessionSeconds: Double?
    public var medianActiveSeconds: Double?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", installations, sessionsStarted = "sessions_started", sessionsMeasured = "sessions_measured", segments
        case foregroundSeconds = "foreground_seconds", adSeconds = "ad_seconds", idleSeconds = "idle_seconds", gridSeconds = "grid_seconds"
        case activeSeconds = "active_seconds", endedByQuit = "ended_by_quit", medianSessionSeconds = "median_session_seconds"
        case p90SessionSeconds = "p90_session_seconds", medianActiveSeconds = "median_active_seconds", suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { day + "|" + appVersion }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, installations: Int?, sessionsStarted: Int?, sessionsMeasured: Int?, segments: Int?,
                foregroundSeconds: Int?, adSeconds: Int?, idleSeconds: Int?, gridSeconds: Int?, activeSeconds: Int?, endedByQuit: Int?,
                medianSessionSeconds: Double?, p90SessionSeconds: Double?, medianActiveSeconds: Double?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.installations = installations; self.sessionsStarted = sessionsStarted
        self.sessionsMeasured = sessionsMeasured; self.segments = segments; self.foregroundSeconds = foregroundSeconds; self.adSeconds = adSeconds
        self.idleSeconds = idleSeconds; self.gridSeconds = gridSeconds; self.activeSeconds = activeSeconds; self.endedByQuit = endedByQuit
        self.medianSessionSeconds = medianSessionSeconds; self.p90SessionSeconds = p90SessionSeconds; self.medianActiveSeconds = medianActiveSeconds
        self.suppressed = suppressed
    }
}

public struct AuroraScreenRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.screens
    public var day: String
    public var appVersion: String
    public var screen: String
    public var installations: Int?
    public var views: Int?
    public var seconds: Int?
    public var medianSeconds: Double?
    public var leftToBackground: Int?
    public var origins: [String: Int]?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", screen, installations, views, seconds, medianSeconds = "median_seconds"
        case leftToBackground = "left_to_background", origins, suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public static var mapKeys: [String] { ["origins"] }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, screen].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, screen: String, installations: Int?, views: Int?, seconds: Int?, medianSeconds: Double?,
                leftToBackground: Int?, origins: [String: Int]?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.screen = screen; self.installations = installations; self.views = views
        self.seconds = seconds; self.medianSeconds = medianSeconds; self.leftToBackground = leftToBackground; self.origins = origins; self.suppressed = suppressed
    }
}

public struct AuroraDialogRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.dialogs
    public var day: String
    public var appVersion: String
    public var dialog: String
    public var installations: Int?
    public var closes: Int?
    public var seconds: Int?
    public var medianSeconds: Double?
    public var outcomes: [String: Int]?
    public var screens: [String: Int]?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", dialog, installations, closes, seconds, medianSeconds = "median_seconds", outcomes, screens, suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public static var mapKeys: [String] { ["outcomes", "screens"] }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, dialog].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, dialog: String, installations: Int?, closes: Int?, seconds: Int?, medianSeconds: Double?,
                outcomes: [String: Int]?, screens: [String: Int]?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.dialog = dialog; self.installations = installations; self.closes = closes
        self.seconds = seconds; self.medianSeconds = medianSeconds; self.outcomes = outcomes; self.screens = screens; self.suppressed = suppressed
    }
}

public struct AuroraActionRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.actions
    public var day: String
    public var appVersion: String
    public var action: String
    public var installations: Int?
    public var events: Int?
    public var valueSum: Int?
    public var valuedEvents: Int?
    public var screens: [String: Int]?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", action, installations, events, valueSum = "value_sum", valuedEvents = "valued_events", screens, suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public static var mapKeys: [String] { ["screens"] }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, action].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, action: String, installations: Int?, events: Int?, valueSum: Int?, valuedEvents: Int?, screens: [String: Int]?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.action = action; self.installations = installations; self.events = events
        self.valueSum = valueSum; self.valuedEvents = valuedEvents; self.screens = screens; self.suppressed = suppressed
    }
}

public struct AuroraGameplayRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.gameplay
    public var day: String
    public var appVersion: String
    public var mode: String
    public var level: Int
    public var difficulty: String
    public var boardSize: Int
    public var outcome: String
    public var installations: Int?
    public var runs: Int?
    public var activeSeconds: Int?
    public var medianActiveSeconds: Double?
    public var moves: Int?
    public var errors: Int?
    public var undos: Int?
    public var hints: Int?
    public var runsWithHints: Int?
    public var runsWithErrors: Int?
    public var scoredRuns: Int?
    public var score: Int?
    public var maxScore: Int?
    public var newBest: Int?
    public var ranked: Int?
    public var completionKnown: Int?
    public var completionPct: Int?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", mode, level, difficulty, boardSize = "board_size", outcome, installations, runs
        case activeSeconds = "active_seconds", medianActiveSeconds = "median_active_seconds", moves, errors, undos, hints
        case runsWithHints = "runs_with_hints", runsWithErrors = "runs_with_errors", scoredRuns = "scored_runs", score
        case maxScore = "max_score", newBest = "new_best", ranked, completionKnown = "completion_known", completionPct = "completion_pct", suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, mode, String(format: "%08d", level), difficulty, String(format: "%03d", boardSize), outcome].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, mode: String, level: Int, difficulty: String, boardSize: Int, outcome: String,
                installations: Int?, runs: Int?, activeSeconds: Int?, medianActiveSeconds: Double?, moves: Int?, errors: Int?, undos: Int?,
                hints: Int?, runsWithHints: Int?, runsWithErrors: Int?, scoredRuns: Int?, score: Int?, maxScore: Int?, newBest: Int?,
                ranked: Int?, completionKnown: Int?, completionPct: Int?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.mode = mode; self.level = level; self.difficulty = difficulty
        self.boardSize = boardSize; self.outcome = outcome; self.installations = installations; self.runs = runs
        self.activeSeconds = activeSeconds; self.medianActiveSeconds = medianActiveSeconds; self.moves = moves; self.errors = errors
        self.undos = undos; self.hints = hints; self.runsWithHints = runsWithHints; self.runsWithErrors = runsWithErrors
        self.scoredRuns = scoredRuns; self.score = score; self.maxScore = maxScore; self.newBest = newBest; self.ranked = ranked
        self.completionKnown = completionKnown; self.completionPct = completionPct; self.suppressed = suppressed
    }
}

public struct AuroraTimelineRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.timeline
    public var day: String
    public var appVersion: String
    public var mode: String
    public var level: Int
    public var difficulty: String
    public var installations: Int?
    public var timelines: Int?
    public var actions: Int?
    public var truncated: Int?
    public var partial: Int?
    /// Sum over the complete timelines, in deciseconds.
    public var firstActionDs: Int?
    public var medianFirstActionDs: Double?
    /// Sum over the timelines, in deciseconds.
    public var lastActionDs: Int?
    public var byKind: [String: Int]?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", mode, level, difficulty, installations, timelines, actions, truncated, partial
        case firstActionDs = "first_action_ds", medianFirstActionDs = "median_first_action_ds", lastActionDs = "last_action_ds"
        case byKind = "by_kind", suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public static var mapKeys: [String] { ["by_kind"] }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, mode, String(format: "%08d", level), difficulty].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, mode: String, level: Int, difficulty: String, installations: Int?, timelines: Int?, actions: Int?,
                truncated: Int?, partial: Int?, firstActionDs: Int?, medianFirstActionDs: Double?, lastActionDs: Int?, byKind: [String: Int]?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.mode = mode; self.level = level; self.difficulty = difficulty
        self.installations = installations; self.timelines = timelines; self.actions = actions; self.truncated = truncated
        self.partial = partial; self.firstActionDs = firstActionDs; self.medianFirstActionDs = medianFirstActionDs
        self.lastActionDs = lastActionDs; self.byKind = byKind; self.suppressed = suppressed
    }
}

public struct AuroraProgressRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.progress
    public var day: String
    public var appVersion: String
    public var kind: String
    public var code: String
    public var installations: Int?
    public var events: Int?
    public var valueMax: Int?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable { case day, appVersion = "app_version", kind, code, installations, events, valueMax = "value_max", suppressed }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, kind, code].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, kind: String, code: String, installations: Int?, events: Int?, valueMax: Int?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.kind = kind; self.code = code; self.installations = installations
        self.events = events; self.valueMax = valueMax; self.suppressed = suppressed
    }
}

public struct AuroraSettingRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.settings
    public var day: String
    public var appVersion: String
    public var setting: String
    public var value: String
    public var installations: Int?
    public var changes: Int?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable { case day, appVersion = "app_version", setting, value, installations, changes, suppressed }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, setting, value].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, setting: String, value: String, installations: Int?, changes: Int?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.setting = setting; self.value = value; self.installations = installations
        self.changes = changes; self.suppressed = suppressed
    }
}

public struct AuroraStabilityRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.stability
    public var day: String
    public var appVersion: String
    public var installations: Int?
    public var launches: Int?
    public var coldStarts: Int?
    /// Launches whose previous run stopped while on screen: a crash or a forced stop, indistinguishable.
    public var stopsWhileOnScreen: Int?
    public var installationsWithStops: Int?
    public var errorEvents: Int?
    public var installationsWithErrors: Int?
    public var sessionsWithErrors: Int?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", installations, launches, coldStarts = "cold_starts", stopsWhileOnScreen = "stops_while_on_screen"
        case installationsWithStops = "installations_with_stops", errorEvents = "error_events", installationsWithErrors = "installations_with_errors"
        case sessionsWithErrors = "sessions_with_errors", suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { day + "|" + appVersion }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, installations: Int?, launches: Int?, coldStarts: Int?, stopsWhileOnScreen: Int?,
                installationsWithStops: Int?, errorEvents: Int?, installationsWithErrors: Int?, sessionsWithErrors: Int?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.installations = installations; self.launches = launches; self.coldStarts = coldStarts
        self.stopsWhileOnScreen = stopsWhileOnScreen; self.installationsWithStops = installationsWithStops; self.errorEvents = errorEvents
        self.installationsWithErrors = installationsWithErrors; self.sessionsWithErrors = sessionsWithErrors; self.suppressed = suppressed
    }
}

public struct AuroraDiagnosticRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.diagnostics
    public var day: String
    public var appVersion: String
    public var kind: String
    public var exceptionType: String
    /// Hash of the error signature (not a person or a device).
    public var fingerprint: String
    public var installations: Int?
    public var events: Int?
    public var sessions: Int?
    public var screens: [String: Int]?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", kind, exceptionType = "exception_type", fingerprint, installations, events, sessions, screens, suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public static var mapKeys: [String] { ["screens"] }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, kind, exceptionType, fingerprint].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, kind: String, exceptionType: String, fingerprint: String, installations: Int?, events: Int?,
                sessions: Int?, screens: [String: Int]?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.kind = kind; self.exceptionType = exceptionType; self.fingerprint = fingerprint
        self.installations = installations; self.events = events; self.sessions = sessions; self.screens = screens; self.suppressed = suppressed
    }
}

public struct AuroraPerformanceRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.performance
    public var day: String
    public var appVersion: String
    public var deviceModel: String
    public var osMajor: String
    public var installations: Int?
    public var stretches: Int?
    public var frames: Int?
    public var slowFrames: Int?
    public var verySlowFrames: Int?
    public var maxFrameMs: Int?
    /// Σ average fps × frames: divided by frames for a frame-weighted average.
    public var fpsFrames: Int?
    public var memoryPeakMbMax: Int?
    public var memoryPeakMbMedian: Double?
    public var startups: Int?
    public var startupMsMedian: Double?
    public var thermalSerious: Int?
    public var lowPower: Int?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", deviceModel = "device_model", osMajor = "os_major", installations, stretches, frames
        case slowFrames = "slow_frames", verySlowFrames = "very_slow_frames", maxFrameMs = "max_frame_ms", fpsFrames = "fps_frames"
        case memoryPeakMbMax = "memory_peak_mb_max", memoryPeakMbMedian = "memory_peak_mb_median", startups
        case startupMsMedian = "startup_ms_median", thermalSerious = "thermal_serious", lowPower = "low_power", suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, deviceModel, osMajor].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, deviceModel: String, osMajor: String, installations: Int?, stretches: Int?, frames: Int?,
                slowFrames: Int?, verySlowFrames: Int?, maxFrameMs: Int?, fpsFrames: Int?, memoryPeakMbMax: Int?, memoryPeakMbMedian: Double?,
                startups: Int?, startupMsMedian: Double?, thermalSerious: Int?, lowPower: Int?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.deviceModel = deviceModel; self.osMajor = osMajor; self.installations = installations
        self.stretches = stretches; self.frames = frames; self.slowFrames = slowFrames; self.verySlowFrames = verySlowFrames
        self.maxFrameMs = maxFrameMs; self.fpsFrames = fpsFrames; self.memoryPeakMbMax = memoryPeakMbMax
        self.memoryPeakMbMedian = memoryPeakMbMedian; self.startups = startups; self.startupMsMedian = startupMsMedian
        self.thermalSerious = thermalSerious; self.lowPower = lowPower; self.suppressed = suppressed
    }
}

public struct AuroraCloudRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.cloud
    public var day: String
    public var appVersion: String
    public var op: String
    public var outcome: String
    public var installations: Int?
    public var ops: Int?
    public var medianMs: Double?
    public var p90Ms: Double?
    public var maxMs: Int?
    public var statuses: [String: Int]?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", op, outcome, installations, ops, medianMs = "median_ms", p90Ms = "p90_ms", maxMs = "max_ms", statuses, suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public static var mapKeys: [String] { ["statuses"] }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, op, outcome].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, op: String, outcome: String, installations: Int?, ops: Int?, medianMs: Double?, p90Ms: Double?,
                maxMs: Int?, statuses: [String: Int]?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.op = op; self.outcome = outcome; self.installations = installations; self.ops = ops
        self.medianMs = medianMs; self.p90Ms = p90Ms; self.maxMs = maxMs; self.statuses = statuses; self.suppressed = suppressed
    }
}

public struct AuroraPrivacyRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.privacy
    public var day: String
    public var appVersion: String
    public var statisticsBasis: String
    public var statisticsSource: String
    public var regionClass: String
    public var attStatus: String
    public var installations: Int?
    public var sessions: Int?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", statisticsBasis = "statistics_basis", statisticsSource = "statistics_source"
        case regionClass = "region_class", attStatus = "att_status", installations, sessions, suppressed
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, statisticsBasis, statisticsSource, regionClass, attStatus].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, statisticsBasis: String, statisticsSource: String, regionClass: String, attStatus: String,
                installations: Int?, sessions: Int?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.statisticsBasis = statisticsBasis; self.statisticsSource = statisticsSource
        self.regionClass = regionClass; self.attStatus = attStatus; self.installations = installations; self.sessions = sessions; self.suppressed = suppressed
    }
}

public struct AuroraConsentRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.consents
    public var day: String
    public var appVersion: String
    public var purpose: String
    public var state: String
    public var source: String
    /// Null for the anonymous withdrawals (`source` = anonymous_count): no installation is known.
    public var installations: Int?
    public var events: Int?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable { case day, appVersion = "app_version", purpose, state, source, installations, events, suppressed }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, purpose, state, source].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public var anonymous: Bool { source == "anonymous_count" }
    public init(day: String, appVersion: String, purpose: String, state: String, source: String, installations: Int?, events: Int?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.purpose = purpose; self.state = state; self.source = source
        self.installations = installations; self.events = events; self.suppressed = suppressed
    }
}

public struct AuroraContextRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.context
    public var day: String
    public var appVersion: String
    public var dimension: String
    /// Null when the device did not report this dimension.
    public var value: String?
    public var installations: Int?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable { case day, appVersion = "app_version", dimension, value, installations, suppressed }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, dimension, value ?? ""].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, dimension: String, value: String?, installations: Int?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.dimension = dimension; self.value = value; self.installations = installations; self.suppressed = suppressed
    }
}

public struct AuroraNotificationRow: AuroraInsightsRow {
    public static let kind = AuroraInsightsKind.notifications
    public var day: String
    public var appVersion: String
    public var kind: String
    public var destination: String
    public var installations: Int?
    public var opens: Int?
    public var suppressed: Bool
    enum CodingKeys: String, CodingKey, CaseIterable { case day, appVersion = "app_version", kind, destination, installations, opens, suppressed }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public var rowVersion: String? { appVersion }
    public var stableKey: String { [day, appVersion, kind, destination].joined(separator: "|") }
    public var masked: Bool { suppressed }
    public init(day: String, appVersion: String, kind: String, destination: String, installations: Int?, opens: Int?, suppressed: Bool = false) {
        self.day = day; self.appVersion = appVersion; self.kind = kind; self.destination = destination
        self.installations = installations; self.opens = opens; self.suppressed = suppressed
    }
}

/// Server side of the collection, per Zurich day of reception (all populations, all versions).
public struct AuroraServerRow: AuroraInsightsRow {
    public typealias Coverage = AuroraInsightsServerCoverage
    public static let kind = AuroraInsightsKind.server
    public var day: String
    public var eventsReceived: Int?
    public var installationsSending: Int?
    public var coreEvents: Int?
    public var extendedEvents: Int?
    public var rejections: [String: Int]?
    public var presenceMinutes: Int?
    public var presencePeak: Int?
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, eventsReceived = "events_received", installationsSending = "installations_sending", coreEvents = "core_events"
        case extendedEvents = "extended_events", rejections, presenceMinutes = "presence_minutes", presencePeak = "presence_peak"
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public static var mapKeys: [String] { ["rejections"] }
    public var stableKey: String { day }
    public init(day: String, eventsReceived: Int?, installationsSending: Int?, coreEvents: Int?, extendedEvents: Int?, rejections: [String: Int]?, presenceMinutes: Int?, presencePeak: Int?) {
        self.day = day; self.eventsReceived = eventsReceived; self.installationsSending = installationsSending; self.coreEvents = coreEvents
        self.extendedEvents = extendedEvents; self.rejections = rejections; self.presenceMinutes = presenceMinutes; self.presencePeak = presencePeak
    }
}

// MARK: Report

/// Type-erased view of a report, for the bundle, the export and the coverage lines.
public protocol AuroraInsightsAnyReport: Sendable {
    var kind: AuroraInsightsKind { get }
    var generatedAt: String { get }
    var asOf: String { get }
    var timezone: String { get }
    var filters: AuroraInsightsFilters { get }
    var rowCount: Int { get }
    var maskedRowCount: Int { get }
    var firstReceivedAt: String? { get }
    var archivedDays: Int { get }
    /// Nil for the server report, whose coverage describes storage.
    var standardCoverage: AuroraInsightsCoverage? { get }
    /// Rows re-encoded through their documented keys only: unknown keys never survive decoding.
    func encodedRows() -> [[String: Any]]
    var documentedKeys: [String] { get }
    var mapKeys: [String] { get }
}

public struct AuroraInsightsReport<Row: AuroraInsightsRow>: Codable, Sendable {
    public var contractVersion: Int
    public var report: String
    public var generatedAt: String
    public var asOf: String
    public var timezone: String
    public var filters: AuroraInsightsFilters
    public var coverage: Row.Coverage
    public var rows: [Row]
    enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion = "contract_version", report, generatedAt = "generated_at", asOf = "as_of", timezone, filters, coverage, rows
    }
    public init(generatedAt: String, asOf: String, filters: AuroraInsightsFilters, coverage: Row.Coverage, rows: [Row]) {
        contractVersion = 1; report = Row.kind.rawValue; self.generatedAt = generatedAt; self.asOf = asOf; timezone = "Europe/Zurich"
        self.filters = filters; self.coverage = coverage; self.rows = rows
    }
}
extension AuroraInsightsReport: AuroraInsightsAnyReport {
    public var kind: AuroraInsightsKind { Row.kind }
    public var rowCount: Int { rows.count }
    public var maskedRowCount: Int { rows.filter(\.masked).count }
    public var firstReceivedAt: String? { coverage.firstReceivedAt }
    public var archivedDays: Int { coverage.archivedDays }
    public var standardCoverage: AuroraInsightsCoverage? { coverage as? AuroraInsightsCoverage }
    public var documentedKeys: [String] { Row.documentedKeys }
    public var mapKeys: [String] { Row.mapKeys }
    /// Unmasked rows only: the ones whose numbers are known.
    public var visibleRows: [Row] { rows.filter { !$0.masked } }
    public func encodedRows() -> [[String: Any]] {
        guard let data = try? JSONEncoder().encode(rows),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return objects
    }
}

enum AuroraInsightsContract {
    static let function = "gamemetrik_aurora_insights_report_v1"
    static let presenceFunction = "gamemetrik_aurora_presence_report_v1"
    static let maxRows = 200_000
    static func require(_ object: [String: Any], _ keys: [String]) throws {
        guard Set(keys).isSubset(of: Set(object.keys)) else { throw AuroraJourneyError.unreadableReport }
    }
    static func span(_ window: AuroraJourneyFilters) -> Int {
        AuroraJourneyContract.calendar.dateComponents([.day], from: AuroraJourneyContract.day(window.fromDay)!, to: AuroraJourneyContract.day(window.toDayExclusive)!).day!
    }
    /// Documented keys present with any extra key allowed; the typed decoding then checks the types.
    static func shape<Row: AuroraInsightsRow>(_ data: Data, row: Row.Type) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuroraJourneyError.unreadableReport }
        try require(root, AuroraInsightsReport<Row>.CodingKeys.allCases.map(\.rawValue))
        guard let filters = root["filters"] as? [String: Any], let coverage = root["coverage"] as? [String: Any],
              let rows = root["rows"] as? [Any], rows.count <= maxRows else { throw AuroraJourneyError.unreadableReport }
        try require(filters, AuroraInsightsFilters.CodingKeys.allCases.map(\.rawValue))
        try Row.Coverage.shape(coverage)
        for item in rows {
            guard let object = item as? [String: Any] else { throw AuroraJourneyError.unreadableReport }
            try require(object, Row.documentedKeys)
        }
    }
    static func validate<Row: AuroraInsightsRow>(_ row: Row, window: AuroraJourneyFilters) throws {
        try AuroraJourneyContract.validateDay(row.day, window)
        if let version = row.rowVersion {
            guard AuroraJourneyContract.version(version), window.appVersion == nil || version == window.appVersion else { throw AuroraJourneyError.unreadableReport }
        }
    }
}

public extension AuroraJourneyReportReader {
    /// One insights family for a period: disjoint windows of at most 366 days concatenated under one `as_of`.
    /// Any window outside the contract rejects the whole report (no partial numbers).
    func insights<Row: AuroraInsightsRow>(_ type: Row.Type, filters: AuroraJourneyFilters, population: AuroraInsightsPopulation, asOf: String? = nil) async throws -> AuroraInsightsReport<Row> {
        try personal.validate()
        guard asOf.map({ Dates.parse($0) != nil }) ?? true else { throw AuroraJourneyError.invalidRequest }
        let windows = try filters.windows()
        var result: AuroraInsightsReport<Row>?
        var boundary = asOf
        for window in windows {
            try Task.checkCancellation()
            var payload: [String: Any] = ["contract_version": 1, "report": Row.kind.rawValue, "from_day": window.fromDay,
                                          "to_day_exclusive": window.toDayExclusive, "population": population.rawValue]
            if let version = filters.appVersion, Row.kind != .server { payload["app_version"] = version }
            if let boundary { payload["as_of"] = boundary }
            let data = try await rpc(AuroraInsightsContract.function, payload: payload)
            do {
                try AuroraInsightsContract.shape(data, row: Row.self)
                let page = try JSONDecoder().decode(AuroraInsightsReport<Row>.self, from: data)
                // The server report covers every population and version.
                let expected = Row.kind == .server
                    ? AuroraInsightsFilters(fromDay: window.fromDay, toDayExclusive: window.toDayExclusive, appVersion: nil, population: .all)
                    : AuroraInsightsFilters(window, population: population)
                guard page.contractVersion == 1, page.report == Row.kind.rawValue, page.filters == expected, page.timezone == "Europe/Zurich",
                      Dates.parse(page.generatedAt) != nil, let instant = Dates.parse(page.asOf),
                      boundary.map({ Dates.parse($0) == instant }) ?? true else { throw AuroraJourneyError.unreadableReport }
                try page.coverage.validate(window: window)
                for row in page.rows { try AuroraInsightsContract.validate(row, window: window) }
                if result == nil { result = page; boundary = page.asOf }
                else {
                    result!.rows += page.rows
                    try result!.coverage.append(page.coverage)
                    if Dates.parse(page.generatedAt)! > Dates.parse(result!.generatedAt)! { result!.generatedAt = page.generatedAt }
                }
                guard result!.rows.count <= AuroraInsightsContract.maxRows else { throw AuroraJourneyError.unreadableReport }
            } catch { throw AuroraJourneyError.unreadableReport }
        }
        guard var result else { throw AuroraJourneyError.unreadableReport }
        // No uniqueness check: a dimension added later by the server would make rows look duplicated here.
        result.rows = result.rows.enumerated().sorted { ($0.element.stableKey, $0.offset) < ($1.element.stableKey, $1.offset) }.map(\.element)
        result.filters = Row.kind == .server
            ? .init(fromDay: filters.fromDay, toDayExclusive: filters.toDayExclusive, appVersion: nil, population: .all)
            : .init(filters, population: population)
        return result
    }
}

// MARK: Presence

public enum AuroraPresenceKind: String, CaseIterable, Sendable {
    case live, history, hourly
    public var title: String {
        switch self {
        case .live: "Présence en direct"
        case .history: "Pics quotidiens"
        case .hourly: "Présence par heure"
        }
    }
}

public struct AuroraPresenceCoverage: Codable, Equatable, Sendable {
    public var windowSeconds: Int
    public var signalIntervalSeconds: Int
    public var collection: String
    public var population: String
    public var productionDefinition: String
    public var firstSignalAt: String?
    public var samplerMinutesToday: Int?
    public var playersAreInstallations: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case windowSeconds = "window_seconds", signalIntervalSeconds = "signal_interval_seconds", collection, population
        case productionDefinition = "production_definition", firstSignalAt = "first_signal_at", samplerMinutesToday = "sampler_minutes_today"
        case playersAreInstallations = "players_are_installations"
    }
    public init(firstSignalAt: String?, samplerMinutesToday: Int?) {
        windowSeconds = 90; signalIntervalSeconds = 30; collection = "usage_data_setting_extended"
        population = "foreground installations whose statistics are allowed for the extended purposes (1.6.0+)"
        productionDefinition = "app_store and unknown builds; testflight and development builds are internal"
        self.firstSignalAt = firstSignalAt; self.samplerMinutesToday = samplerMinutesToday; playersAreInstallations = true
    }
    func validate() throws {
        guard windowSeconds > 0, signalIntervalSeconds > 0, playersAreInstallations,
              firstSignalAt.map({ Dates.parse($0) != nil }) ?? true, population.count <= 1_000 else { throw AuroraJourneyError.unreadableReport }
    }
}

public struct AuroraPresenceFilters: Codable, Equatable, Sendable {
    public var fromDay: String?
    public var toDayExclusive: String?
    enum CodingKeys: String, CodingKey, CaseIterable { case fromDay = "from_day", toDayExclusive = "to_day_exclusive" }
    public init(fromDay: String? = nil, toDayExclusive: String? = nil) { self.fromDay = fromDay; self.toDayExclusive = toDayExclusive }
}

public protocol AuroraPresenceRow: Codable, Equatable, Sendable {
    static var kind: AuroraPresenceKind { get }
    static var documentedKeys: [String] { get }
    func validate(window: AuroraJourneyFilters?) throws
}

/// Players present now: a signal within the last 90 s. Production = app_store and unknown builds.
public struct AuroraPresenceLiveRow: AuroraPresenceRow {
    public static let kind = AuroraPresenceKind.live
    public var distribution: String
    public var appVersion: String
    public var state: String
    public var gameMode: String
    public var players: Int
    enum CodingKeys: String, CodingKey, CaseIterable { case distribution, appVersion = "app_version", state, gameMode = "game_mode", players }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public init(distribution: String, appVersion: String, state: String, gameMode: String, players: Int) {
        self.distribution = distribution; self.appVersion = appVersion; self.state = state; self.gameMode = gameMode; self.players = players
    }
    public var isProduction: Bool { ["app_store", "unknown"].contains(distribution) }
    public func belongs(to population: AuroraInsightsPopulation) -> Bool {
        switch population {
        case .production: isProduction
        case .internalBuilds: !isProduction
        case .all: true
        }
    }
    public func validate(window: AuroraJourneyFilters?) throws {
        guard players >= 0, AuroraJourneyContract.version(appVersion) else { throw AuroraJourneyError.unreadableReport }
    }
}

/// Daily peaks of present production installations (and of internal builds, apart). `complete` = finished day.
public struct AuroraPresenceDayRow: AuroraPresenceRow {
    public static let kind = AuroraPresenceKind.history
    public var day: String
    public var peakInApp: Int?
    public var peakOnGrid: Int?
    public var peakAt: String?
    public var avgInApp: Double?
    public var minutesObserved: Int?
    public var internalPeakInApp: Int?
    public var complete: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, peakInApp = "peak_in_app", peakOnGrid = "peak_on_grid", peakAt = "peak_at", avgInApp = "avg_in_app"
        case minutesObserved = "minutes_observed", internalPeakInApp = "internal_peak_in_app", complete
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public init(day: String, peakInApp: Int?, peakOnGrid: Int?, peakAt: String?, avgInApp: Double?, minutesObserved: Int?, internalPeakInApp: Int?, complete: Bool) {
        self.day = day; self.peakInApp = peakInApp; self.peakOnGrid = peakOnGrid; self.peakAt = peakAt; self.avgInApp = avgInApp
        self.minutesObserved = minutesObserved; self.internalPeakInApp = internalPeakInApp; self.complete = complete
    }
    public func validate(window: AuroraJourneyFilters?) throws {
        if let window { try AuroraJourneyContract.validateDay(day, window) }
        guard peakAt.map({ Dates.parse($0) != nil }) ?? true else { throw AuroraJourneyError.unreadableReport }
    }
}

/// One Zurich hour (local time, without offset).
public struct AuroraPresenceHourRow: AuroraPresenceRow {
    public static let kind = AuroraPresenceKind.hourly
    public var hour: String
    public var avgInApp: Double?
    public var peakInApp: Int?
    public var avgOnGrid: Double?
    public var peakOnGrid: Int?
    public var minutesObserved: Int?
    enum CodingKeys: String, CodingKey, CaseIterable {
        case hour, avgInApp = "avg_in_app", peakInApp = "peak_in_app", avgOnGrid = "avg_on_grid", peakOnGrid = "peak_on_grid", minutesObserved = "minutes_observed"
    }
    public static var documentedKeys: [String] { CodingKeys.allCases.map(\.rawValue) }
    public init(hour: String, avgInApp: Double?, peakInApp: Int?, avgOnGrid: Double?, peakOnGrid: Int?, minutesObserved: Int?) {
        self.hour = hour; self.avgInApp = avgInApp; self.peakInApp = peakInApp; self.avgOnGrid = avgOnGrid; self.peakOnGrid = peakOnGrid; self.minutesObserved = minutesObserved
    }
    public var day: String { String(hour.prefix(10)) }
    public var hourOfDay: Int? { hour.count >= 13 ? Int(hour.dropFirst(11).prefix(2)) : nil }
    public func validate(window: AuroraJourneyFilters?) throws {
        guard AuroraJourneyContract.whole(hour, #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$"#) else { throw AuroraJourneyError.unreadableReport }
        if let window { try AuroraJourneyContract.validateDay(day, window) }
    }
}

public struct AuroraPresenceReport<Row: AuroraPresenceRow>: Codable, Sendable {
    public var contractVersion: Int
    public var report: String
    public var generatedAt: String
    public var timezone: String
    public var filters: AuroraPresenceFilters
    public var coverage: AuroraPresenceCoverage
    public var rows: [Row]
    enum CodingKeys: String, CodingKey, CaseIterable { case contractVersion = "contract_version", report, generatedAt = "generated_at", timezone, filters, coverage, rows }
    public init(generatedAt: String, filters: AuroraPresenceFilters, coverage: AuroraPresenceCoverage, rows: [Row]) {
        contractVersion = 1; report = Row.kind.rawValue; self.generatedAt = generatedAt; timezone = "Europe/Zurich"
        self.filters = filters; self.coverage = coverage; self.rows = rows
    }
}

extension AuroraJourneyContract {
    static func whole(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == (value.startIndex..<value.endIndex)
    }
}

public extension AuroraJourneyReportReader {
    func presenceLive() async throws -> AuroraPresenceReport<AuroraPresenceLiveRow> {
        try personal.validate()
        return try await presencePage(window: nil)
    }
    /// Daily peaks over windows of at most 366 days, concatenated.
    func presenceHistory(filters: AuroraJourneyFilters) async throws -> AuroraPresenceReport<AuroraPresenceDayRow> {
        try personal.validate()
        var result: AuroraPresenceReport<AuroraPresenceDayRow>?
        for window in try filters.windows() {
            try Task.checkCancellation()
            let page: AuroraPresenceReport<AuroraPresenceDayRow> = try await presencePage(window: window)
            if result == nil { result = page }
            else {
                result!.rows += page.rows
                let first = [result!.coverage.firstSignalAt, page.coverage.firstSignalAt].compactMap { $0 }.min { Dates.parse($0)! < Dates.parse($1)! }
                result!.coverage = page.coverage; result!.coverage.firstSignalAt = first
                if Dates.parse(page.generatedAt)! > Dates.parse(result!.generatedAt)! { result!.generatedAt = page.generatedAt }
            }
        }
        guard var result else { throw AuroraJourneyError.unreadableReport }
        result.filters = .init(fromDay: filters.fromDay, toDayExclusive: filters.toDayExclusive)
        result.rows.sort { $0.day < $1.day }
        return result
    }
    /// Hourly averages, at most 31 days.
    func presenceHourly(filters: AuroraJourneyFilters) async throws -> AuroraPresenceReport<AuroraPresenceHourRow> {
        try personal.validate()
        let windows = try filters.windows()
        guard windows.count == 1, AuroraInsightsContract.span(filters) <= 31 else { throw AuroraJourneyError.invalidRequest }
        return try await presencePage(window: filters)
    }
    private func presencePage<Row: AuroraPresenceRow>(window: AuroraJourneyFilters?) async throws -> AuroraPresenceReport<Row> {
        var payload: [String: Any] = ["contract_version": 1, "report": Row.kind.rawValue]
        if let window { payload["from_day"] = window.fromDay; payload["to_day_exclusive"] = window.toDayExclusive }
        let data = try await rpc(AuroraInsightsContract.presenceFunction, payload: payload)
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let filters = root["filters"] as? [String: Any], let coverage = root["coverage"] as? [String: Any],
                  let rows = root["rows"] as? [Any], rows.count <= AuroraInsightsContract.maxRows else { throw AuroraJourneyError.unreadableReport }
            try AuroraInsightsContract.require(root, AuroraPresenceReport<Row>.CodingKeys.allCases.map(\.rawValue))
            if window != nil { try AuroraInsightsContract.require(filters, AuroraPresenceFilters.CodingKeys.allCases.map(\.rawValue)) }
            try AuroraInsightsContract.require(coverage, AuroraPresenceCoverage.CodingKeys.allCases.map(\.rawValue))
            for item in rows {
                guard let object = item as? [String: Any] else { throw AuroraJourneyError.unreadableReport }
                try AuroraInsightsContract.require(object, Row.documentedKeys)
            }
            let page = try JSONDecoder().decode(AuroraPresenceReport<Row>.self, from: data)
            guard page.contractVersion == 1, page.report == Row.kind.rawValue, page.timezone == "Europe/Zurich", Dates.parse(page.generatedAt) != nil,
                  page.filters == (window.map { AuroraPresenceFilters(fromDay: $0.fromDay, toDayExclusive: $0.toDayExclusive) } ?? AuroraPresenceFilters()) else {
                throw AuroraJourneyError.unreadableReport
            }
            try page.coverage.validate()
            for row in page.rows { try row.validate(window: window) }
            return page
        } catch { throw AuroraJourneyError.unreadableReport }
    }
}
