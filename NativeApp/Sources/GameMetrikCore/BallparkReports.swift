import Foundation

public enum BallparkReportKind: String, Codable, CaseIterable, Sendable {
    case overview, questions, series, habits, quality

    var dayBasis: BallparkDayBasis {
        switch self {
        case .overview, .habits, .quality: .civil
        case .questions, .series: .game09
        }
    }
}

public enum BallparkReportMode: String, Codable, CaseIterable, Sendable {
    case all, daily, group, party
}

/// Server enums that only qualify a value. A label added by a later server
/// release is kept as `unrecognized` instead of rejecting the whole report.
private protocol BallparkOpenEnum: RawRepresentable<String>, Decodable {
    static var unrecognized: Self { get }
}

extension BallparkOpenEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }
}

/// Descriptive text the server may leave null (a missing translation or a
/// unitless answer). It is shown empty rather than discarding its row.
@propertyWrapper
public struct BallparkText: Codable, Equatable, Sendable {
    public var wrappedValue: String
    public init(wrappedValue: String) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? "" : try container.decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: BallparkText.Type, forKey key: Key) throws -> BallparkText {
        try decodeIfPresent(type, forKey: key) ?? BallparkText(wrappedValue: "")
    }
}

public enum BallparkReportLocale: String, Codable, CaseIterable, Sendable {
    case all, fr, en
}

public enum BallparkDayBasis: String, Codable, Sendable {
    case civil
    case game09 = "game_09"
}

public enum BallparkUnavailableReason: String, Codable, Sendable, BallparkOpenEnum {
    case notInstrumented = "not_instrumented"
    case insufficientSample = "insufficient_sample"
    case immatureCohort = "immature_cohort"
    case partialCoverage = "partial_coverage"
    case numericOverflow = "numeric_overflow"
    case noObservations = "no_observations"
    case unrecognized
}

public enum BallparkCoverageWarning: String, Codable, Sendable, BallparkOpenEnum {
    case optionalCollectionBias = "optional_collection_bias"
    case v1PartialCoverage = "v1_partial_coverage"
    case partialDurationCoverage = "partial_duration_coverage"
    case limitedSample = "limited_sample"
    case immatureCohort = "immature_cohort"
    case suspectClientTime = "suspect_client_time"
    case unrecognized
}

public struct BallparkReportFilters: Codable, Equatable, Sendable {
    public var fromDay: String
    public var toDayExclusive: String
    public var mode: BallparkReportMode
    public var locale: BallparkReportLocale
    public var appVersion: String?
    public var includeTestAccounts: Bool

    enum CodingKeys: String, CodingKey {
        case fromDay = "from_day", toDayExclusive = "to_day_exclusive", mode, locale
        case appVersion = "app_version", includeTestAccounts = "include_test_accounts"
    }

    public init(
        fromDay: String,
        toDayExclusive: String,
        mode: BallparkReportMode = .all,
        locale: BallparkReportLocale = .all,
        appVersion: String? = nil,
        includeTestAccounts: Bool = false
    ) {
        self.fromDay = fromDay
        self.toDayExclusive = toDayExclusive
        self.mode = mode
        self.locale = locale
        self.appVersion = appVersion
        self.includeTestAccounts = includeTestAccounts
    }

    public func validate() throws {
        guard let start = BallparkContract.day(fromDay),
              let end = BallparkContract.day(toDayExclusive),
              let span = Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day,
              (1...366).contains(span) else {
            throw BallparkReportError.invalidRequest("La période Ballpark doit contenir de 1 à 366 jours civils valides.")
        }
        if let appVersion {
            guard appVersion.utf8.count <= 32,
                  appVersion.range(of: #"^[A-Za-z0-9_.+\-]+$"#, options: .regularExpression) != nil else {
                throw BallparkReportError.invalidRequest("Le filtre de version Ballpark est invalide.")
            }
        }
    }
}

public struct BallparkNullableCount: Codable, Equatable, Sendable {
    public var value: Int?
    public var reason: BallparkUnavailableReason?

    public init(value: Int?, reason: BallparkUnavailableReason?) {
        self.value = value
        self.reason = reason
    }

    func validate(_ name: String) throws {
        guard value.map({ $0 >= 0 }) ?? true, (value == nil) != (reason == nil) else {
            throw BallparkReportError.invalidResponse("Mesure Ballpark incohérente : \(name).")
        }
    }

}

