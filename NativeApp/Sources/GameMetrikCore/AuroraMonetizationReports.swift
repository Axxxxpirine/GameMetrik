import Foundation

/// Measured monetization of Aurora Grove, read from `gamemetrik_aurora_monetization_report_v1`.
/// A report separate from the journey v1 contract, read with the same administrative identity, windows and `as_of`.
/// Only validated aggregates: no installation, display or account identifier ever enters memory or the export.
public enum AuroraMonetizationReportKind: String, Codable, CaseIterable, Sendable {
    case ads, adLoads = "ad_loads", premium, experiment
    public var title: String {
        switch self {
        case .ads: "Publicité"
        case .adLoads: "Chargements"
        case .premium: "Paisible"
        case .experiment: "Test Chemins"
        }
    }
}

public enum AuroraAdFormat: String, Codable, CaseIterable, Sendable {
    case interstitial, rewarded
    public var title: String { self == .interstitial ? "Interstitielle" : "Vidéo récompensée" }
}
public enum AuroraAdPlacement: String, Codable, CaseIterable, Sendable {
    case next, replay, home, hint
    public var title: String {
        switch self {
        case .next: "Partie suivante"
        case .replay: "Rejouer"
        case .home: "Retour à l’accueil"
        case .hint: "Indice"
        }
    }
}
public enum AuroraAdGameMode: String, Codable, CaseIterable, Sendable {
    case campaign, quick, daily, lightpaths, none
    public var title: String { self == .none ? "Hors partie" : AuroraJourneyMode(rawValue: rawValue)!.title }
}
public enum AuroraAdVariant: String, Codable, CaseIterable, Sendable {
    case none, lpControl = "lp_control", lpTreatment = "lp_treatment"
    public var title: String {
        switch self {
        case .none: "Hors test"
        case .lpControl: "Groupe témoin"
        case .lpTreatment: "Groupe test"
        }
    }
}
public enum AuroraRevenuePrecision: String, Codable, CaseIterable, Sendable {
    case unknown, estimated, publisherProvided = "publisher_provided", precise
    public var title: String {
        switch self {
        case .unknown: "précision inconnue"
        case .estimated: "estimée"
        case .publisherProvided: "fournie par l’éditeur"
        case .precise: "précise"
        }
    }
}
public enum AuroraPremiumPlacement: String, Codable, CaseIterable, Sendable {
    case home, settings, hint, dailyLimit = "daily_limit", afterInterstitial = "after_interstitial", restore
    public var title: String {
        switch self {
        case .home: "Accueil"
        case .settings: "Réglages"
        case .hint: "Indice"
        case .dailyLimit: "Limite quotidienne"
        case .afterInterstitial: "Après une interstitielle"
        case .restore: "Restauration"
        }
    }
}

public typealias AuroraMonetizationFilters = AuroraJourneyStepsFilters

public struct AuroraMonetizationCoverage: Codable, Equatable, Sendable {
    public var collectionFirstReceivedAt: String?
    public var archivedDaysInWindow: Int
    public var graceDays: Int
    public var collection: String
    public var collectionRule: String
    public var consentSignals: String
    public var revenueScope: String
    public var revenueSource: String
    public var authoritativeRevenue: String
    public var currenciesConverted: Bool
    public var attribution: String
    public var experimentRowsFromRawEvents: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case collectionFirstReceivedAt = "collection_first_received_at"
        case archivedDaysInWindow = "archived_days_in_window"
        case graceDays = "grace_days"
        case collection
        case collectionRule = "collection_rule"
        case consentSignals = "consent_signals"
        case revenueScope = "revenue_scope"
        case revenueSource = "revenue_source"
        case authoritativeRevenue = "authoritative_revenue"
        case currenciesConverted = "currencies_converted"
        case attribution
        case experimentRowsFromRawEvents = "experiment_rows_from_raw_events"
    }
    public init(collectionFirstReceivedAt: String?, archivedDaysInWindow: Int = 0, collectionRule: String) {
        self.collectionFirstReceivedAt = collectionFirstReceivedAt; self.archivedDaysInWindow = archivedDaysInWindow
        graceDays = 3; collection = "usage_data_setting"; self.collectionRule = collectionRule; consentSignals = "not_fed"
        revenueScope = "consenting_installations_only"; revenueSource = "admob_on_paid"; authoritativeRevenue = "admob_reports"
        currenciesConverted = false; attribution = "not_collected"; experimentRowsFromRawEvents = true
    }
    /// Every fixed value of the contract is checked: a change of meaning on the server rejects the report.
    func validate(filters: AuroraJourneyFilters) throws {
        let span = AuroraJourneyContract.calendar.dateComponents([.day], from: AuroraJourneyContract.day(filters.fromDay)!, to: AuroraJourneyContract.day(filters.toDayExclusive)!).day!
        guard collectionFirstReceivedAt.map({ Dates.parse($0) != nil }) ?? true, (0...span).contains(archivedDaysInWindow),
              graceDays == 3, collection == "usage_data_setting", !collectionRule.isEmpty, collectionRule.count <= 1_000,
              consentSignals == "not_fed", revenueScope == "consenting_installations_only", revenueSource == "admob_on_paid",
              authoritativeRevenue == "admob_reports", !currenciesConverted, attribution == "not_collected",
              experimentRowsFromRawEvents else { throw AuroraJourneyError.unreadableReport }
    }
    /// `collection_first_received_at` is global: windows keep the earliest. Archived days of disjoint windows add up.
    mutating func append(_ other: Self) throws {
        var a = self, b = other
        a.collectionFirstReceivedAt = nil; b.collectionFirstReceivedAt = nil; a.archivedDaysInWindow = 0; b.archivedDaysInWindow = 0
        guard a == b else { throw AuroraJourneyError.unreadableReport }
        if let next = other.collectionFirstReceivedAt,
           collectionFirstReceivedAt == nil || Dates.parse(next)! < Dates.parse(collectionFirstReceivedAt!)! { collectionFirstReceivedAt = next }
        archivedDaysInWindow = try AuroraJourneyContract.add(archivedDaysInWindow, other.archivedDaysInWindow)
    }
}

