import Foundation

/// Same causes and statuses as the measured monetization: 404 = function not deployed (`not_connected`),
/// every other failure leaves this family partial. Never an identity failure: the journey reports are not concerned.
public typealias AuroraInsightsFailure = AuroraMonetizationFailure

public enum AuroraInsightsState: Equatable, Sendable {
    /// Not read yet; not requested (hourly presence over more than 31 days); read failure; nothing collected over the
    /// period (before 1.6.0 or collection off: never zero); collection started but no row; rows (zeros are real zeros).
    case notLoaded, notRequested, failed(AuroraInsightsFailure.Cause), notCollected, noData, data
}

/// Every insights family and the presence of one synchronization, for one population.
/// Only validated aggregates: no installation, session, presence or account identifier.
public struct AuroraInsightsBundle: Sendable {
    public var population: AuroraInsightsPopulation
    /// Requested period (Zurich days, `to_day_exclusive` excluded).
    public var filters: AuroraJourneyFilters
    var reports: [AuroraInsightsKind: any AuroraInsightsAnyReport] = [:]
    public var errors: [AuroraInsightsKind: AuroraInsightsFailure] = [:]
    public var live: AuroraPresenceReport<AuroraPresenceLiveRow>?
    public var history: AuroraPresenceReport<AuroraPresenceDayRow>?
    public var hourly: AuroraPresenceReport<AuroraPresenceHourRow>?
    public var presenceErrors: [AuroraPresenceKind: AuroraInsightsFailure] = [:]
    public init(population: AuroraInsightsPopulation, filters: AuroraJourneyFilters) { self.population = population; self.filters = filters }

    public func report<Row: AuroraInsightsRow>(_ type: Row.Type) -> AuroraInsightsReport<Row>? { reports[Row.kind] as? AuroraInsightsReport<Row> }
    public func anyReport(_ kind: AuroraInsightsKind) -> (any AuroraInsightsAnyReport)? { reports[kind] }
    public mutating func set<Row: AuroraInsightsRow>(_ report: AuroraInsightsReport<Row>) { reports[Row.kind] = report; errors[Row.kind] = nil }

    public var activity: AuroraInsightsReport<AuroraActivityRow>? { report(AuroraActivityRow.self) }
    public var sessions: AuroraInsightsReport<AuroraSessionsRow>? { report(AuroraSessionsRow.self) }
    public var screens: AuroraInsightsReport<AuroraScreenRow>? { report(AuroraScreenRow.self) }
    public var dialogs: AuroraInsightsReport<AuroraDialogRow>? { report(AuroraDialogRow.self) }
    public var actions: AuroraInsightsReport<AuroraActionRow>? { report(AuroraActionRow.self) }
    public var gameplay: AuroraInsightsReport<AuroraGameplayRow>? { report(AuroraGameplayRow.self) }
    public var timeline: AuroraInsightsReport<AuroraTimelineRow>? { report(AuroraTimelineRow.self) }
    public var progress: AuroraInsightsReport<AuroraProgressRow>? { report(AuroraProgressRow.self) }
    public var settings: AuroraInsightsReport<AuroraSettingRow>? { report(AuroraSettingRow.self) }
    public var stability: AuroraInsightsReport<AuroraStabilityRow>? { report(AuroraStabilityRow.self) }
    public var diagnostics: AuroraInsightsReport<AuroraDiagnosticRow>? { report(AuroraDiagnosticRow.self) }
    public var performance: AuroraInsightsReport<AuroraPerformanceRow>? { report(AuroraPerformanceRow.self) }
    public var cloud: AuroraInsightsReport<AuroraCloudRow>? { report(AuroraCloudRow.self) }
    public var privacy: AuroraInsightsReport<AuroraPrivacyRow>? { report(AuroraPrivacyRow.self) }
    public var consents: AuroraInsightsReport<AuroraConsentRow>? { report(AuroraConsentRow.self) }
    public var context: AuroraInsightsReport<AuroraContextRow>? { report(AuroraContextRow.self) }
    public var notifications: AuroraInsightsReport<AuroraNotificationRow>? { report(AuroraNotificationRow.self) }
    public var server: AuroraInsightsReport<AuroraServerRow>? { report(AuroraServerRow.self) }