/// A server-calculated fraction or ratio. `value` is deliberately retained verbatim:
/// the client never derives it from a page or combines ratios from separate pages.
public struct BallparkRatio: Codable, Equatable, Sendable {
    public var numerator: Int
    public var denominator: Int
    public var value: Double?
    public var reason: BallparkUnavailableReason?

    public init(numerator: Int, denominator: Int, value: Double?, reason: BallparkUnavailableReason?) {
        self.numerator = numerator
        self.denominator = denominator
        self.value = value
        self.reason = reason
    }

    func validate(_ name: String) throws {
        guard numerator >= 0, denominator >= 0,
              value.map({ $0.isFinite && $0 >= 0 }) ?? true,
              (value == nil) != (reason == nil) else {
            throw BallparkReportError.invalidResponse("Taux Ballpark incohérent : \(name).")
        }
    }

    func validateFraction(_ name: String) throws {
        try validate(name)
        guard numerator <= denominator, value.map({ $0 <= 1 }) ?? true else {
            throw BallparkReportError.invalidResponse("Fraction Ballpark incohérente : \(name).")
        }
    }
}

public struct BallparkCoverage: Codable, Equatable, Sendable {
    public var v2AvailableFrom: String?
    public var excludedTestAccounts: Int
    public var participantsEligible: Int
    public var participantsMeasured: Int
    public var eventsRejectedKnown: BallparkNullableCount
    public var eventsLostKnown: BallparkNullableCount
    public var completeDuration: BallparkRatio
    public var v1Events: Int
    public var v2Events: Int
    public var observedThrough: String?
    public var warnings: [BallparkCoverageWarning]

    enum CodingKeys: String, CodingKey {
        case v2AvailableFrom = "v2_available_from", excludedTestAccounts = "excluded_test_accounts"
        case participantsEligible = "participants_eligible", participantsMeasured = "participants_measured"
        case eventsRejectedKnown = "events_rejected_known", eventsLostKnown = "events_lost_known"
        case completeDuration = "complete_duration", v1Events = "v1_events", v2Events = "v2_events"
        case observedThrough = "observed_through", warnings
    }

    public init(
        v2AvailableFrom: String?, excludedTestAccounts: Int, participantsEligible: Int,
        participantsMeasured: Int, eventsRejectedKnown: BallparkNullableCount,
        eventsLostKnown: BallparkNullableCount, completeDuration: BallparkRatio,
        v1Events: Int, v2Events: Int, observedThrough: String?, warnings: [BallparkCoverageWarning]
    ) {
        self.v2AvailableFrom = v2AvailableFrom
        self.excludedTestAccounts = excludedTestAccounts
        self.participantsEligible = participantsEligible
        self.participantsMeasured = participantsMeasured
        self.eventsRejectedKnown = eventsRejectedKnown
        self.eventsLostKnown = eventsLostKnown
        self.completeDuration = completeDuration
        self.v1Events = v1Events
        self.v2Events = v2Events
        self.observedThrough = observedThrough
        self.warnings = warnings
    }

    func validate() throws {
        guard excludedTestAccounts >= 0, participantsEligible >= 0, participantsMeasured >= 0,
              participantsMeasured <= participantsEligible, v1Events >= 0, v2Events >= 0,
              v2AvailableFrom.map(BallparkContract.instant) ?? true,
              observedThrough.map(BallparkContract.instant) ?? true,
              Set(warnings.filter { $0 != .unrecognized }.map(\.rawValue)).count
                == warnings.filter({ $0 != .unrecognized }).count else {
            throw BallparkReportError.invalidResponse("Couverture Ballpark incohérente.")
        }
        try eventsRejectedKnown.validate("événements rejetés")
        try eventsLostKnown.validate("événements perdus")
        try completeDuration.validateFraction("durées complètes")
    }
}

public struct BallparkReport<Row: Codable & Sendable>: Codable, Sendable {
    public var contractVersion: Int
    public var report: BallparkReportKind
    public var generatedAt: String
    public var asOf: String
    public var timezone: String
    public var dayBasis: BallparkDayBasis
    public var filters: BallparkReportFilters
    public var coverage: BallparkCoverage
    public var rows: [Row]
    public var pageCount: Int
    /// Rows the server returned that were unreadable or inconsistent. They are
    /// left out of the view and the export, and reported instead of hidden.
    public var discardedRows: Int

