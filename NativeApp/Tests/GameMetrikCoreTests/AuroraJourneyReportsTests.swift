import Foundation
import Testing
@testable import GameMetrikCore

private actor JourneyStub {
    static let shared = JourneyStub()
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    var handler: Handler?
    private(set) var requests: [URLRequest] = []
    func install(_ handler: @escaping Handler) { self.handler = handler; requests = [] }
    func response(_ request: URLRequest) throws -> (Int, Data) {
        requests.append(request)
        return try handler!(request)
    }
}
private final class JourneyURLProtocol: URLProtocol, @unchecked Sendable {
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
                let (status, data) = try await JourneyStub.shared.response(incoming)
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: incoming.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}

@Suite(.serialized) struct AuroraJourneyReportsTests {
    var project: PersonalSupabase { .init(ref: "aurora", name: "Aurora Grove", url: URL(string: "https://fixture.supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_synthetic_only_test_credential") }
    var http: HTTPClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [JourneyURLProtocol.self]
        return .init(session: URLSession(configuration: config))
    }
    var reader: AuroraJourneyReportReader { .init(personal: project, http: http) }
    var filters: AuroraJourneyFilters { .init(fromDay: "2026-09-10", toDayExclusive: "2026-09-11", appVersion: "1.5.0") }
    func fixture(_ kind: AuroraJourneyReportKind) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: "aurora-journey-" + kind.rawValue, withExtension: "json", subdirectory: "Fixtures")))
    }
    func changed(_ kind: AuroraJourneyReportKind = .funnel, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: fixture(kind)) as? [String: Any]); edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func payload(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["p_request"])
        return try #require(object["p_request"] as? [String: Any])
    }

    @Test func sqlOraclesForSeptember10Version150() async throws {
        // Expected values copied from player_journey_test.sql; no production data.
        for kind in AuroraJourneyReportKind.allCases {
            let data = try fixture(kind)
            await JourneyStub.shared.install { _ in (200, data) }
            switch kind {
            case .funnel:
                let row = try #require(try await reader.funnel(filters: filters).rows.first)
                #expect(row.tutorialStarted == .init(numerator: 2, denominator: 3, value: 0.6667))
                #expect(row.tutorialCompleted.value == 0.3333)
                #expect(row.firstRunCompleted.value == 0.3333)
                #expect(row.measuredShare == .init(numerator: 3, denominator: 6, value: 0.5))
                #expect(row.consentAccepted == 4); #expect(row.consentDeclined == 1)
            case .retentionOpen:
                let row = try #require(try await reader.retentionOpen(filters: filters).rows.first)
                #expect(row.returnD1 == .init(numerator: 2, denominator: 3, value: 0.6667))
                #expect(row.returnD7.value == 0.3333); #expect(row.returnD7D13.value == 0.3333)
            case .retentionCompleted:
                let row = try #require(try await reader.retentionCompleted(filters: filters).rows.first)
                #expect(row.cohortSize == 1); #expect(row.returnD1.value == 1); #expect(row.returnD7.value == 0)
            case .runs:
                var window = filters; window.toDayExclusive = "2026-09-20"
                let rows = try await reader.runs(filters: window).rows
                #expect(rows.map(\.games) == [2, 1, 3]); #expect(rows[0].leftAppNotReturned == 1)
                #expect(rows[2].abandonedRestart == 1); #expect(rows[2].appStoppedWhilePlaying == 1)
            case .quality:
                var window = filters; window.toDayExclusive = "2026-09-13"
                let rows = try await reader.quality(filters: window).rows
                #expect(rows[0].lostEventsReported == 3); #expect(rows[0].firstOpenExistingPlayer == 1)
                #expect(rows[2].launchesAfterForegroundStop == 1)
            }
        }
    }

    @Test func anonymousAndFutureRejectionsKeepAllFiveReportsReadable() async throws {
        let counts = ["anonymous_rate_limited": 2, "anonymous_out_of_range": 3, "future_code": 5]
        let boundary = "2026-10-02T13:50:05.567638+00:00"
        let fixtures = try Dictionary(uniqueKeysWithValues: AuroraJourneyReportKind.allCases.map { kind in
            (kind.rawValue, try changed(kind) { object in
                var coverage = object["coverage"] as! [String: Any]
                coverage["rejections_in_window"] = counts
                object["coverage"] = coverage
                var filters = object["filters"] as! [String: Any]
                filters["to_day_exclusive"] = "2026-09-20"
                object["filters"] = filters
            })
        })
        await JourneyStub.shared.install { request in
            // The separate steps RPC is not deployed in these scenarios.
            if request.url!.path.hasSuffix("gamemetrik_aurora_journey_steps_v1") { return (404, Data()) }
            // The separate monetization RPC is not deployed in these scenarios either.
            if request.url!.path.hasSuffix("gamemetrik_aurora_monetization_report_v1") { return (404, Data()) }
            let p = try Self.payload(request), kind = p["report"] as! String
            #expect(p["as_of"] as? String == (kind == "funnel" ? nil : boundary))
            return (200, fixtures[kind]!)
        }
        var window = filters; window.toDayExclusive = "2026-09-20"
        let bundle = try await reader.bundle(filters: window)
        #expect(bundle.status == .loaded)
        #expect(bundle.errors.isEmpty)
        #expect(bundle.loadedKinds == AuroraJourneyReportKind.allCases)
        #expect(bundle.asOf == boundary)
        for kind in AuroraJourneyReportKind.allCases {
            let coverage = try #require(bundle.coverage(for: kind))
            #expect(coverage.rejectionsInWindow == counts)
            #expect(coverage.collectionFirstReceivedAt == "2026-09-10T08:00:00.123456+00:00")
        }
        #expect([bundle.funnel?.generatedAt, bundle.retentionOpen?.generatedAt, bundle.retentionCompleted?.generatedAt,
                 bundle.runs?.generatedAt, bundle.quality?.generatedAt].allSatisfy { $0 == boundary })
        #expect(AuroraJourneyCoverage.rejectionLabel(for: "anonymous_rate_limited") == "Limite d’envoi des premiers lancements anonymes atteinte")
        #expect(AuroraJourneyCoverage.rejectionLabel(for: "anonymous_out_of_range") == "Signal anonyme hors de la période autorisée")
        #expect(AuroraJourneyCoverage.rejectionLabel(for: "future_code") == "future_code")
        #expect(AuroraJourneyCoverage.rejectionLabel(for: "missing_field") == "Champ manquant")
    }

    @Test func rejectionValidationKeepsFormatAndCountGuards() async throws {
        // Valid codes at both length boundaries stay extensible, without accepting malformed counts.
        let valid = ["_": 0, String(repeating: "a", count: 40): 1]
        let data = try changed { object in
            var coverage = object["coverage"] as! [String: Any]
            coverage["rejections_in_window"] = valid; object["coverage"] = coverage
        }
        await JourneyStub.shared.install { _ in (200, data) }
        #expect(try await reader.funnel(filters: filters).coverage.rejectionsInWindow == valid)
        let invalid: [[String: Any]] = [
            ["": 1], ["Future_code": 1], ["future-code": 1], ["future_code1": 1], ["future_code\n": 1],
            ["refus_é": 1], [String(repeating: "a", count: 41): 1],
            ["future_code": -1], ["future_code": 1.5], ["future_code": "2"], ["future_code": 1_000_000_000_001]
        ]
        for rejections in invalid {
            let malformed = try changed { object in
                var coverage = object["coverage"] as! [String: Any]
                coverage["rejections_in_window"] = rejections; object["coverage"] = coverage
            }
            await JourneyStub.shared.install { _ in (200, malformed) }
            await #expect(throws: AuroraJourneyError.unreadableReport) { try await reader.funnel(filters: filters) }
        }
    }

    @Test(arguments: ["filters", "report", "timezone", "contract_version", "generated_at", "as_of", "rows", "extra", "missing", "ratio", "coverage"])
    func rejectsWholeMalformedReport(field: String) async throws {
        let data = try changed { object in
            switch field {
            case "filters": var f = object["filters"] as! [String: Any]; f["population"] = "new_installs"; object["filters"] = f
            case "report": object["report"] = "retention_open"
            case "timezone": object["timezone"] = "UTC"
            case "contract_version": object[field] = 2
            case "generated_at", "as_of": object[field] = "not-a-date"
            case "rows": var rows = object["rows"] as! [[String: Any]]; rows[0]["cohort_day"] = "2026-09-11"; object["rows"] = rows
            case "extra": object["installation_id"] = "must-never-enter-the-model"
            case "missing": var f = object["filters"] as! [String: Any]; f.removeValue(forKey: "app_version"); object["filters"] = f
            case "ratio": var rows = object["rows"] as! [[String: Any]]; rows[0]["tutorial_started"] = ["numerator": 2, "denominator": 3, "value": 0]; object["rows"] = rows
            default: var c = object["coverage"] as! [String: Any]; c["attribution"] = "organic"; object["coverage"] = c
            }
        }
        await JourneyStub.shared.install { _ in (200, data) }
        await #expect(throws: AuroraJourneyError.unreadableReport) { try await reader.funnel(filters: filters) }
    }

    @Test func weightedMatureTotalsExcludeImmatureRowsAndNeverShowUnknownAsZero() async throws {
        let data = try changed(.retentionOpen) { object in
            var rows = object["rows"] as! [[String: Any]]
            rows[0]["return_d7"] = ["numerator": NSNull(), "denominator": NSNull(), "value": NSNull(), "reason": "immature_cohort"]
            object["rows"] = rows
        }
        await JourneyStub.shared.install { _ in (200, data) }
        let immature = try #require(try await reader.retentionOpen(filters: filters).rows.first).returnD7
        #expect(immature.value == nil); #expect(!immature.formatted.contains("0")); #expect(immature.formatted.contains("attente"))
        let total = AuroraJourneyRatioTotal.sum([.init(numerator: 2, denominator: 3, value: 0.6667), .init(numerator: 1, denominator: 10, value: 0.1), immature])
        #expect(total.ratio.numerator == 3); #expect(total.ratio.denominator == 13)
        #expect(total.ratio.value == 3.0 / 13); #expect(total.excludedRows == 1)
        #expect(AuroraJourneyRatioTotal.sum([immature]).ratio.value == nil)
    }

    @Test func sequentialWindowsPinAsOfAndDoNotDoubleCount() async throws {
        let fixture = try fixture(.funnel)
        let filters = AuroraJourneyFilters(fromDay: "2024-02-28", toDayExclusive: "2026-03-02", appVersion: "1.5.0")
        let windows = try filters.windows()
        #expect(windows.count == 3)
        #expect(windows[0].toDayExclusive == windows[1].fromDay)
        #expect(windows[1].toDayExclusive == windows[2].fromDay)
        await JourneyStub.shared.install { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/rest/v1/rpc/gamemetrik_aurora_journey_report_v1")
            #expect(request.value(forHTTPHeaderField: "apikey") == "sb_secret_synthetic_only_test_credential")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let p = try Self.payload(request)
            #expect(p["population"] == nil); #expect(p["cursor"] == nil)
            #expect(p["as_of"] as? String == (p["from_day"] as? String == filters.fromDay ? nil : "2026-10-02T13:50:05.567638+00:00"))
            var object = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
            object["filters"] = ["from_day": p["from_day"]!, "to_day_exclusive": p["to_day_exclusive"]!, "app_version": "1.5.0", "population": "all"]
            var rows = object["rows"] as! [[String: Any]]; rows[0]["cohort_day"] = p["from_day"]; object["rows"] = rows
            return (200, try JSONSerialization.data(withJSONObject: object))
        }
        let report = try await reader.funnel(filters: filters)
        #expect(report.rows.count == 3); #expect(Set(report.rows.map(\.cohortDay)).count == 3)
        #expect(report.filters == filters); #expect(report.coverage.firstOpenInWindow.newInstall == 9)
        #expect(AuroraJourneyRatioTotal.sum(report.rows.map(\.tutorialStarted)).ratio == .init(numerator: 6, denominator: 9, value: 6.0 / 9))
        #expect(await JourneyStub.shared.requests.count == 3)
    }

    @Test func runsAcrossWindowsAddEveryOutcomeOnlyOnce() async throws {
        let data = try fixture(.runs)
        await JourneyStub.shared.install { request in
            let p = try Self.payload(request)
            #expect(p["population"] as? String == "new_installs")
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["filters"] = ["from_day": p["from_day"]!, "to_day_exclusive": p["to_day_exclusive"]!, "app_version": "1.5.0", "population": "new_installs"]
            return (200, try JSONSerialization.data(withJSONObject: object))
        }
        let report = try await reader.runs(filters: .init(fromDay: "2025-09-10", toDayExclusive: "2026-09-20", appVersion: "1.5.0", population: .newInstalls))
        #expect(report.rows.count == 3); #expect(report.rows.map(\.games) == [4, 2, 6])
        #expect(report.rows[0].leftAppNotReturned == 2)
    }

    @Test func secondWindowErrorDiscardsTheFirstWindow() async throws {
        let data = try fixture(.funnel)
        await JourneyStub.shared.install { request in
            let p = try Self.payload(request)
            if p["as_of"] != nil { return (500, Data()) }
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["filters"] = ["from_day": p["from_day"]!, "to_day_exclusive": p["to_day_exclusive"]!, "app_version": "1.5.0", "population": "all"]
            return (200, try JSONSerialization.data(withJSONObject: object))
        }
        await #expect(throws: GameMetrikError.http(500)) { try await reader.funnel(filters: .init(fromDay: "2026-09-10", toDayExclusive: "2027-09-20", appVersion: "1.5.0")) }
    }

    @Test func bundleSharesServerBoundaryAndReports404WithoutThrowing() async throws {
        let fixtures = try Dictionary(uniqueKeysWithValues: AuroraJourneyReportKind.allCases.map { ($0.rawValue, try fixture($0)) })
        await JourneyStub.shared.install { request in
            // The separate steps RPC is not deployed in these scenarios.
            if request.url!.path.hasSuffix("gamemetrik_aurora_journey_steps_v1") { return (404, Data()) }
            // The separate monetization RPC is not deployed in these scenarios either.
            if request.url!.path.hasSuffix("gamemetrik_aurora_monetization_report_v1") { return (404, Data()) }
            let p = try Self.payload(request), kind = p["report"] as! String
            #expect(p["as_of"] as? String == (kind == "funnel" ? nil : "2026-10-02T13:50:05.567638+00:00"))
            var object = try #require(JSONSerialization.jsonObject(with: fixtures[kind]!) as? [String: Any])
            object["filters"] = ["from_day": p["from_day"]!, "to_day_exclusive": p["to_day_exclusive"]!, "app_version": "1.5.0", "population": "all"]
            if kind == "quality" { object["rows"] = [] }
            return (200, try JSONSerialization.data(withJSONObject: object))
        }
        #expect(try await reader.bundle(filters: filters).loadedKinds.count == 5)
        await JourneyStub.shared.install { _ in (404, Data()) }
        let missing = try await reader.bundle(filters: filters)
        #expect(missing.status == .notConnected); #expect(missing.loadedKinds.isEmpty)
    }

    @Test(arguments: [401, 403]) func accessRefusalsPropagate(status: Int) async {
        await JourneyStub.shared.install { _ in (status, Data()) }
        await #expect(throws: GameMetrikError.http(status)) { try await reader.bundle(filters: filters) }
        #expect(await JourneyStub.shared.requests.count == 1)
    }

    @Test(arguments: [404, 401, 403]) func connectionProbeDistinguishesMissingFromDenied(status: Int) async throws {
        await JourneyStub.shared.install { _ in (status, Data()) }
        let check = await ConnectionChecks.auroraJourney(project: project, http: http)
        #expect(!check.success)
        #expect(check.detail.contains(status == 404 ? "not_connected" : "refusé"))
        let request = try #require(await JourneyStub.shared.requests.first)
        let p = try Self.payload(request)
        #expect(p["report"] as? String == "quality")
        let f = AuroraJourneyFilters(fromDay: p["from_day"] as! String, toDayExclusive: p["to_day_exclusive"] as! String)
        #expect(AuroraJourneyContract.calendar.dateComponents([.day], from: AuroraJourneyContract.day(f.fromDay)!, to: AuroraJourneyContract.day(f.toDayExclusive)!).day == 1)
    }

    @Test func exportsNullableRatiosDefinitionsAndCoverageWithoutIdentifiers() throws {
        let now = Dates.parse("2026-10-02T00:00:00Z")!
        let bundle = AuroraJourneyDemo.bundle(filters: .period(.month, now: now), now: now)
        var export = DataExport(mode: "Démo", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "30 jours", scope: "Parcours")
        export.addAuroraJourney(bundle)
        #expect(export.tables.count == 9)
        let funnel = try #require(export.tables.first { $0.id == "parcours_entonnoir" })
        let value = try #require(funnel.columns.firstIndex(of: "tutorial_started_value"))
        let reason = try #require(funnel.columns.firstIndex(of: "tutorial_started_reason"))
        #expect(funnel.rows.contains { $0[value] == .null && $0[reason] == .text("immature_cohort") })
        #expect(export.readme.contains("0,25 = 25 %")); #expect(export.readme.contains("pas de retour sous 7 jours"))
        let json = String(decoding: try export.jsonData(), as: UTF8.self)
        for forbidden in ["installation_id", "run_id", "user_id", "sb_secret_"] { #expect(!json.contains(forbidden)) }
    }

    @Test func availabilityUsesCollectionStartAndPreservesArchivedHistory() throws {
        var bundle = AuroraJourneyDemo.bundle(filters: filters, now: Dates.parse("2026-10-02T00:00:00Z")!)
        #expect(bundle.availability(for: .init(fromDay: "2026-08-01", toDayExclusive: "2026-09-10")) == .notCollected)
        #expect(bundle.availability(for: .init(fromDay: "2026-09-01", toDayExclusive: "2026-09-11")) == .partial)
        #expect(bundle.availability(for: filters) == .loaded)
        // Archived days inside the window do not make the days before collection collected.
        bundle.funnel?.coverage.archivedDaysInWindow = 1
        #expect(bundle.availability(for: .init(fromDay: "2026-08-01", toDayExclusive: "2026-09-10")) == .notCollected)
        #expect(bundle.availability(for: .init(fromDay: "2026-09-01", toDayExclusive: "2026-09-11")) == .partial)
        // Once the 25-month purge has moved the first raw event forward, the archive holds the older days.
        bundle.funnel?.coverage.collectionFirstReceivedAt = "2026-10-03T08:00:00Z"
        bundle.funnel?.asOf = "2028-11-01T00:00:00Z"
        #expect(bundle.availability(for: .init(fromDay: "2026-09-10", toDayExclusive: "2026-10-01")) == .loaded)
        bundle.funnel?.coverage.archivedDaysInWindow = 0
        #expect(bundle.availability(for: .init(fromDay: "2026-09-10", toDayExclusive: "2026-10-01")) == .notCollected)
    }

    @Test func exportedSQLUsesTheSameDisjointWindowsAndBoundary() throws {
        let window = AuroraJourneyFilters(fromDay: "2026-01-01", toDayExclusive: "2027-03-01", appVersion: "1.5.0")
        let bundle = AuroraJourneyDemo.bundle(filters: window, now: Dates.parse("2027-03-01T00:00:00Z")!)
        var export = DataExport(mode: "Démo", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "Tout", scope: "Parcours")
        export.addAuroraJourney(bundle)
        let queries = export.notes.filter { $0.contains("SELECT public.gamemetrik_aurora_journey_report_v1") }
        let windows = try window.windows()
        #expect(queries.count == 2)
        #expect(windows[0].toDayExclusive == windows[1].fromDay)
        for (query, expected) in zip(queries, windows) {
            #expect(query.contains("\"from_day\":\"\(expected.fromDay)\""))
            #expect(query.contains("\"to_day_exclusive\":\"\(expected.toDayExclusive)\""))
            #expect(query.contains("\"as_of\":\"\(bundle.asOf!)\""))
            #expect(query.contains("\"app_version\":\"1.5.0\""))
        }
    }
    // MARK: Anonymous steps (gamemetrik_aurora_journey_steps_v1)

    var stepsFilters: AuroraJourneyFilters { .init(fromDay: "2026-10-01", toDayExclusive: "2026-10-07") }
    func stepsFixture() throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: "aurora-journey-steps", withExtension: "json", subdirectory: "Fixtures")))
    }
    func changedSteps(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: stepsFixture()) as? [String: Any]); edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func stepsPage(_ fixture: Data, for request: URLRequest, cohortDayFromRequest: Bool = false) throws -> Data {
        let p = try payload(request)
        var object = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        object["filters"] = ["from_day": p["from_day"]!, "to_day_exclusive": p["to_day_exclusive"]!, "app_version": p["app_version"] ?? NSNull()]
        if let boundary = p["as_of"] { object["as_of"] = boundary }
        if cohortDayFromRequest {
            var rows = object["rows"] as! [[String: Any]]
            rows = [rows[1]]; rows[0]["cohort_day"] = p["from_day"]; object["rows"] = rows
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func stepsDecodeReasonsAndMatureTotals() async throws {
        let data = try stepsFixture()
        await JourneyStub.shared.install { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/rest/v1/rpc/gamemetrik_aurora_journey_steps_v1")
            #expect(request.value(forHTTPHeaderField: "apikey") == "sb_secret_synthetic_only_test_credential")
            let p = try Self.payload(request)
            #expect(Set(p.keys) == ["contract_version", "from_day", "to_day_exclusive", "app_version"])
            #expect(p["app_version"] is NSNull); #expect(p["contract_version"] as? Int == 1)
            return (200, data)
        }
        let report = try await reader.steps(filters: stepsFilters)
        #expect(report.rows.map(\.stableKey) == ["2026-10-01|1.5.0", "2026-10-01|1.5.1", "2026-10-06|1.5.1"])
        #expect(report.coverage.identifier == "none"); #expect(report.coverage.stepsFirstDay == "2026-10-01")
        let old = report.rows[0], mature = report.rows[1], young = report.rows[2]
        #expect(old.tutorialStarted.reason == .notCollected); #expect(old.tutorialStarted.formatted == "Non collecté")
        #expect(old.measuredShare == .init(numerator: 0, denominator: 9, value: 0))
        #expect(mature.solved3 == .init(numerator: 7, denominator: 14, value: 0.5))
        #expect(mature.returnD7D13 == .immature); #expect(young.tutorialStarted.formatted == "En attente de maturité")
        // Totals add numerators and denominators of published rows only, never percentages.
        let tutorial = report.total(\.tutorialStarted)
        #expect(tutorial.ratio == .init(numerator: 13, denominator: 14, value: 13.0 / 14)); #expect(tutorial.excludedRows == 2)
        let d1 = report.total(\.returnD1)
        #expect(d1.ratio == .init(numerator: 9, denominator: 22, value: 9.0 / 22)); #expect(d1.excludedRows == 1)
        #expect(report.total(\.measuredShare).ratio == .init(numerator: 22, denominator: 39, value: 22.0 / 39))
        #expect(report.total(\.returnD7D13).ratio.value == nil); #expect(report.total(\.returnD7D13).ratio.reason == .immatureCohort)
        #expect(report.firstLaunches == 39); #expect(report.stepsOpen == 22)
    }

    @Test(arguments: ["missing", "extra_root", "extra_row", "extra_coverage", "report", "identifier", "grace", "filters", "version_filter",
                      "not_collected_with_steps", "immature_without_steps", "denominator", "value", "share", "empty_reason", "week_split",
                      "d1_after_week", "d7_before_week", "duplicate", "day_outside"])
    func stepsRejectWholeMalformedReport(field: String) async throws {
        let data = try changedSteps { object in
            var rows = object["rows"] as! [[String: Any]]
            var coverage = object["coverage"] as! [String: Any]
            switch field {
            case "missing": rows[1].removeValue(forKey: "solved_10")
            case "extra_root": object["installation_id"] = "must-never-enter-the-model"
            case "extra_row": rows[1]["install_id"] = "x"
            case "extra_coverage": coverage["device"] = "x"
            case "report": object["report"] = "funnel"
            case "identifier": coverage["identifier"] = "install_id"
            case "grace": coverage["grace_days"] = 2
            case "filters": object["filters"] = ["from_day": "2026-10-01", "to_day_exclusive": "2026-10-08", "app_version": NSNull()]
            case "version_filter": object["filters"] = ["from_day": "2026-10-01", "to_day_exclusive": "2026-10-07"]
            case "not_collected_with_steps": rows[1]["solved_1"] = ["numerator": 0, "denominator": 0, "value": NSNull(), "reason": "not_collected"]
            case "immature_without_steps": rows[0]["return_d1"] = ["numerator": NSNull(), "denominator": NSNull(), "value": NSNull(), "reason": "immature_cohort"]
            case "denominator": rows[1]["solved_1"] = ["numerator": 10, "denominator": 20, "value": 0.5]
            case "value": rows[1]["solved_1"] = ["numerator": 10, "denominator": 14, "value": 0.5]
            case "share": rows[1]["measured_share"] = ["numerator": 13, "denominator": 20, "value": 0.65]
            case "empty_reason": rows[1]["solved_1"] = ["numerator": 0, "denominator": 0, "value": NSNull(), "reason": "empty_cohort"]
            case "week_split": rows[2]["solved_1"] = ["numerator": 1, "denominator": 8, "value": 0.125]
            case "d1_after_week": rows[1]["return_d1"] = ["numerator": NSNull(), "denominator": NSNull(), "value": NSNull(), "reason": "immature_cohort"]
            case "d7_before_week": rows[2]["return_d7_d13"] = ["numerator": 1, "denominator": 8, "value": 0.125]
            case "duplicate": rows.append(rows[1])
            default: rows[1]["cohort_day"] = "2026-10-07"
            }
            object["rows"] = rows; object["coverage"] = coverage
        }
        await JourneyStub.shared.install { _ in (200, data) }
        await #expect(throws: AuroraJourneyError.unreadableReport) { try await reader.steps(filters: stepsFilters) }
    }

    @Test func stepsAcrossWindowsConcatenateRowsWithOneBoundary() async throws {
        let fixture = try stepsFixture()
        let filters = AuroraJourneyFilters(fromDay: "2024-02-28", toDayExclusive: "2026-03-02", appVersion: "1.5.1")
        let boundary = "2026-10-13T10:00:00.123456+00:00"
        await JourneyStub.shared.install { request in
            let p = try Self.payload(request)
            #expect(p["app_version"] as? String == "1.5.1")
            #expect(p["as_of"] as? String == (p["from_day"] as? String == filters.fromDay ? nil : boundary))
            return (200, try Self.stepsPage(fixture, for: request, cohortDayFromRequest: true))
        }
        let report = try await reader.steps(filters: filters)
        #expect(await JourneyStub.shared.requests.count == 3)
        #expect(report.rows.count == 3); #expect(Set(report.rows.map(\.cohortDay)).count == 3)
        #expect(report.filters == .init(fromDay: "2024-02-28", toDayExclusive: "2026-03-02", appVersion: "1.5.1"))
        #expect(report.total(\.tutorialStarted).ratio == .init(numerator: 39, denominator: 42, value: 39.0 / 42))
    }

    @Test(arguments: [404, 403, 500, 0]) func stepsFailureNeverBreaksTheFiveReports(status: Int) async throws {
        let fixtures = try Dictionary(uniqueKeysWithValues: AuroraJourneyReportKind.allCases.map { ($0.rawValue, try fixture($0)) })
        let boundary = "2026-10-02T13:50:05.567638+00:00"
        await JourneyStub.shared.install { request in
            if request.url!.path.hasSuffix("gamemetrik_aurora_monetization_report_v1") { return (404, Data()) }
            let p = try Self.payload(request)
            if request.url!.path.hasSuffix("gamemetrik_aurora_journey_steps_v1") {
                #expect(p["as_of"] as? String == boundary)
                // 0 stands for a readable HTTP response that breaks the steps contract.
                return status == 0 ? (200, Data("{\"contract_version\":1}".utf8)) : (status, Data())
            }
            let kind = p["report"] as! String
            var object = try #require(JSONSerialization.jsonObject(with: fixtures[kind]!) as? [String: Any])
            object["filters"] = ["from_day": p["from_day"]!, "to_day_exclusive": p["to_day_exclusive"]!, "app_version": "1.5.0", "population": "all"]
            if kind == "quality" { object["rows"] = [] }
            return (200, try JSONSerialization.data(withJSONObject: object))
        }
        let bundle = try await reader.bundle(filters: filters)
        #expect(bundle.status == .loaded); #expect(bundle.errors.isEmpty)
        #expect(bundle.loadedKinds == AuroraJourneyReportKind.allCases)
        #expect(bundle.steps == nil)
        let failure = try #require(bundle.stepsError)
        #expect(failure.status == (status == 404 ? .notConnected : .partial))
        #expect(bundle.stepsAvailability == failure.status)
        #expect(failure.detail.contains(status == 404 ? "pas encore déployée" : status == 0 ? "illisibles" : String(status)))
        var export = DataExport(mode: "Démo", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "1 jour", scope: "Parcours")
        export.addAuroraJourney(bundle)
        #expect(!export.tables.contains { $0.id == "parcours_etapes" })
        #expect(export.tables.contains { $0.id == "parcours_entonnoir" })
        let check = try #require(export.checks.first { $0.section == "Parcours · Étapes anonymes" })
        #expect(check.status == failure.status.rawValue); #expect(check.detail == failure.detail)
        #expect(export.checks.filter { $0.section.hasPrefix("Parcours · ") && $0.section != "Parcours · Étapes anonymes" }.allSatisfy { $0.status == "loaded" })
    }

    @Test func stepsLoadedInTheBundleShareItsBoundary() async throws {
        let fixtures = try Dictionary(uniqueKeysWithValues: AuroraJourneyReportKind.allCases.map { ($0.rawValue, try fixture($0)) })
        let steps = try stepsFixture()
        await JourneyStub.shared.install { request in
            if request.url!.path.hasSuffix("gamemetrik_aurora_monetization_report_v1") { return (404, Data()) }
            let p = try Self.payload(request)
            if request.url!.path.hasSuffix("gamemetrik_aurora_journey_steps_v1") { return (200, try Self.stepsPage(steps, for: request)) }
            var object = try #require(JSONSerialization.jsonObject(with: fixtures[p["report"] as! String]!) as? [String: Any])
            object["filters"] = ["from_day": p["from_day"]!, "to_day_exclusive": p["to_day_exclusive"]!, "app_version": p["app_version"] ?? NSNull(), "population": "all"]
            object["rows"] = []
            return (200, try JSONSerialization.data(withJSONObject: object))
        }
        let bundle = try await reader.bundle(filters: stepsFilters)
        #expect(bundle.status == .loaded)
        let report = try #require(bundle.steps)
        #expect(report.asOf == bundle.asOf); #expect(bundle.stepsAvailability == .loaded); #expect(bundle.stepsError == nil)
    }

    @Test func exportsStepsWithReasonsDefinitionsAndAccountsNote() throws {
        let now = Dates.parse("2026-10-13T00:00:00Z")!
        let bundle = AuroraJourneyDemo.bundle(filters: .period(.month, now: now), now: now)
        var export = DataExport(mode: "Démo", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "30 jours", scope: "Parcours")
        export.addAuroraJourney(bundle)
        let table = try #require(export.tables.first { $0.id == "parcours_etapes" })
        let ratios = ["measured_share", "tutorial_started", "tutorial_completed", "solved_1", "solved_3", "solved_10", "return_d1", "return_d7_d13"]
        #expect(table.columns == ["cohort_day", "app_version", "first_launches", "steps_open"]
                + ratios.flatMap { name in ["numerator", "denominator", "value", "reason"].map { name + "_" + $0 } })
        let value = try #require(table.columns.firstIndex(of: "tutorial_started_value"))
        let reason = try #require(table.columns.firstIndex(of: "tutorial_started_reason"))
        let version = try #require(table.columns.firstIndex(of: "app_version"))
        #expect(table.rows.contains { $0[version] == .text("1.5.0") && $0[value] == .null && $0[reason] == .text("not_collected") })
        #expect(table.rows.contains { $0[version] == .text("1.5.1") && $0[value] == .null && $0[reason] == .text("immature_cohort") })
        #expect(table.rows.contains { $0[version] == .text("1.5.1") && $0[value] != .null })
        #expect(export.checks.contains { $0.section == "Parcours · Étapes anonymes" && $0.status == "loaded" })
        #expect(export.readme.contains("parcours_etapes : étapes anonymes")); #expect(export.readme.contains("parcours_etapes.csv"))
        let json = String(decoding: try export.jsonData(), as: UTF8.self)
        #expect(json.contains("\"id\" : \"parcours_etapes\""))
        for forbidden in ["installation_id", "install_id", "request_id", "sb_secret_"] { #expect(!json.contains(forbidden)) }
        _ = try export.fileWrapper()
        var players = DataExport(mode: "Démo", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "30 jours", scope: "Joueurs")
        let directory = try Demo.directory(range: .month, game: Demo.games[0], now: now)
        players.addDirectory(directory, includePlayers: true, jardin: true, timezone: "Europe/Zurich", connectedAccountsOnly: true)
        #expect(players.readme.contains("comptes connectés (Apple ou Google) uniquement"))
        #expect(players.readme.contains("invités sont mesurés dans Parcours"))
        var other = DataExport(mode: "Démo", gameID: "orbit-tactics", gameName: "Orbit Tactics", timeframe: "30 jours", scope: "Joueurs")
        other.addDirectory(directory, includePlayers: true, jardin: false, timezone: nil)
        #expect(!other.readme.contains("comptes connectés"))
    }

    /// Optional check against a LOCAL Supabase stack only (never production). Skipped unless both variables are set.
    @Test func localStackStepsResponseDecodes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["GAMEMETRIK_LOCAL_STEPS_URL"].flatMap(URL.init(string:)),
              let key = environment["GAMEMETRIK_LOCAL_STEPS_KEY"], ["127.0.0.1", "localhost"].contains(base.host ?? "") else { return }
        var request = URLRequest(url: base.appendingPathComponent("rest/v1/rpc/gamemetrik_aurora_journey_steps_v1"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "apikey"); request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let today = Dates.day(Date(), timezone: AuroraJourneyContract.zone)
        let window = AuroraJourneyFilters(fromDay: Dates.day(AuroraJourneyContract.calendar.date(byAdding: .day, value: -30, to: Date())!, timezone: AuroraJourneyContract.zone),
                                         toDayExclusive: Dates.day(AuroraJourneyContract.calendar.date(byAdding: .day, value: 1, to: Date())!, timezone: AuroraJourneyContract.zone))
        request.httpBody = try JSONSerialization.data(withJSONObject: ["p_request": ["contract_version": 1, "from_day": window.fromDay, "to_day_exclusive": window.toDayExclusive, "app_version": NSNull()]])
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        // Same validation path as the reader: closed shape, envelope, coverage and every row.
        try AuroraJourneyContract.validateStepsShape(data)
        let report = try JSONDecoder().decode(AuroraJourneyStepsReport.self, from: data)
        #expect(report.report == "steps"); #expect(report.filters == .init(window))
        try report.coverage.validate()
        for row in report.rows { try row.validate(filters: window) }
        print("Local steps report: \(report.rows.count) row(s), steps_first_day \(report.coverage.stepsFirstDay ?? "none"), today \(today)")
        for row in report.rows {
            print("  \(row.cohortDay) \(row.appVersion) first_launches=\(row.firstLaunches) steps_open=\(row.stepsOpen) share=\(row.measuredShare.formatted) "
                  + AuroraJourneyStepsRow.steps.map { "\($0.key)=\(row[keyPath: $0.path].formatted) (\(row[keyPath: $0.path].sample))" }.joined(separator: " "))
        }
    }
}
