import Foundation
import CryptoKit

// Provider requests must never forward credentials to a redirect destination.
public final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
public struct HTTPClient: Sendable {
    public var session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest, acceptingStatusCodes: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw GameMetrikError.message("Réponse réseau invalide.") }
        guard (200..<300).contains(response.statusCode) || acceptingStatusCodes.contains(response.statusCode) else { throw GameMetrikError.http(response.statusCode) }
        return (data, response)
    }
    public func json<T: Decodable>(_ request: URLRequest, as: T.Type = T.self) async throws -> T {
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(T.self, from: data)
    }
    public static func form(_ values: [String: String]) -> Data {
        // application/x-www-form-urlencoded: '+' in tokens must be percent-escaped.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return values.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").data(using: .utf8)!
    }
    public static func post(_ url: URL, form: [String: String]) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(form); return request
    }
}
public struct NativeConfiguration: Codable, Sendable {
    public var apiKey: String
    public var projectID: String
    public var clientID: String
    public var callbackScheme: String
    public var organizationID: String?
    public var redirectURI: String { callbackScheme + ":/oauth2redirect" }
    public static func readPlist(_ data: Data) throws -> Self {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let apiKey = values["API_KEY"] as? String, !apiKey.isEmpty,
              let projectID = values["PROJECT_ID"] as? String, !projectID.isEmpty,
              let clientID = values["CLIENT_ID"] as? String, clientID.hasSuffix(".apps.googleusercontent.com"),
              let callback = values["REVERSED_CLIENT_ID"] as? String,
              callback == clientID.split(separator: ".").reversed().joined(separator: "."),
              values["BUNDLE_ID"] as? String == "ch.gamemetrik.native" else {
            throw GameMetrikError.message("Importe le GoogleService-Info.plist de l’app Apple ch.gamemetrik.native, avec le fournisseur Google activé. La configuration web ne contient pas ce client OAuth.")
        }
        guard validID(projectID) else { throw GameMetrikError.message("Identifiant de projet invalide.") }
        return Self(apiKey: apiKey, projectID: projectID, clientID: clientID, callbackScheme: callback)
    }
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("?") && !id.contains("#") && !id.contains("%")
    }
}
public struct PKCE: Sendable {
    public var verifier: String
    public var state: String
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public init() { verifier = Self.random(); state = Self.random() }
    public init(verifier: String, state: String) { self.verifier = verifier; self.state = state }
    private static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
    private static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public func authorizationURL(config: NativeConfiguration) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": config.clientID, "redirect_uri": config.redirectURI, "response_type": "code", "scope": "openid email profile", "code_challenge": challenge, "code_challenge_method": "S256", "state": state, "prompt": "select_account"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    public func code(callback: URL, config: NativeConfiguration) throws -> String {
        guard callback.scheme == config.callbackScheme, callback.path == "/oauth2redirect", callback.host == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state,
              !items.contains(where: { $0.name == "error" }), items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw GameMetrikError.message("La réponse de connexion n’a pas pu être vérifiée. Recommence la connexion.")
        }
        return code
    }
}
public struct AuthSession: Codable, Sendable {
    public var uid: String
    public var email: String
    public var idToken: String
    public var refreshToken: String
    public var expiresAt: Date
}
public struct FirebaseAuth: Sendable {
    public var config: NativeConfiguration
    public var http: HTTPClient
    public init(config: NativeConfiguration, http: HTTPClient = .init()) { self.config = config; self.http = http }
    public func exchange(code: String, pkce: PKCE) async throws -> AuthSession {
        struct GoogleToken: Decodable { var id_token: String }
        let google: GoogleToken = try await http.json(HTTPClient.post(URL(string: "https://oauth2.googleapis.com/token")!, form: ["code": code, "client_id": config.clientID, "redirect_uri": config.redirectURI, "grant_type": "authorization_code", "code_verifier": pkce.verifier]))
        var endpoint = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp")!
        endpoint.queryItems = [URLQueryItem(name: "key", value: config.apiKey)]
        var request = URLRequest(url: endpoint.url!); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["postBody": String(data: HTTPClient.form(["id_token": google.id_token, "providerId": "google.com"]), encoding: .utf8)!, "requestUri": "http://localhost", "returnSecureToken": true])
        struct Response: Decodable { var localId: String; var email: String?; var idToken: String; var refreshToken: String; var expiresIn: String }
        let response: Response = try await http.json(request)
        guard NativeConfiguration.validID(response.localId) else { throw GameMetrikError.message("Compte Firebase invalide.") }
        return AuthSession(uid: response.localId, email: response.email ?? "Compte Google", idToken: response.idToken, refreshToken: response.refreshToken, expiresAt: Date().addingTimeInterval(Double(response.expiresIn) ?? 3600))
    }
    public func refresh(_ session: AuthSession) async throws -> AuthSession {
        var endpoint = URLComponents(string: "https://securetoken.googleapis.com/v1/token")!
        endpoint.queryItems = [URLQueryItem(name: "key", value: config.apiKey)]
        struct Response: Decodable { var user_id: String; var id_token: String; var refresh_token: String; var expires_in: String }
        let result: Response = try await http.json(HTTPClient.post(endpoint.url!, form: ["grant_type": "refresh_token", "refresh_token": session.refreshToken]))
        guard result.user_id == session.uid else { throw GameMetrikError.message("La session a changé de compte. Reconnecte-toi.") }
        return AuthSession(uid: session.uid, email: session.email, idToken: result.id_token, refreshToken: result.refresh_token, expiresAt: Date().addingTimeInterval(Double(result.expires_in) ?? 3600))
    }
}