    public init(
        contractVersion: Int, report: BallparkReportKind, generatedAt: String, asOf: String,
        timezone: String, dayBasis: BallparkDayBasis, filters: BallparkReportFilters,
        coverage: BallparkCoverage, rows: [Row], pageCount: Int, discardedRows: Int = 0
    ) {
        self.contractVersion = contractVersion
        self.report = report
        self.generatedAt = generatedAt
        self.asOf = asOf
        self.timezone = timezone
        self.dayBasis = dayBasis
        self.filters = filters
        self.coverage = coverage
        self.rows = rows
        self.pageCount = pageCount
        self.discardedRows = discardedRows
    }
}

public enum BallparkReportError: Error, LocalizedError, Equatable {
    case invalidRequest(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .invalidResponse(let message): message
        }
    }
}

private protocol BallparkReportRow: Codable, Sendable {
    var stableKey: String { get }
    func validate() throws
}

public struct BallparkOverviewRow: Codable, Equatable, Sendable {
    public var day: String
    public var openedAccounts: Int
    public var playedAccounts: Int
    public var completedAccounts: Int
    public var sessionsObserved: Int
    public var firstActivitiesObserved: Int
    public var participationsAssigned: Int
    public var participationsStarted: Int
    public var participationsCompleted: Int
    public var participationsExpiredIncomplete: Int
    public var participationsOpenIncomplete: Int

    enum CodingKeys: String, CodingKey {
        case day, openedAccounts = "opened_accounts", playedAccounts = "played_accounts"
        case completedAccounts = "completed_accounts", sessionsObserved = "sessions_observed"
        case firstActivitiesObserved = "first_activities_observed", participationsAssigned = "participations_assigned"
        case participationsStarted = "participations_started", participationsCompleted = "participations_completed"
        case participationsExpiredIncomplete = "participations_expired_incomplete"
        case participationsOpenIncomplete = "participations_open_incomplete"
    }
}

extension BallparkOverviewRow: BallparkReportRow {
    fileprivate var stableKey: String { day }
    fileprivate func validate() throws {
        let counts = [openedAccounts, playedAccounts, completedAccounts, sessionsObserved,
                      firstActivitiesObserved, participationsAssigned, participationsStarted,
                      participationsCompleted, participationsExpiredIncomplete, participationsOpenIncomplete]
        guard BallparkContract.day(day) != nil, counts.allSatisfy({ $0 >= 0 }) else {
            throw BallparkReportError.invalidResponse("Ligne de vue d’ensemble Ballpark incohérente.")
        }
    }
}

public enum BallparkQuestionLocale: String, Codable, Sendable { case fr, en }
public enum BallparkQuestionSampleStatus: String, Codable, Sendable {
    case insufficientSample = "insufficient_sample"
    case limitedSample = "limited_sample"
    case available
}

public struct BallparkFactorBins: Codable, Equatable, Sendable {
    public var oneTo15: Int?
    public var over15To2: Int?
    public var over2To5: Int?
    public var over5To10: Int?
    public var over10: Int?

    enum CodingKeys: String, CodingKey {
        case oneTo15 = "one_to_1_5"
        case over15To2 = "over_1_5_to_2"
        case over2To5 = "over_2_to_5"
        case over5To10 = "over_5_to_10"
        case over10 = "over_10"
    }

    func validate() throws {
        let values = [oneTo15, over15To2, over2To5, over5To10, over10]
        guard values.allSatisfy({ $0.map { $0 >= 0 } ?? true }),
              values.allSatisfy({ $0 == nil }) || values.allSatisfy({ $0 != nil }) else {
            throw BallparkReportError.invalidResponse("Distribution de facteur Ballpark incohérente.")
        }
    }

    var isAvailable: Bool { oneTo15 != nil }
}