    public var loadedKinds: [AuroraInsightsKind] { AuroraInsightsKind.allCases.filter { reports[$0] != nil } }
    /// Boundary shared by every insights family: the first one read supplies it (presence has none).
    public var asOf: String? { AuroraInsightsKind.allCases.lazy.compactMap { reports[$0]?.asOf }.first }
    /// Hourly presence is requested only for periods of at most 31 days.
    public var hourlyRequested: Bool { AuroraInsightsContract.span(filters) <= 31 }
    public var generations: [String] {
        AuroraInsightsKind.allCases.compactMap { reports[$0]?.generatedAt } + [live?.generatedAt, history?.generatedAt, hourly?.generatedAt].compactMap { $0 }
    }
    public var latestGeneration: Date? { generations.compactMap(Dates.parse).max() }

    public func availability(for kind: AuroraInsightsKind) -> AuroraJourneyAvailability {
        errors[kind]?.status ?? (reports[kind] == nil ? .notLoaded : .loaded)
    }
    /// `.notCollected` when the whole period precedes the first event of the family, `.partial` when it starts before
    /// it or when archived days are not available for this population (internal builds); nil otherwise.
    public func collectionGap(for kind: AuroraInsightsKind) -> AuroraJourneyAvailability? {
        guard let report = reports[kind], kind != .server else { return nil }
        if archiveUnavailable(for: kind) { return .partial }
        // The archive outlives the raw events behind collection_first_received_at.
        if report.archivedDays > 0 { return nil }
        guard let first = report.firstReceivedAt.flatMap(Dates.parse) else { return .notCollected }
        let firstDay = Dates.day(first, timezone: AuroraJourneyContract.zone)
        if filters.toDayExclusive <= firstDay { return .notCollected }
        if filters.fromDay < firstDay { return .partial }
        return nil
    }
    /// Archived days (older than 60 days) exist only for production and all populations.
    public func archiveUnavailable(for kind: AuroraInsightsKind) -> Bool {
        guard let coverage = reports[kind]?.standardCoverage else { return false }
        return !coverage.archiveAvailableForPopulation && coverage.archivedDaysInWindow > 0
    }
    public func state(for kind: AuroraInsightsKind) -> AuroraInsightsState {
        if let failure = errors[kind] { return .failed(failure.cause) }
        guard let report = reports[kind] else { return .notLoaded }
        if report.rowCount > 0 { return .data }
        if kind == .server { return .noData }
        return collectionGap(for: kind) == .notCollected ? .notCollected : .noData
    }
    public func presenceState(for kind: AuroraPresenceKind) -> AuroraInsightsState {
        if let failure = presenceErrors[kind] { return .failed(failure.cause) }
        if kind == .hourly && !hourlyRequested { return .notRequested }
        let context: (rows: Int, first: String?)?
        switch kind {
        case .live: context = live.map { ($0.rows.count, $0.coverage.firstSignalAt) }
        case .history: context = history.map { ($0.rows.count, $0.coverage.firstSignalAt) }
        case .hourly: context = hourly.map { ($0.rows.count, $0.coverage.firstSignalAt) }
        }
        guard let context else { return .notLoaded }
        if context.rows > 0 { return .data }
        guard let first = context.first.flatMap(Dates.parse) else { return .notCollected }
        if kind != .live, filters.toDayExclusive <= Dates.day(first, timezone: AuroraJourneyContract.zone) { return .notCollected }
        return .noData
    }
    /// loaded: every family and presence read; not_connected: both functions absent (404); partial otherwise.
    public var status: AuroraJourneyAvailability {
        let presenceRead = live != nil && history != nil && (hourly != nil || !hourlyRequested)
        if loadedKinds.count == AuroraInsightsKind.allCases.count && presenceRead { return .loaded }
        let failures = Array(errors.values) + Array(presenceErrors.values)
        if loadedKinds.isEmpty && live == nil && history == nil && hourly == nil && errors.count == AuroraInsightsKind.allCases.count
            && !presenceErrors.isEmpty && failures.allSatisfy({ $0.cause == .missingFunction }) { return .notConnected }
        return .partial
    }
    /// Nothing read and no definite answer (absent function or refusal): the caller keeps the previous bundle.
    public var readNothing: Bool {
        loadedKinds.isEmpty && live == nil && history == nil && hourly == nil
            && !(Array(errors.values) + Array(presenceErrors.values)).contains { $0.cause == .missingFunction || $0.cause == .denied }
    }
    public var firstFailureDetail: String? {
        AuroraInsightsKind.allCases.lazy.compactMap { errors[$0]?.detail }.first
            ?? AuroraPresenceKind.allCases.lazy.compactMap { presenceErrors[$0]?.detail }.first
    }