/// Google's OnAdPaid values of one currency and precision. Never converted, never added to another currency.
public struct AuroraAdRevenue: Codable, Equatable, Sendable {
    public var currency: String
    public var precision: AuroraRevenuePrecision
    public var valueMicros: Int
    public var paidEvents: Int
    enum CodingKeys: String, CodingKey, CaseIterable { case currency, precision, valueMicros = "value_micros", paidEvents = "paid_events" }
    public init(currency: String, precision: AuroraRevenuePrecision, valueMicros: Int, paidEvents: Int) {
        self.currency = currency; self.precision = precision; self.valueMicros = valueMicros; self.paidEvents = paidEvents
    }
    public var amount: String { AuroraMonetizationContract.amount(valueMicros, currency: currency) }
}
public struct AuroraExperimentRevenue: Codable, Equatable, Sendable {
    public var currency: String
    public var valueMicros: Int
    public var paidEvents: Int
    enum CodingKeys: String, CodingKey, CaseIterable { case currency, valueMicros = "value_micros", paidEvents = "paid_events" }
    public init(currency: String, valueMicros: Int, paidEvents: Int) { self.currency = currency; self.valueMicros = valueMicros; self.paidEvents = paidEvents }
    public var amount: String { AuroraMonetizationContract.amount(valueMicros, currency: currency) }
}
/// A sum within one currency (and optionally one precision). There is no total across currencies.
public struct AuroraRevenueTotal: Equatable, Sendable {
    public var currency: String
    public var precision: AuroraRevenuePrecision?
    public var valueMicros: Int
    public var paidEvents: Int
    public var amount: String { AuroraMonetizationContract.amount(valueMicros, currency: currency) }
    /// One total per currency, or per currency × precision when `byPrecision` is true, sorted by currency.
    public static func totals(_ items: [(currency: String, precision: AuroraRevenuePrecision?, valueMicros: Int, paidEvents: Int)], byPrecision: Bool) -> [Self] {
        var result: [String: Self] = [:]
        for item in items {
            let precision = byPrecision ? item.precision : nil
            let key = item.currency + "|" + (precision?.rawValue ?? "")
            var total = result[key] ?? .init(currency: item.currency, precision: precision, valueMicros: 0, paidEvents: 0)
            let (micros, o1) = total.valueMicros.addingReportingOverflow(item.valueMicros)
            let (events, o2) = total.paidEvents.addingReportingOverflow(item.paidEvents)
            guard !o1, !o2 else { continue }
            total.valueMicros = micros; total.paidEvents = events; result[key] = total
        }
        return result.values.sorted { ($0.currency, $0.precision?.rawValue ?? "") < ($1.currency, $1.precision?.rawValue ?? "") }
    }
    public static func totals(_ revenue: [AuroraAdRevenue], byPrecision: Bool) -> [Self] {
        totals(revenue.map { ($0.currency, $0.precision, $0.valueMicros, $0.paidEvents) }, byPrecision: byPrecision)
    }
    public static func totals(_ revenue: [AuroraExperimentRevenue]) -> [Self] {
        totals(revenue.map { ($0.currency, nil, $0.valueMicros, $0.paidEvents) }, byPrecision: false)
    }
}