public struct BallparkQuestionRow: Codable, Equatable, Sendable {
    public var questionID: String
    public var revision: Int
    public var locale: BallparkQuestionLocale
    public var metadataFingerprint: String
    @BallparkText public var prompt: String
    @BallparkText public var unit: String
    public var reference: String
    @BallparkText public var theme: String
    public var subject: String?
    public var dimension: String?
    public var editorialDifficulty: String?
    public var seenParticipations: Int
    public var answers: Int
    public var players: Int
    public var completeTimeSample: Int
    public var sampleStatus: BallparkQuestionSampleStatus
    public var factorQ25: Double?
    public var factorMedian: Double?
    public var factorQ75: Double?
    public var factorReason: BallparkUnavailableReason?
    public var logErrorQ25: Double?
    public var logErrorMedian: Double?
    public var logErrorQ75: Double?
    public var factorLe15: BallparkRatio
    public var factorLe2: BallparkRatio
    public var factorLe5: BallparkRatio
    public var factorLe10: BallparkRatio
    public var exact: BallparkRatio
    public var under: BallparkRatio
    public var over: BallparkRatio
    public var factorBins: BallparkFactorBins
    public var activeTimeMedianMs: Double?
    public var activeTimeP75Ms: Double?
    public var activeTimeP90Ms: Double?
    public var calculatorOpened: BallparkRatio
    public var calculatorResultUsed: BallparkRatio
    public var explanationOpened: BallparkRatio
    public var sourceOpened: BallparkRatio
    public var interruptions: Int
    public var resumes: Int

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id", revision, locale, metadataFingerprint = "metadata_fingerprint"
        case prompt, unit, reference, theme, subject, dimension, editorialDifficulty = "editorial_difficulty"
        case seenParticipations = "seen_participations", answers, players, completeTimeSample = "complete_time_sample"
        case sampleStatus = "sample_status", factorQ25 = "factor_q25", factorMedian = "factor_median", factorQ75 = "factor_q75"
        case factorReason = "factor_reason", logErrorQ25 = "log_error_q25", logErrorMedian = "log_error_median", logErrorQ75 = "log_error_q75"
        case factorLe15 = "factor_le_1_5", factorLe2 = "factor_le_2", factorLe5 = "factor_le_5", factorLe10 = "factor_le_10"
        case exact, under, over, factorBins = "factor_bins", activeTimeMedianMs = "active_time_median_ms"
        case activeTimeP75Ms = "active_time_p75_ms", activeTimeP90Ms = "active_time_p90_ms"
        case calculatorOpened = "calculator_opened", calculatorResultUsed = "calculator_result_used"
        case explanationOpened = "explanation_opened", sourceOpened = "source_opened", interruptions, resumes
    }
}

extension BallparkQuestionRow: BallparkReportRow {
    fileprivate var stableKey: String {
        questionID + "\u{1f}" + String(format: "%020d", revision) + "\u{1f}" + locale.rawValue + "\u{1f}" + metadataFingerprint
    }
    fileprivate func validate() throws {
        let counts = [revision, seenParticipations, answers, players, completeTimeSample, interruptions, resumes]
        let factors = [factorQ25, factorMedian, factorQ75].compactMap { $0 }
        let logs = [logErrorQ25, logErrorMedian, logErrorQ75].compactMap { $0 }
        let times = [activeTimeMedianMs, activeTimeP75Ms, activeTimeP90Ms].compactMap { $0 }
        let validFactorReason = factorReason == nil || factorReason == .insufficientSample || factorReason == .numericOverflow
        let expectedStatus: BallparkQuestionSampleStatus = players < 5 ? .insufficientSample : players < 30 ? .limitedSample : .available
        guard !questionID.isEmpty, !metadataFingerprint.isEmpty, !reference.isEmpty,
              counts.allSatisfy({ $0 >= 0 }), factors.allSatisfy({ $0.isFinite && $0 >= 1 }),
              logs.allSatisfy(\.isFinite), times.allSatisfy({ $0.isFinite && $0 >= 0 }), validFactorReason,
              sampleStatus == expectedStatus,
              factorReason == nil ? factors.count == 3 : factors.isEmpty,
              players < 5
                ? factorReason == .insufficientSample && logs.isEmpty && times.isEmpty && !factorBins.isAvailable
                : factorReason != .insufficientSample && logs.count == 3 && factorBins.isAvailable else {
            throw BallparkReportError.invalidResponse("Ligne de question Ballpark incohérente.")
        }
        try factorBins.validate()
        for (name, ratio) in [("facteur ≤ 1,5", factorLe15), ("facteur ≤ 2", factorLe2),
                              ("facteur ≤ 5", factorLe5), ("facteur ≤ 10", factorLe10),
                              ("exact", exact), ("sous-estimation", under), ("surestimation", over)] {
            try ratio.validateFraction(name)
        }
        // Usage rates count participations from separate events (a locale change
        // or an unacknowledged answer can exceed the denominator): kept verbatim.
        for (name, ratio) in [("calculatrice ouverte", calculatorOpened), ("résultat calculatrice", calculatorResultUsed),
                              ("explication", explanationOpened), ("source", sourceOpened)] {
            try ratio.validate(name)
        }
    }
}

public enum BallparkSeriesMode: String, Codable, Sendable, BallparkOpenEnum { case daily, group, party, unrecognized }

