import Foundation

public enum AuroraJourneyAvailability: String, Codable, Sendable {
    case loaded, partial, notConnected = "not_connected", notCollected = "not_collected", notLoaded = "not_loaded"
}
public struct AuroraJourneyFailure: Codable, Sendable {
    public var status: AuroraJourneyAvailability
    public var detail: String
    public init(status: AuroraJourneyAvailability, detail: String) { self.status = status; self.detail = detail }
}
/// Only validated aggregates. No raw event, player, installation or credential is retained.
public struct AuroraJourneyBundle: Sendable {
    public var funnel: AuroraJourneyReport<AuroraJourneyFunnelRow>?
    public var retentionOpen: AuroraJourneyReport<AuroraJourneyRetentionRow>?
    public var retentionCompleted: AuroraJourneyReport<AuroraJourneyRetentionRow>?
    public var runs: AuroraJourneyReport<AuroraJourneyRunRow>?
    public var quality: AuroraJourneyReport<AuroraJourneyQualityRow>?
    public var errors: [AuroraJourneyReportKind: AuroraJourneyFailure] = [:]
    /// Anonymous steps come from a separate RPC. Their failure never changes `status` of the five v1 reports.
    public var steps: AuroraJourneyStepsReport?
    public var stepsError: AuroraJourneyFailure?
    /// Measured monetization (separate RPC, read last). Its failures never change `status` nor the steps report.
    public var monetization = AuroraMonetizationBundle()
    public init() {}
    /// Boundary shared by every report of the synchronization: the first report read supplies it.
    public var boundary: String? { asOf ?? steps?.asOf ?? monetization.asOf }
    /// Nothing could be read at all (network, unreadable reports): the caller keeps the previous journey.
    /// An absent v1 function (404) is a readable answer and replaces it.
    public var readNothing: Bool {
        loadedKinds.isEmpty && steps == nil && monetization.loadedKinds.isEmpty && !errors.values.contains { $0.status == .notConnected }
    }
    public var stepsAvailability: AuroraJourneyAvailability { stepsError?.status ?? (steps == nil ? .notLoaded : .loaded) }
    public var loadedKinds: [AuroraJourneyReportKind] {
        AuroraJourneyReportKind.allCases.filter { coverage(for: $0) != nil }
    }
    public var status: AuroraJourneyAvailability {
        if loadedKinds.count == 5 { return .loaded }
        if loadedKinds.isEmpty && errors.count == 5 && errors.values.allSatisfy({ $0.status == .notConnected }) { return .notConnected }
        return .partial
    }
    public var latestGeneration: Date? { ([funnel?.generatedAt, retentionOpen?.generatedAt, retentionCompleted?.generatedAt, runs?.generatedAt, quality?.generatedAt, steps?.generatedAt].compactMap { $0.flatMap(Dates.parse) }
        + monetization.generations.compactMap(Dates.parse)).max() }
    public var filters: AuroraJourneyFilters? { funnel?.filters ?? retentionOpen?.filters ?? retentionCompleted?.filters ?? runs?.filters ?? quality?.filters }
    public var asOf: String? { funnel?.asOf ?? retentionOpen?.asOf ?? retentionCompleted?.asOf ?? runs?.asOf ?? quality?.asOf }
    public var coverage: AuroraJourneyCoverage? { funnel?.coverage ?? retentionOpen?.coverage ?? retentionCompleted?.coverage ?? runs?.coverage ?? quality?.coverage }
    public func coverage(for kind: AuroraJourneyReportKind) -> AuroraJourneyCoverage? {
        switch kind {
        case .funnel: funnel?.coverage
        case .retentionOpen: retentionOpen?.coverage
        case .retentionCompleted: retentionCompleted?.coverage
        case .runs: runs?.coverage
        case .quality: quality?.coverage
        }
    }
    /// Window-wide anonymous consent counters, given the versions read: the consent card disappeared after 1.5.1.
    public enum ConsentSignals: String, Sendable { case fed, mixed, notFed = "not_fed" }
    public var consentSignals: ConsentSignals {
        if let version = filters?.appVersion { return AuroraConsentSignals.fed(appVersion: version) ? .fed : .notFed }
        let versions = Set((funnel?.rows.map(\.appVersion) ?? []) + (retentionOpen?.rows.map(\.appVersion) ?? [])
            + (quality?.rows.map(\.appVersion) ?? []) + (steps?.rows.map(\.appVersion) ?? []) + (monetization.ads?.rows.map(\.appVersion) ?? []))
        return versions.allSatisfy(AuroraConsentSignals.fed) ? .fed : .mixed
    }
    /// Raw journey events are deleted 25 months after their day; only the anonymous archive keeps older days.
    static let rawRetentionMonths = 25
    public func availability(for filters: AuroraJourneyFilters) -> AuroraJourneyAvailability {
        collectionGap(for: filters) ?? status
    }
    /// `.notCollected` when the whole period precedes the collection, `.partial` when it starts before it,
    /// nil when every day of the period could be collected. Independent of the reports that failed.
    public func collectionGap(for filters: AuroraJourneyFilters) -> AuroraJourneyAvailability? {
        guard let coverage else { return nil }
        guard let first = coverage.collectionFirstReceivedAt.flatMap(Dates.parse) else {
            // An archive can outlive every raw event used by collection_first_received_at.
            return coverage.archivedDaysInWindow > 0 ? nil : .notCollected
        }
        let firstDay = Dates.day(first, timezone: AuroraJourneyContract.zone)
        // Archived days come from collected events, so they never precede the first one until the purge has deleted
        // it. Only then can the archive explain days before collection_first_received_at.
        if coverage.archivedDaysInWindow > 0, purgeReached(firstDay) { return nil }
        if filters.toDayExclusive <= firstDay { return .notCollected }
        if filters.fromDay < firstDay { return .partial }
        return nil
    }
    /// A week of slack: the oldest remaining event can be a few days younger than the purge boundary.
    private func purgeReached(_ firstDay: String) -> Bool {
        guard let reference = asOf.flatMap(Dates.parse) ?? latestGeneration,
              let boundary = AuroraJourneyContract.calendar.date(byAdding: .month, value: -Self.rawRetentionMonths, to: reference),
              let slack = AuroraJourneyContract.calendar.date(byAdding: .day, value: 7, to: boundary) else { return false }
        return Dates.day(slack, timezone: AuroraJourneyContract.zone) >= firstDay
    }
    mutating func record(_ error: Error, for kind: AuroraJourneyReportKind) throws {
        if error is CancellationError { throw CancellationError() }
        if let service = error as? GameMetrikError, service == .http(401) || service == .http(403) { throw service }
        let missing = (error as? GameMetrikError) == .http(404)
        errors[kind] = .init(status: missing ? .notConnected : .partial,
                            detail: missing ? "Parcours non connecté : la fonction Aurora Grove n’est pas disponible (404)."
                            : error is AuroraJourneyError ? error.localizedDescription : "Rapport indisponible. Vérifie le réseau et réessaie la synchronisation.")
    }
    /// Unlike the v1 reports, a refusal here is not an identity failure: the five reports already read with the same key.
    mutating func recordSteps(_ error: Error) throws {
        if error is CancellationError { throw CancellationError() }
        let detail: String
        switch error as? GameMetrikError {
        case .http(404)?:
            stepsError = .init(status: .notConnected, detail: "La fonction gamemetrik_aurora_journey_steps_v1 n’est pas encore déployée (404). Les autres rapports du parcours ne sont pas concernés.")
            return
        case .http(let status)? where status == 401 || status == 403:
            detail = "Lecture des étapes anonymes refusée (\(status)). Les autres rapports du parcours ne sont pas concernés."
        case .http(let status)?:
            detail = "Étapes anonymes indisponibles (réponse \(status) du serveur). Les autres rapports du parcours ne sont pas concernés."
        default:
            detail = error is AuroraJourneyError ? "Étapes anonymes illisibles : la réponse ne respecte pas le contrat steps v1."
                : "Étapes anonymes indisponibles. Vérifie le réseau et réessaie la synchronisation."
        }
        stepsError = .init(status: .partial, detail: detail)
    }
}

