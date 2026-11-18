import Foundation
import Testing
@testable import GameMetrikCore

private actor BallparkStubStore {
    static let shared = BallparkStubStore()
    typealias Handler = @Sendable (URLRequest) throws -> Data
    private var handler: Handler?
    private(set) var requests: [URLRequest] = []

    func install(_ handler: @escaping Handler) { self.handler = handler; requests = [] }
    func response(to request: URLRequest) throws -> Data {
        requests.append(request)
        guard let handler else { throw URLError(.unsupportedURL) }
        return try handler(request)
    }
}

private final class BallparkURLProtocol: URLProtocol, @unchecked Sendable {
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
            captured.httpBodyStream = nil
            captured.httpBody = data
        }
        let incoming = captured
        responseTask = Task { @Sendable in
            do {
                let data = try await BallparkStubStore.shared.response(to: incoming)
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}

@Suite(.serialized) struct BallparkReportsTests {
    private var reader: BallparkReportReader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BallparkURLProtocol.self]
        let project = PersonalSupabase(
            ref: "ballpark", name: "Ballpark", url: URL(string: "https://ballpark.supabase.co")!,
            timezone: "Europe/Zurich", secret: "sb_secret_test_credential_long_enough"
        )
        return BallparkReportReader(personal: project, http: HTTPClient(session: URLSession(configuration: configuration)))
    }

    private var filters: BallparkReportFilters {
        BallparkReportFilters(fromDay: "2026-09-19", toDayExclusive: "2026-09-21")
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func page<Row: Encodable>(_ kind: BallparkReportKind, rows: [Row]) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: fixture("ballpark-overview-page-2")) as? [String: Any])
        object["report"] = kind.rawValue
        object["day_basis"] = [BallparkReportKind.overview, .habits, .quality].contains(kind) ? "civil" : "game_09"
        object["rows"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows))
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func personalRPCPaginatesWithFixedContextAndPreservesServerAggregates() async throws {
        let page1 = try fixture("ballpark-overview-page-1")
        let page2 = try fixture("ballpark-overview-page-2")
        await BallparkStubStore.shared.install { request in
            #expect(request.url?.path == "/rest/v1/rpc/gamemetrik_ballpark_report_v1")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "apikey") == "sb_secret_test_credential_long_enough")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let requestData = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            let payload = try #require(body["p_request"] as? [String: Any])
            #expect(Set(payload.keys) == ["contract_version", "report", "from_day", "to_day_exclusive", "mode", "locale", "app_version", "include_test_accounts", "limit", "cursor"])
            #expect(payload["contract_version"] as? Int == 1)
            #expect(payload["report"] as? String == "overview")
            #expect(payload["include_test_accounts"] as? Bool == false)
            #expect(payload["limit"] as? Int == 1)
            return payload["cursor"] is NSNull ? page1 : page2
        }

        let report = try await reader.overview(filters: filters, limit: 1)
        #expect(report.pageCount == 2)
        #expect(report.rows.map(\.day) == ["2026-09-19", "2026-09-20"])
        #expect(report.coverage.participantsMeasured == 10)
        #expect(report.coverage.completeDuration.value == 0.8)
        #expect(await BallparkStubStore.shared.requests.count == 2)
    }

    @Test func changedAsOfDuringPaginationIsRejected() async throws {
        let page1 = try fixture("ballpark-overview-page-1")
        var object = try #require(JSONSerialization.jsonObject(with: fixture("ballpark-overview-page-2")) as? [String: Any])
        object["as_of"] = "2026-09-21T10:00:01Z"
        let changed = try JSONSerialization.data(withJSONObject: object)
        await BallparkStubStore.shared.install { request in
            let requestData = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            let payload = try #require(body["p_request"] as? [String: Any])
            return payload["cursor"] is NSNull ? page1 : changed
        }
        await #expect(throws: BallparkReportError.self) {
            try await reader.overview(filters: filters, limit: 1)
        }
    }

    @Test func rejectsInvalidWindowBeforeNetworkAccess() async {
        await BallparkStubStore.shared.install { _ in Issue.record("Unexpected network request"); return Data() }
        let invalid = BallparkReportFilters(fromDay: "2026-02-30", toDayExclusive: "2026-03-02")
        await #expect(throws: BallparkReportError.self) { try await reader.overview(filters: invalid) }
        #expect(await BallparkStubStore.shared.requests.isEmpty)
    }

    @Test func rejectsWrongReportAndDayBasis() async throws {
        var object = try #require(JSONSerialization.jsonObject(with: fixture("ballpark-overview-page-2")) as? [String: Any])
        object["report"] = "questions"
        object["day_basis"] = "game_09"
        let wrong = try JSONSerialization.data(withJSONObject: object)
        await BallparkStubStore.shared.install { _ in wrong }
        await #expect(throws: BallparkReportError.self) { try await reader.overview(filters: filters) }
    }

    @Test func decodesEveryClosedReportRowShape() async throws {
        let demo = BallparkDemo.bundle
        let pages: [String: Data] = [
            "questions": try page(.questions, rows: demo.questions.rows),
            "series": try page(.series, rows: demo.series.rows),
            "habits": try page(.habits, rows: demo.habits.rows),
            "quality": try page(.quality, rows: demo.quality.rows)
        ]
        await BallparkStubStore.shared.install { request in
            let requestData = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            let payload = try #require(body["p_request"] as? [String: Any])
            return try #require(pages[payload["report"] as? String ?? ""])
        }
        let questions = try await reader.questions(filters: filters)
        let series = try await reader.series(filters: filters)
        let habits = try await reader.habits(filters: filters)
        let quality = try await reader.quality(filters: filters)
        #expect(questions.rows[0].reference == "5972000000000000000000000")
        #expect(series.rows[0].questions.count == 3)
        #expect(habits.rows.filter { if case .day = $0 { true } else { false } }.count == 7)
        #expect(habits.rows.filter { if case .week = $0 { true } else { false } }.count == 1)
        #expect(habits.rows.filter { if case .hour = $0 { true } else { false } }.count == 5)
        #expect(quality.rows[0].knownLostEvents.reason == .notInstrumented)
    }
    @Test func unreadableRowsAreDiscardedAndCountedInsteadOfRejectingTheReport() async throws {
        let demo = BallparkDemo.bundle
        var questions = try #require(JSONSerialization.jsonObject(with: page(.questions, rows: demo.questions.rows)) as? [String: Any])
        var rows = try #require(questions["rows"] as? [[String: Any]])
        rows[0]["prompt"] = NSNull()
        rows[0]["unit"] = NSNull()
        rows.append(["question_id": "truncated-row"])
        questions["rows"] = rows
        var coverage = try #require(questions["coverage"] as? [String: Any])
        coverage["warnings"] = ["v1_partial_coverage", "warning_from_a_later_server"]
        questions["coverage"] = coverage

        var series = try #require(JSONSerialization.jsonObject(with: page(.series, rows: demo.series.rows)) as? [String: Any])
        var seriesRows = try #require(series["rows"] as? [[String: Any]])
        var party = seriesRows[0]
        let template = try #require((party["questions"] as? [[String: Any]])?.first)
        party["mode"] = "party"
        party["series_id"] = "party-series"
        party["questions"] = (1...6).map { position in
            var question = template
            question["position"] = position
            question["question_id"] = "party-q\(position)"
            return question
        }
        seriesRows.append(party)
        series["rows"] = seriesRows

        let pages: [String: Data] = [
            "questions": try JSONSerialization.data(withJSONObject: questions),
            "series": try JSONSerialization.data(withJSONObject: series)
        ]
        await BallparkStubStore.shared.install { request in
            let requestData = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            let payload = try #require(body["p_request"] as? [String: Any])
            return try #require(pages[payload["report"] as? String ?? ""])
        }
        let questionReport = try await reader.questions(filters: filters)
        #expect(questionReport.rows.count == demo.questions.rows.count)
        #expect(questionReport.discardedRows == 1)
        #expect(questionReport.rows[0].prompt.isEmpty && questionReport.rows[0].unit.isEmpty)
        #expect(questionReport.coverage.warnings == [.v1PartialCoverage, .unrecognized])

        let seriesReport = try await reader.series(filters: filters)
        #expect(seriesReport.discardedRows == 0)
        let partyRow = try #require(seriesReport.rows.first { $0.seriesID == "party-series" })
        #expect(partyRow.mode == .party)
        #expect(partyRow.questions.count == 6)
    }
}


extension BallparkReportsTests {
    @Test func partyHabitsRemainUnknownOnOldServerAndArePreservedWhenAvailable() async throws {
        let old = try page(.habits, rows: BallparkDemo.bundle.habits.rows)
        var object = try #require(JSONSerialization.jsonObject(with: old) as? [String:Any])
        var rows = try #require(object["rows"] as? [[String:Any]])
        for index in rows.indices where rows[index]["row_type"] as? String == "day" {
            rows[index]["party_participations"] = 2
        }
        object["rows"] = rows
        let updated = try JSONSerialization.data(withJSONObject: object)
        await BallparkStubStore.shared.install { _ in old }
        let original = try await reader.habits(filters: filters)
        #expect(original.rows.compactMap { if case .day(let row) = $0 { row.partyParticipations } else { nil } }.isEmpty)
        await BallparkStubStore.shared.install { _ in updated }
        let report = try await reader.habits(filters: filters)
        #expect(report.discardedRows == 0)
        #expect(report.rows.compactMap { if case .day(let row) = $0 { row.partyParticipations } else { nil } } == Array(repeating:2,count:7))
        #expect(BallparkReportMode.party.rawValue == "party")
    }
}
