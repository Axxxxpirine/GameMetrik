import Foundation
import Testing
@testable import GameMetrikNative
@testable import GameMetrikCore

actor ExportHTTPStub {
    static let shared = ExportHTTPStub()
    var responses: [String: (Int, Data)] = [:]
    var requests: [URLRequest] = []
    var delay: UInt64 = 0
    func setDelay(_ value: UInt64) { delay = value }
    func setResponse(_ path: String, status: Int = 200, data: Data) { responses[path] = (status, data) }
    func install(_ responses: [String: (Int, Data)]) { self.responses = responses; requests = []; delay = 0 }
    func response(_ request: URLRequest) async -> (Int, Data) {
        requests.append(request)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        let path = request.url!.path
        return responses.sorted { $0.key.count > $1.key.count }.first { path.hasSuffix($0.key) }?.value ?? (500, Data())
    }
}
private final class ExportURLProtocol: URLProtocol, @unchecked Sendable {
    var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        responseTask = Task {
            let (status, data) = await ExportHTTPStub.shared.response(request)
            guard !Task.isCancelled else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Range": "*/0"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}
extension AppStateTests {
@Suite(.serialized) @MainActor struct ExportPreparationTests {
    func document(_ object: [String: Any]) -> [String: Any] {
        func field(_ value: Any) -> [String: Any] {
            if let value = value as? String { return ["stringValue": value] }
            if let value = value as? [String: Any] { return ["mapValue": ["fields": value.mapValues(field)]] }
            if let value = value as? [Any] { return ["arrayValue": ["values": value.map(field)]] }
            if let value = value as? NSNumber {
                if CFGetTypeID(value) == CFBooleanGetTypeID() { return ["booleanValue": value.boolValue] }
                return ["doubleValue": value.doubleValue]
            }
            return ["nullValue": NSNull()]
        }
        return ["name": "fixture/document", "fields": object.mapValues(field)]
    }
    func encodedDocument<T: Encodable>(_ value: T) throws -> [String: Any] {
        document(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any])
    }
    func setup(playerStatus: Int = 200, reviewStatus: Int = 200) async throws -> AppState {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExportURLProtocol.self]
        let state = AppState(http: HTTPClient(session: URLSession(configuration: config)))
        state.isLocked = false; state.demo = false; state.accessMode = "member"
        state.destination = .dashboard; state.gameID = "aurora-grove"; state.range = .week
        state.config = .init(apiKey: "fixture", projectID: "fixture", clientID: "fixture", callbackScheme: "fixture", organizationID: "org")
        state.session = .init(uid: "user", email: "fixture@example.test", idToken: "fixture-token", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3600))
        state.membership = .init(organization: "org", role: "owner"); state.games = Demo.games
        state.supabaseProjects = [.init(ref: "aurora-grove", url: URL(string: "https://fixture.supabase.co")!, publishableKey: "sb_publishable_fixture_only", timezone: "Europe/Zurich")]
        func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        await ExportHTTPStub.shared.install(try [
            "/users/user": (200, data(document(["organizationIds": ["org"]]))),
            "/members/user": (200, data(document(["role": "owner"]))),
            "/games": (200, data(["documents": [encodedDocument(Demo.games[0])]])),
            "/dashboardSnapshots/7d": (200, data(encodedDocument(Demo.dashboard(range: .week, gameID: "aurora-grove")))),
            "/reviews": (reviewStatus, data(["documents": []])),
            "/profiles": (playerStatus, Data("[]".utf8)),
            "/completion_events": (playerStatus, Data("[]".utf8)),
            "/purchase_entitlements": (200, Data("[]".utf8)),
            "/premium_grants": (200, Data("[]".utf8))
        ])
        return state
    }
    @Test func allViewsUseAuthorizedReadsAndEmptyIsDifferentFromMissing() async throws {
        let state = try await setup()
        await state.refresh(forExport: true)?.value
        #expect(state.error == nil); #expect(state.canExport)
        let report = try state.makeExport(scope: .available)
        #expect(report.missingViews.isEmpty)
        #expect(report.checks.contains { $0.section == "Avis" && $0.status == "empty" })
        #expect(report.checks.contains { $0.section == "Gameplay et joueurs" && $0.status == "empty" })
        let requests = await ExportHTTPStub.shared.requests
        #expect(requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" })
        #expect(requests.contains { $0.url?.path.hasSuffix("/reviews") == true })
        state.lock()
    }
    @Test func exportActionLoadsMissingViewsFromDashboardBeforeSaving() async throws {
        let state = try await setup()
        await state.refresh()?.value
        #expect(state.canExport); #expect(state.exportHasUnreadViews)
        #expect(!(try state.makeExport(scope: .available)).tables.contains { $0.id == "joueurs" })
        try await state.prepareRequestedExport(scope: .available)
        let report = try state.makeExport(scope: .available)
        #expect(report.missingViews.isEmpty)
        #expect(report.tables.contains { $0.id == "joueurs" })
        #expect(report.tables.contains { $0.id == "gameplay_resume" })
        #expect(state.destination == .dashboard)
        let requestCount = await ExportHTTPStub.shared.requests.count
        try await state.prepareRequestedExport(scope: .available)
        #expect(await ExportHTTPStub.shared.requests.count == requestCount)
        state.lock()
    }
    @Test func missingPlayerReadBlocksCompleteExportAndRequiresExplicitPartialChoice() async throws {
        let state = try await setup(playerStatus: 500)
        await state.refresh()?.value
        await #expect(throws: GameMetrikError.self) {
            try await state.prepareRequestedExport(scope: .available)
        }
        #expect(state.exportReadFailures.contains { $0.section == "Gameplay et joueurs" && $0.status == "failed" })
        let requests = await ExportHTTPStub.shared.requests.count
        try await state.prepareRequestedExport(scope: .available, allowIncomplete: true)
        #expect(await ExportHTTPStub.shared.requests.count == requests)
        #expect((try state.makeExport(scope: .available)).missingViews.contains("Gameplay et joueurs"))
        state.lock()
    }
    @Test func currentViewAndExplicitPartialChoiceDoNotTriggerNetworkReads() async throws {
        let state = try await setup()
        await state.refresh()?.value
        let requests = await ExportHTTPStub.shared.requests.count
        try await state.prepareRequestedExport(scope: .current)
        try await state.prepareRequestedExport(scope: .available, allowIncomplete: true)
        #expect(await ExportHTTPStub.shared.requests.count == requests)
        state.lock()
    }
    @Test func accessRefusalCannotBeBypassedWithPartialExport() async throws {
        let state = try await setup(playerStatus: 403)
        await state.refresh()?.value
        await #expect(throws: GameMetrikError.self) { try await state.prepareRequestedExport(scope: .available) }
        await #expect(throws: GameMetrikError.self) { try await state.prepareRequestedExport(scope: .available, allowIncomplete: true) }
        #expect(!state.canExport)
        state.lock()
    }
    @Test func cancelledExportActionDoesNotAdvanceToSaving() async throws {
        let state = try await setup()
        await state.refresh()?.value
        await ExportHTTPStub.shared.setDelay(100_000_000)
        let action = Task { @MainActor in
            try await state.prepareRequestedExport(scope: .available)
        }
        while !state.preparingExport { await Task.yield() }
        state.cancelRefresh()
        await #expect(throws: CancellationError.self) { try await action.value }
        #expect(!state.preparingExport)
        #expect(state.localViews[state.localViewKey(for: .players)] == nil)
        state.lock()
    }
    @Test func sourceFailureContinuesOtherViewsAndPreservesOldReadDate() async throws {
        let state = try await setup(playerStatus: 500)
        let old = Date().addingTimeInterval(-86400)
        state.localViews[state.localViewKey(for: .players)] = .init(dashboard: nil, directory: try Demo.directory(range: .week, game: Demo.games[0], now: old), reviews: [], date: old)
        await state.refresh(forExport: true)?.value
        let report = try state.makeExport(scope: .available)
        #expect(state.error == nil)
        #expect(report.tables.first { $0.id == "joueurs" }?.generatedAt == Dates.iso(old))
        #expect(report.checks.contains { $0.section == "Synchronisation · Gameplay et joueurs" && $0.status == "failed" })
        #expect(report.checks.contains { $0.section == "Avis" && $0.status == "empty" })
        state.lock()
    }
    @Test func refusedAccessPurgesPriorDataAndStopsExport() async throws {
        let state = try await setup(playerStatus: 403)
        await state.refresh(forExport: true)?.value
        #expect(!state.canExport); #expect(state.error != nil)
        #expect(state.localViews.isEmpty); #expect(state.dashboard == nil); #expect(state.directory == nil)
        #expect(!(await ExportHTTPStub.shared.requests).contains { $0.url?.path.hasSuffix("/reviews") == true })
        state.lock()
    }
    @Test func failedCurrentReviewsAreNotReportedAsAnEmptyCollection() async throws {
        let state = try await setup(reviewStatus: 500); state.destination = .reviews
        await state.refresh(forExport: true)?.value
        let report = try state.makeExport(scope: .available)
        #expect(report.missingViews.contains("Avis"))
        #expect(!report.checks.contains { $0.section == "Avis" && $0.status == "empty" })
        state.lock()
    }
}

}
