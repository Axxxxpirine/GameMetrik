import Foundation
import Testing
@testable import GameMetrikCore

/// Optional end-to-end read against a LOCAL Supabase stack only (never production), disabled by default.
/// GAMEMETRIK_LOCAL_SUPABASE_URL      loopback base URL, e.g. http://127.0.0.1:54321
/// GAMEMETRIK_LOCAL_SUPABASE_SERVICE_KEY  local service_role key (sb_secret_… or service_role JWT); never printed
/// GAMEMETRIK_LOCAL_FROM_DAY / GAMEMETRIK_LOCAL_TO_DAY  optional, YYYY-MM-DD, TO_DAY exclusive (default: the last 3 Zurich days, today included)
/// GAMEMETRIK_LOCAL_EXPECT_DATA=1     also require rows in the activity, sessions, gameplay and presence history families
private enum InsightsLocalStack {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var configured: Bool {
        environment["GAMEMETRIK_LOCAL_SUPABASE_URL"]?.isEmpty == false && environment["GAMEMETRIK_LOCAL_SUPABASE_SERVICE_KEY"]?.isEmpty == false
    }
    /// The real reader keeps its https project URL; only this test transport forwards it to the loopback stack.
    static func local(_ url: URL) -> URL? {
        guard let base = environment["GAMEMETRIK_LOCAL_SUPABASE_URL"].flatMap(URL.init(string:)),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(base.host ?? ""),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = (base.path == "/" ? "" : base.path) + url.path
        parts.percentEncodedQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        return parts.url
    }
}

private final class InsightsLocalStackURLProtocol: URLProtocol, @unchecked Sendable {
    private var forwardedTask: URLSessionDataTask?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.supabase.co" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let target = InsightsLocalStack.local(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var forwarded = request
        forwarded.url = target
        if forwarded.httpBody == nil, let stream = forwarded.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            forwarded.httpBodyStream = nil; forwarded.httpBody = data
        }
        let session = URLSession(configuration: .ephemeral)
        forwardedTask = session.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            guard let http = response as? HTTPURLResponse,
                  let echoed = HTTPURLResponse(url: url, statusCode: http.statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            self.client?.urlProtocol(self, didReceive: echoed, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data ?? Data())
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardedTask?.resume()
        session.finishTasksAndInvalidate()
    }
    override func stopLoading() { forwardedTask?.cancel() }
}

@Suite(.serialized, .enabled(if: InsightsLocalStack.configured, "Définir GAMEMETRIK_LOCAL_SUPABASE_URL et GAMEMETRIK_LOCAL_SUPABASE_SERVICE_KEY (stack locale uniquement)"))
struct AuroraInsightsLocalStackTests {
    var filters: AuroraJourneyFilters {
        let zone = AuroraJourneyContract.zone, calendar = AuroraJourneyContract.calendar, today = calendar.startOfDay(for: Date())
        let from = InsightsLocalStack.environment["GAMEMETRIK_LOCAL_FROM_DAY"] ?? Dates.day(calendar.date(byAdding: .day, value: -2, to: today)!, timezone: zone)
        let to = InsightsLocalStack.environment["GAMEMETRIK_LOCAL_TO_DAY"] ?? Dates.day(calendar.date(byAdding: .day, value: 1, to: today)!, timezone: zone)
        return .init(fromDay: from, toDayExclusive: to)
    }
    var reader: AuroraJourneyReportReader {
        let project = PersonalSupabase(ref: "aurora-local", name: "Aurora Grove (local)", url: URL(string: "https://fixture.supabase.co")!,
                                       timezone: "Europe/Zurich", secret: InsightsLocalStack.environment["GAMEMETRIK_LOCAL_SUPABASE_SERVICE_KEY"] ?? "")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [InsightsLocalStackURLProtocol.self]
        return .init(personal: project, http: .init(session: URLSession(configuration: config)))
    }

    @Test(arguments: [AuroraInsightsPopulation.all, .production, .internalBuilds])
    func realReaderDecodesEveryFamilyAndThePresence(population: AuroraInsightsPopulation) async throws {
        let base = try #require(InsightsLocalStack.environment["GAMEMETRIK_LOCAL_SUPABASE_URL"].flatMap(URL.init(string:)))
        try #require(InsightsLocalStack.local(base) != nil, "GAMEMETRIK_LOCAL_SUPABASE_URL doit désigner une stack locale (127.0.0.1, localhost ou ::1).")
        let filters = self.filters
        let bundle = try await reader.insightsBundle(filters: filters, population: population)
        #expect(bundle.errors.isEmpty, "\(bundle.errors.mapValues(\.detail))")
        #expect(bundle.presenceErrors.isEmpty, "\(bundle.presenceErrors.mapValues(\.detail))")
        #expect(bundle.loadedKinds == AuroraInsightsKind.allCases)
        #expect(bundle.status == .loaded)
        print("Stack locale · insights \(population.rawValue) · période \(filters.fromDay) → \(filters.toDayExclusive) exclu · as_of \(bundle.asOf ?? "?")")
        print("  " + AuroraInsightsKind.allCases.map { "\($0.rawValue) \(bundle.anyReport($0)?.rowCount ?? -1)" }.joined(separator: " · "))
        print("  présence : direct \(bundle.live?.rows.count ?? -1) · jours \(bundle.history?.rows.count ?? -1) · heures \(bundle.hourly?.rows.count ?? -1) · premier signal \(bundle.live?.coverage.firstSignalAt ?? "aucun")")
        if InsightsLocalStack.environment["GAMEMETRIK_LOCAL_EXPECT_DATA"] == "1", population == .all {
            #expect(bundle.activity?.rows.isEmpty == false)
            #expect(bundle.sessions?.rows.isEmpty == false)
            #expect(bundle.gameplay?.rows.isEmpty == false)
            #expect(bundle.history?.rows.isEmpty == false)
        }
        var export = DataExport(mode: "Local", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "local", scope: "Activité et jeu")
        export.addAuroraInsights(bundle)
        let json = String(decoding: try export.jsonData(), as: UTF8.self)
        for forbidden in ["installation_id", "session_id", "presence_id", "user_id", "sb_secret_"] { #expect(!json.contains(forbidden), "\(forbidden)") }
    }
}