    static func failure(_ error: Error, function: String, name: String) -> AuroraInsightsFailure {
        let others = " Les rapports du parcours et de la monétisation ne sont pas concernés."
        switch error as? GameMetrikError {
        case .http(404)?:
            return .init(cause: .missingFunction, detail: "Collecte complète non raccordée : la fonction \(function) est absente (404), la migration de Aurora Grove 1.6.0 n’est pas appliquée sur ce projet." + others)
        case .http(let status)? where status == 401 || status == 403:
            return .init(cause: .denied, detail: "Lecture de « \(name) » refusée (\(status)) : ce rapport exige les droits service_role." + others)
        case .http(let status)?:
            return .init(cause: .server, detail: "« \(name) » indisponible (réponse \(status) du serveur)." + others)
        default:
            return error is AuroraJourneyError
                ? .init(cause: .unreadable, detail: "« \(name) » illisible : la réponse ne respecte pas le contrat v1 de la collecte complète. Aucune ligne n’est conservée." + others)
                : .init(cause: .network, detail: "« \(name) » indisponible. Vérifie le réseau et réessaie la synchronisation." + others)
        }
    }
    mutating func record(_ error: Error, for kind: AuroraInsightsKind) throws {
        if error is CancellationError { throw CancellationError() }
        errors[kind] = Self.failure(error, function: AuroraInsightsContract.function, name: kind.title)
    }
    mutating func record(_ error: Error, presence kind: AuroraPresenceKind) throws {
        if error is CancellationError { throw CancellationError() }
        presenceErrors[kind] = Self.failure(error, function: AuroraInsightsContract.presenceFunction, name: kind.title)
    }
    /// Same message for every family when the administrative connection is missing.
    public static func notConnected(_ detail: String, population: AuroraInsightsPopulation, filters: AuroraJourneyFilters) -> Self {
        var result = Self(population: population, filters: filters)
        for kind in AuroraInsightsKind.allCases { result.errors[kind] = .init(cause: .missingFunction, detail: detail) }
        for kind in AuroraPresenceKind.allCases where kind != .hourly || result.hourlyRequested { result.presenceErrors[kind] = .init(cause: .missingFunction, detail: detail) }
        return result
    }
}

public extension AuroraJourneyReportReader {
    /// Every insights family under one `as_of` (the journey's when given, else the first answer's), then presence.
    /// An absent function or a refusal is the same for every family of that function: it is read once.
    func insightsBundle(filters: AuroraJourneyFilters, population: AuroraInsightsPopulation, asOf: String? = nil) async throws -> AuroraInsightsBundle {
        var result = AuroraInsightsBundle(population: population, filters: filters)
        var boundary = asOf
        var definitive: AuroraInsightsFailure?
        for kind in AuroraInsightsKind.allCases {
            try Task.checkCancellation()
            if let definitive { result.errors[kind] = definitive; continue }
            do {
                try await read(kind, into: &result, filters: filters, population: population, asOf: boundary)
                if boundary == nil { boundary = result.asOf }
            } catch {
                try result.record(error, for: kind)
                if let failure = result.errors[kind], failure.cause == .missingFunction || failure.cause == .denied { definitive = failure }
            }
        }
        definitive = nil
        for kind in AuroraPresenceKind.allCases where kind != .hourly || result.hourlyRequested {
            try Task.checkCancellation()
            if let definitive { result.presenceErrors[kind] = definitive; continue }
            do {
                switch kind {
                case .live: result.live = try await presenceLive()
                case .history: result.history = try await presenceHistory(filters: filters)
                case .hourly: result.hourly = try await presenceHourly(filters: filters)
                }
            } catch {
                try result.record(error, presence: kind)
                if let failure = result.presenceErrors[kind], failure.cause == .missingFunction || failure.cause == .denied { definitive = failure }
            }
        }
        try Task.checkCancellation()
        return result
    }
    private func read(_ kind: AuroraInsightsKind, into result: inout AuroraInsightsBundle, filters: AuroraJourneyFilters, population: AuroraInsightsPopulation, asOf: String?) async throws {
        func load<Row: AuroraInsightsRow>(_ type: Row.Type) async throws -> any AuroraInsightsAnyReport {
            try await insights(type, filters: filters, population: population, asOf: asOf)
        }
        let report: any AuroraInsightsAnyReport
        switch kind {
        case .activity: report = try await load(AuroraActivityRow.self)
        case .sessions: report = try await load(AuroraSessionsRow.self)
        case .screens: report = try await load(AuroraScreenRow.self)
        case .dialogs: report = try await load(AuroraDialogRow.self)
        case .actions: report = try await load(AuroraActionRow.self)
        case .gameplay: report = try await load(AuroraGameplayRow.self)
        case .timeline: report = try await load(AuroraTimelineRow.self)
        case .progress: report = try await load(AuroraProgressRow.self)
        case .settings: report = try await load(AuroraSettingRow.self)
        case .stability: report = try await load(AuroraStabilityRow.self)
        case .diagnostics: report = try await load(AuroraDiagnosticRow.self)
        case .performance: report = try await load(AuroraPerformanceRow.self)
        case .cloud: report = try await load(AuroraCloudRow.self)
        case .privacy: report = try await load(AuroraPrivacyRow.self)
        case .consents: report = try await load(AuroraConsentRow.self)
        case .context: report = try await load(AuroraContextRow.self)
        case .notifications: report = try await load(AuroraNotificationRow.self)
        case .server: report = try await load(AuroraServerRow.self)
        }
        result.reports[kind] = report
    }
}