public indirect enum FireValue: Decodable, Sendable {
    case string(String), number(Double), bool(Bool), null, array([FireValue]), map([String: FireValue])
    enum Keys: String, CodingKey { case stringValue, timestampValue, integerValue, doubleValue, booleanValue, nullValue, arrayValue, mapValue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let v = try c.decodeIfPresent(String.self, forKey: .stringValue) { self = .string(v) }
        else if let v = try c.decodeIfPresent(String.self, forKey: .timestampValue) { self = .string(v) }
        else if let v = try c.decodeIfPresent(String.self, forKey: .integerValue), let n = Double(v), n.isFinite { self = .number(n) }
        else if let v = try c.decodeIfPresent(Double.self, forKey: .doubleValue), v.isFinite { self = .number(v) }
        else if let v = try c.decodeIfPresent(Bool.self, forKey: .booleanValue) { self = .bool(v) }
        else if c.contains(.nullValue) { self = .null }
        else if c.contains(.arrayValue) {
            struct Value: Decodable { var values: [FireValue]? }
            self = .array(try c.decode(Value.self, forKey: .arrayValue).values ?? [])
        } else if c.contains(.mapValue) {
            struct Value: Decodable { var fields: [String: FireValue]? }
            self = .map(try c.decode(Value.self, forKey: .mapValue).fields ?? [:])
        } else { throw GameMetrikError.message("Type de donnée Firestore non pris en charge.") }
    }
    public var json: Any {
        switch self { case .string(let v): v; case .number(let v): v; case .bool(let v): v; case .null: NSNull(); case .array(let v): v.map(\.json); case .map(let v): v.mapValues(\.json) }
    }
}
public struct FireDocument: Decodable, Sendable {
    public var name: String
    public var fields: [String: FireValue]?
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        var values = (fields ?? [:]).mapValues(\.json)
        if values["id"] == nil { values["id"] = name.split(separator: "/").last.map(String.init) }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: values))
    }
}
public struct Firestore: Sendable {
    public var project: String
    public var token: String
    public var http: HTTPClient
    public init(project: String, token: String, http: HTTPClient = .init()) { self.project = project; self.token = token; self.http = http }
    private func request(_ path: [String], query: [URLQueryItem] = []) throws -> URLRequest {
        guard NativeConfiguration.validID(project), path.allSatisfy(NativeConfiguration.validID) else { throw GameMetrikError.message("Chemin de données invalide.") }
        var url = URL(string: "https://firestore.googleapis.com/v1/projects")!
        for part in [project, "databases", "(default)", "documents"] + path { url.appendPathComponent(part) }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!; parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }
    public func document<T: Decodable>(_ path: [String], as: T.Type = T.self) async throws -> T {
        let document: FireDocument = try await http.json(try request(path))
        return try document.decode(T.self)
    }
    private struct Page: Decodable { var documents: [FireDocument]?; var nextPageToken: String? }
    public func list<T: Decodable>(_ path: [String], order: String = "name", as: T.Type = T.self) async throws -> [T] {
        var results: [T] = []; var pageToken: String?; var seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "300"), URLQueryItem(name: "orderBy", value: order)]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: Page = try await http.json(try request(path, query: query))
            results += try (page.documents ?? []).map { try $0.decode(T.self) }
            pageToken = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let pageToken, !seen.insert(pageToken).inserted { throw GameMetrikError.message("Pagination Firestore incohérente.") }
            guard results.count <= 100_000 else { throw GameMetrikError.message("Le catalogue est trop volumineux pour cette lecture.") }
        } while pageToken != nil
        return results
    }
    public func membership(uid: String, preferredOrganization: String?) async throws -> Membership {
        struct User: Decodable { var organizationIds: [String] }
        struct Member: Decodable { var role: String }
        let user: User = try await document(["users", uid])
        let org: String
        if let preferredOrganization, !preferredOrganization.isEmpty {
            guard user.organizationIds.contains(preferredOrganization) else { throw GameMetrikError.message("Ce compte n’est pas membre de l’organisation demandée.") }
            org = preferredOrganization
        } else {
            guard user.organizationIds.count == 1, let only = user.organizationIds.first else {
                throw GameMetrikError.message(user.organizationIds.isEmpty ? "Ce compte n’est membre d’aucune organisation GameMetrik." : "Ce compte appartient à plusieurs organisations. Indique l’identifiant de l’organisation dans les réglages.")
            }
            org = only
        }
        let member: Member = try await document(["organizations", org, "members", uid])
        guard ["owner", "admin", "viewer"].contains(member.role) else { throw GameMetrikError.message("Rôle du membre non reconnu.") }
        return Membership(organization: org, role: member.role)
    }
}
public struct Membership: Sendable {
    public var organization: String
    public var role: String
    public var canReadPlayers: Bool { ["owner", "admin"].contains(role) }
}
