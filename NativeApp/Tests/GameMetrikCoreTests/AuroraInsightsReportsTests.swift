import Foundation
import Testing
@testable import GameMetrikCore

private actor InsightsStub {
    static let shared = InsightsStub()
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    var handler: Handler?
    private(set) var requests: [URLRequest] = []
    func install(_ handler: @escaping Handler) { self.handler = handler; requests = [] }
    func response(_ request: URLRequest) throws -> (Int, Data) {
        requests.append(request)
        return try handler!(request)
    }
}
private final class InsightsURLProtocol: URLProtocol, @unchecked Sendable {
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
                let (status, data) = try await InsightsStub.shared.response(incoming)
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: incoming.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}

@Suite(.serialized) struct AuroraInsightsReportsTests {
    var project: PersonalSupabase { .init(ref: "aurora", name: "Aurora Grove", url: URL(string: "https://fixture.supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_synthetic_only_test_credential") }
    var reader: AuroraJourneyReportReader {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [InsightsURLProtocol.self]
        return .init(personal: project, http: .init(session: URLSession(configuration: config)))
    }
    /// The window of the samples generated against the local stack (rows on 2026-10-18).
    static let window = AuroraJourneyFilters(fromDay: "2026-10-17", toDayExclusive: "2026-10-19")
    static let forbidden = ["installation_id", "session_id", "presence_id", "user_id"]

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    static func object(_ data: Data) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    static func payload(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["p_request"])
        return try #require(object["p_request"] as? [String: Any])
    }
    static func isPresence(_ request: URLRequest) -> Bool { request.url!.path.hasSuffix("gamemetrik_aurora_presence_report_v1") }
    /// The sample of the requested report, moved into the requested window, population, version and boundary.
    static func page(for request: URLRequest, edit: (@Sendable (String, inout [String: Any]) -> Void)? = nil) throws -> Data {
        let p = try payload(request)
        let report = try #require(p["report"] as? String)
        var object = try object(data((isPresence(request) ? "aurora-presence-" : "aurora-insights-") + report))
        if isPresence(request) {
            if report != "live" { object["filters"] = ["from_day": p["from_day"]!, "to_day_exclusive": p["to_day_exclusive"]!] }
        } else {
            object["filters"] = ["from_day": p["from_day"]!, "to_day_exclusive": p["to_day_exclusive"]!,
                                 "app_version": report == "server" ? NSNull() : (p["app_version"] ?? NSNull()),
                                 "population": report == "server" ? "all" : (p["population"] ?? "production")]
            if let boundary = p["as_of"] { object["as_of"] = boundary }
        }
        edit?(report, &object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    func install(_ edit: (@Sendable (String, inout [String: Any]) -> Void)? = nil) async {
        await InsightsStub.shared.install { request in (200, try Self.page(for: request, edit: edit)) }
    }

    // MARK: Decoding

    @Test func decodesEveryFamilyAndThePresenceOfTheSamples() async throws {
        await install()
        let bundle = try await reader.insightsBundle(filters: Self.window, population: .all)
        #expect(bundle.errors.isEmpty, "\(bundle.errors.mapValues(\.detail))")
        #expect(bundle.presenceErrors.isEmpty, "\(bundle.presenceErrors.mapValues(\.detail))")
        #expect(bundle.loadedKinds == AuroraInsightsKind.allCases)
        #expect(bundle.status == .loaded)
        for kind in AuroraInsightsKind.allCases { #expect(bundle.state(for: kind) == .data, "\(kind)") }
        for kind in AuroraPresenceKind.allCases { #expect(bundle.presenceState(for: kind) == .data, "\(kind)") }

        let requests = await InsightsStub.shared.requests
        let insights = try requests.filter { !Self.isPresence($0) }.map(Self.payload)
        #expect(insights.count == AuroraInsightsKind.allCases.count)
        #expect(insights.allSatisfy { $0["contract_version"] as? Int == 1 && $0["population"] as? String == "all" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "apikey") == "sb_secret_synthetic_only_test_credential" })
        // The first answer supplies the boundary; every other family is read with it.
        #expect(insights.first?["as_of"] == nil)
        #expect(insights.dropFirst().allSatisfy { $0["as_of"] as? String == "2026-10-18T02:52:10.065144+00:00" })
        #expect(bundle.asOf == "2026-10-18T02:52:10.065144+00:00")
        #expect(requests.filter(Self.isPresence).count == 3)

        let activity = try #require(bundle.activity?.rows.first)
        #expect(activity.dau == 2 && activity.mau == 2 && activity.newInstallations == 2 && activity.installationsWithContext == 1)
        let sessions = try #require(bundle.sessions?.rows.first)
        #expect(sessions.foregroundSeconds == 120 && sessions.activeSeconds == 75 && sessions.adSeconds == 15 && sessions.medianSessionSeconds == 120)
        #expect(bundle.screens?.rows.first?.origins == ["launch": 1])
        #expect(bundle.dialogs?.rows.first?.outcomes == ["decline": 1])
        #expect(bundle.actions?.rows.first?.valueSum == 1)
        let quick = try #require(bundle.gameplay?.rows.first { $0.mode == "quick" })
        #expect(quick.score == 820 && quick.maxScore == 1_000 && quick.runsWithErrors == 1 && quick.medianActiveSeconds == 4)
        #expect(bundle.gameplay?.rows.first { $0.mode == "lightpaths" }?.level == 12)
        #expect(bundle.timeline?.rows.first { $0.mode == "quick" }?.byKind == ["f": 1, "u": 1, "x": 1])
        #expect(bundle.progress?.rows.first?.valueMax == 4)
        #expect(bundle.settings?.rows.first?.value == "off")
        #expect(bundle.stability?.rows.first?.stopsWhileOnScreen == 0)
        #expect(bundle.diagnostics?.rows.first?.exceptionType == "NullReferenceException")
        #expect(bundle.performance?.rows.first?.fpsFrames == 216_000)
        #expect(bundle.cloud?.rows.first?.p90Ms == 180 && bundle.cloud?.rows.first?.statuses == ["200": 1])
        #expect(bundle.privacy?.rows.first?.statisticsBasis == "regional_default")
        #expect(bundle.consents?.rows.first?.state == "granted")
        #expect(bundle.context?.rows.count == 12)
        #expect(bundle.notifications?.rows.first?.opens == 1)
        let server = try #require(bundle.server)
        #expect(server.rows.first?.eventsReceived == 57 && server.rows.first?.rejections == [:])
        #expect(server.coverage.functions?.count == 4 && server.coverage.storage.databaseBytes == 16_993_427)
        #expect(server.filters.population == .all)
        #expect(bundle.activity?.coverage.rawRetentionDays == 761)
        #expect(bundle.activity?.coverage.installationsArePeople == false)

        let live = try #require(bundle.live?.rows.first)
        #expect(live.players == 1 && !live.isProduction && live.belongs(to: .internalBuilds) && !live.belongs(to: .production))
        let day = try #require(bundle.history?.rows.first)
        #expect(day.peakInApp == 0 && day.internalPeakInApp == 1 && !day.complete)
        #expect(bundle.hourly?.rows.first?.hourOfDay == 4)
    }

    @Test func maskedArchivedRowAndUnknownKeysOrCodesAreAccepted() async throws {
        await install { report, object in
            guard report == "screens" else { return }
            object["future_root"] = ["anything": true]
            var coverage = object["coverage"] as! [String: Any]
            coverage["archived_days_in_window"] = 1; coverage["future_coverage"] = 7
            object["coverage"] = coverage
            var rows = object["rows"] as! [[String: Any]]
            rows[0]["future_metric"] = 42
            rows.append(["day": "2026-10-17", "app_version": "1.6.0", "screen": "brand_new_screen", "installations": NSNull(), "views": NSNull(),
                         "seconds": NSNull(), "median_seconds": NSNull(), "left_to_background": NSNull(), "origins": NSNull(), "suppressed": true])
            object["rows"] = rows
        }
        let bundle = try await reader.insightsBundle(filters: Self.window, population: .production)
        #expect(bundle.errors.isEmpty, "\(bundle.errors.mapValues(\.detail))")
        let screens = try #require(bundle.screens)
        #expect(screens.rows.count == 2)
        let masked = try #require(screens.rows.first { $0.suppressed })
        #expect(masked.screen == "brand_new_screen")
        #expect(masked.views == nil && masked.seconds == nil && masked.installations == nil && masked.origins == nil)
        #expect(screens.maskedRowCount == 1 && screens.visibleRows.count == 1)
        // Never 0 for an unknown or masked number.
        #expect(AuroraInsightsFormat.count(masked.views) == "inconnu")
        #expect(AuroraInsightsMath.sum([masked], \.views) == nil)
        #expect(AuroraInsightsMath.sum(screens.rows, \.views) == 1)
        #expect(bundle.collectionGap(for: .screens) == nil)

        var export = DataExport(mode: "Test", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "test", scope: "Activité et jeu")
        export.addAuroraInsights(bundle)
        let table = try #require(export.tables.first { $0.id == "collecte_ecrans" })
        #expect(!table.columns.contains("future_metric"))
        let row = try #require(table.rows.first { $0[table.columns.firstIndex(of: "screen")!] == .text("brand_new_screen") })
        #expect(row[table.columns.firstIndex(of: "views")!] == .null)
        #expect(row[table.columns.firstIndex(of: "suppressed")!] == .boolean(true))
        let json = String(decoding: try export.jsonData(), as: UTF8.self)
        #expect(!json.contains("future_metric") && !json.contains("future_coverage") && !json.contains("future_root"))
        #expect(export.checks.first { $0.section == "Collecte complète · Écrans" }?.detail.contains("masquée") == true)
        #expect(AuroraInsightsLabels.dimension("ad_config_revision") == "Révision des réglages publicitaires")
        #expect(AuroraInsightsLabels.dimension("future_dimension") == "future_dimension")
    }

    @Test func aMissingDocumentedKeyRejectsOnlyItsFamily() async throws {
        await install { report, object in
            guard report == "sessions" else { return }
            var rows = object["rows"] as! [[String: Any]]
            rows[0].removeValue(forKey: "active_seconds")
            object["rows"] = rows
        }
        let bundle = try await reader.insightsBundle(filters: Self.window, population: .production)
        #expect(bundle.errors[.sessions]?.cause == .unreadable)
        #expect(bundle.sessions == nil)
        #expect(bundle.loadedKinds.count == AuroraInsightsKind.allCases.count - 1)
        #expect(bundle.status == .partial)
        // A wrong type is rejected too.
        await install { report, object in
            guard report == "gameplay" else { return }
            var rows = object["rows"] as! [[String: Any]]
            rows[0]["runs"] = "one"
            object["rows"] = rows
        }
        let typed = try await reader.insightsBundle(filters: Self.window, population: .production)
        #expect(typed.errors[.gameplay]?.cause == .unreadable)
        #expect(typed.errors.count == 1)
    }

    @Test func absentFunctionsAreNotConnectedAndReadOnce() async throws {
        await InsightsStub.shared.install { _ in (404, Data()) }
        let bundle = try await reader.insightsBundle(filters: Self.window, population: .production)
        #expect(bundle.status == .notConnected)
        #expect(bundle.errors.count == AuroraInsightsKind.allCases.count)
        #expect(bundle.errors.values.allSatisfy { $0.cause == .missingFunction && $0.status == .notConnected })
        #expect(bundle.presenceErrors.values.allSatisfy { $0.cause == .missingFunction })
        #expect(bundle.state(for: .activity) == .failed(.missingFunction))
        #expect(!bundle.readNothing)
        let requests = await InsightsStub.shared.requests
        #expect(requests.filter { !Self.isPresence($0) }.count == 1)
        #expect(requests.filter(Self.isPresence).count == 1)
        var export = DataExport(mode: "Test", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "test", scope: "Activité et jeu")
        export.addAuroraInsights(bundle)
        #expect(export.checks.filter { $0.section.hasPrefix("Collecte complète · ") }.allSatisfy { $0.status == "not_connected" })
        #expect(!export.tables.contains { $0.id.hasPrefix("collecte_") })
    }

    @Test(arguments: [401, 403]) func refusalIsDeniedAndPartial(status: Int) async throws {
        await InsightsStub.shared.install { _ in (status, Data()) }
        let bundle = try await reader.insightsBundle(filters: Self.window, population: .production)
        #expect(bundle.errors.values.allSatisfy { $0.cause == .denied && $0.status == .partial })
        #expect(bundle.status == .partial)
        #expect(!bundle.readNothing)
        #expect(bundle.errors[.activity]?.detail.contains("\(status)") == true)
        // A network failure, by contrast, is no definite answer.
        await InsightsStub.shared.install { _ in throw URLError(.notConnectedToInternet) }
        let offline = try await reader.insightsBundle(filters: Self.window, population: .production)
        #expect(offline.readNothing)
        #expect(offline.errors.values.allSatisfy { $0.cause == .network })
    }

    @Test func aPeriodBeforeTheCollectionIsNotCollectedNeverZero() async throws {
        let early = AuroraJourneyFilters(fromDay: "2026-09-01", toDayExclusive: "2026-09-10")
        await install { report, object in
            object["rows"] = []
            if report == "context" {
                var coverage = object["coverage"] as! [String: Any]
                coverage["collection_first_received_at"] = NSNull()
                object["coverage"] = coverage
            }
        }
        let bundle = try await reader.insightsBundle(filters: early, population: .production)
        #expect(bundle.errors.isEmpty, "\(bundle.errors.mapValues(\.detail))")
        #expect(bundle.state(for: .screens) == .notCollected)
        #expect(bundle.state(for: .context) == .notCollected)
        #expect(bundle.state(for: .server) == .noData)
        #expect(bundle.presenceState(for: .history) == .notCollected)
        var export = DataExport(mode: "Test", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "test", scope: "Activité et jeu")
        export.addAuroraInsights(bundle)
        #expect(export.checks.first { $0.section == "Collecte complète · Écrans" }?.status == "not_collected")
        #expect(export.tables.first { $0.id == "collecte_ecrans" }?.rows.isEmpty == true)

        // A window that starts before the first event is partial; one after it with no row is empty.
        let overlap = AuroraJourneyFilters(fromDay: "2026-10-10", toDayExclusive: "2026-10-19")
        await install()
        let partial = try await reader.insightsBundle(filters: overlap, population: .production)
        #expect(partial.collectionGap(for: .screens) == .partial)
        export = DataExport(mode: "Test", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "test", scope: "Activité et jeu")
        export.addAuroraInsights(partial)
        #expect(export.checks.first { $0.section == "Collecte complète · Écrans" }?.status == "partial")
    }

    @Test func internalPopulationWithoutArchiveIsPartial() async throws {
        await install { _, object in
            guard var coverage = object["coverage"] as? [String: Any], coverage["archive_available_for_population"] != nil else { return }
            coverage["archive_available_for_population"] = false; coverage["archived_days_in_window"] = 1
            object["coverage"] = coverage
        }
        let bundle = try await reader.insightsBundle(filters: Self.window, population: .internalBuilds)
        #expect(bundle.errors.isEmpty, "\(bundle.errors.mapValues(\.detail))")
        #expect(bundle.archiveUnavailable(for: .activity))
        #expect(bundle.collectionGap(for: .activity) == .partial)
        let requests = try await InsightsStub.shared.requests.filter { !Self.isPresence($0) }.map(Self.payload)
        #expect(requests.allSatisfy { $0["population"] as? String == "internal" })
    }

    @Test func longPeriodsAreSplitUnderOneBoundaryAndHourlyIsLimited() async throws {
        let long = AuroraJourneyFilters(fromDay: "2025-09-01", toDayExclusive: "2026-10-19")
        await install { report, object in
            if report != "live" { object["rows"] = [] }
        }
        let report = try await reader.insights(AuroraActivityRow.self, filters: long, population: .production)
        let requests = try await InsightsStub.shared.requests.map(Self.payload)
        #expect(requests.count == 2)
        #expect(requests[1]["as_of"] as? String == report.asOf)
        #expect(report.filters == .init(fromDay: "2025-09-01", toDayExclusive: "2026-10-19", population: .production))
        await #expect(throws: AuroraJourneyError.invalidRequest) { try await reader.presenceHourly(filters: long) }
        let bundle = try await reader.insightsBundle(filters: long, population: .production)
        #expect(!bundle.hourlyRequested)
        #expect(bundle.presenceState(for: .hourly) == .notRequested)
        #expect(bundle.status == .loaded)
    }

    @Test func otherAnswersOutsideTheContractAreRejected() async throws {
        // Wrong population echoed, or a row outside the window: the whole family is unreadable.
        await install { report, object in
            if report == "actions" { var f = object["filters"] as! [String: Any]; f["population"] = "internal"; object["filters"] = f }
            if report == "dialogs" { var rows = object["rows"] as! [[String: Any]]; rows[0]["day"] = "2026-10-25"; object["rows"] = rows }
            if report == "notifications" { var c = object["coverage"] as! [String: Any]; c["installations_are_people"] = true; object["coverage"] = c }
        }
        let bundle = try await reader.insightsBundle(filters: Self.window, population: .production)
        #expect(Set(bundle.errors.keys) == [.actions, .dialogs, .notifications])
        #expect(bundle.errors.values.allSatisfy { $0.cause == .unreadable })
    }

    // MARK: Export

    @Test func exportHasEveryFamilyWithChecksAndNoIdentifier() async throws {
        await install()
        let bundle = try await reader.insightsBundle(filters: Self.window, population: .all)
        var export = DataExport(mode: "Test", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "test", scope: "Activité et jeu")
        export.addAuroraInsights(bundle)
        export.finishChecks()
        let ids = Set(export.tables.map(\.id))
        for kind in AuroraInsightsKind.allCases { #expect(ids.contains(AuroraInsightsExport.family(kind).id), "\(kind)") }
        for id in ["collecte_presence_direct", "collecte_presence_jours", "collecte_presence_heures", "collecte_couverture", "collecte_ecrans_origines",
                   "collecte_fenetres_issues", "collecte_chronologies_coups", "collecte_reseau_statuts", "collecte_serveur_stockage", "collecte_serveur_fonctions", "collecte_erreurs_ecrans"] {
            #expect(ids.contains(id), "\(id)")
        }
        #expect(export.checks.filter { $0.section.hasPrefix("Collecte complète · ") }.count == AuroraInsightsKind.allCases.count + AuroraPresenceKind.allCases.count)
        // The samples' window starts the day before their first event: the families are partial, server and presence loaded.
        #expect(export.checks.filter { $0.section.hasPrefix("Collecte complète · ") }.allSatisfy { ["loaded", "partial"].contains($0.status) })
        #expect(export.checks.first { $0.section == "Collecte complète · Fréquentation" }?.status == "partial")
        #expect(export.checks.first { $0.section == "Collecte complète · Serveur" }?.status == "loaded")
        #expect(export.checks.first { $0.section == "Collecte complète · Pics quotidiens" }?.status == "loaded")
        let coups = try #require(export.tables.first { $0.id == "collecte_chronologies_coups" })
        #expect(coups.columns == ["day", "app_version", "mode", "level", "difficulty", "suppressed", "code", "count"])
        #expect(coups.rows.count == 4)
        let json = String(decoding: try export.jsonData(), as: UTF8.self)
        for forbidden in Self.forbidden + ["sb_secret_"] { #expect(!json.contains(forbidden), "\(forbidden)") }
        for table in export.tables { for column in table.columns { #expect(!Self.forbidden.contains(column)) } }
        #expect(export.readme.contains("durées en secondes"))
        #expect(export.readme.contains("Une installation n’est pas une personne"))
        _ = try export.fileWrapper()
        #expect(AIFolder.guide(AIFolderIndex(updatedAt: "2026-10-18T00:00:00Z", snapshots: [])).contains("`collecte_*`"))
    }

    @Test func demoBundleIsCompleteAndRespectsThePeriod() throws {
        let now = Dates.parse("2026-10-18T10:00:00Z")!
        let month = AuroraInsightsDemo.bundle(filters: .period(.month, now: now), population: .production, now: now)
        #expect(month.loadedKinds == AuroraInsightsKind.allCases && month.status == .loaded)
        #expect(month.collectionGap(for: .activity) == .partial)
        #expect(month.live?.rows.contains { !$0.isProduction } == true)
        let old = AuroraInsightsDemo.bundle(filters: .init(fromDay: "2026-08-01", toDayExclusive: "2026-09-01"), population: .production, now: now)
        #expect(old.state(for: .screens) == .notCollected)
        var export = DataExport(mode: "Démonstration", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "30d", scope: "Activité et jeu")
        export.addAuroraInsights(month)
        _ = try export.jsonData()
        #expect(AuroraInsightsFormat.duration(seconds: 3_900) == "1 h 05 min")
        #expect(AuroraInsightsFormat.duration(seconds: 200) == "3 min 20 s")
        #expect(AuroraInsightsFormat.duration(seconds: 45) == "45 s")
        #expect(AuroraInsightsFormat.duration(nil) == "inconnu")
    }
}