// MARK: Reading helpers

public enum AuroraInsightsMath {
    /// Sum of the values present; nil (unknown or masked, never 0) when no row carries one.
    public static func sum<R>(_ rows: [R], _ path: KeyPath<R, Int?>) -> Int? {
        let values = rows.compactMap { $0[keyPath: path] }
        return values.isEmpty ? nil : values.reduce(0, &+)
    }
    public static func ratio(_ numerator: Int?, _ denominator: Int?) -> Double? {
        guard let numerator, let denominator, denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }
    /// Map values summed per code over the rows that carry the map.
    public static func merge<R>(_ rows: [R], _ path: KeyPath<R, [String: Int]?>) -> [(code: String, count: Int)] {
        var result: [String: Int] = [:]
        for row in rows { for (code, count) in row[keyPath: path] ?? [:] { result[code, default: 0] &+= count } }
        return result.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { ($0.key, $0.value) }
    }
    /// Smallest and largest per-row installations: they are distinct per row and never added up as people.
    public static func installationsRange(_ values: [Int?]) -> String {
        let known = values.compactMap { $0 }
        guard let low = known.min(), let high = known.max() else { return "installations inconnues" }
        return (low == high ? "\(low)" : "\(low) à \(high)") + " installation(s) par ligne"
    }
}

public enum AuroraInsightsFormat {
    public static let masked = "masqué (moins de 5 installations)"
    public static let unknown = "inconnu"
    static let locale = Locale(identifier: "fr_CH")
    public static func count(_ value: Int?) -> String { value.map { $0.formatted(.number.locale(locale)) } ?? unknown }
    public static func decimal(_ value: Double?, digits: Int = 1) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...digits)).locale(locale)) } ?? unknown
    }
    public static func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.percent.precision(.fractionLength(1)).locale(locale)) } ?? unknown
    }
    /// Human-readable duration: « 1 h 05 min », « 3 min 20 s », « 45 s », « 0,4 s ».
    public static func duration(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return unknown }
        if seconds < 10, seconds != seconds.rounded() { return decimal(seconds) + " s" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        if hours > 0 { return "\(hours) h " + String(format: "%02d", minutes) + " min" }
        if minutes > 0 { return "\(minutes) min" + (rest > 0 ? " " + String(format: "%02d", rest) + " s" : "") }
        return "\(rest) s"
    }
    public static func duration(_ seconds: Int?) -> String { duration(seconds: seconds.map(Double.init)) }
    /// Start of a Zurich day "YYYY-MM-DD", for charts.
    public static func date(day: String) -> Date? { AuroraJourneyContract.day(day) }
    public static func today(_ now: Date = Date()) -> String { Dates.day(now, timezone: AuroraJourneyContract.zone) }
    /// Local time of an ISO instant in Zurich, « 20:14 ».
    public static func zurichTime(_ iso: String?) -> String {
        guard let iso, let date = Dates.parse(iso) else { return unknown }
        var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale); style.timeZone = AuroraJourneyContract.zone
        return date.formatted(style)
    }
    public static func milliseconds(_ value: Double?) -> String {
        guard let value else { return unknown }
        return value >= 1_000 ? decimal(value / 1_000, digits: 2) + " s" : decimal(value, digits: 0) + " ms"
    }
    public static func bytes(_ value: Int?) -> String {
        guard let value, value >= 0 else { return unknown }
        let formatter = ByteCountFormatter(); formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(value))
    }
}

