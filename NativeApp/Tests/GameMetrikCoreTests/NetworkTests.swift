import Foundation
import Testing
import CryptoKit
@testable import GameMetrikCore

private actor Stub {
    static let shared = Stub()
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data, [String: String])
    var handler: Handler?
    var requests: [URLRequest] = []
    func install(_ handler: @escaping Handler) { self.handler = handler; requests = [] }
    func response(_ request: URLRequest) async throws -> (Int, Data, [String: String]) {
        requests.append(request)
        guard let handler else { throw URLError(.unsupportedURL) }
        return try await handler(request)
    }
}
private final class ProtocolStub: URLProtocol, @unchecked Sendable {
    var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBodyStream = nil; captured.httpBody = data
        }
        let incoming = captured
        responseTask = Task {
            do {
                let (status, data, headers) = try await Stub.shared.response(incoming)
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}
private actor ResponseGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []
    func arrive() async {
        started = true; startWaiters.forEach { $0.resume() }; startWaiters = []
        if !released { await withCheckedContinuation { responseWaiters.append($0) } }
    }
    func waitForStart() async {
        if !started { await withCheckedContinuation { startWaiters.append($0) } }
    }
    func release() { released = true; responseWaiters.forEach { $0.resume() }; responseWaiters = [] }
}
@Suite(.serialized) struct NetworkTests {
    var http: HTTPClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProtocolStub.self]
        return HTTPClient(session: URLSession(configuration: config))
    }
    var supabase: SupabaseReader {
        SupabaseReader(config: .init(ref: "test", url: URL(string: "https://test.supabase.co")!, publishableKey: "sb_publishable_test_long_enough", timezone: "Europe/Zurich"), token: "firebase-test", http: http)
    }
    @Test func clearingTokensRejectsAResponseAlreadyInFlight() async throws {
        let gate = ResponseGate()
        let (account, _) = try PersonalConnectionsTests().keyPair()
        let tokens = ServiceAccountTokens()
        await Stub.shared.install { _ in
            await gate.arrive()
            return (200, Data(#"{"access_token":"late-token","expires_in":3600}"#.utf8), [:])
        }
        let request = Task { try await tokens.token(account: account, scopes: ["test"], http: http) }
        await gate.waitForStart()
        await tokens.clear()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        let fresh = try await tokens.token(account: account, scopes: ["test"], http: http)
        #expect(fresh == "late-token")
        #expect(await Stub.shared.requests.count == 2)
    }
    @Test func connectionChecksSeparateProviderFailuresAndDoNotSync() async throws {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        let connections = PersonalConnections(projectID: "test-project", firebase: account, supabase: [], admob: PersonalAdMob(clientID: "test", clientSecret: "test-secret", refreshToken: "test-refresh", publisherID: "pub-123"), apple: PersonalApple(issuerID: "issuer", keyID: "key", privateKey: nil, vendor: nil), googlePlay: account, googlePlayReportBucket: nil, importedAt: Date(), notes: [])
        await Stub.shared.install { request in
            switch request.url!.host! {
            case "oauth2.googleapis.com":
                #expect(request.httpMethod == "POST")
                return (200, Data(#"{"access_token":"test-access","expires_in":3600}"#.utf8), [:])
            case "firestore.googleapis.com":
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access")
                return (200, Data(#"{"documents":[{"name":"organizations/org"}]}"#.utf8), [:])
            case "admob.googleapis.com":
                #expect(request.httpMethod == "GET")
                #expect(request.url!.path == "/v1/accounts/pub-123/apps")
                return (200, Data(#"{"apps":[{}]}"#.utf8), [:])
            case "playdeveloperreporting.googleapis.com": return (403, Data(), [:])
            default: Issue.record("Unexpected provider call"); return (500, Data(), [:])
            }
        }
        let result = await ConnectionChecks.run(connections, http: http)
        #expect(result.count == 4)
        #expect(result.first { $0.id == "firebase" }?.success == true)
        #expect(result.first { $0.id == "admob" }?.success == true)
        #expect(result.first { $0.id == "googlePlay" }?.success == false)
        #expect(result.first { $0.id == "apple" }?.success == false)
        #expect(!result.map(\.detail).joined().contains("test-secret"))
    }
    @Test func personalSecretNeverBecomesFirebaseBearer() async throws {
        await Stub.shared.install { request in
            #expect(request.value(forHTTPHeaderField: "apikey") == "sb_secret_test_credential_long_enough")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, Data("[]".utf8), ["Content-Range": "*/0"])
        }
        let project = PersonalSupabase(ref: "test", name: "Test", url: URL(string: "https://test.supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_test_credential_long_enough")
        let values: [Int] = try await SupabaseReader(personal: project, http: http).rows("profiles", select: "value", order: "value")
        #expect(values.isEmpty)
    }
    @Test func legacyPersonalKeyUsesServiceBearer() async throws {
        let secret = "header." + JWTEncoding.encode(Data(#"{"role":"service_role"}"#.utf8)) + ".signature"
        await Stub.shared.install { request in
            #expect(request.value(forHTTPHeaderField: "apikey") == secret)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + secret)
            return (200, Data("[]".utf8), ["Content-Range": "*/0"])
        }
        let project = PersonalSupabase(ref: "test", name: "Test", url: URL(string: "https://test.supabase.co")!, timezone: "Europe/Zurich", secret: secret)
        let _: [Int] = try await SupabaseReader(personal: project, http: http).rows("profiles", select: "value", order: "value")
    }
    @Test func shortServerPagesAreNotTruncated() async throws {
        await Stub.shared.install { request in
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "offset" }!.value!
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer firebase-test")
            #expect(request.value(forHTTPHeaderField: "apikey")?.hasPrefix("sb_publishable_") == true)
            let n = Int(offset)!
            return (206, Data("[{\"value\":\(n)}]".utf8), ["Content-Range": "\(n)-\(n)/3"])
        }
        struct Row: Decodable { var value: Int }
        let rows: [Row] = try await supabase.rows("profiles", select: "value", order: "value.asc")
        #expect(rows.map(\.value) == [0, 1, 2])
        #expect(await Stub.shared.requests.count == 3)
    }
    @Test func missingCountContinuesToEmptyPage() async throws {
        await Stub.shared.install { request in
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "offset" }!.value!
            return (200, Data((offset == "0" ? "[1]" : "[]").utf8), ["Content-Range": "0-0/*"])
        }
        let rows: [Int] = try await supabase.rows("profiles", select: "value", order: "value.asc")
        #expect(rows == [1]); #expect(await Stub.shared.requests.count == 2)
    }
    @Test func missingRowsWithKnownTotalFail() async {
        await Stub.shared.install { _ in (200, Data("[]".utf8), ["Content-Range": "*/3"]) }
        await #expect(throws: GameMetrikError.self) {
            let _: [Int] = try await supabase.rows("profiles", select: "value", order: "value.asc")
        }
    }
    @Test func firestoreDecodesNestedAndNullValues() throws {
        let json = #"{"name":"projects/p/databases/(default)/documents/games/g","fields":{"name":{"stringValue":"Test"},"count":{"integerValue":"3"},"missing":{"nullValue":null},"items":{"arrayValue":{"values":[{"mapValue":{"fields":{"active":{"booleanValue":true}}}}]}}}}"#
        struct Row: Decodable { struct Item: Decodable { var active: Bool }; var id: String; var name: String; var count: Int; var missing: Double?; var items: [Item] }
        let document = try JSONDecoder().decode(FireDocument.self, from: Data(json.utf8))
        let row = try document.decode(Row.self)
        #expect(row.id == "g"); #expect(row.count == 3); #expect(row.missing == nil); #expect(row.items[0].active)
    }
    @Test func firestoreReadsEveryPageWithAuthHeader() async throws {
        await Stub.shared.install { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer id-token")
            let next = request.url!.query?.contains("pageToken") == true
            let id = next ? "b" : "a"
            let more = next ? "" : ",\"nextPageToken\":\"next\""
            return (200, Data("{\"documents\":[{\"name\":\"games/\(id)\",\"fields\":{\"name\":{\"stringValue\":\"\(id)\"}}}]\(more)}".utf8), [:])
        }
        struct Row: Decodable { var id: String }
        let rows: [Row] = try await Firestore(project: "project", token: "id-token", http: http).list(["organizations", "org", "games"])
        #expect(rows.map(\.id) == ["a", "b"])
    }
    @Test func deniedMembershipNeverProducesAnAuthorizedMember() async {
        await Stub.shared.install { request in
            if request.url!.path.contains("/users/") { return (200, Data(#"{"name":"users/u","fields":{"organizationIds":{"arrayValue":{"values":[{"stringValue":"org"}]}}}}"#.utf8), [:]) }
            return (403, Data(), [:])
        }
        await #expect(throws: GameMetrikError.http(403)) { try await Firestore(project: "project", token: "id-token", http: http).membership(uid: "u", preferredOrganization: nil) }
    }
    @Test func authorizationFailureNeverBecomesEmptyResults() async {
        await Stub.shared.install { _ in (401, Data(), [:]) }
        await #expect(throws: GameMetrikError.http(401)) {
            let _: [Int] = try await supabase.rows("profiles", select: "value", order: "value.asc")
        }
    }
    @Test func purchasesAndGrantsAreUnioned() async throws {
        await Stub.shared.install { request in
            let url = request.url!
            let profile = #"[{"user_id":"00000000-0000-4000-8000-000000000001","public_id":"20000000-0000-4000-8000-000000000001","display_name":"Test","adventure_step":1}]"#
            let data = url.path.hasSuffix("profiles") ? profile : url.path.hasSuffix("premium_grants") ? #"[{"user_id":"00000000-0000-4000-8000-000000000001"}]"# : "[]"
            return (200, Data(data.utf8), ["Content-Range": data == "[]" ? "*/0" : "0-0/1"])
        }
        let directory = try await supabase.directory(game: Demo.games[0], range: .month)
        #expect(directory.players[0].jardinPaisible == true)
        #expect(await Stub.shared.requests.contains { $0.url!.path.hasSuffix("purchase_entitlements") })
    }
    @Test func entitlementFailureLeavesUnknownStatus() async throws {
        await Stub.shared.install { request in
            if request.url!.path.hasSuffix("profiles") {
                return (200, Data(#"[{"user_id":"00000000-0000-4000-8000-000000000001","public_id":"20000000-0000-4000-8000-000000000001","display_name":null,"adventure_step":1}]"#.utf8), ["Content-Range": "0-0/1"])
            }
            if request.url!.path.hasSuffix("completion_events") { return (200, Data("[]".utf8), ["Content-Range": "*/0"]) }
            return (403, Data(), [:])
        }
        let data = try await supabase.directory(game: Demo.games[0], range: .week)
        #expect(data.players[0].jardinPaisible == nil); #expect(data.entitlementNote != nil)
    }
    @Test func cancelledRequestDoesNotReturnData() async {
        await Stub.shared.install { _ in (200, Data("[]".utf8), [:]) }
        let task = Task { try Task.checkCancellation(); return try await supabase.rows("profiles", select: "value", order: "value", as: Int.self) }
        task.cancel()
        do { _ = try await task.value; Issue.record("A cancelled request returned data") }
        catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
}

extension NetworkTests {
    @Test func studioCollectionBuildsEveryGameAndActivePortfolioFromOneReadPerGame() async throws {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        let now = Dates.parse("2026-09-20T12:00:00Z")!
        var active = Demo.games[0]; active.integrations.supabaseProjectRef = "active"; active.platforms = []
        var archived = Demo.games[1]; archived.integrations.supabaseProjectRef = "archived"; archived.platforms = []; archived.status = "archived"
        let projects = ["active", "archived"].map { PersonalSupabase(ref: $0, name: $0, url: URL(string: "https://\($0).supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_test_credential_long_enough") }
        let connections = PersonalConnections(projectID: "test", firebase: account, supabase: projects, importedAt: now, notes: [])
        await Stub.shared.install { request in
            #expect(request.url?.path == "/rest/v1/completion_events")
            let count = request.url?.host == "active.supabase.co" ? 1 : 2
            let events = (0..<count).map { _ in ["user_id": UUID().uuidString, "run_id": UUID().uuidString, "completed_at": Dates.iso(now.addingTimeInterval(-60))] }
            return (200, try JSONSerialization.data(withJSONObject: events), ["Content-Range": "*/\(count)"])
        }
        var cache = AggregateCache()
        let studio = try await NativeDashboardSync(http: http).runCached(games: [active, archived], gameID: nil, range: .week, connections: connections, cache: &cache, entireStudio: true, now: now, googlePlayGameIDs: [])
        #expect(await Stub.shared.requests.count == 2)
        #expect(studio.gameId == nil)
        #expect(studio.trend.last?.players == 1)
        #expect(cache.snapshot(gameID: active.id, range: .week)?.trend.last?.players == 1)
        #expect(cache.snapshot(gameID: archived.id, range: .week)?.trend.last?.players == 2)
        #expect(cache.snapshot(gameID: archived.id, range: .week)?.alerts.allSatisfy { $0.id.hasPrefix(archived.id + ".") } == true)
        #expect(studio.alerts.allSatisfy { $0.id.hasPrefix(active.id + ".") })
        let persisted = String(decoding: try JSONEncoder().encode(cache), as: UTF8.self)
        #expect(!persisted.contains("user_id")); #expect(!persisted.contains("run_id"))
    }
    @Test func nativeSyncBackfillsAllThirtyDaysAndContinuesWithoutAppleKey() async throws {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        var game = Demo.games[0]; game.integrations.admobAppIds = ["ca-app-pub-123~123"]; game.integrations.appleAppId = "123"; game.integrations.supabaseProjectRef = "test"; game.integrations.googlePackageName = "com.test.unpublished"; game.platforms = ["ios", "android"]
        let connections = PersonalConnections(projectID:"test-project",firebase:account,supabase:[PersonalSupabase(ref:"test",name:"Test",url:URL(string:"https://test.supabase.co")!,timezone:"Europe/Zurich",secret:"sb_secret_test_credential_long_enough")],admob:PersonalAdMob(clientID:"test",clientSecret:"test-secret",refreshToken:"test-refresh",publisherID:"pub-123"),apple:PersonalApple(issuerID:"issuer",keyID:"key",privateKey:nil,vendor:"123"),importedAt:Date(),notes:[])
        await Stub.shared.install { request in
            let url = request.url!
            if url.host == "oauth2.googleapis.com" { return (200,Data(#"{"access_token":"test"}"#.utf8),[:]) }
            if url.path.hasSuffix("networkReport:generate") {
                let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
                let spec = body["reportSpec"] as! [String:Any]
                #expect(spec["dimensionFilters"] != nil)
                #expect(spec["dimensions"] as? [String] == ["DATE", "APP", "COUNTRY", "PLATFORM"])
                #expect(spec["metrics"] as? [String] == ["ESTIMATED_EARNINGS", "IMPRESSIONS"])
                #expect(spec["timeZone"] == nil, "AdMob rejects explicit non-Pacific time zones; omit to use the account default.")
                return (200,try JSONSerialization.data(withJSONObject:[["header":["localizationSettings":["currencyCode":"CHF"],"dateRange":spec["dateRange"]!]],["footer":["matchingRowCount":"0"]]]),[:])
            }
            if url.path.hasSuffix("/apps") { return (200,Data(#"{"apps":[{"appId":"ca-app-pub-123~123"}]}"#.utf8),[:]) }
            if url.host == "admob.googleapis.com" { return (200,Data(#"{"reportingTimeZone":"Europe/Zurich"}"#.utf8),[:]) }
            if url.host == "test.supabase.co" {
                #expect(url.path == "/rest/v1/completion_events")
                #expect(request.value(forHTTPHeaderField:"apikey") == "sb_secret_test_credential_long_enough")
                return (200,Data("[]".utf8),["Content-Range":"*/0"])
            }
            Issue.record("Unexpected endpoint"); throw URLError(.unsupportedURL)
        }
        let result = try await NativeDashboardSync(http:http).run(games:[game],gameID:game.id,range:.month,connections:connections,now:Dates.parse("2026-09-07T12:00:00Z")!,googlePlayGameIDs:[])
        #expect(!result.alerts.contains { $0.id.contains("google-") })
        #expect(!result.kpis.contains { $0.source.contains("Google Play") })
        #expect(result.kpis.first { $0.id == "ads" }?.coverage?.availableDays == 29)
        #expect(result.kpis.first { $0.id == "adImpressions" }?.value == 0)
        #expect(result.kpis.first { $0.id == "adImpressions" }?.coverage?.availableDays == 29)
        #expect(result.kpis.first { $0.id == "dau" }?.value == 0)
        #expect(result.alerts.contains { $0.description.contains(".p8") })
        let requests = await Stub.shared.requests.filter { $0.url!.path.hasSuffix("networkReport:generate") }
        #expect(requests.count == 2)
        let bodies = try requests.map { try JSONSerialization.jsonObject(with:$0.httpBody!) as! [String:Any] }
        let ranges = bodies.map { ($0["reportSpec"] as! [String:Any])["dateRange"] as! [String:[String:Int]] }
        #expect(ranges[0]["startDate"] == ["year":2026,"month":8,"day":9])
        #expect(ranges[1]["endDate"] == ["year":2026,"month":9,"day":7])
        #expect(await Stub.shared.requests.allSatisfy { $0.url?.host != "firestore.googleapis.com" })
    }
    @Test func nativeCancellationStopsProviderReads() async throws {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        var game = Demo.games[0]; game.integrations.admobAppIds = ["ca-app-pub-123~123"]
        let connections = PersonalConnections(projectID:"test",firebase:account,supabase:[],admob:PersonalAdMob(clientID:"test",clientSecret:"secret",refreshToken:"refresh",publisherID:"pub-123"),importedAt:Date(),notes:[])
        let gate = ResponseGate()
        await Stub.shared.install { _ in
            await gate.arrive()
            return (200,Data(#"{"access_token":"test"}"#.utf8),[:])
        }
        let task = Task { try await NativeDashboardSync(http:http).run(games:[game],gameID:game.id,range:.month,connections:connections) }
        await gate.waitForStart(); task.cancel(); await gate.release()
        await #expect(throws:CancellationError.self) { try await task.value }
        #expect(await Stub.shared.requests.count == 1)
    }
}

extension NetworkTests {
    @Test func earningsPaginationIncludesCorrectionFiles() async throws {
        await Stub.shared.install { request in
            let url = request.url!
            #expect(url.host == "storage.googleapis.com")
            #expect(request.value(forHTTPHeaderField:"Authorization") == "Bearer test")
            if url.path.hasSuffix("/o") {
                let query = URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
                if query.contains(where: { $0.name == "pageToken" }) {
                    return (200,Data(#"{"items":[{"name":"earnings/earnings_202608_adjustment.zip"}]}"#.utf8),[:])
                }
                return (200,Data(#"{"items":[{"name":"earnings/earnings_202608.zip"}],"nextPageToken":"next"}"#.utf8),[:])
            }
            let amount = url.absoluteString.contains("adjustment") ? "-1" : "5"
            return (200,Data("Transaction Date,Package ID,Product Type,Merchant Currency,Amount (Merchant Currency)\n2026-08-01,com.test.app,Subscription,CHF,\(amount)\n".utf8),[:])
        }
        let files = try await NativeReports(http:http,tokens:.init()).earningsFiles(bucket:"test",month:"202608",token:"test")
        #expect(files.count == 2)
        let rows = try NativeReports.googleEarningsFiles(files,package:"com.test.app",days:["2026-08-01","2026-08-02"],completedMonth:true)
        #expect(rows["2026-08-01"]?.money["CHF"] == 4)
        #expect(rows["2026-08-02"] != nil)
        #expect(await Stub.shared.requests.count == 4)
    }
    @Test func deniedReportDoesNotExposeServerPayload() async throws {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        let connections = PersonalConnections(projectID:"test",firebase:account,supabase:[],admob:PersonalAdMob(clientID:"test",clientSecret:"secret",refreshToken:"refresh",publisherID:"pub-123"),importedAt:Date(),notes:[])
        await Stub.shared.install { _ in (403,Data("sensitive-server-payload".utf8),[:]) }
        let report = try await NativeReports(http:http,tokens:.init()).admob(game:Demo.games[0],connections:connections,window:SyncWindow(range:.month,now:Date()))
        #expect(report.days.isEmpty); #expect(report.note.contains("Accès refusé")); #expect(!report.note.contains("sensitive-server-payload"))
        #expect(await Stub.shared.requests.count == 1)
    }
}

extension NetworkTests {
    @Test func appleRequestsEachDayAndLeaves404Missing() async throws {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        var game = Demo.games[0]; game.integrations.appleAppId = "123"
        let connections = PersonalConnections(projectID:"test",firebase:account,supabase:[],apple:PersonalApple(issuerID:"issuer",keyID:"key",privateKey:P256.Signing.PrivateKey().pemRepresentation,vendor:"123"),importedAt:Date(),notes:[])
        await Stub.shared.install { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.host == "api.appstoreconnect.apple.com")
            if request.url!.path.contains("/apps/") { return (200,Data(#"{"data":{"attributes":{"sku":"game-sku"}}}"#.utf8),[:]) }
            let items = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
            let day = items.first { $0.name == "filter[reportDate]" }!.value!
            #expect(day >= "2026-09-01" && day <= "2026-09-06")
            if day == "2026-09-02" { return (404,Data(),[:]) }
            return (200,Data("Apple Identifier\tParent Identifier\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds\n123\t\t1F\t2\t0\tCHF\n".utf8),[:])
        }
        let report = try await NativeReports(http:http,tokens:.init()).apple(game:game,connections:connections,window:SyncWindow(range:.week,now:Dates.parse("2026-09-07T12:00:00Z")!),progress:{ _ in })
        #expect(report.days.count == 5); #expect(report.days["2026-09-02"] == nil)
        #expect(report.days.values.reduce(0) { $0+$1.installs } == 10)
        #expect(await Stub.shared.requests.count == 7)
    }
}

extension NetworkTests {
    @Test func cachedSyncOnlyDownloadsMissingAppleDatesAcrossRangesAndPreservesOfflineTotals() async throws {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        var game = Demo.games[0]; game.integrations.appleAppId = "123"; game.integrations.supabaseProjectRef = "test"
        let connections = PersonalConnections(projectID: "test", firebase: account,
            supabase: [PersonalSupabase(ref: "test", name: "Test", url: URL(string: "https://test.supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_test_credential_long_enough")],
            apple: PersonalApple(issuerID: "issuer", keyID: "key", privateKey: P256.Signing.PrivateKey().pemRepresentation, vendor: "123"), importedAt: Date(), notes: [])
        await Stub.shared.install { request in
            if request.url?.host == "test.supabase.co" {
                return (200, Data(#"[{"user_id":"11111111-1111-1111-1111-111111111111","run_id":"22222222-2222-2222-2222-222222222222","completed_at":"2026-09-06T10:00:00Z"}]"#.utf8), ["Content-Range": "0-0/1"])
            }
            if request.url!.path.contains("/apps/") { return (200, Data(#"{"data":{"attributes":{"sku":"game-sku"}}}"#.utf8), [:]) }
            #expect(request.url!.path == "/v1/salesReports")
            return (200, Data("Apple Identifier\tParent Identifier\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds\n123\t\t1F\t2\t0\tCHF\n".utf8), [:])
        }
        let now = Dates.parse("2026-09-07T12:00:00Z")!
        let sync = NativeDashboardSync(http: http)
        var cache = AggregateCache()
        _ = try await sync.runCached(games: [game], gameID: game.id, range: .week, connections: connections, cache: &cache, now: now, googlePlayGameIDs: [])
        #expect(await Stub.shared.requests.filter { $0.url!.path == "/v1/salesReports" }.count == 6)
        _ = try await sync.runCached(games: [game], gameID: game.id, range: .week, connections: connections, cache: &cache, now: now.addingTimeInterval(60), googlePlayGameIDs: [])
        #expect(await Stub.shared.requests.filter { $0.url!.path == "/v1/salesReports" }.count == 6)
        let month = try await sync.runCached(games: [game], gameID: game.id, range: .month, connections: connections, cache: &cache, now: now.addingTimeInterval(120), googlePlayGameIDs: [])
        #expect(await Stub.shared.requests.filter { $0.url!.path == "/v1/salesReports" }.count == 29)
        #expect(month.kpis.first { $0.id == "installs" }?.value == 58)
        // Same source snapshot: forcing all 29 reports must change provenance, not results.
        let full = try await sync.runCached(games: [game], gameID: game.id, range: .month, connections: connections, cache: &cache, force: true, now: now.addingTimeInterval(120), googlePlayGameIDs: [])
        #expect(await Stub.shared.requests.filter { $0.url!.path == "/v1/salesReports" }.count == 58)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(month.kpis) == encoder.encode(full.kpis))
        #expect(try encoder.encode(month.trend) == encoder.encode(full.trend))
        #expect(try encoder.encode(month.platformBreakdown) == encoder.encode(full.platformBreakdown))
        #expect(try encoder.encode(month.countryBreakdown) == encoder.encode(full.countryBreakdown))
        #expect(month.sourceDays?.filter { $0.provider == "apple" && $0.status == "cached" }.count == 6)
        #expect(full.sourceDays?.filter { $0.provider == "apple" && $0.status == "received" }.count == 29)
        let stored = String(decoding: try JSONEncoder().encode(cache), as: UTF8.self)
        #expect(!stored.contains("11111111-1111-1111-1111-111111111111"))
        #expect(!stored.contains("22222222-2222-2222-2222-222222222222"))
        #expect(!stored.contains("sb_secret")); #expect(!stored.contains("PRIVATE KEY"))
        await Stub.shared.install { _ in throw URLError(.notConnectedToInternet) }
        let offline = try await sync.runCached(games: [game], gameID: game.id, range: .month, connections: connections, cache: &cache, force: true, now: now.addingTimeInterval(180), googlePlayGameIDs: [])
        #expect(offline.kpis.first { $0.id == "installs" }?.value == 58)
        #expect(offline.kpis.first { $0.id == "mau" }?.value == 1)
        #expect(offline.alerts.contains { $0.description.contains("Statistiques agrégées conservées") })
        #expect(offline.alerts.contains { $0.description.contains("29 jour(s) réutilisé(s)") })
    }
}

extension NetworkTests {
    @Test func appleOnlyExplicitNoSales404IsZeroAndBadDayDoesNotStopFollowingReports() async throws {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        var game = Demo.games[0]; game.integrations.appleAppId = "123"
        let connections = PersonalConnections(projectID: "test", firebase: account, supabase: [], apple: PersonalApple(issuerID: "issuer", keyID: "key", privateKey: P256.Signing.PrivateKey().pemRepresentation, vendor: "123"), importedAt: Date(), notes: [])
        await Stub.shared.install { request in
            if request.url!.path.contains("/apps/") { return (200, Data(#"{"data":{"attributes":{"sku":"game"}}}"#.utf8), [:]) }
            let day = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "filter[reportDate]" }!.value!
            if day == "2026-09-01" { return (404, Data(#"{"errors":[{"code":"NOT_FOUND","detail":"There were no sales for the date specified."}]}"#.utf8), [:]) }
            if day == "2026-09-02" { return (404, Data(#"{"errors":[{"code":"NOT_FOUND","detail":"Report not available yet."}]}"#.utf8), [:]) }
            if day == "2026-09-03" { return (200, Data("unexpected-format".utf8), [:]) }
            return (200, Data("Apple Identifier\tParent Identifier\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds\n123\t\t1F\t6\t0.00\t \n".utf8), [:])
        }
        let report = try await NativeReports(http: http, tokens: .init()).apple(game: game, connections: connections, window: SyncWindow(range: .week, now: Dates.parse("2026-09-07T12:00:00Z")!), progress: { _ in })
        #expect(report.days.count == 4)
        #expect(report.days["2026-09-01"]?.installs == 0)
        #expect(report.days["2026-09-02"] == nil)
        #expect(report.days["2026-09-03"] == nil)
        #expect(report.days["2026-09-06"]?.installs == 6)
        #expect(report.note.contains("1 rapport(s) illisible(s)"))
        #expect(report.note.contains("1 journée(s) sans ventes"))
        #expect(!report.note.contains("unexpected-format"))
        #expect(await Stub.shared.requests.count == 7)
    }
}

extension NetworkTests {
    private func isolated(_ game: Game, apple: String? = nil, admob: String? = nil) -> Game {
        var copy = game
        copy.integrations = .init(admobAppIds: admob.map { [$0] }, appleAppId: apple)
        copy.platforms = apple == nil ? [] : ["ios"]; copy.status = "active"
        return copy
    }
    @Test func appleVendorReportIsDownloadedOncePerDayForEveryGame() async throws {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        let first = isolated(Demo.games[0], apple: "111"), second = isolated(Demo.games[1], apple: "222")
        let connections = PersonalConnections(projectID: "test", firebase: account, supabase: [], apple: PersonalApple(issuerID: "issuer", keyID: "key", privateKey: P256.Signing.PrivateKey().pemRepresentation, vendor: "123"), importedAt: Date(), notes: [])
        await Stub.shared.install { request in
            let path = request.url!.path
            if path.hasSuffix("/apps/111") { return (200, Data(#"{"data":{"attributes":{"sku":"one"}}}"#.utf8), [:]) }
            if path.hasSuffix("/apps/222") { return (200, Data(#"{"data":{"attributes":{"sku":"two"}}}"#.utf8), [:]) }
            #expect(path == "/v1/salesReports")
            return (200, Data("Apple Identifier\tParent Identifier\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds\n111\t\t1F\t2\t0\tCHF\n222\t\t1F\t5\t0\tCHF\n".utf8), [:])
        }
        var cache = AggregateCache()
        let now = Dates.parse("2026-09-07T12:00:00Z")!
        _ = try await NativeDashboardSync(http: http).runCached(games: [first, second], gameID: nil, range: .week, connections: connections, cache: &cache, entireStudio: true, now: now, googlePlayGameIDs: [])
        #expect(await Stub.shared.requests.filter { $0.url!.path == "/v1/salesReports" }.count == 6)
        #expect(cache.snapshot(gameID: first.id, range: .week)?.kpis.first { $0.id == "installs" }?.value == 12)
        #expect(cache.snapshot(gameID: second.id, range: .week)?.kpis.first { $0.id == "installs" }?.value == 30)
    }
    @Test func admobAccountIsReadOncePerSynchronization() async throws {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        let first = isolated(Demo.games[0], admob: "ca-app-pub-1~1"), second = isolated(Demo.games[1], admob: "ca-app-pub-1~2")
        let connections = PersonalConnections(projectID: "test", firebase: account, supabase: [], admob: PersonalAdMob(clientID: "c", clientSecret: "s", refreshToken: "r", publisherID: "pub-1"), importedAt: Date(), notes: [])
        await Stub.shared.install { request in
            let url = request.url!
            if url.host == "oauth2.googleapis.com" { return (200, Data(#"{"access_token":"test"}"#.utf8), [:]) }
            if url.path.hasSuffix("networkReport:generate") {
                let spec = (try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["reportSpec"] as! [String: Any]
                return (200, try JSONSerialization.data(withJSONObject: [["header": ["localizationSettings": ["currencyCode": "CHF"], "dateRange": spec["dateRange"]!]], ["footer": ["matchingRowCount": "0"]]]), [:])
            }
            if url.path.hasSuffix("/apps") { return (200, Data(#"{"apps":[{"appId":"ca-app-pub-1~1"},{"appId":"ca-app-pub-1~2"}]}"#.utf8), [:]) }
            return (200, Data(#"{"reportingTimeZone":"Europe/Zurich"}"#.utf8), [:])
        }
        var cache = AggregateCache()
        _ = try await NativeDashboardSync(http: http).runCached(games: [first, second], gameID: nil, range: .week, connections: connections, cache: &cache, entireStudio: true, now: Dates.parse("2026-09-07T12:00:00Z")!, googlePlayGameIDs: [])
        let requests = await Stub.shared.requests
        #expect(requests.filter { $0.url!.host == "oauth2.googleapis.com" }.count == 1)
        #expect(requests.filter { $0.url!.path == "/v1/accounts/pub-1" }.count == 1)
        #expect(requests.filter { $0.url!.path.hasSuffix("/apps") }.count == 1)
        #expect(requests.filter { $0.url!.path.hasSuffix("networkReport:generate") }.count == 2)
        #expect(cache.snapshot(gameID: second.id, range: .week)?.kpis.first { $0.id == "adImpressions" }?.value == 0)
    }
    @Test func supabaseCountsRowsOnlyOnTheFirstPage() async throws {
        await Stub.shared.install { request in
            let offset = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "offset" }!.value!)!
            return (206, Data("[{\"value\":\(offset)}]".utf8), ["Content-Range": offset == 0 ? "0-0/3" : "\(offset)-\(offset)/*"])
        }
        struct Row: Decodable { var value: Int }
        let rows: [Row] = try await supabase.rows("profiles", select: "value", order: "value.asc")
        #expect(rows.map(\.value) == [0, 1, 2])
        #expect(await Stub.shared.requests.map { $0.value(forHTTPHeaderField: "Prefer") } == ["count=exact", nil, nil])
    }
    @Test func unknownGoogleProductTypeStaysInRevenueButNotInPurchases() throws {
        let csv = Data("Transaction Date,Package ID,Product Type,Merchant Currency,Amount (Merchant Currency)\n2026-08-01,com.test.app,Subscription,CHF,5\n2026-08-01,com.test.app,Promotion credit,CHF,2\n".utf8)
        let parsed = try NativeReports.googleEarningsParse([csv], package: "com.test.app", days: ["2026-08-01"], completedMonth: true)
        #expect(parsed.days["2026-08-01"]?.money["CHF"] == 7)
        #expect(parsed.days["2026-08-01"]?.iap["CHF"] == 5)
        #expect(parsed.unknownTypes == ["Promotion credit": 1])
    }
    @Test func invalidActivityRowsAreSetAsideAndCounted() throws {
        let now = Dates.parse("2026-09-07T12:00:00Z")!
        let window = try SyncWindow(range: .week, now: now)
        let user = "11111111-1111-1111-1111-111111111111", run = "22222222-2222-2222-2222-222222222222"
        let events = [ActivityEvent(user_id: user, run_id: run, completed_at: "2026-09-06T10:00:00Z"),
                      ActivityEvent(user_id: user, run_id: run, completed_at: "2026-09-05T10:00:00Z"),
                      ActivityEvent(user_id: "not-a-uuid", run_id: run, completed_at: "2026-09-06T10:00:00Z"),
                      ActivityEvent(user_id: "33333333-3333-3333-3333-333333333333", run_id: run, completed_at: "2026-09-06T11:00:00Z")]
        let engagement = try Engagement.build(events, window: window, timezone: TimeZone(identifier: "Europe/Zurich")!)
        #expect(engagement.ignoredEvents == 2)
        #expect(engagement.daily["2026-09-06"] == 2)
    }
}
