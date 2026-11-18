import Foundation
import Security

public struct ServiceAccount: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var project_id: String
    public var client_email: String
    var private_key: String
    var private_key_id: String?
    var type: String?
    public var description: String { "ServiceAccount(credentials: redacted)" }
    public var debugDescription: String { description }
    public func validate() throws {
        guard type == nil || type == "service_account", NativeConfiguration.validID(project_id), client_email.hasSuffix(".gserviceaccount.com") else {
            throw GameMetrikError.message("Le fichier Google doit contenir un compte de service valide.")
        }
        _ = try RSASigning.key(pem: private_key)
    }
}
public struct PersonalSupabase: Codable, Sendable, CustomStringConvertible {
    public var ref: String
    public var name: String
    public var url: URL
    public var timezone: String
    var secret: String
    public var description: String { "PersonalSupabase(credentials: redacted)" }
    public init(ref: String, name: String, url: URL, timezone: String, secret: String) {
        self.ref = ref
        self.name = name
        self.url = url
        self.timezone = timezone
        self.secret = secret
    }
    public func validate() throws {
        guard !ref.isEmpty, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/", TimeZone(identifier: timezone) != nil else {
            throw GameMetrikError.message("Un projet Supabase importé a une URL ou un fuseau invalide.")
        }
        if secret.hasPrefix("sb_secret_"), secret.count > 20 { return }
        // Legacy service_role JWTs are accepted only in this private administrative path.
        let parts = secret.split(separator: ".")
        if parts.count == 3, let data = JWTEncoding.decode(String(parts[1])), let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any], payload["role"] as? String == "service_role" { return }
        throw GameMetrikError.message("L’identifiant Supabase administrateur est absent ou non reconnu.")
    }
    var headers: [String: String] {
        var result = ["apikey": secret]
        if !secret.hasPrefix("sb_secret_") { result["Authorization"] = "Bearer " + secret }
        return result
    }
}
public struct PersonalAdMob: Codable, Sendable, CustomStringConvertible {
    var clientID: String
    var clientSecret: String
    var refreshToken: String
    public var publisherID: String
    public var description: String { "PersonalAdMob(credentials: redacted)" }
}
public struct PersonalApple: Codable, Sendable, CustomStringConvertible {
    public var issuerID: String
    public var keyID: String
    var privateKey: String?
    public var vendor: String?
    public var description: String { "PersonalApple(credentials: redacted)" }
    public var hasKey: Bool { privateKey != nil }
}
public struct PersonalConnections: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var projectID: String
    public var firebase: ServiceAccount
    public var supabase: [PersonalSupabase]
    public var admob: PersonalAdMob?
    public var apple: PersonalApple?
    public var googlePlay: ServiceAccount?
    public var googlePlayReportBucket: String?
    public var importedAt: Date
    public var notes: [String]
    public var description: String { "PersonalConnections(credentials: redacted)" }
    public var debugDescription: String { description }
    public func validate() throws {
        guard NativeConfiguration.validID(projectID) else { throw GameMetrikError.message("Identifiant du projet Firebase invalide.") }
        try firebase.validate()
        guard Set(supabase.map(\.ref)).count == supabase.count else { throw GameMetrikError.message("Projet Supabase dupliqué.") }
        try supabase.forEach { try $0.validate() }
    }
    public static func read(directory: URL) throws -> Self {
        let data = try readFile(directory.appendingPathComponent(".env.local"))
        guard let text = String(data: data, encoding: .utf8) else { throw GameMetrikError.message("La configuration doit être encodée en UTF-8.") }
        let values = try DotEnv.parse(text)
        func value(_ key: String) -> String? {
            guard let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func path(_ key: String) -> URL? {
            guard let value = value(key) else { return nil }
            let expanded = (value as NSString).expandingTildeInPath
            return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)
        }
        func account(_ data: Data) throws -> ServiceAccount {
            do { let account = try JSONDecoder().decode(ServiceAccount.self, from: data); try account.validate(); return account }
            catch { throw GameMetrikError.message("Le compte de service Google ne peut pas être importé. Vérifie son format JSON et sa clé RSA.") }
        }
        let projectID = value("FIREBASE_PROJECT_ID") ?? value("NEXT_PUBLIC_FIREBASE_PROJECT_ID") ?? ""
        let firebase: ServiceAccount
        if let email = value("FIREBASE_CLIENT_EMAIL"), let pem = value("FIREBASE_PRIVATE_KEY") {
            firebase = ServiceAccount(project_id: projectID, client_email: email, private_key: pem.replacingOccurrences(of: "\\n", with: "\n"))
        } else if let url = path("GOOGLE_APPLICATION_CREDENTIALS") { firebase = try account(readFile(url)) }
        else { throw GameMetrikError.message("Le projet ne contient pas de compte de service Firebase importable.") }
        var notes: [String] = []
        struct Project: Decodable { var ref: String; var name: String; var url: URL; var secretEnv: String; var timezone: String? }
        var supabase: [PersonalSupabase] = []
        if let json = value("SUPABASE_PROJECTS_JSON") {
            let projects: [Project]
            do { projects = try JSONDecoder().decode([Project].self, from: Data(json.utf8)) }
            catch { throw GameMetrikError.message("La liste des projets Supabase est invalide.") }
            for project in projects {
                guard let secret = value(project.secretEnv) else { notes.append("Supabase : un projet n’a pas d’identifiant ; il n’a pas été importé."); continue }
                let item = PersonalSupabase(ref: project.ref, name: project.name, url: project.url, timezone: project.timezone ?? "Europe/Zurich", secret: secret)
                try item.validate(); supabase.append(item)
            }
        }
        var admob: PersonalAdMob?
        if let client = value("ADMOB_CLIENT_ID"), let secret = value("ADMOB_CLIENT_SECRET"), let token = value("ADMOB_REFRESH_TOKEN"), let publisher = value("ADMOB_PUBLISHER_ID") {
            let id = publisher.replacingOccurrences(of: "accounts/", with: "")
            guard id.range(of: #"^pub-[0-9]+$"#, options: .regularExpression) != nil else { throw GameMetrikError.message("Identifiant éditeur AdMob invalide.") }
            admob = PersonalAdMob(clientID: client, clientSecret: secret, refreshToken: token, publisherID: id)
        }
        var apple: PersonalApple?
        if let issuer = value("APPLE_ISSUER_ID"), let keyID = value("APPLE_KEY_ID") {
            var pem = value("APPLE_PRIVATE_KEY")?.replacingOccurrences(of: "\\n", with: "\n")
            if pem == nil, let url = path("APPLE_PRIVATE_KEY_PATH") {
                if let data = try? readFile(url) { pem = String(data: data, encoding: .utf8) }
                if pem == nil { notes.append("Apple : fichier de clé introuvable. Sélectionne la clé .p8 dans les réglages pour rétablir cette connexion.") }
            }
            apple = PersonalApple(issuerID: issuer, keyID: keyID, privateKey: pem, vendor: value("APPLE_VENDOR_NUMBER"))
        }
        var googlePlay: ServiceAccount?
        if let encoded = value("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64"), let data = Data(base64Encoded: encoded) {
            googlePlay = try account(data)
        } else if let url = path("GOOGLE_PLAY_SERVICE_ACCOUNT_PATH") { googlePlay = try account(readFile(url)) }
        else { googlePlay = firebase }
        let result = Self(projectID: projectID.isEmpty ? firebase.project_id : projectID, firebase: firebase, supabase: supabase, admob: admob, apple: apple, googlePlay: googlePlay, googlePlayReportBucket: value("GOOGLE_PLAY_REPORT_BUCKET"), importedAt: Date(), notes: notes)
        try result.validate(); return result
    }
    /// A reimport replaces what the folder provides, but keeps what was added later in GameMetrik:
    /// Supabase projects absent from the folder (Ballpark), a usable Apple key, vendor, bucket and AdMob.
    /// A different Firebase project is a different workspace: nothing is carried over.
    public func preservingManualSettings(from previous: PersonalConnections?) -> (connections: PersonalConnections, preserved: [String]) {
        guard let previous, previous.projectID == projectID else { return (self, []) }
        var result = self, preserved: [String] = []
        let imported = Set(supabase.map(\.ref))
        let kept = previous.supabase.filter { !imported.contains($0.ref) }
        if !kept.isEmpty { result.supabase += kept; preserved += kept.map { "Supabase · " + $0.name } }
        if let old = previous.apple {
            if result.apple?.hasKey != true, old.hasKey {
                // A key chosen in GameMetrik beats a folder reference to a missing file.
                result.apple = old; preserved.append("Clé Apple .p8 (\(old.keyID))")
                result.notes.removeAll { $0.hasPrefix("Apple :") }
            } else if result.apple == nil {
                result.apple = old; preserved.append("Identifiants Apple")
            }
            if result.apple?.vendor == nil, let vendor = old.vendor {
                result.apple?.vendor = vendor; preserved.append("Numéro vendeur Apple")
            }
        }
        if result.googlePlayReportBucket == nil, let bucket = previous.googlePlayReportBucket {
            result.googlePlayReportBucket = bucket; preserved.append("Bucket Google Play")
        }
        if result.admob == nil, let admob = previous.admob { result.admob = admob; preserved.append("AdMob") }
        return (result, preserved)
    }
    private static func readFile(_ url: URL) throws -> Data {
        // Bound before and after read. Files are read only once during explicit import.
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000 else { throw GameMetrikError.message("Un fichier de connexion dépasse la taille autorisée.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw GameMetrikError.message("Fichier de connexion trop volumineux.") }
        return data
    }
}

public enum JWTEncoding {
    public static func encode(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public static func decode(_ string: String) -> Data? {
        let base = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}

enum RSASigning {
    static func key(pem: String) throws -> SecKey {
        let lines = pem.components(separatedBy: .newlines)
        guard let der = Data(base64Encoded: lines.filter { !$0.hasPrefix("-----") }.joined()) else { throw GameMetrikError.message("Clé RSA non valide.") }
        let bytes: Data
        if pem.contains("BEGIN RSA PRIVATE KEY") { bytes = der }
        else if pem.contains("BEGIN PRIVATE KEY") { bytes = try unwrapPKCS8(der) }
        else { throw GameMetrikError.message("Format de clé RSA non pris en charge.") }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(bytes as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &error) else {
            throw GameMetrikError.message("La clé RSA n’a pas pu être chargée par macOS.")
        }
        return key
    }
    static func unwrapPKCS8(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        func element(_ offset: inout Int, within end: Int) throws -> (UInt8, Range<Int>) {
            guard offset + 2 <= end else { throw GameMetrikError.message("Clé PKCS8 tronquée.") }
            let tag = bytes[offset]; offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard (1...4).contains(count), offset + count <= end else { throw GameMetrikError.message("Longueur PKCS8 invalide.") }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
            }
            guard length <= end - offset else { throw GameMetrikError.message("Clé PKCS8 tronquée.") }
            let range = offset..<(offset + length); offset += length
            return (tag, range)
        }
        var offset = 0
        let (tag, root) = try element(&offset, within: bytes.count)
        guard tag == 0x30, offset == bytes.count else { throw GameMetrikError.message("Conteneur PKCS8 invalide.") }
        offset = root.lowerBound
        let (versionTag, _) = try element(&offset, within: root.upperBound)
        let (algorithmTag, algorithm) = try element(&offset, within: root.upperBound)
        var algoOffset = algorithm.lowerBound
        let (oidTag, oid) = try element(&algoOffset, within: algorithm.upperBound)
        guard versionTag == 0x02, algorithmTag == 0x30, oidTag == 0x06, Array(bytes[oid]) == [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01] else { throw GameMetrikError.message("La clé privée n’est pas une clé RSA.") }
        let (keyTag, key) = try element(&offset, within: root.upperBound)
        guard keyTag == 0x04 else { throw GameMetrikError.message("Clé PKCS8 invalide.") }
        return Data(bytes[key])
    }
}
public actor ServiceAccountTokens {
    private var cached: [String: (String, Date)] = [:]
    private var generation = 0
    public init() {}
    public func token(account: ServiceAccount, scopes: [String], http: HTTPClient = .init()) async throws -> String {
        let cacheKey = account.client_email + ":" + (account.private_key_id ?? "") + ":" + scopes.sorted().joined(separator: " ")
        if let (token, expiry) = cached[cacheKey], expiry.timeIntervalSinceNow > 120 { return token }
        let revision = generation
        let assertion = try Self.assertion(account: account, scopes: scopes)
        struct Response: Decodable { var access_token: String; var expires_in: Double }
        let result: Response = try await http.json(HTTPClient.post(URL(string: "https://oauth2.googleapis.com/token")!, form: ["grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion]))
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        cached[cacheKey] = (result.access_token, Date().addingTimeInterval(result.expires_in))
        return result.access_token
    }
    public static func assertion(account: ServiceAccount, scopes: [String], now: Date = Date()) throws -> String {
        let key = try RSASigning.key(pem: account.private_key)
        var header = ["alg": "RS256", "typ": "JWT"]
        if let id = account.private_key_id { header["kid"] = id }
        let payload: [String: Any] = ["iss": account.client_email, "scope": scopes.sorted().joined(separator: " "), "aud": "https://oauth2.googleapis.com/token", "iat": Int(now.timeIntervalSince1970), "exp": Int(now.timeIntervalSince1970) + 900]
        let input = JWTEncoding.encode(try JSONSerialization.data(withJSONObject: header, options: .sortedKeys)) + "." + JWTEncoding.encode(try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, &error) else { throw GameMetrikError.message("Impossible de signer la connexion Google.") }
        return input + "." + JWTEncoding.encode(signature as Data)
    }
    public func clear() { generation += 1; cached = [:] }
}