public struct BallparkSeriesQuestion: Codable, Equatable, Sendable {
    public var position: Int
    public var questionID: String
    public var revision: Int
    public var metadataFingerprint: String
    @BallparkText public var theme: String
    public var subject: String?
    public var dimension: String?
    public var editorialDifficulty: String?

    enum CodingKeys: String, CodingKey {
        case position, questionID = "question_id", revision, metadataFingerprint = "metadata_fingerprint"
        case theme, subject, dimension, editorialDifficulty = "editorial_difficulty"
    }
}

public struct BallparkSeriesStatusCounts: Codable, Equatable, Sendable {
    public var openIncomplete: Int
    public var expiredIncomplete: Int
    public var completed: Int
    public var cancelled: Int

    enum CodingKeys: String, CodingKey {
        case openIncomplete = "open_incomplete", expiredIncomplete = "expired_incomplete", completed, cancelled
    }
}

public struct BallparkSeriesRow: Codable, Equatable, Sendable {
    public var gameDay: String
    public var seriesID: String
    public var mode: BallparkSeriesMode
    public var closesAt: String
    public var selectorVersion: Int?
    public var questions: [BallparkSeriesQuestion]
    public var assigned: Int
    public var started: Int
    public var atLeastOneAnswer: Int
    public var exactlyOneAnswer: Int
    public var exactlyTwoAnswers: Int
    public var exactlyThreeAnswers: Int
    public var resumed: Int
    public var statusCounts: BallparkSeriesStatusCounts
    public var completion: BallparkRatio

    enum CodingKeys: String, CodingKey {
        case gameDay = "game_day", seriesID = "series_id", mode, closesAt = "closes_at"
        case selectorVersion = "selector_version", questions, assigned, started
        case atLeastOneAnswer = "at_least_one_answer", exactlyOneAnswer = "exactly_one_answer"
        case exactlyTwoAnswers = "exactly_two_answers", exactlyThreeAnswers = "exactly_three_answers"
        case resumed, statusCounts = "status_counts", completion
    }
}

extension BallparkSeriesRow: BallparkReportRow {
    fileprivate var stableKey: String { gameDay + "\u{1f}" + seriesID }
    fileprivate func validate() throws {
        let counts = [assigned, started, atLeastOneAnswer, exactlyOneAnswer, exactlyTwoAnswers,
                      exactlyThreeAnswers, resumed, statusCounts.openIncomplete, statusCounts.expiredIncomplete,
                      statusCounts.completed, statusCounts.cancelled]
        guard BallparkContract.day(gameDay) != nil, !seriesID.isEmpty, BallparkContract.instant(closesAt),
              selectorVersion.map({ $0 >= 0 }) ?? true, counts.allSatisfy({ $0 >= 0 }), !questions.isEmpty,
              Set(questions.map(\.position)) == Set(1...questions.count), questions.allSatisfy({
                  !$0.questionID.isEmpty && $0.revision >= 0 && !$0.metadataFingerprint.isEmpty
              }) else {
            throw BallparkReportError.invalidResponse("Ligne de série Ballpark incohérente.")
        }
        try completion.validateFraction("complétion de série")
    }
}

public struct BallparkHabitDay: Codable, Equatable, Sendable {
    public var day: String
    public var openedAccounts: Int
    public var answeredAccounts: Int
    public var dau: Int
    public var wau: Int
    public var mau: Int
    public var newObservedAccounts: Int
    public var returningAccounts: Int
    public var sessions: Int
    public var completedSeries: Int
    public var dailyParticipations: Int
    public var groupParticipations: Int
    /// Absent on the server before Party analytics, rather than an invented zero.
    public var partyParticipations: Int? = nil
    public var retentionJ1: BallparkRatio
    public var retentionJ7: BallparkRatio
    public var retentionJ30: BallparkRatio

    enum CodingKeys: String, CodingKey {
        case day, openedAccounts = "opened_accounts", answeredAccounts = "answered_accounts", dau, wau, mau
        case newObservedAccounts = "new_observed_accounts", returningAccounts = "returning_accounts", sessions
        case completedSeries = "completed_series", dailyParticipations = "daily_participations"
        case partyParticipations = "party_participations"
        case groupParticipations = "group_participations", retentionJ1 = "retention_j1"
        case retentionJ7 = "retention_j7", retentionJ30 = "retention_j30"
    }
}