public struct AuroraAdRow: Codable, Equatable, Sendable {
    public var day: String
    public var appVersion: String
    public var platform: AuroraJourneyPlatform
    public var format: AuroraAdFormat
    public var placement: AuroraAdPlacement
    public var gameMode: AuroraAdGameMode
    public var variant: AuroraAdVariant
    public var installations: Int
    public var opportunities: Int
    public var decisions: [String: Int]
    public var showRequested: Int
    public var opened: Int
    public var impressions: Int
    public var closed: Int
    public var displayFailed: Int
    public var rewardsGranted: Int
    public var rewardsNotGranted: Int
    public var paidEvents: Int
    public var revenue: [AuroraAdRevenue]
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", platform, format, placement, gameMode = "game_mode", variant, installations, opportunities, decisions
        case showRequested = "show_requested", opened, impressions, closed, displayFailed = "display_failed"
        case rewardsGranted = "rewards_granted", rewardsNotGranted = "rewards_not_granted", paidEvents = "paid_events", revenue
    }
    public init(day: String, appVersion: String, platform: AuroraJourneyPlatform, format: AuroraAdFormat, placement: AuroraAdPlacement,
                gameMode: AuroraAdGameMode, variant: AuroraAdVariant = .none, installations: Int, opportunities: Int, decisions: [String: Int],
                showRequested: Int, opened: Int, impressions: Int, closed: Int, displayFailed: Int,
                rewardsGranted: Int = 0, rewardsNotGranted: Int = 0, paidEvents: Int, revenue: [AuroraAdRevenue]) {
        self.day = day; self.appVersion = appVersion; self.platform = platform; self.format = format; self.placement = placement
        self.gameMode = gameMode; self.variant = variant; self.installations = installations; self.opportunities = opportunities
        self.decisions = decisions; self.showRequested = showRequested; self.opened = opened; self.impressions = impressions
        self.closed = closed; self.displayFailed = displayFailed; self.rewardsGranted = rewardsGranted
        self.rewardsNotGranted = rewardsNotGranted; self.paidEvents = paidEvents; self.revenue = revenue
    }
    /// Additive event counts, in display and export order. Installations are distinct per row and never summed.
    public static var counts: [(key: String, title: String, path: KeyPath<Self, Int>)] { [
        ("opportunities", "Occasions", \.opportunities),
        ("show_requested", "Demandes d’affichage", \.showRequested),
        ("opened", "Ouvertures", \.opened),
        ("impressions", "Impressions", \.impressions),
        ("closed", "Fermetures", \.closed),
        ("display_failed", "Échecs d’affichage", \.displayFailed),
        ("rewards_granted", "Récompenses accordées", \.rewardsGranted),
        ("rewards_not_granted", "Récompenses non accordées", \.rewardsNotGranted),
        ("paid_events", "Revenus reçus (événements)", \.paidEvents)
    ] }
}
public extension AuroraAdRow {
    /// Server code kept visible beside its label.
    static func decisionTitle(_ code: String) -> String { AuroraMonetizationContract.decisions.first { $0.key == code }?.title ?? code }
    /// Decisions summed over rows, in the closed contract order.
    static func decisionTotals(_ rows: [Self]) -> [(code: String, count: Int)] {
        AuroraMonetizationContract.decisions.map(\.key).compactMap { code in
            let values = rows.compactMap { $0.decisions[code] }
            return values.isEmpty ? nil : (code, values.reduce(0, +))
        }
    }
}
public extension AuroraPremiumRow {
    static var stepOrder: [String] { AuroraMonetizationContract.premiumSteps.map(\.key) }
    static func stepTitle(_ code: String) -> String { AuroraMonetizationContract.premiumSteps.first { $0.key == code }?.title ?? code }
}
extension AuroraAdRow: AuroraJourneyRow {
    public var stableKey: String { [day, appVersion, platform.rawValue, format.rawValue, placement.rawValue, gameMode.rawValue, variant.rawValue].joined(separator: "|") }
    func validate(filters: AuroraJourneyFilters) throws {
        try validateVersion(filters)
        try AuroraJourneyContract.validateDay(day, filters)
        let values = Self.counts.map { self[keyPath: $0.path] }
        guard AuroraJourneyContract.count(installations), values.allSatisfy(AuroraJourneyContract.count),
              (format == .rewarded) == (placement == .hint),
              format == .rewarded || (rewardsGranted == 0 && rewardsNotGranted == 0),
              installations <= values.reduce(0, +),
              Set(decisions.keys).isSubset(of: AuroraMonetizationContract.decisionCodes),
              decisions.values.allSatisfy(AuroraJourneyContract.count),
              decisions.values.reduce(0, +) == opportunities else { throw AuroraJourneyError.unreadableReport }
        try AuroraMonetizationContract.validate(revenue.map { ($0.currency, $0.precision.rawValue, $0.valueMicros, $0.paidEvents) }, paidEvents: paidEvents)
    }
}