public extension AuroraJourneyReportReader {
    func bundle(filters: AuroraJourneyFilters) async throws -> AuroraJourneyBundle {
        var result = AuroraJourneyBundle()
        // The first successful response supplies the boundary. No local clock is substituted for it.
        do { result.funnel = try await funnel(filters: filters) } catch { try result.record(error, for: .funnel) }
        do { result.retentionOpen = try await retentionOpen(filters: filters, asOf: result.asOf) } catch { try result.record(error, for: .retentionOpen) }
        do { result.retentionCompleted = try await retentionCompleted(filters: filters, asOf: result.asOf) } catch { try result.record(error, for: .retentionCompleted) }
        do { result.runs = try await runs(filters: filters, asOf: result.asOf) } catch { try result.record(error, for: .runs) }
        do { result.quality = try await quality(filters: filters, asOf: result.asOf) } catch { try result.record(error, for: .quality) }
        // Read last, with the same boundary: its absence (not yet deployed) leaves the five reports untouched.
        do { result.steps = try await steps(filters: filters, asOf: result.asOf) } catch { try result.recordSteps(error) }
        // Monetization after the steps, each report with its own state and the same boundary (or the first it reads).
        for kind in AuroraMonetizationReportKind.allCases {
            do { try await result.monetization.read(kind, reader: self, filters: filters, asOf: result.boundary) }
            catch { try result.monetization.record(error, for: kind) }
        }
        try Task.checkCancellation()
        return result
    }
}
