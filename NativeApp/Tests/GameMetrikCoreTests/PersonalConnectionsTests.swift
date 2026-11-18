import Foundation
import Security
import CryptoKit
import Testing
@testable import GameMetrikCore

struct PersonalConnectionsTests {
    func keyPair() throws -> (ServiceAccount, SecKey) {
        let key = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let data = try #require(SecKeyCopyExternalRepresentation(key, nil)) as Data
        // PKCS8 wrapper used by Google's JSON account files.
        func der(_ tag: UInt8, _ content: Data) -> Data {
            let size = content.count
            let length: [UInt8] = size < 128 ? [UInt8(size)] : [0x82, UInt8(size >> 8), UInt8(size & 255)]
            return Data([tag] + length) + content
        }
        let algorithm = Data([0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00])
        let pkcs8 = der(0x30, Data([0x02,0x01,0x00]) + algorithm + der(0x04, data))
        let pem = "-----BEGIN PRIVATE KEY-----\n" + pkcs8.base64EncodedString() + "\n-----END PRIVATE KEY-----"
        return (ServiceAccount(project_id: "test-project", client_email: "test@test-project.iam.gserviceaccount.com", private_key: pem, private_key_id: "test-key", type: "service_account"), key)
    }
    @Test func assertionHasVerifiedSignatureAndBoundedLifetime() throws {
        let (account, key) = try keyPair()
        try account.validate()
        let token = try ServiceAccountTokens.assertion(account: account, scopes: ["scope-b", "scope-a"], now: Date(timeIntervalSince1970: 1_000))
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let payload = try #require(JSONSerialization.jsonObject(with: JWTEncoding.decode(parts[1])!) as? [String: Any])
        #expect(payload["aud"] as? String == "https://oauth2.googleapis.com/token")
        #expect(payload["scope"] as? String == "scope-a scope-b")
        #expect(payload["iat"] as? Int == 1000); #expect(payload["exp"] as? Int == 1900)
        let input = Data((parts[0] + "." + parts[1]).utf8)
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        #expect(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, JWTEncoding.decode(parts[2])! as CFData, nil))
        #expect(!SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data("changed".utf8) as CFData, JWTEncoding.decode(parts[2])! as CFData, nil))
        #expect(!String(reflecting: account).contains("BEGIN PRIVATE KEY"))
    }
    @Test func importCopiesRelativeKeyAndMarksMissingAppleFile() throws {
        let (account, _) = try keyPair()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONEncoder().encode(account).write(to: directory.appendingPathComponent("account.json"))
        let env = """
        FIREBASE_PROJECT_ID=test-project
        GOOGLE_APPLICATION_CREDENTIALS=account.json
        SUPABASE_PROJECTS_JSON='[{"ref":"test","name":"Test","url":"https://test.supabase.co","secretEnv":"SUPABASE_SECRET"}]'
        SUPABASE_SECRET=sb_secret_test_credential_long_enough
        APPLE_ISSUER_ID=test-issuer
        APPLE_KEY_ID=test-key
        APPLE_PRIVATE_KEY_PATH=missing.p8
        """
        try Data(env.utf8).write(to: directory.appendingPathComponent(".env.local"))
        let result = try PersonalConnections.read(directory: directory)
        #expect(result.projectID == "test-project"); #expect(result.supabase.count == 1)
        #expect(result.apple?.hasKey == false); #expect(result.notes.count == 1)
        #expect(!String(reflecting: result).contains("sb_secret"))
        #expect(!result.notes.joined().contains("sb_secret"))
        let restored = try JSONDecoder().decode(PersonalConnections.self, from: JSONEncoder().encode(result))
        try restored.validate()
    }
    @Test func appleJWTUsesRawP256SignatureAndCorrectAudience() throws {
        let key = P256.Signing.PrivateKey()
        let original = PersonalApple(issuerID: "issuer", keyID: "key", privateKey: nil, vendor: nil)
        #expect(throws: GameMetrikError.self) { try original.assertion() }
        let config = try original.replacingKey(Data(key.pemRepresentation.utf8))
        let jwt = try config.assertion(now: Date(timeIntervalSince1970: 1_000))
        let parts = jwt.split(separator: ".").map(String.init)
        let claims = try #require(JSONSerialization.jsonObject(with: JWTEncoding.decode(parts[1])!) as? [String: Any])
        #expect(claims["aud"] as? String == "appstoreconnect-v1")
        #expect(claims["exp"] as? Int == 1900)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: JWTEncoding.decode(parts[2])!)
        #expect(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        #expect(throws: GameMetrikError.self) { try original.replacingKey(Data("not a private key".utf8)) }
    }
    @Test func malformedPrivateKeysFailSafely() {
        for bytes in [Data(), Data([0x30,0x82,0xff]), Data([0x30,0x80,0x00]), Data([0x30,0xff])] {
            #expect(throws: GameMetrikError.self) { try RSASigning.unwrapPKCS8(bytes) }
        }
    }
}

