import Foundation
import Testing
@testable import GameMetrikNative
@testable import GameMetrikCore

private actor BallparkSyncServer {
    static let shared = BallparkSyncServer()
    var requests: [URLRequest] = []
    var failure: (String, Int)?
    func reset(failure: (String, Int)? = nil) { requests = []; self.failure = failure }
    func response(_ request: URLRequest) throws -> (Int, Data) {
        requests.append(request)
        guard request.url?.host == "ballpark-fixture.supabase.co",
              request.url?.path == "/rest/v1/rpc/gamemetrik_ballpark_report_v1",
              let body = request.httpBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let input = json["p_request"] as? [String: Any], let kind = input["report"] as? String else {
            return (403, Data()) // Firebase and all other providers are deliberately unavailable.
        }
        if let failure, failure.0 == kind { return (failure.1, Data()) }
        var envelope = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BallparkDemo.bundle.overview)) as! [String: Any]
        for (local, wire) in [("contractVersion", "contract_version"), ("generatedAt", "generated_at"), ("asOf", "as_of")] {
            envelope[wire] = envelope.removeValue(forKey: local)
        }
        envelope["report"] = kind
        envelope["day_basis"] = ["questions", "series"].contains(kind) ? "game_09" : "civil"
        envelope["filters"] = input.filter { ["from_day", "to_day_exclusive", "mode", "locale", "app_version", "include_test_accounts"].contains($0.key) }
        envelope["rows"] = []
        envelope["next_cursor"] = NSNull()
        return (200, try JSONSerialization.data(withJSONObject: envelope))
    }
}

private final class BallparkSyncProtocol: URLProtocol, @unchecked Sendable {
    var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        responseTask = Task {
            do {
                // URLSession may expose the POST body as a stream to URLProtocol.
                var copy = request
                if copy.httpBody == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }; data.append(buffer, count: count)
                    }
                    copy.httpBody = data
                }
                let (status, data) = try await BallparkSyncServer.shared.response(copy)
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}

extension AppStateTests {
@Suite(.serialized) @MainActor struct BallparkDirectSyncTests {
    private func worker() -> AppState {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BallparkSyncProtocol.self]
        let state = AppState(http: HTTPClient(session: URLSession(configuration: configuration)), headless: true)
        let connections = PersonalConnections(projectID: "fixture",
            firebase: .init(project_id: "fixture", client_email: "fixture@example.invalid", private_key: "intentionally unusable"),
            supabase: [.init(ref: Game.ballparkProjectRef, name: "Ballpark", url: URL(string: "https://ballpark-fixture.supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_synthetic_only")], importedAt: Date(), notes: [])
        state.startHeadless(.init(connections: connections, organization: "fixture", cacheKey: Data(repeating: 42, count: 32), token: String(repeating: "a", count: 64)))
        state.gameID = Game.ballpark.id; state.destination = .dashboard
        return state
    }

    @Test func firstBallparkSyncLoadsFiveReportsWithoutFirebaseOrStudioAndKeepsWindowPreferences() async throws {
        let defaults = UserDefaults.standard, bookmark = defaults.object(forKey: AppState.aiFolderBookmarkKey)
        let game = defaults.object(forKey: "live.game"), range = defaults.object(forKey: "live.range")
        defaults.removeObject(forKey: AppState.aiFolderBookmarkKey)
        defer { defaults.set(bookmark, forKey: AppState.aiFolderBookmarkKey) }
        await BallparkSyncServer.shared.reset()
        let state = worker(); defer { state.lock() }
        #expect(state.games.isEmpty)
        for period in [Timeframe.week, .month, .quarter] {
            state.range = period
            await state.synchronizeSelection()?.value
            #expect(state.error == nil)
            #expect(state.gameID == Game.ballpark.id)
            #expect(state.destination == .ballpark)
            #expect(state.ballparkAnalytics?.loadedKinds.count == 5)
            #expect(state.studioSyncResults.count == 1)
            #expect(state.studioSyncResults.first?.status == "loaded")
        }
        let requests = await BallparkSyncServer.shared.requests
        #expect(requests.count == 15)
        #expect(requests.allSatisfy { $0.url?.host == "ballpark-fixture.supabase.co" })
        #expect(defaults.object(forKey: "live.game") as? String == game as? String)
        #expect(defaults.object(forKey: "live.range") as? String == range as? String)
    }

    @Test func missingReportIsPartialAndAccessDenialClearsProtectedReports() async throws {
        let defaults = UserDefaults.standard, bookmark = defaults.object(forKey: AppState.aiFolderBookmarkKey)
        defaults.removeObject(forKey: AppState.aiFolderBookmarkKey)
        defer { defaults.set(bookmark, forKey: AppState.aiFolderBookmarkKey) }
        let state = worker(); defer { state.lock() }; state.range = .week
        await BallparkSyncServer.shared.reset(failure: ("quality", 500))
        await state.synchronizeSelection()?.value
        #expect(state.error == nil)
        #expect(state.ballparkAnalytics?.loadedKinds.count == 4)
        #expect(state.studioSyncResults.first?.status == "partial")
        await BallparkSyncServer.shared.reset(failure: ("overview", 403))
        await state.synchronizeSelection()?.value
        #expect(state.error != nil)
        #expect(state.ballparkAnalytics == nil)
        #expect(state.localViews.isEmpty)
    }
}
}