public struct AuroraAdLoadRow: Codable, Equatable, Sendable {
    public var day: String
    public var appVersion: String
    public var platform: AuroraJourneyPlatform
    public var format: AuroraAdFormat
    public var installations: Int
    public var requested: Int
    public var loaded: Int
    public var failed: Int
    public var errors: [String: Int]
    enum CodingKeys: String, CodingKey, CaseIterable { case day, appVersion = "app_version", platform, format, installations, requested, loaded, failed, errors }
    public init(day: String, appVersion: String, platform: AuroraJourneyPlatform, format: AuroraAdFormat, installations: Int,
                requested: Int, loaded: Int, failed: Int, errors: [String: Int]) {
        self.day = day; self.appVersion = appVersion; self.platform = platform; self.format = format; self.installations = installations
        self.requested = requested; self.loaded = loaded; self.failed = failed; self.errors = errors
    }
    /// Google error codes sorted numerically ("-1" before "3").
    public var sortedErrorCodes: [String] { errors.keys.sorted { (Int($0) ?? 0, $0) < (Int($1) ?? 0, $1) } }
}
extension AuroraAdLoadRow: AuroraJourneyRow {
    public var stableKey: String { [day, appVersion, platform.rawValue, format.rawValue].joined(separator: "|") }
    func validate(filters: AuroraJourneyFilters) throws {
        try validateVersion(filters)
        try AuroraJourneyContract.validateDay(day, filters)
        guard [installations, requested, loaded, failed].allSatisfy(AuroraJourneyContract.count),
              installations <= requested + loaded + failed,
              errors.keys.allSatisfy(AuroraMonetizationContract.errorCode), errors.values.allSatisfy(AuroraJourneyContract.count),
              errors.values.reduce(0, +) == failed else { throw AuroraJourneyError.unreadableReport }
    }
}

public struct AuroraPremiumRow: Codable, Equatable, Sendable {
    public var day: String
    public var appVersion: String
    public var platform: AuroraJourneyPlatform
    public var placement: AuroraPremiumPlacement
    public var installations: Int
    public var steps: [String: Int]
    public var installationsByStep: [String: Int]
    enum CodingKeys: String, CodingKey, CaseIterable {
        case day, appVersion = "app_version", platform, placement, installations, steps, installationsByStep = "installations_by_step"
    }
    public init(day: String, appVersion: String, platform: AuroraJourneyPlatform, placement: AuroraPremiumPlacement, installations: Int,
                steps: [String: Int], installationsByStep: [String: Int]) {
        self.day = day; self.appVersion = appVersion; self.platform = platform; self.placement = placement
        self.installations = installations; self.steps = steps; self.installationsByStep = installationsByStep
    }
    /// Steps present in the row, in the order of the Peaceful Grove offer.
    public var orderedSteps: [String] { AuroraMonetizationContract.premiumSteps.map(\.key).filter { steps[$0] != nil } }
}
extension AuroraPremiumRow: AuroraJourneyRow {
    public var stableKey: String { [day, appVersion, platform.rawValue, placement.rawValue].joined(separator: "|") }
    func validate(filters: AuroraJourneyFilters) throws {
        try validateVersion(filters)
        try AuroraJourneyContract.validateDay(day, filters)
        let known = Set(AuroraMonetizationContract.premiumSteps.map(\.key))
        guard AuroraJourneyContract.count(installations), Set(steps.keys).isSubset(of: known), Set(steps.keys) == Set(installationsByStep.keys),
              steps.values.allSatisfy(AuroraJourneyContract.count), installationsByStep.values.allSatisfy(AuroraJourneyContract.count),
              steps.allSatisfy({ installationsByStep[$0.key]! <= $0.value }),
              installationsByStep.values.allSatisfy({ $0 <= installations }),
              installations <= installationsByStep.values.reduce(0, +) else { throw AuroraJourneyError.unreadableReport }
    }
}