/// French labels of the known codes. Codes are free strings: an unknown one stays visible as its raw code.
public enum AuroraInsightsLabels {
    public static func title(_ code: String?, in dimension: String) -> String {
        guard let code else { return "non renseigné" }
        return table[dimension]?[code] ?? code
    }
    public static func dimension(_ code: String) -> String { dimensions[code] ?? code }
    static let dimensions: [String: String] = [
        "distribution": "Distribution", "device_model": "Modèle d’appareil", "os_major": "Système (version majeure)",
        "os_version": "Système (version)", "device_language": "Langue de l’appareil", "game_language": "Langue du jeu",
        "storefront": "Pays App Store", "connection": "Connexion", "memory_class": "Mémoire", "screen": "Écran",
        "signed_in": "Compte connecté", "premium": "Jardin paisible", "ad_config_revision": "Révision des réglages publicitaires"
    ]
    static let modes = ["campaign": "Aventure", "quick": "Partie rapide", "daily": "Défi quotidien", "lightpaths": "Chemins de lumière", "none": "Hors partie"]
    static let table: [String: [String: String]] = [
        "mode": modes, "game_mode": modes,
        "outcome": ["solved": "Résolue", "restart": "Recommencée", "new_puzzle": "Nouvelle grille", "back": "Retour", "parked": "Mise de côté",
                    "success": "Réussie", "failure": "Échec", "no_answer": "Sans réponse", "unauthorized": "Non autorisée", "conflict": "Conflit", "rate_limited": "Limitée"],
        "difficulty": ["gentle": "Douce", "steady": "Régulière", "demanding": "Exigeante", "initiation": "Initiation", "facile": "Facile",
                       "normal": "Normale", "difficile": "Difficile", "expert": "Expert"],
        "timeline": ["f": "Lucioles posées", "x": "Croix posées", "e": "Effacements", "u": "Annulations", "h": "Indices", "r": "Coups refusés", "t": "Rotations (Chemins)"],
        "distribution": ["app_store": "App Store", "testflight": "TestFlight", "development": "Développement", "unknown": "Inconnue"],
        "state": ["app": "Dans l’app", "grid": "Sur une grille", "granted": "Accordé", "denied": "Refusé", "withdrawn": "Retiré"],
        "statistics_basis": ["explicit_granted": "Oui explicite", "explicit_denied": "Non explicite", "regional_default": "Règle régionale par défaut", "no_answer": "Sans réponse"],
        "statistics_source": ["regional_rule": "Règle régionale", "settings": "Réglages", "google_form": "Formulaire Google", "legacy": "Ancien choix"],
        "region_class": ["eea_uk": "EEE et Royaume-Uni", "other": "Hors EEE et Royaume-Uni", "unknown": "Inconnue"],
        "att_status": ["not_determined": "Non demandé", "restricted": "Restreint", "denied": "Refusé", "authorized": "Autorisé", "unavailable": "Indisponible"],
        "purpose": ["statistics": "Statistiques", "ad_measurement": "Mesure publicitaire"],
        "source": ["settings": "Réglages", "google_form": "Formulaire Google", "legacy": "Ancien choix", "anonymous_count": "Décompte anonyme"],
        "kind": ["exception": "Exception", "assert": "Assertion", "error": "Erreur", "grove_reminder": "Rappel du jardin", "streak": "Série"],
        "setting": ["music": "Musique", "ambience": "Ambiance", "effects": "Effets sonores", "rain_ambience": "Ambiance pluie",
                    "fire_ambience": "Ambiance feu", "vibrations": "Vibrations"],
        "memory_class": ["le_3gb": "≤ 3 Go", "le_4gb": "≤ 4 Go", "le_6gb": "≤ 6 Go", "le_8gb": "≤ 8 Go", "gt_8gb": "> 8 Go"],
        "boolean": ["true": "oui", "false": "non"]
    ]
}