public struct BallparkHabitWeek: Codable, Equatable, Sendable {
    public var weekStart: String
    public var activeAccounts: Int
    /// Seven buckets, where index zero represents one played day and index six seven played days.
    public var daysPlayedDistribution: [Int]
    public var seriesPerActiveAccount: BallparkRatio

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start", activeAccounts = "active_accounts"
        case daysPlayedDistribution = "days_played_distribution"
        case seriesPerActiveAccount = "series_per_active_account"
    }
}

public struct BallparkHabitHour: Codable, Equatable, Sendable {
    public var hour: Int
    public var responses: Int
    public var sessions: Int
}

public enum BallparkHabitRow: Codable, Equatable, Sendable {
    case day(BallparkHabitDay)
    case week(BallparkHabitWeek)
    case hour(BallparkHabitHour)

    private enum RowType: String, Codable { case day, week, hour }
    private enum CodingKeys: String, CodingKey { case rowType = "row_type" }

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: CodingKeys.self).decode(RowType.self, forKey: .rowType)
        switch type {
        case .day: self = .day(try BallparkHabitDay(from: decoder))
        case .week: self = .week(try BallparkHabitWeek(from: decoder))
        case .hour: self = .hour(try BallparkHabitHour(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .day(let row):
            try container.encode(RowType.day, forKey: .rowType); try row.encode(to: encoder)
        case .week(let row):
            try container.encode(RowType.week, forKey: .rowType); try row.encode(to: encoder)
        case .hour(let row):
            try container.encode(RowType.hour, forKey: .rowType); try row.encode(to: encoder)
        }
    }
}

extension BallparkHabitRow: BallparkReportRow {
    fileprivate var stableKey: String {
        switch self {
        case .day(let row): "day\u{1f}" + row.day
        case .week(let row): "week\u{1f}" + row.weekStart
        case .hour(let row): "hour\u{1f}" + String(format: "%02d", row.hour)
        }
    }
    fileprivate func validate() throws {
        switch self {
        case .day(let row):
            let counts = [row.openedAccounts, row.answeredAccounts, row.dau, row.wau, row.mau,
                          row.newObservedAccounts, row.returningAccounts, row.sessions, row.completedSeries,
                          row.dailyParticipations, row.groupParticipations] + [row.partyParticipations].compactMap { $0 }
            guard BallparkContract.day(row.day) != nil, counts.allSatisfy({ $0 >= 0 }) else {
                throw BallparkReportError.invalidResponse("Ligne d’habitudes quotidiennes Ballpark incohérente.")
            }
            try row.retentionJ1.validateFraction("rétention J1")
            try row.retentionJ7.validateFraction("rétention J7")
            try row.retentionJ30.validateFraction("rétention J30")
        case .week(let row):
            guard BallparkContract.day(row.weekStart) != nil, row.activeAccounts >= 0,
                  row.daysPlayedDistribution.count == 7,
                  row.daysPlayedDistribution.allSatisfy({ $0 >= 0 }) else {
                throw BallparkReportError.invalidResponse("Ligne d’habitudes hebdomadaires Ballpark incohérente.")
            }
            try row.seriesPerActiveAccount.validate("séries par compte actif")
        case .hour(let row):
            guard (0...23).contains(row.hour), row.responses >= 0, row.sessions >= 0 else {
                throw BallparkReportError.invalidResponse("Ligne d’habitudes horaires Ballpark incohérente.")
            }
        }
    }
}

public struct BallparkQualityRow: Codable, Equatable, Sendable {
    public var appVersion: String
    public var buildNumber: String
    public var osVersion: String
    public var operation: String
    public var operationsObserved: Int
    public var successes: Int
    public var controlledErrors: Int
    public var failure: BallparkRatio
    public var latencySample: Int
    public var latencyMedianMs: Double?
    public var latencyP95Ms: Double?
    public var knownLostEvents: BallparkNullableCount
    public var suspectTimelines: Int
    public var partialDurations: Int
    public var overlappingDurations: Int

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version", buildNumber = "build_number", osVersion = "os_version", operation
        case operationsObserved = "operations_observed", successes, controlledErrors = "controlled_errors", failure
        case latencySample = "latency_sample", latencyMedianMs = "latency_median_ms", latencyP95Ms = "latency_p95_ms"
        case knownLostEvents = "known_lost_events", suspectTimelines = "suspect_timelines"
        case partialDurations = "partial_durations", overlappingDurations = "overlapping_durations"
    }
}