extension PersonalConnectionsTests {
    @Test func appleImportUsesDownloadedKeyIDAndEditedIssuer() throws {
        let key = P256.Signing.PrivateKey()
        let issuer = UUID().uuidString
        let imported = try PersonalApple.importingKey(Data(key.pemRepresentation.utf8),
            fileName: "AuthKey_0123456789.p8", issuerID: " \(issuer)\n", keyID: "OLDKEY1234", vendor: " 123 ")
        #expect(imported.keyID == "0123456789")
        #expect(imported.issuerID == issuer)
        #expect(imported.vendor == "123")
        let parts = try imported.assertion().split(separator: ".").map(String.init)
        let header = try #require(JSONSerialization.jsonObject(with: JWTEncoding.decode(parts[0])!) as? [String: Any])
        let claims = try #require(JSONSerialization.jsonObject(with: JWTEncoding.decode(parts[1])!) as? [String: Any])
        #expect(header["kid"] as? String == "0123456789")
        #expect(claims["iss"] as? String == issuer)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: JWTEncoding.decode(parts[2])!)
        #expect(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
    }
    @Test func renamedAppleKeyRequiresValidManualMetadata() throws {
        let data = Data(P256.Signing.PrivateKey().pemRepresentation.utf8)
        let issuer = UUID().uuidString
        let imported = try PersonalApple.importingKey(data, fileName: "renamed.p8", issuerID: issuer, keyID: " abcdefghij ", vendor: "")
        #expect(imported.keyID == "ABCDEFGHIJ")
        #expect(imported.vendor == nil)
        #expect(throws: GameMetrikError.self) {
            try PersonalApple.importingKey(data, fileName: "AuthKey_ABCDEFGHIJ.p8.bak", issuerID: issuer, keyID: "", vendor: nil)
        }
        #expect(throws: GameMetrikError.self) {
            try PersonalApple.importingKey(data, fileName: "AuthKey_ABCDEFGHIJ.p8", issuerID: "invalid", keyID: "", vendor: nil)
        }
        #expect(throws: GameMetrikError.self) {
            try PersonalApple.importingKey(Data("invalid".utf8), fileName: "AuthKey_ABCDEFGHIJ.p8", issuerID: issuer, keyID: "", vendor: nil)
        }
    }
    @Test func changingAppleKeyIDCannotReusePreviousPrivateKey() throws {
        let issuer = UUID().uuidString
        let old = PersonalApple(issuerID:issuer,keyID:"ABCDEFGHIJ",privateKey:"test-only-private-material",vendor:"123")
        let same = try PersonalApple.configured(issuerID:issuer,keyID:"ABCDEFGHIJ",vendor:"456",previous:old)
        #expect(same.hasKey); #expect(same.vendor == "456")
        let replaced = try PersonalApple.configured(issuerID:issuer,keyID:"0123456789",vendor:"123",previous:old)
        #expect(!replaced.hasKey)
        #expect(throws:GameMetrikError.self) { try PersonalApple.configured(issuerID:"invalid",keyID:"short",vendor:nil,previous:old) }
    }

    private func workspace(_ project: String = "test-project") throws -> PersonalConnections {
        let (account, _) = try keyPair()
        let aurora = PersonalSupabase(ref: "aurora", name: "Aurora", url: URL(string: "https://aurora.supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_test_only_value")
        return PersonalConnections(projectID: project, firebase: account, supabase: [aurora], importedAt: Date(), notes: [])
    }
    @Test func reimportKeepsSettingsAddedInTheAppWhenTheFolderLacksThem() throws {
        var previous = try workspace()
        previous.supabase.append(PersonalSupabase(ref: Game.ballparkProjectRef, name: "Ballpark", url: URL(string: "https://\(Game.ballparkProjectRef).supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_ballpark_test_only"))
        previous.apple = PersonalApple(issuerID: "issuer", keyID: "NEWKEY0001", privateKey: "chosen-in-app", vendor: "123")
        previous.googlePlayReportBucket = "pubsite_prod_rev_test"
        previous.admob = PersonalAdMob(clientID: "client", clientSecret: "secret", refreshToken: "refresh", publisherID: "pub-1")
        // The folder still references an older, missing Apple key and has none of the later settings.
        var folder = try workspace()
        folder.apple = PersonalApple(issuerID: "issuer", keyID: "OLDKEY0001", privateKey: nil, vendor: nil)
        folder.notes = ["Apple : fichier de clé introuvable. Sélectionne la clé .p8 dans les réglages pour rétablir cette connexion."]
        let (merged, preserved) = folder.preservingManualSettings(from: previous)
        #expect(merged.supabase.map(\.ref) == ["aurora", Game.ballparkProjectRef])
        #expect(merged.apple?.keyID == "NEWKEY0001"); #expect(merged.apple?.hasKey == true); #expect(merged.apple?.vendor == "123")
        #expect(merged.googlePlayReportBucket == "pubsite_prod_rev_test")
        #expect(merged.admob?.publisherID == "pub-1")
        #expect(merged.notes.isEmpty)
        #expect(preserved.count == 4)
        #expect(!preserved.joined().contains("chosen-in-app"))
    }
    @Test func reimportLetsTheFolderWinWhenItProvidesTheValue() throws {
        var previous = try workspace()
        previous.supabase[0].secret = "sb_secret_previous_value"
        previous.apple = PersonalApple(issuerID: "issuer", keyID: "OLDKEY0001", privateKey: "previous-key", vendor: "123")
        previous.googlePlayReportBucket = "old-bucket"
        var folder = try workspace()
        folder.apple = PersonalApple(issuerID: "issuer", keyID: "NEWKEY0001", privateKey: "folder-key", vendor: nil)
        folder.googlePlayReportBucket = "new-bucket"
        let (merged, preserved) = folder.preservingManualSettings(from: previous)
        #expect(merged.supabase[0].secret == "sb_secret_test_only_value")
        #expect(merged.apple?.keyID == "NEWKEY0001"); #expect(merged.apple?.privateKey == "folder-key")
        #expect(merged.apple?.vendor == "123")
        #expect(merged.googlePlayReportBucket == "new-bucket")
        #expect(preserved == ["Numéro vendeur Apple"])
    }
    @Test func reimportOfAnotherFirebaseProjectCarriesNothingOver() throws {
        var previous = try workspace("old-project")
        previous.apple = PersonalApple(issuerID: "issuer", keyID: "NEWKEY0001", privateKey: "key", vendor: "123")
        previous.googlePlayReportBucket = "bucket"
        let folder = try workspace("new-project")
        let (merged, preserved) = folder.preservingManualSettings(from: previous)
        #expect(merged.apple == nil); #expect(merged.googlePlayReportBucket == nil); #expect(preserved.isEmpty)
        #expect(folder.preservingManualSettings(from: nil).preserved.isEmpty)
    }
}
