import Foundation
import Testing
@testable import GameMetrikCore

private actor MonetizationStub {
    static let shared = MonetizationStub()
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    var handler: Handler?
    private(set) var requests: [URLRequest] = []
    func install(_ handler: @escaping Handler) { self.handler = handler; requests = [] }
    func response(_ request: URLRequest) throws -> (Int, Data) {
        requests.append(request)
        return try handler!(request)
    }
}
private final class MonetizationURLProtocol: URLProtocol, @unchecked Sendable {
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBodyStream = nil; captured.httpBody = data
        }
        let incoming = captured
        responseTask = Task { @Sendable in
            do {
                let (status, data) = try await MonetizationStub.shared.response(incoming)
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: incoming.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}

@Suite(.serialized) struct AuroraMonetizationReportsTests {
    var project: PersonalSupabase { .init(ref: "aurora", name: "Aurora Grove", url: URL(string: "https://fixture.supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_synthetic_only_test_credential") }
    var http: HTTPClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MonetizationURLProtocol.self]
        return .init(session: URLSession(configuration: config))
    }
    var reader: AuroraJourneyReportReader { .init(personal: project, http: http) }
    static let boundary = "2026-10-16T09:30:00.123456+00:00"
    static let journeyBoundary = "2026-10-02T13:50:05.567638+00:00"
    func window(_ kind: AuroraMonetizationReportKind) -> AuroraJourneyFilters {
        .init(fromDay: kind == .experiment ? "2026-10-01" : "2026-10-14", toDayExclusive: "2026-10-16")
    }
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    static func fixture(_ kind: AuroraMonetizationReportKind) throws -> Data { try data("aurora-monetization-" + kind.rawValue) }
    static func object(_ data: Data) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    func changed(_ kind: AuroraMonetizationReportKind, _ edit: (inout [String: Any], inout [[String: Any]]) -> Void) throws -> Data {
        var object = try Self.object(Self.fixture(kind))
        var rows = object["rows"] as! [[String: Any]]
        edit(&object, &rows)
        object["rows"] = rows
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func payload(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["p_request"])
        return try #require(object["p_request"] as? [String: Any])
    }
    /// The fixture of `kind`, moved into the requested window and version, with the requested boundary.
    static func page(_ kind: AuroraMonetizationReportKind, for request: URLRequest, edit: ((inout [String: Any]) -> Void)? = nil) throws -> Data {
        let p = try payload(request)
        var object = try Self.object(fixture(kind))
        object["filters"] = ["from_day": p["from_day"]!, "to_day_exclusive": p["to_day_exclusive"]!, "app_version": p["app_version"] ?? NSNull()]
        if let boundary = p["as_of"] { object["as_of"] = boundary; object["generated_at"] = boundary }
        var rows = object["rows"] as! [[String: Any]]
        if kind == .experiment { rows = Array(rows.prefix(2)) }
        for index in rows.indices {
            rows[index][kind == .experiment ? "cohort_day" : "day"] = p["from_day"]
            if let version = p["app_version"] { rows[index]["app_version"] = version }
        }
        object["rows"] = rows
        edit?(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func journeyPage(_ kind: String, for request: URLRequest) throws -> Data {
        let p = try payload(request)
        var object = try Self.object(data("aurora-journey-" + kind))
        object["filters"] = ["from_day": p["from_day"]!, "to_day_exclusive": p["to_day_exclusive"]!, "app_version": "1.5.0", "population": "all"]
        if kind == "quality" { object["rows"] = [] }
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func isMonetization(_ request: URLRequest) -> Bool { request.url!.path.hasSuffix("gamemetrik_aurora_monetization_report_v1") }
    static func isSteps(_ request: URLRequest) -> Bool { request.url!.path.hasSuffix("gamemetrik_aurora_journey_steps_v1") }
    var journeyFilters: AuroraJourneyFilters { .init(fromDay: "2026-09-10", toDayExclusive: "2026-09-11", appVersion: "1.5.0") }

    // MARK: Decoding

    @Test func decodesTheFourReportsWithoutAddingCurrencies() async throws {
        await MonetizationStub.shared.install { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/rest/v1/rpc/gamemetrik_aurora_monetization_report_v1")
            #expect(request.value(forHTTPHeaderField: "apikey") == "sb_secret_synthetic_only_test_credential")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let p = try Self.payload(request)
            #expect(Set(p.keys) == ["contract_version", "report", "from_day", "to_day_exclusive"])
            #expect(p["contract_version"] as? Int == 1)
            return (200, try Self.fixture(AuroraMonetizationReportKind(rawValue: p["report"] as! String)!))
        }
        let ads = try await reader.ads(filters: window(.ads))
        #expect(ads.rows.count == 3); #expect(ads.asOf == Self.boundary)
        #expect(ads.coverage.revenueScope == "consenting_installations_only"); #expect(!ads.coverage.currenciesConverted)
        let interstitial = try #require(ads.rows.first { $0.format == .interstitial && $0.placement == .next })
        #expect(interstitial.decisions.values.reduce(0, +) == interstitial.opportunities)
        #expect(ads.decisionTotals.first?.code == "show"); #expect(ads.decisionTotals.first?.count == 17)
        // Real zeros stay zeros: a present row with 0 impressions, an opening without show request.
        let home = try #require(ads.rows.first { $0.placement == .home })
        #expect(home.impressions == 0); #expect(home.opened == 1); #expect(home.showRequested == 0)
        // Above 2^31 micros, kept exact.
        #expect(interstitial.revenue.contains { $0.currency == "EUR" && $0.valueMicros == 3_000_000_000 })
        // One total per currency: CHF and EUR are never added together.
        let byCurrency = ads.revenueTotals(byPrecision: false)
        #expect(byCurrency.map(\.currency) == ["CHF", "EUR"])
        #expect(byCurrency[0].valueMicros == 71_250); #expect(byCurrency[0].paidEvents == 8)
        #expect(byCurrency[1].valueMicros == 3_000_018_000); #expect(byCurrency[1].paidEvents == 9)
        let byPrecision = ads.revenueTotals()
        #expect(byPrecision.count == 4)
        #expect(byPrecision.contains { $0.currency == "CHF" && $0.precision == .unknown && $0.valueMicros == 0 })
        #expect(byCurrency[0].amount.hasSuffix(" CHF")); #expect(byCurrency[0].amount.contains("07125"))
        #expect(byCurrency[1].amount.hasSuffix(" EUR")); #expect(byCurrency[1].amount.contains("3"))

        let loads = try await reader.adLoads(filters: window(.adLoads))
        #expect(loads.rows.count == 2)
        let failing = try #require(loads.rows.first { $0.failed > 0 })
        #expect(failing.sortedErrorCodes == ["-1", "1"]); #expect(failing.errors["1"] == 2)

        let premium = try await reader.premium(filters: window(.premium))
        let home2 = try #require(premium.rows.first { $0.placement == .home })
        #expect(home2.orderedSteps.first == "offer_viewed"); #expect(home2.orderedSteps.last == "account_changed")
        #expect(home2.installationsByStep["entitlement_unknown"] == 1)
        #expect(AuroraPremiumRow.stepTitle("entitlement_unknown") == "Vérification du droit impossible")

        let experiment = try await reader.experiment(filters: window(.experiment))
        #expect(experiment.rows.count == 3)
        let young = try #require(experiment.rows.first { !$0.mature })
        #expect(young.lightpathsSolved == nil); #expect(young.revenue == nil)
        #expect(young.returnD1.formatted == "En attente de maturité"); #expect(!young.returnD1.formatted.contains("%"))
        // Immature cohorts are excluded from the totals, never counted as 0 %.
        let d1 = AuroraJourneyRatioTotal.sum(experiment.rows.filter { $0.variant == .lpTreatment }.map(\.returnD1))
        #expect(d1.ratio == .init(numerator: 16, denominator: 38, value: 16.0 / 38)); #expect(d1.excludedRows == 1)
        let d7 = AuroraJourneyRatioTotal.sum(experiment.rows.filter { $0.variant == .lpTreatment }.map(\.returnD7))
        #expect(d7.ratio.value == nil); #expect(d7.ratio.reason == .immatureCohort); #expect(!d7.ratio.formatted.contains("0"))
        #expect(experiment.revenueTotals(variant: .lpControl).map(\.currency) == ["CHF", "EUR"])
        #expect(experiment.revenueTotals(variant: .lpTreatment).isEmpty)
    }

    @Test(arguments: [
        "extra_root", "installation_id_row", "display_id_revenue", "currency", "decision_sum", "precision", "day_outside",
        "unknown_decision", "rewarded_placement", "interstitial_reward", "paid_sum", "negative", "duplicate", "duplicate_revenue",
        "coverage_converted", "coverage_extra", "coverage_consent", "filters_version", "report_kind", "timezone", "as_of", "missing"
    ]) func adsRejectWholeMalformedReport(field: String) async throws {
        let data = try changed(.ads) { object, rows in
            switch field {
            case "extra_root": object["installation_id"] = "must-never-enter-the-model"
            case "installation_id_row": rows[0]["installation_id"] = "3f0c1a8e-0000-4000-8000-000000000000"
            case "display_id_revenue":
                var revenue = rows[0]["revenue"] as! [[String: Any]]; revenue[0]["display_id"] = "x"; rows[0]["revenue"] = revenue
            case "currency":
                var revenue = rows[0]["revenue"] as! [[String: Any]]; revenue[0]["currency"] = "chf"; rows[0]["revenue"] = revenue
            case "decision_sum": rows[0]["decisions"] = ["show": 14, "frequency": 12]
            case "precision":
                var revenue = rows[0]["revenue"] as! [[String: Any]]; revenue[0]["precision"] = "approximate"; rows[0]["revenue"] = revenue
            case "day_outside": rows[0]["day"] = "2026-10-16"
            case "unknown_decision": rows[0]["decisions"] = ["show": 14, "frequency": 12, "time_gap": 6, "discovery": 4, "not_ready": 2, "vip": 2]
            case "rewarded_placement": rows[1]["placement"] = "next"
            case "interstitial_reward": rows[0]["rewards_granted"] = 1
            case "paid_sum": rows[0]["paid_events"] = 12
            case "negative": rows[2]["opened"] = -1
            case "duplicate": rows.append(rows[0])
            case "duplicate_revenue":
                var revenue = rows[1]["revenue"] as! [[String: Any]]; revenue[1]["precision"] = "precise"; rows[1]["revenue"] = revenue
            case "coverage_converted":
                var coverage = object["coverage"] as! [String: Any]; coverage["currencies_converted"] = true; object["coverage"] = coverage
            case "coverage_extra":
                var coverage = object["coverage"] as! [String: Any]; coverage["advertising_id"] = "x"; object["coverage"] = coverage
            case "coverage_consent":
                var coverage = object["coverage"] as! [String: Any]; coverage["consent_signals"] = "fed"; object["coverage"] = coverage
            case "filters_version": object["filters"] = ["from_day": "2026-10-14", "to_day_exclusive": "2026-10-16", "app_version": "1.5.2"]
            case "report_kind": object["report"] = "premium"
            case "timezone": object["timezone"] = "UTC"
            case "as_of": object["as_of"] = "hier"
            default: rows[0].removeValue(forKey: "closed")
            }
        }
        await MonetizationStub.shared.install { _ in (200, data) }
        await #expect(throws: AuroraJourneyError.unreadableReport) { try await reader.ads(filters: window(.ads)) }
    }

    @Test(arguments: ["error_sum", "error_code", "installations", "extra"]) func adLoadsRejectWholeMalformedReport(field: String) async throws {
        let data = try changed(.adLoads) { _, rows in
            switch field {
            case "error_sum": rows[0]["errors"] = ["1": 2]
            case "error_code": rows[0]["errors"] = ["no_fill": 2, "-1": 1]
            case "installations": rows[1]["installations"] = 9
            default: rows[0]["request_id"] = "x"
            }
        }
        await MonetizationStub.shared.install { _ in (200, data) }
        await #expect(throws: AuroraJourneyError.unreadableReport) { try await reader.adLoads(filters: window(.adLoads)) }
    }

    @Test(arguments: ["unknown_step", "step_keys", "installations_by_step", "account_id"]) func premiumRejectsWholeMalformedReport(field: String) async throws {
        let data = try changed(.premium) { _, rows in
            switch field {
            case "unknown_step":
                rows[1]["steps"] = ["restore_started": 1, "refund": 1]; rows[1]["installations_by_step"] = ["restore_started": 1, "refund": 1]
            case "step_keys": rows[1]["installations_by_step"] = ["restore_started": 1]
            case "installations_by_step": rows[1]["installations_by_step"] = ["restore_started": 2, "restore_completed": 1]
            default: rows[0]["account_id"] = "x"
            }
        }
        await MonetizationStub.shared.install { _ in (200, data) }
        await #expect(throws: AuroraJourneyError.unreadableReport) { try await reader.premium(filters: window(.premium)) }
    }

    @Test(arguments: ["immature_zero", "immature_revenue", "mature_null", "variant_none", "d7_before_week", "d1_after_week", "experiment",
                      "ratio_denominator", "revenue_precision", "lightpaths_over_total"])
    func experimentRejectsWholeMalformedReport(field: String) async throws {
        let data = try changed(.experiment) { _, rows in
            switch field {
            case "immature_zero": rows[2]["lightpaths_solved"] = 0
            case "immature_revenue": rows[2]["revenue"] = [] as [Any]
            case "mature_null": rows[0]["rewarded_impressions"] = NSNull()
            case "variant_none": rows[0]["variant"] = "none"
            case "d7_before_week": rows[2]["return_d7"] = ["numerator": 0, "denominator": 11, "value": 0]
            case "d1_after_week": rows[0]["return_d1"] = ["numerator": NSNull(), "denominator": NSNull(), "value": NSNull(), "reason": "immature_cohort"]
            case "experiment": rows[0]["experiment"] = "home_ads_v2"
            case "ratio_denominator": rows[0]["return_d1"] = ["numerator": 18, "denominator": 41, "value": 0.439]
            case "revenue_precision":
                var revenue = rows[0]["revenue"] as! [[String: Any]]; revenue[0]["precision"] = "precise"; rows[0]["revenue"] = revenue
            default: rows[0]["lightpaths_interstitials"] = 31
            }
        }
        await MonetizationStub.shared.install { _ in (200, data) }
        await #expect(throws: AuroraJourneyError.unreadableReport) { try await reader.experiment(filters: window(.experiment)) }
    }

    // MARK: Windows and boundary

    @Test func windowsOver366DaysConcatenateUnderOneAsOf() async throws {
        let filters = AuroraJourneyFilters(fromDay: "2024-02-28", toDayExclusive: "2026-03-02", appVersion: "1.5.2")
        let windows = try filters.windows()
        #expect(windows.count == 3)
        await MonetizationStub.shared.install { request in
            let p = try Self.payload(request)
            #expect(p["app_version"] as? String == "1.5.2")
            #expect(p["as_of"] as? String == (p["from_day"] as? String == filters.fromDay ? nil : Self.boundary))
            return (200, try Self.page(.ads, for: request) { object in
                object["rows"] = [(object["rows"] as! [[String: Any]])[0]]
                var coverage = object["coverage"] as! [String: Any]
                coverage["archived_days_in_window"] = 1
                if p["from_day"] as? String == windows[1].fromDay { coverage["collection_first_received_at"] = "2025-06-01T00:00:00Z" }
                object["coverage"] = coverage
            })
        }
        let report = try await reader.ads(filters: filters)
        #expect(await MonetizationStub.shared.requests.count == 3)
        #expect(report.rows.map(\.day) == windows.map(\.fromDay))
        #expect(report.asOf == Self.boundary)
        #expect(report.coverage.archivedDaysInWindow == 3)
        #expect(report.coverage.collectionFirstReceivedAt == "2025-06-01T00:00:00Z")
        #expect(report.filters == .init(fromDay: "2024-02-28", toDayExclusive: "2026-03-02", appVersion: "1.5.2"))
        // Counts of disjoint windows add up; revenue stays per currency.
        #expect(report.total(\.opportunities) == 120)
        #expect(report.revenueTotals(byPrecision: false).map(\.valueMicros) == [123_750, 9_000_000_000])
    }

    @Test func aWindowWithAnotherBoundaryRejectsTheWholeReport() async throws {
        let filters = AuroraJourneyFilters(fromDay: "2025-01-01", toDayExclusive: "2026-03-02")
        await MonetizationStub.shared.install { request in
            let later = try Self.payload(request)["as_of"] != nil
            return (200, try Self.page(.premium, for: request) { object in if later { object["as_of"] = "2026-10-16T09:31:00Z" } })
        }
        await #expect(throws: AuroraJourneyError.unreadableReport) { try await reader.premium(filters: filters) }
    }

    // MARK: Bundle

    @Test func bundleSharesTheJourneyBoundaryAndLoadsEveryReport() async throws {
        await MonetizationStub.shared.install { request in
            let p = try Self.payload(request)
            if Self.isSteps(request) { return (404, Data()) }
            if Self.isMonetization(request) {
                #expect(p["as_of"] as? String == Self.journeyBoundary)
                return (200, try Self.page(AuroraMonetizationReportKind(rawValue: p["report"] as! String)!, for: request))
            }
            return (200, try Self.journeyPage(p["report"] as! String, for: request))
        }
        let bundle = try await reader.bundle(filters: journeyFilters)
        #expect(bundle.status == .loaded); #expect(bundle.loadedKinds == AuroraJourneyReportKind.allCases)
        #expect(bundle.monetization.loadedKinds == AuroraMonetizationReportKind.allCases)
        #expect(bundle.monetization.errors.isEmpty)
        #expect(bundle.monetization.asOf == bundle.asOf)
        for kind in AuroraMonetizationReportKind.allCases { #expect(bundle.monetization.state(for: kind) == .data) }
        #expect(!bundle.readNothing)
        // Monetization is read after the steps, in contract order.
        let order = await MonetizationStub.shared.requests.compactMap { request -> String? in
            Self.isSteps(request) ? "steps" : Self.isMonetization(request) ? try? Self.payload(request)["report"] as? String : nil
        }
        #expect(order == ["steps", "ads", "ad_loads", "premium", "experiment"])
    }

    @Test(arguments: [404, 401, 403]) func monetizationFailureNeverChangesTheJourney(status: Int) async throws {
        await MonetizationStub.shared.install { request in
            let p = try Self.payload(request)
            if Self.isSteps(request) { return (404, Data()) }
            if Self.isMonetization(request) { return (status, Data()) }
            return (200, try Self.journeyPage(p["report"] as! String, for: request))
        }
        let bundle = try await reader.bundle(filters: journeyFilters)
        // The five v1 reports and the steps keep their own status; nothing already read is purged.
        #expect(bundle.status == .loaded); #expect(bundle.errors.isEmpty)
        #expect(bundle.loadedKinds == AuroraJourneyReportKind.allCases)
        #expect(bundle.stepsError?.status == .notConnected)
        #expect(bundle.monetization.loadedKinds.isEmpty)
        for kind in AuroraMonetizationReportKind.allCases {
            let failure = try #require(bundle.monetization.errors[kind])
            #expect(failure.cause == (status == 404 ? .missingFunction : .denied))
            #expect(bundle.monetization.availability(for: kind) == (status == 404 ? .notConnected : .partial))
            #expect(bundle.monetization.state(for: kind) == .failed(failure.cause))
            #expect(failure.detail.contains(status == 404 ? "migration" : "refusée"))
        }
        var export = DataExport(mode: "Démo", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "1 jour", scope: "Parcours")
        export.addAuroraJourney(bundle); export.addAuroraMonetization(bundle.monetization)
        #expect(!export.tables.contains { $0.id.hasPrefix("monetisation_") })
        #expect(export.checks.filter { $0.section.hasPrefix("Monétisation mesurée · ") }.allSatisfy { $0.status == (status == 404 ? "not_connected" : "partial") })
        #expect(export.checks.filter { $0.section.hasPrefix("Parcours · ") && $0.section != "Parcours · Étapes anonymes" }.allSatisfy { $0.status == "loaded" })
    }

    @Test func oneFailingReportLeavesTheOthersLoaded() async throws {
        await MonetizationStub.shared.install { request in
            let p = try Self.payload(request)
            if Self.isSteps(request) { return (404, Data()) }
            if Self.isMonetization(request) {
                switch p["report"] as! String {
                case "ad_loads": return (500, Data())
                case "premium": return (200, Data("{\"contract_version\":1}".utf8))
                case "experiment": return (200, try Self.page(.experiment, for: request) { $0["rows"] = [] as [Any] })
                default: return (200, try Self.page(.ads, for: request))
                }
            }
            return (200, try Self.journeyPage(p["report"] as! String, for: request))
        }
        let bundle = try await reader.bundle(filters: journeyFilters)
        #expect(bundle.status == .loaded)
        let m = bundle.monetization
        #expect(m.state(for: .ads) == .data)
        #expect(m.state(for: .adLoads) == .failed(.server)); #expect(m.errors[.adLoads]?.detail.contains("500") == true)
        #expect(m.state(for: .premium) == .failed(.unreadable)); #expect(m.errors[.premium]?.detail.contains("illisible") == true)
        #expect(m.state(for: .experiment) == .noData)
        #expect(m.premium == nil)
    }

    @Test func nothingReadKeepsThePreviousJourneyUnlessMonetizationAnswered() async throws {
        await MonetizationStub.shared.install { request in
            if Self.isMonetization(request), try Self.payload(request)["report"] as? String == "ads" { return (200, try Self.page(.ads, for: request)) }
            return (500, Data())
        }
        let partial = try await reader.bundle(filters: journeyFilters)
        #expect(partial.loadedKinds.isEmpty); #expect(partial.steps == nil)
        #expect(partial.monetization.loadedKinds == [.ads]); #expect(!partial.readNothing)
        // Without any boundary from the journey, the first monetization report fixes it.
        #expect(partial.boundary == partial.monetization.ads?.asOf)
        await MonetizationStub.shared.install { _ in (500, Data()) }
        #expect(try await reader.bundle(filters: journeyFilters).readNothing)
    }

    @Test func noMeasurementNoDataAndRealZeroAreDistinct() throws {
        let coverage = AuroraMonetizationCoverage(collectionFirstReceivedAt: nil, collectionRule: "rule")
        let filters = AuroraMonetizationFilters(fromDay: "2026-10-14", toDayExclusive: "2026-10-16")
        var bundle = AuroraMonetizationBundle()
        bundle.ads = .init(report: .ads, generatedAt: Self.boundary, asOf: Self.boundary, filters: filters, coverage: coverage, rows: [])
        #expect(bundle.state(for: .ads) == .noMeasurement)
        var started = coverage; started.collectionFirstReceivedAt = "2026-10-01T08:00:00Z"
        bundle.ads?.coverage = started
        #expect(bundle.state(for: .ads) == .noData)
        bundle.ads?.rows = [.init(day: "2026-10-14", appVersion: "1.5.2", platform: .ios, format: .interstitial, placement: .next, gameMode: .quick,
                                  installations: 1, opportunities: 1, decisions: ["not_ready": 1], showRequested: 0, opened: 0, impressions: 0,
                                  closed: 0, displayFailed: 0, paidEvents: 0, revenue: [])]
        #expect(bundle.state(for: .ads) == .data)
        #expect(bundle.state(for: .premium) == .notLoaded)
        var export = DataExport(mode: "Démo", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "1 jour", scope: "Parcours")
        bundle.adLoads = .init(report: .adLoads, generatedAt: Self.boundary, asOf: Self.boundary, filters: filters, coverage: coverage, rows: [])
        bundle.premium = .init(report: .premium, generatedAt: Self.boundary, asOf: Self.boundary, filters: filters, coverage: started, rows: [])
        export.addAuroraMonetization(bundle)
        #expect(export.checks.first { $0.section == "Monétisation mesurée · Publicité" }?.status == "loaded")
        #expect(export.checks.first { $0.section == "Monétisation mesurée · Chargements" }?.status == "not_collected")
        #expect(export.checks.first { $0.section == "Monétisation mesurée · Paisible" }?.status == "empty")
        #expect(export.checks.first { $0.section == "Monétisation mesurée · Test Chemins" }?.status == "not_loaded")
        let pubs = try #require(export.tables.first { $0.id == "monetisation_pubs" })
        let impressions = try #require(pubs.columns.firstIndex(of: "impressions"))
        #expect(pubs.rows.first?[impressions] == .number(0))
    }

    // MARK: Journey fixes

    @Test func qualityAcceptsTheSevenMonetizationEvents() async throws {
        let names = ["ad_opportunity", "ad_load", "ad_display", "ad_reward", "ad_paid", "premium_step", "experiment_assigned"]
        func quality(extra: [String]) throws -> Data {
            var object = try Self.object(Self.data("aurora-journey-quality"))
            var rows = object["rows"] as! [[String: Any]]
            var byEvent = rows[0]["by_event"] as! [String: Int]
            for name in extra { byEvent[name] = 2 }
            rows[0]["by_event"] = byEvent
            rows[0]["events"] = (rows[0]["events"] as! Int) + 2 * extra.count
            object["rows"] = rows
            return try JSONSerialization.data(withJSONObject: object)
        }
        let accepted = try quality(extra: names)
        await MonetizationStub.shared.install { _ in (200, accepted) }
        let filters = AuroraJourneyFilters(fromDay: "2026-09-10", toDayExclusive: "2026-09-13", appVersion: "1.5.0")
        let report = try await reader.quality(filters: filters)
        for name in names { #expect(report.rows[0].byEvent[name] == 2) }
        let unknown = try quality(extra: ["ad_unknown"])
        await MonetizationStub.shared.install { _ in (200, unknown) }
        await #expect(throws: AuroraJourneyError.unreadableReport) { try await reader.quality(filters: filters) }
    }

    @Test func consentSignalsCompareVersionsNumerically() {
        for version in ["1.5.1", "1.5.0", "1.4.9", "1.5", "0.9.12", "1.5.1-hotfix", "beta"] { #expect(AuroraConsentSignals.fed(appVersion: version), "\(version)") }
        for version in ["1.5.2", "1.5.10", "1.10.0", "1.6", "2", "1.5.1.1"] { #expect(!AuroraConsentSignals.fed(appVersion: version), "\(version)") }
        // A lexical comparison would place 1.10.0 before 1.5.1.
        #expect("1.10.0" < "1.5.1")
    }

    @Test func consentSignalsAfter151AreExportedAsNotFed() throws {
        let now = Dates.parse("2026-10-16T00:00:00Z")!
        var bundle = AuroraJourneyDemo.bundle(filters: .period(.month, now: now), now: now)
        var row = try #require(bundle.funnel?.rows.first)
        row.appVersion = "1.10.0"; row.consentAccepted = 0; row.consentDeclined = 0
        bundle.funnel?.rows.append(row)
        #expect(bundle.consentSignals == .mixed)
        var export = DataExport(mode: "Démo", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "30 jours", scope: "Parcours")
        export.addAuroraJourney(bundle)
        let funnel = try #require(export.tables.first { $0.id == "parcours_entonnoir" })
        let version = try #require(funnel.columns.firstIndex(of: "app_version"))
        let accepted = try #require(funnel.columns.firstIndex(of: "consent_accepted"))
        let declined = try #require(funnel.columns.firstIndex(of: "consent_declined"))
        let signals = try #require(funnel.columns.firstIndex(of: "consent_signals"))
        let newer = try #require(funnel.rows.first { $0[version] == .text("1.10.0") })
        #expect(newer[accepted] == .null); #expect(newer[declined] == .null); #expect(newer[signals] == .text("not_fed"))
        let older = try #require(funnel.rows.first { $0[version] == .text("1.5.0") })
        #expect(older[accepted] == .number(4)); #expect(older[signals] == .text("fed"))
        let coverage = try #require(export.tables.first { $0.id == "parcours_couverture" })
        #expect(coverage.rows.allSatisfy { $0.last == .text("mixed") })
        #expect(export.readme.contains("Aucun taux d’acceptation"))
        // A version filter after 1.5.1 empties the window-wide counters.
        let filtered = AuroraJourneyDemo.bundle(filters: .init(fromDay: "2026-09-16", toDayExclusive: "2026-10-16", appVersion: "1.5.2"), now: now)
        #expect(filtered.consentSignals == .notFed)
        var other = DataExport(mode: "Démo", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "30 jours", scope: "Parcours")
        other.addAuroraJourney(filtered)
        let filteredCoverage = try #require(other.tables.first { $0.id == "parcours_couverture" })
        let anonymousAccepted = try #require(filteredCoverage.columns.firstIndex(of: "anonymous_consent_accepted"))
        #expect(filteredCoverage.rows.allSatisfy { $0[anonymousAccepted] == .null && $0.last == .text("not_fed") })
    }

    // MARK: Export, demo and probe

    @Test func exportsEveryMonetizationTableWithoutIdentifiers() throws {
        let now = Dates.parse("2026-10-16T00:00:00Z")!
        let bundle = AuroraJourneyDemo.bundle(filters: .period(.month, now: now), now: now)
        let m = bundle.monetization
        #expect(m.loadedKinds == AuroraMonetizationReportKind.allCases)
        // Demo: two currencies, an unknown precision, a failed load, a Peaceful journey, a mature and an immature cohort.
        let ads = try #require(m.ads)
        #expect(Set(ads.rows.flatMap(\.revenue).map(\.currency)) == ["CHF", "EUR"])
        #expect(ads.rows.flatMap(\.revenue).contains { $0.precision == .unknown && $0.valueMicros == 0 })
        #expect(m.adLoads?.rows.contains { $0.failed > 0 } == true)
        #expect(m.premium?.rows.contains { $0.steps["purchase_validated"] != nil } == true)
        #expect(m.experiment?.rows.contains { $0.mature } == true); #expect(m.experiment?.rows.contains { !$0.mature } == true)
        var export = DataExport(mode: "Démo", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "30 jours", scope: "Parcours")
        export.addAuroraJourney(bundle); export.addAuroraMonetization(m)
        let ids = ["monetisation_pubs", "monetisation_pubs_motifs", "monetisation_revenus", "monetisation_chargements", "monetisation_chargements_erreurs",
                   "monetisation_paisible", "monetisation_test", "monetisation_test_revenus", "monetisation_couverture"]
        #expect(export.tables.filter { $0.id.hasPrefix("monetisation_") }.map(\.id) == ids)
        let revenue = try #require(export.tables.first { $0.id == "monetisation_revenus" })
        #expect(revenue.columns == ["day", "app_version", "platform", "format", "placement", "game_mode", "variant", "currency", "precision", "value_micros", "paid_events"])
        #expect(revenue.rows.count == ads.rows.reduce(0) { $0 + $1.revenue.count })
        let motifs = try #require(export.tables.first { $0.id == "monetisation_pubs_motifs" })
        #expect(motifs.rows.count == ads.rows.reduce(0) { $0 + $1.decisions.count })
        let test = try #require(export.tables.first { $0.id == "monetisation_test" })
        let solved = try #require(test.columns.firstIndex(of: "lightpaths_solved")), mature = try #require(test.columns.firstIndex(of: "mature"))
        #expect(test.rows.filter { $0[mature] == .boolean(false) }.allSatisfy { $0[solved] == .null })
        let coverage = try #require(export.tables.first { $0.id == "monetisation_couverture" })
        #expect(coverage.rows.count == 4)
        #expect(export.checks.filter { $0.section.hasPrefix("Monétisation mesurée · ") }.map(\.status) == ["loaded", "loaded", "loaded", "loaded"])
        for text in ["distinct du revenu total AdMob", "pas une attribution aux campagnes Meta", "Les annonces de test rapportent 0 avec la précision unknown",
                     "Rupture de couverture", "comparer version par version", "Ne jamais additionner deux devises"] {
            #expect(export.readme.contains(text), "\(text)")
        }
        #expect(export.notes.contains { $0.contains("SELECT public.gamemetrik_aurora_monetization_report_v1") })
        let json = String(decoding: try export.jsonData(), as: UTF8.self)
        for forbidden in ["installation_id", "display_id", "event_id", "session_id", "account_id", "sb_secret_"] { #expect(!json.contains(forbidden), "\(forbidden)") }
        _ = try export.fileWrapper()
    }

    @Test(arguments: [404, 401, 403]) func connectionProbeDistinguishesMissingFromDenied(status: Int) async throws {
        await MonetizationStub.shared.install { _ in (status, Data()) }
        let check = await ConnectionChecks.auroraMonetization(project: project, http: http)
        #expect(!check.success)
        #expect(check.detail.contains(status == 404 ? "not_connected" : "refusé"))
        #expect(check.detail.contains(status == 404 ? "migration non appliquée" : String(status)))
        let request = try #require(await MonetizationStub.shared.requests.first)
        #expect(request.url?.path == "/rest/v1/rpc/gamemetrik_aurora_monetization_report_v1")
        #expect(try Self.payload(request)["report"] as? String == "ads")
    }
}