extension BallparkQualityRow: BallparkReportRow {
    fileprivate var stableKey: String {
        appVersion + "\u{1f}" + buildNumber + "\u{1f}" + osVersion + "\u{1f}" + operation
    }
    fileprivate func validate() throws {
        let counts = [operationsObserved, successes, controlledErrors, latencySample,
                      suspectTimelines, partialDurations, overlappingDurations]
        let latencies = [latencyMedianMs, latencyP95Ms].compactMap { $0 }
        guard !appVersion.isEmpty, !buildNumber.isEmpty, !osVersion.isEmpty, !operation.isEmpty,
              counts.allSatisfy({ $0 >= 0 }), latencies.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw BallparkReportError.invalidResponse("Ligne de qualité Ballpark incohérente.")
        }
        try failure.validateFraction("échec d’opération")
        try knownLostEvents.validate("événements perdus connus")
    }
}

private struct BallparkRequest: Encodable, Sendable {
    var contractVersion = 1
    var report: BallparkReportKind
    var fromDay: String
    var toDayExclusive: String
    var mode: BallparkReportMode
    var locale: BallparkReportLocale
    var appVersion: String?
    var includeTestAccounts: Bool
    var limit: Int
    var cursor: String?

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version", report, fromDay = "from_day", toDayExclusive = "to_day_exclusive"
        case mode, locale, appVersion = "app_version", includeTestAccounts = "include_test_accounts", limit, cursor
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contractVersion, forKey: .contractVersion)
        try container.encode(report, forKey: .report)
        try container.encode(fromDay, forKey: .fromDay)
        try container.encode(toDayExclusive, forKey: .toDayExclusive)
        try container.encode(mode, forKey: .mode)
        try container.encode(locale, forKey: .locale)
        if let appVersion { try container.encode(appVersion, forKey: .appVersion) }
        else { try container.encodeNil(forKey: .appVersion) }
        try container.encode(includeTestAccounts, forKey: .includeTestAccounts)
        try container.encode(limit, forKey: .limit)
        if let cursor { try container.encode(cursor, forKey: .cursor) }
        else { try container.encodeNil(forKey: .cursor) }
    }
}

private struct BallparkRPCBody: Encodable, Sendable {
    var pRequest: BallparkRequest

    enum CodingKeys: String, CodingKey { case pRequest = "p_request" }
}

private struct BallparkPage<Row: Codable & Sendable>: Decodable, Sendable {
    var contractVersion: Int
    var report: BallparkReportKind
    var generatedAt: String
    var asOf: String
    var timezone: String
    var dayBasis: BallparkDayBasis
    var filters: BallparkReportFilters
    var coverage: BallparkCoverage
    var rows: [BallparkLossyRow<Row>]
    var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version", report, generatedAt = "generated_at", asOf = "as_of"
        case timezone, dayBasis = "day_basis", filters, coverage, rows, nextCursor = "next_cursor"
    }
}

/// One row decoded on its own, so a malformed row cannot reject its whole page.
private enum BallparkLossyRow<Row: Decodable & Sendable>: Decodable, Sendable {
    case row(Row)
    case unreadable

    init(from decoder: Decoder) throws {
        self = (try? Row(from: decoder)).map(Self.row) ?? .unreadable
    }
}

public struct BallparkReportReader: Sendable {
    private let personal: PersonalSupabase
    public var http: HTTPClient

    public init(personal: PersonalSupabase, http: HTTPClient = .init()) {
        self.personal = personal
        self.http = http
    }

    public func overview(filters: BallparkReportFilters, limit: Int = 200) async throws -> BallparkReport<BallparkOverviewRow> {
        try await read(.overview, filters: filters, limit: limit)
    }

    public func questions(filters: BallparkReportFilters, limit: Int = 200) async throws -> BallparkReport<BallparkQuestionRow> {
        try await read(.questions, filters: filters, limit: limit)
    }

    public func series(filters: BallparkReportFilters, limit: Int = 200) async throws -> BallparkReport<BallparkSeriesRow> {
        try await read(.series, filters: filters, limit: limit)
    }

    public func habits(filters: BallparkReportFilters, limit: Int = 200) async throws -> BallparkReport<BallparkHabitRow> {
        try await read(.habits, filters: filters, limit: limit)
    }

    public func quality(filters: BallparkReportFilters, limit: Int = 200) async throws -> BallparkReport<BallparkQualityRow> {
        try await read(.quality, filters: filters, limit: limit)
    }