public struct AuroraExperimentRow: Codable, Equatable, Sendable {
    public var cohortDay: String
    public var experiment: String
    public var variant: AuroraAdVariant
    public var appVersion: String
    public var cohortSize: Int
    public var window: String
    public var mature: Bool
    public var returnD1: AuroraJourneyRatio
    public var returnD7: AuroraJourneyRatio
    public var lightpathsSolved: Int?
    public var interstitialImpressions: Int?
    public var lightpathsInterstitials: Int?
    public var rewardedImpressions: Int?
    public var revenue: [AuroraExperimentRevenue]?
    enum CodingKeys: String, CodingKey, CaseIterable {
        case cohortDay = "cohort_day", experiment, variant, appVersion = "app_version", cohortSize = "cohort_size", window, mature
        case returnD1 = "return_d1", returnD7 = "return_d7", lightpathsSolved = "lightpaths_solved"
        case interstitialImpressions = "interstitial_impressions", lightpathsInterstitials = "lightpaths_interstitials"
        case rewardedImpressions = "rewarded_impressions", revenue
    }
    public init(cohortDay: String, variant: AuroraAdVariant, appVersion: String, cohortSize: Int, mature: Bool,
                returnD1: AuroraJourneyRatio, returnD7: AuroraJourneyRatio, lightpathsSolved: Int?, interstitialImpressions: Int?,
                lightpathsInterstitials: Int?, rewardedImpressions: Int?, revenue: [AuroraExperimentRevenue]?) {
        self.cohortDay = cohortDay; experiment = AuroraMonetizationContract.experiment; self.variant = variant; self.appVersion = appVersion
        self.cohortSize = cohortSize; window = "J0-J6"; self.mature = mature; self.returnD1 = returnD1; self.returnD7 = returnD7
        self.lightpathsSolved = lightpathsSolved; self.interstitialImpressions = interstitialImpressions
        self.lightpathsInterstitials = lightpathsInterstitials; self.rewardedImpressions = rewardedImpressions; self.revenue = revenue
    }
    /// J0–J6 sums, published together once the cohort is mature; nil (never 0) before.
    public static var sums: [(key: String, title: String, path: KeyPath<Self, Int?>)] { [
        ("lightpaths_solved", "Chemins résolus", \.lightpathsSolved),
        ("interstitial_impressions", "Impressions interstitielles", \.interstitialImpressions),
        ("lightpaths_interstitials", "dont dans les Chemins", \.lightpathsInterstitials),
        ("rewarded_impressions", "Impressions de vidéos récompensées", \.rewardedImpressions)
    ] }
}
extension AuroraExperimentRow: AuroraJourneyRow {
    public var stableKey: String { [cohortDay, experiment, variant.rawValue, appVersion].joined(separator: "|") }
    func validate(filters: AuroraJourneyFilters) throws {
        try validateVersion(filters)
        try AuroraJourneyContract.validateDay(cohortDay, filters)
        guard experiment == AuroraMonetizationContract.experiment, variant != .none, window == "J0-J6",
              AuroraJourneyContract.count(cohortSize) else { throw AuroraJourneyError.unreadableReport }
        for ratio in [returnD1, returnD7] {
            try ratio.validate()
            guard ratio.reason == .immatureCohort || ratio.denominator == cohortSize else { throw AuroraJourneyError.unreadableReport }
        }
        let sums = Self.sums.map { self[keyPath: $0.path] }
        // J1 matures before J0–J6, which matures before J7: never the reverse within one row.
        guard mature ? sums.allSatisfy({ $0.map(AuroraJourneyContract.count) ?? false }) && revenue != nil : sums.allSatisfy({ $0 == nil }) && revenue == nil,
              !(mature && returnD1.reason == .immatureCohort), !(!mature && returnD7.reason != .immatureCohort),
              (lightpathsInterstitials ?? 0) <= (interstitialImpressions ?? 0) else { throw AuroraJourneyError.unreadableReport }
        if let revenue {
            try AuroraMonetizationContract.validate(revenue.map { ($0.currency, "", $0.valueMicros, $0.paidEvents) }, paidEvents: nil)
        }
    }
}

public struct AuroraMonetizationReport<Row: Codable & Sendable>: Codable, Sendable {
    public var contractVersion: Int
    public var report: AuroraMonetizationReportKind
    public var generatedAt: String
    public var asOf: String
    public var timezone: String
    public var filters: AuroraMonetizationFilters
    public var coverage: AuroraMonetizationCoverage
    public var rows: [Row]
    enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion = "contract_version", report, generatedAt = "generated_at", asOf = "as_of", timezone, filters, coverage, rows
    }
    public init(report: AuroraMonetizationReportKind, generatedAt: String, asOf: String, filters: AuroraMonetizationFilters,
                coverage: AuroraMonetizationCoverage, rows: [Row]) {
        contractVersion = 1; self.report = report; self.generatedAt = generatedAt; self.asOf = asOf; timezone = "Europe/Zurich"
        self.filters = filters; self.coverage = coverage; self.rows = rows
    }
}

public extension AuroraMonetizationReport where Row == AuroraAdRow {
    /// Measured revenue per currency (and precision): never a single total across currencies.
    func revenueTotals(byPrecision: Bool = true) -> [AuroraRevenueTotal] { AuroraRevenueTotal.totals(rows.flatMap(\.revenue), byPrecision: byPrecision) }
    func total(_ path: KeyPath<AuroraAdRow, Int>) -> Int { rows.reduce(0) { $0 + $1[keyPath: path] } }
    var decisionTotals: [(code: String, count: Int)] { AuroraAdRow.decisionTotals(rows) }
}
public extension AuroraMonetizationReport where Row == AuroraExperimentRow {
    /// Only mature cohorts contribute; immature cohorts are excluded, never counted as 0.
    func revenueTotals(variant: AuroraAdVariant) -> [AuroraRevenueTotal] {
        AuroraRevenueTotal.totals(rows.filter { $0.variant == variant && $0.mature }.flatMap { $0.revenue ?? [] })
    }
}

