import Foundation
import Testing
@testable import GameMetrikCore

/// Optional end-to-end read against a LOCAL Supabase stack only (never production), disabled by default.
/// GAMEMETRIK_LOCAL_SUPABASE_URL      loopback base URL, e.g. http://127.0.0.1:54321
/// GAMEMETRIK_LOCAL_SUPABASE_SERVICE_KEY  local service_role key (sb_secret_… or service_role JWT); never printed
/// GAMEMETRIK_LOCAL_FROM_DAY / GAMEMETRIK_LOCAL_TO_DAY  optional, YYYY-MM-DD, TO_DAY exclusive (default: the last 3 Zurich days, today included)
/// GAMEMETRIK_LOCAL_EXPECT_DATA=1     also require at least one ads row with revenue
private enum LocalStack {
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

private final class LocalStackURLProtocol: URLProtocol, @unchecked Sendable {
    private var forwardedTask: URLSessionDataTask?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.supabase.co" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let target = LocalStack.local(url) else {
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

@Suite(.serialized, .enabled(if: LocalStack.configured, "Définir GAMEMETRIK_LOCAL_SUPABASE_URL et GAMEMETRIK_LOCAL_SUPABASE_SERVICE_KEY (stack locale uniquement)"))
struct AuroraMonetizationLocalStackTests {
    var filters: AuroraJourneyFilters {
        let zone = AuroraJourneyContract.zone, calendar = AuroraJourneyContract.calendar, today = calendar.startOfDay(for: Date())
        let from = LocalStack.environment["GAMEMETRIK_LOCAL_FROM_DAY"] ?? Dates.day(calendar.date(byAdding: .day, value: -2, to: today)!, timezone: zone)
        let to = LocalStack.environment["GAMEMETRIK_LOCAL_TO_DAY"] ?? Dates.day(calendar.date(byAdding: .day, value: 1, to: today)!, timezone: zone)
        return .init(fromDay: from, toDayExclusive: to)
    }
    var reader: AuroraJourneyReportReader {
        let project = PersonalSupabase(ref: "aurora-local", name: "Aurora Grove (local)", url: URL(string: "https://fixture.supabase.co")!,
                                       timezone: "Europe/Zurich", secret: LocalStack.environment["GAMEMETRIK_LOCAL_SUPABASE_SERVICE_KEY"] ?? "")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LocalStackURLProtocol.self]
        return .init(personal: project, http: .init(session: URLSession(configuration: config)))
    }

    @Test func realReaderDecodesTheFourReportsAndTheWholeBundle() async throws {
        let base = try #require(LocalStack.environment["GAMEMETRIK_LOCAL_SUPABASE_URL"].flatMap(URL.init(string:)))
        try #require(LocalStack.local(base) != nil, "GAMEMETRIK_LOCAL_SUPABASE_URL doit désigner une stack locale (127.0.0.1, localhost ou ::1).")
        let filters = self.filters
        print("Stack locale · période \(filters.fromDay) → \(filters.toDayExclusive) exclu")
        let ads = try await reader.ads(filters: filters)
        let boundary = ads.asOf
        let loads = try await reader.adLoads(filters: filters, asOf: boundary)
        let premium = try await reader.premium(filters: filters, asOf: boundary)
        let experiment = try await reader.experiment(filters: filters, asOf: boundary)
        #expect([loads.asOf, premium.asOf, experiment.asOf].allSatisfy { Dates.parse($0) == Dates.parse(boundary) })
        print("  as_of \(boundary) · première mesure \(ads.coverage.collectionFirstReceivedAt ?? "aucune") · jours archivés \(ads.coverage.archivedDaysInWindow)")
        print("  ads \(ads.rows.count) ligne(s) · occasions \(ads.total(\.opportunities)) · impressions \(ads.total(\.impressions)) · revenus "
              + ads.revenueTotals().map { "\($0.currency)/\($0.precision?.rawValue ?? "-") \($0.valueMicros) µ (\($0.paidEvents))" }.joined(separator: ", "))
        print("  ad_loads \(loads.rows.count) · premium \(premium.rows.count) · experiment \(experiment.rows.count) ligne(s)")
        if LocalStack.environment["GAMEMETRIK_LOCAL_EXPECT_DATA"] == "1" {
            #expect(!ads.rows.isEmpty)
            #expect(ads.rows.contains { !$0.revenue.isEmpty })
            // Revenue stays separated per currency: one total per currency, each with its own code.
            let totals = ads.revenueTotals(byPrecision: false)
            #expect(!totals.isEmpty); #expect(Set(totals.map(\.currency)).count == totals.count)
            #expect(ads.coverage.collectionFirstReceivedAt != nil)
        }

        let bundle = try await reader.bundle(filters: filters)
        #expect(bundle.errors.isEmpty, "\(bundle.errors.mapValues(\.detail))")
        #expect(bundle.stepsError == nil, "\(bundle.stepsError?.detail ?? "")")
        #expect(bundle.monetization.errors.isEmpty, "\(bundle.monetization.errors.mapValues(\.detail))")
        #expect(bundle.monetization.loadedKinds == AuroraMonetizationReportKind.allCases)
        #expect(bundle.monetization.asOf == bundle.asOf)
        // The quality report counts every received event name, the seven monetization events included.
        let names = Set(bundle.quality?.rows.flatMap(\.byEvent.keys) ?? [])
        print("  bundle : statut \(bundle.status.rawValue) · as_of \(bundle.asOf ?? "?") · événements qualité \(names.sorted().joined(separator: ", "))")
        if LocalStack.environment["GAMEMETRIK_LOCAL_EXPECT_DATA"] == "1" {
            #expect(!names.isDisjoint(with: ["ad_opportunity", "ad_load", "ad_display", "ad_reward", "ad_paid", "premium_step", "experiment_assigned"]))
        }
        var export = DataExport(mode: "Local", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "local", scope: "Parcours")
        export.addAuroraJourney(bundle); export.addAuroraMonetization(bundle.monetization)
        let json = String(decoding: try export.jsonData(), as: UTF8.self)
        for forbidden in ["installation_id", "display_id", "event_id", "session_id", "sb_secret_"] { #expect(!json.contains(forbidden), "\(forbidden)") }
    }
}