    private func read<Row: BallparkReportRow>(
        _ report: BallparkReportKind, filters: BallparkReportFilters, limit: Int
    ) async throws -> BallparkReport<Row> {
        try personal.validate()
        try filters.validate()
        guard (1...200).contains(limit) else {
            throw BallparkReportError.invalidRequest("La taille de page Ballpark doit être comprise entre 1 et 200.")
        }

        var cursor: String?
        var seenCursors = Set<String>()
        var seenRows = Set<String>()
        var allRows: [Row] = []
        var discarded = 0
        var first: BallparkPage<Row>?
        var pageCount = 0

        repeat {
            try Task.checkCancellation()
            let request = BallparkRequest(
                report: report, fromDay: filters.fromDay, toDayExclusive: filters.toDayExclusive,
                mode: filters.mode, locale: filters.locale, appVersion: filters.appVersion,
                includeTestAccounts: filters.includeTestAccounts, limit: limit, cursor: cursor
            )
            let page: BallparkPage<Row> = try await page(request)
            try validate(page, report: report, filters: filters, first: first)
            for entry in page.rows {
                guard case .row(let row) = entry, (try? row.validate()) != nil else {
                    discarded += 1
                    continue
                }
                guard seenRows.insert(row.stableKey).inserted else {
                    throw BallparkReportError.invalidResponse("La pagination Ballpark contient une ligne dupliquée.")
                }
                allRows.append(row)
            }
            guard allRows.count + discarded <= 100_000 else {
                throw BallparkReportError.invalidResponse("Le rapport Ballpark dépasse 100 000 lignes.")
            }
            pageCount += 1
            if first == nil { first = page }
            cursor = page.nextCursor
            if let cursor {
                guard !cursor.isEmpty, cursor.utf8.count <= 8_192,
                      seenCursors.insert(cursor).inserted, !page.rows.isEmpty else {
                    throw BallparkReportError.invalidResponse("Pagination Ballpark incohérente.")
                }
            }
        } while cursor != nil

        guard let first else { throw BallparkReportError.invalidResponse("Réponse Ballpark absente.") }
        return BallparkReport(
            contractVersion: first.contractVersion, report: first.report,
            generatedAt: first.generatedAt, asOf: first.asOf, timezone: first.timezone,
            dayBasis: first.dayBasis, filters: first.filters, coverage: first.coverage,
            rows: allRows, pageCount: pageCount, discardedRows: discarded
        )
    }

    private func page<Row: Codable & Sendable>(_ request: BallparkRequest) async throws -> BallparkPage<Row> {
        var url = personal.url
        url.append(path: "rest/v1/rpc/gamemetrik_ballpark_report_v1")
        var networkRequest = URLRequest(url: url)
        networkRequest.httpMethod = "POST"
        for (name, value) in personal.headers { networkRequest.setValue(value, forHTTPHeaderField: name) }
        networkRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        networkRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        networkRequest.httpBody = try JSONEncoder().encode(BallparkRPCBody(pRequest: request))
        let (data, _) = try await http.send(networkRequest)
        let decoder = JSONDecoder()
        do { return try decoder.decode(BallparkPage<Row>.self, from: data) }
        catch { throw BallparkReportError.invalidResponse("Le service Ballpark a renvoyé un rapport v1 illisible.") }
    }

    private func validate<Row>(
        _ page: BallparkPage<Row>, report: BallparkReportKind,
        filters: BallparkReportFilters, first: BallparkPage<Row>?
    ) throws {
        guard page.contractVersion == 1, page.report == report,
              page.filters == filters, page.timezone == "Europe/Zurich",
              page.dayBasis == report.dayBasis,
              BallparkContract.instant(page.generatedAt), BallparkContract.instant(page.asOf) else {
            throw BallparkReportError.invalidResponse("L’enveloppe du rapport Ballpark ne correspond pas à la requête.")
        }
        try page.coverage.validate()
        if let first {
            // `generated_at` may describe the individual page response. `as_of` is the
            // contractually fixed data boundary and must remain identical across cursors.
            guard page.asOf == first.asOf, page.coverage == first.coverage else {
                throw BallparkReportError.invalidResponse("Le contexte du rapport Ballpark a changé pendant la pagination.")
            }
        }
    }
}

private enum BallparkContract {
    static func day(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(timeZone: calendar.timeZone, year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date).year == parts[0],
              calendar.dateComponents([.year, .month, .day], from: date).month == parts[1],
              calendar.dateComponents([.year, .month, .day], from: date).day == parts[2] else { return nil }
        return date
    }

    static func instant(_ value: String) -> Bool { Dates.parse(value) != nil }
}