enum AuroraMonetizationContract {
    static let function = "gamemetrik_aurora_monetization_report_v1"
    static let experiment = "lightpaths_ads_v1"
    /// Closed list of `ad_opportunity.decision`, in reading order.
    static let decisions: [(key: String, title: String)] = [
        ("show", "Affichage décidé"),
        ("offered", "Vidéo proposée"),
        ("premium", "Jardin paisible acheté"),
        ("disabled", "Publicité désactivée"),
        ("mode_disabled", "Désactivée pour ce mode"),
        ("placement_disabled", "Désactivée pour cet emplacement"),
        ("discovery", "Période de découverte"),
        ("minimum_victories", "Victoires minimales non atteintes"),
        ("minimum_play", "Temps de jeu minimal non atteint"),
        ("session_cap", "Plafond de la session atteint"),
        ("day_cap", "Plafond du jour atteint"),
        ("rewarded_cooldown", "Délai entre vidéos récompensées"),
        ("frequency", "Fréquence d’affichage"),
        ("time_gap", "Délai depuis la dernière publicité"),
        ("not_in_test", "Hors groupe du test"),
        ("not_ready", "Publicité non chargée"),
        ("busy", "Affichage déjà en cours"),
        ("daily_limit", "Limite quotidienne"),
        ("cancelled", "Annulée")
    ]
    static let decisionCodes = Set(decisions.map(\.key))
    /// Closed list of `premium_step.step`, in the order of the offer.
    static let premiumSteps: [(key: String, title: String)] = [
        ("offer_viewed", "Offre affichée"),
        ("sign_in_requested", "Connexion demandée"),
        ("sign_in_completed", "Connexion réussie"),
        ("sign_in_cancelled", "Connexion annulée"),
        ("sign_in_failed", "Connexion échouée"),
        ("confirm_viewed", "Confirmation affichée"),
        ("purchase_started", "Achat commencé"),
        ("purchase_validated", "Achat validé"),
        ("purchase_failed", "Achat échoué"),
        ("already_owned", "Déjà acheté"),
        ("entitlement_unknown", "Vérification du droit impossible"),
        ("account_changed", "Compte changé pendant la vérification"),
        ("restore_started", "Restauration commencée"),
        ("restore_completed", "Restauration réussie"),
        ("restore_failed", "Restauration échouée")
    ]
    static func whole(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == (value.startIndex..<value.endIndex)
    }
    static func currency(_ value: String) -> Bool { whole(value, #"^[A-Z]{3}$"#) }
    static func errorCode(_ value: String) -> Bool { whole(value, #"^-?\d{1,5}$"#) }
    /// Unique currency × precision, valid codes, non-negative micros; their paid events add up to the row's.
    static func validate(_ items: [(currency: String, precision: String, micros: Int, events: Int)], paidEvents: Int?) throws {
        guard items.allSatisfy({ currency($0.currency) && $0.micros >= 0 && AuroraJourneyContract.count($0.events) }),
              Set(items.map { $0.currency + "|" + $0.precision }).count == items.count else { throw AuroraJourneyError.unreadableReport }
        var events = 0
        for item in items { events = try AuroraJourneyContract.add(events, item.events) }
        if let paidEvents, events != paidEvents { throw AuroraJourneyError.unreadableReport }
    }
    /// value_micros / 1 000 000 in its own currency, without conversion or rounding below the micro.
    static func amount(_ micros: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_CH"); formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 6
        let value = Decimal(micros) / Decimal(1_000_000)
        return (formatter.string(from: value as NSDecimalNumber) ?? value.description) + " " + currency
    }
    static func shape(_ data: Data, kind: AuroraMonetizationReportKind) throws {
        typealias C = AuroraJourneyContract
        let root = try C.object(JSONSerialization.jsonObject(with: data), keys: C.keys(AuroraMonetizationReport<AuroraAdRow>.CodingKeys.allCases))
        _ = try C.object(root["filters"], keys: C.keys(AuroraJourneyStepsFilters.CodingKeys.allCases))
        _ = try C.object(root["coverage"], keys: C.keys(AuroraMonetizationCoverage.CodingKeys.allCases))
        guard let rows = root["rows"] as? [[String: Any]], rows.count <= 100_000 else { throw AuroraJourneyError.unreadableReport }
        for row in rows {
            switch kind {
            case .ads:
                _ = try C.object(row, keys: C.keys(AuroraAdRow.CodingKeys.allCases))
                guard let revenue = row["revenue"] as? [Any] else { throw AuroraJourneyError.unreadableReport }
                for item in revenue { _ = try C.object(item, keys: C.keys(AuroraAdRevenue.CodingKeys.allCases)) }
            case .adLoads: _ = try C.object(row, keys: C.keys(AuroraAdLoadRow.CodingKeys.allCases))
            case .premium: _ = try C.object(row, keys: C.keys(AuroraPremiumRow.CodingKeys.allCases))
            case .experiment:
                _ = try C.object(row, keys: C.keys(AuroraExperimentRow.CodingKeys.allCases))
                for key in ["return_d1", "return_d7"] { _ = try C.object(row[key], keys: ["numerator", "denominator", "value"], optional: ["reason"]) }
                if let revenue = row["revenue"] as? [Any] {
                    for item in revenue { _ = try C.object(item, keys: C.keys(AuroraExperimentRevenue.CodingKeys.allCases)) }
                } else if !(row["revenue"] is NSNull) { throw AuroraJourneyError.unreadableReport }
            }
        }
    }
}

public extension AuroraJourneyReportReader {
    func ads(filters: AuroraJourneyFilters, asOf: String? = nil) async throws -> AuroraMonetizationReport<AuroraAdRow> { try await monetization(.ads, filters: filters, asOf: asOf) }
    func adLoads(filters: AuroraJourneyFilters, asOf: String? = nil) async throws -> AuroraMonetizationReport<AuroraAdLoadRow> { try await monetization(.adLoads, filters: filters, asOf: asOf) }
    func premium(filters: AuroraJourneyFilters, asOf: String? = nil) async throws -> AuroraMonetizationReport<AuroraPremiumRow> { try await monetization(.premium, filters: filters, asOf: asOf) }
    func experiment(filters: AuroraJourneyFilters, asOf: String? = nil) async throws -> AuroraMonetizationReport<AuroraExperimentRow> { try await monetization(.experiment, filters: filters, asOf: asOf) }
}

extension AuroraJourneyReportReader {
    /// Same administrative identity and 366-day windows as the journey; rows of disjoint windows are concatenated
    /// under one `as_of`. Any window outside the contract rejects the whole report.
    func monetization<Row: AuroraJourneyRow>(_ kind: AuroraMonetizationReportKind, filters: AuroraJourneyFilters, asOf: String?) async throws -> AuroraMonetizationReport<Row> {
        try personal.validate()
        guard filters.population == .all, asOf.map({ Dates.parse($0) != nil }) ?? true else { throw AuroraJourneyError.invalidRequest }
        let windows = try filters.windows()
        var result: AuroraMonetizationReport<Row>?
        var boundary = asOf
        for window in windows {
            try Task.checkCancellation()
            var payload: [String: Any] = ["contract_version": 1, "report": kind.rawValue, "from_day": window.fromDay, "to_day_exclusive": window.toDayExclusive]
            if let version = filters.appVersion { payload["app_version"] = version }
            if let boundary { payload["as_of"] = boundary }
            let data = try await rpc(AuroraMonetizationContract.function, payload: payload)
            do {
                try AuroraMonetizationContract.shape(data, kind: kind)
                let page = try JSONDecoder().decode(AuroraMonetizationReport<Row>.self, from: data)
                guard page.contractVersion == 1, page.report == kind, page.filters == .init(window), page.timezone == "Europe/Zurich",
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
        result.filters = .init(filters)
        return result
    }
}

// MARK: Bundle

public struct AuroraMonetizationFailure: Sendable, Equatable {
    public enum Cause: String, Sendable { case missingFunction = "missing_function", denied, server, network, unreadable }
    public var cause: Cause
    public var detail: String
    /// `not_connected` for an absent function; every other failure leaves the report partial.
    public var status: AuroraJourneyAvailability { cause == .missingFunction ? .notConnected : .partial }
    public var failure: AuroraJourneyFailure { .init(status: status, detail: detail) }
}
public enum AuroraMonetizationState: Equatable, Sendable {
    /// Not read yet, read failure, no event ever received (no build sends them or collection is off),
    /// collection started but no row in the period, or rows (whose zeros are real zeros).
    case notLoaded, failed(AuroraMonetizationFailure.Cause), noMeasurement, noData, data
}

/// The four monetization reports of one synchronization. Their failure never changes the journey reports.
public struct AuroraMonetizationBundle: Sendable {
    public var ads: AuroraMonetizationReport<AuroraAdRow>?
    public var adLoads: AuroraMonetizationReport<AuroraAdLoadRow>?
    public var premium: AuroraMonetizationReport<AuroraPremiumRow>?
    public var experiment: AuroraMonetizationReport<AuroraExperimentRow>?
    public var errors: [AuroraMonetizationReportKind: AuroraMonetizationFailure] = [:]
    public init() {}
    private func context(_ kind: AuroraMonetizationReportKind) -> (coverage: AuroraMonetizationCoverage, rows: Int, asOf: String, generatedAt: String, filters: AuroraMonetizationFilters)? {
        switch kind {
        case .ads: ads.map { ($0.coverage, $0.rows.count, $0.asOf, $0.generatedAt, $0.filters) }
        case .adLoads: adLoads.map { ($0.coverage, $0.rows.count, $0.asOf, $0.generatedAt, $0.filters) }
        case .premium: premium.map { ($0.coverage, $0.rows.count, $0.asOf, $0.generatedAt, $0.filters) }
        case .experiment: experiment.map { ($0.coverage, $0.rows.count, $0.asOf, $0.generatedAt, $0.filters) }
        }
    }
    public func coverage(for kind: AuroraMonetizationReportKind) -> AuroraMonetizationCoverage? { context(kind)?.coverage }
    public func generatedAt(for kind: AuroraMonetizationReportKind) -> String? { context(kind)?.generatedAt }
    public func filters(for kind: AuroraMonetizationReportKind) -> AuroraMonetizationFilters? { context(kind)?.filters }
    public func rowCount(for kind: AuroraMonetizationReportKind) -> Int? { context(kind)?.rows }
    public var loadedKinds: [AuroraMonetizationReportKind] { AuroraMonetizationReportKind.allCases.filter { context($0) != nil } }
    public var asOf: String? { AuroraMonetizationReportKind.allCases.lazy.compactMap { context($0)?.asOf }.first }
    public var generations: [String] { AuroraMonetizationReportKind.allCases.compactMap { context($0)?.generatedAt } }
    public func availability(for kind: AuroraMonetizationReportKind) -> AuroraJourneyAvailability {
        errors[kind]?.status ?? (context(kind) == nil ? .notLoaded : .loaded)
    }
    public func state(for kind: AuroraMonetizationReportKind) -> AuroraMonetizationState {
        if let failure = errors[kind] { return .failed(failure.cause) }
        guard let context = context(kind) else { return .notLoaded }
        if context.rows > 0 { return .data }
        return context.coverage.collectionFirstReceivedAt == nil && context.coverage.archivedDaysInWindow == 0 ? .noMeasurement : .noData
    }
    /// Unlike the journey v1 reports, a refusal is not an identity failure: what was read with the same key stays.
    mutating func record(_ error: Error, for kind: AuroraMonetizationReportKind) throws {
        if error is CancellationError { throw CancellationError() }
        let name = "« " + kind.title + " »"
        let others = " Les autres rapports du parcours ne sont pas concernés."
        switch error as? GameMetrikError {
        case .http(404)?:
            errors[kind] = .init(cause: .missingFunction, detail: "Mesure de la monétisation non raccordée : la fonction \(AuroraMonetizationContract.function) est absente (404), la migration n’est pas appliquée sur ce projet." + others)
        case .http(let status)? where status == 401 || status == 403:
            errors[kind] = .init(cause: .denied, detail: "Lecture du rapport \(name) refusée (\(status)) : il exige les droits service_role." + others)
        case .http(let status)?:
            errors[kind] = .init(cause: .server, detail: "Rapport \(name) indisponible (réponse \(status) du serveur)." + others)
        default:
            errors[kind] = error is AuroraJourneyError
                ? .init(cause: .unreadable, detail: "Rapport \(name) illisible : la réponse ne respecte pas le contrat monetization v1. Aucune ligne n’est conservée." + others)
                : .init(cause: .network, detail: "Rapport \(name) indisponible. Vérifie le réseau et réessaie la synchronisation." + others)
        }
    }
    mutating func read(_ kind: AuroraMonetizationReportKind, reader: AuroraJourneyReportReader, filters: AuroraJourneyFilters, asOf: String?) async throws {
        switch kind {
        case .ads: ads = try await reader.ads(filters: filters, asOf: asOf)
        case .adLoads: adLoads = try await reader.adLoads(filters: filters, asOf: asOf)
        case .premium: premium = try await reader.premium(filters: filters, asOf: asOf)
        case .experiment: experiment = try await reader.experiment(filters: filters, asOf: asOf)
        }
    }
    /// Same message for every report when the administrative connection is missing.
    public static func notConnected(_ detail: String) -> Self {
        var result = Self()
        for kind in AuroraMonetizationReportKind.allCases { result.errors[kind] = .init(cause: .missingFunction, detail: detail) }
        return result
    }
}

public enum AuroraConsentSignals {
    /// The consent card disappeared after 1.5.1: its anonymous counters are no longer fed by later versions.
    /// Numeric comparison ("1.10.0" is after "1.5.1"); a version without numeric part is assumed to feed them.
    public static func fed(appVersion: String) -> Bool {
        var parts: [Int] = []
        for component in appVersion.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = component.prefix { $0.isASCII && $0.isNumber }
            guard let value = Int(digits) else { break }
            parts.append(value)
            if digits.count != component.count { break }
        }
        guard !parts.isEmpty else { return true }
        let reference = [1, 5, 1]
        for index in 0..<max(parts.count, reference.count) {
            let a = index < parts.count ? parts[index] : 0, b = index < reference.count ? reference[index] : 0
            if a != b { return a < b }
        }
        return true
    }
}
