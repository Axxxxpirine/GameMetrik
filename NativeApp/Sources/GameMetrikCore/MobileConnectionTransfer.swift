import Foundation
import CryptoKit

/// Private owner setup, never a distributable app configuration. The key travels separately.
public struct MobileConnectionPayload: Codable, Sendable {
    public var connections: PersonalConnections
    public var organization: String
    public var googlePlayOverrides: [String: Bool]
    public var createdAt: Date
    public var expiresAt: Date

    public init(connections: PersonalConnections, organization: String, googlePlayOverrides: [String: Bool], now: Date = Date()) {
        self.connections = connections; self.organization = organization
        self.googlePlayOverrides = googlePlayOverrides; createdAt = now
        expiresAt = now.addingTimeInterval(MobileConnectionTransfer.lifetime)
    }
}

public enum MobileConnectionTransfer {
    private static let header = Data("GameMetrik iPhone connection v1\n".utf8)
    public static let maximumSize = 2 * 1024 * 1024
    /// Short on purpose: the file is useless once expired, even if it lingers in Downloads or a backup.
    public static let lifetime: TimeInterval = 10 * 60
    /// Prefix of the QR code shown by the Mac, so the iPhone never mistakes another QR code for a transfer code.
    public static let scanPrefix = "gamemetrik-transfer:"

    /// The text encoded in the QR code: the code never needs to be typed, copied or sent through a message.
    public static func scanText(for code: String) -> String { scanPrefix + code }
    /// The transfer code read from a scanned QR code, or nil for any other QR code.
    public static func code(fromScanned text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix(scanPrefix) else { return nil }
        let code = String(clean.dropFirst(scanPrefix.count))
        return (try? key(code)) == nil ? nil : code
    }

    /// 256 bits of random key material; this is deliberately not a human-chosen password.
    public static func newCode() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { JWTEncoding.encode(Data($0)) }
    }
    private static func key(_ code: String) throws -> SymmetricKey {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count == 43, let data = JWTEncoding.decode(clean), data.count == 32,
              JWTEncoding.encode(data) == clean else {
            throw GameMetrikError.message("Le code de transfert doit être copié en entier depuis le Mac.")
        }
        return SymmetricKey(data: data)
    }
    public static func seal(_ payload: MobileConnectionPayload, code: String) throws -> Data {
        try payload.connections.validate()
        guard NativeConfiguration.validID(payload.organization) else {
            throw GameMetrikError.message("Sélectionne et synchronise ton organisation avant de préparer l’iPhone.")
        }
        let data = try JSONEncoder().encode(payload)
        // The limit applies to the whole file the iPhone will read: header, nonce and tag included.
        guard let combined = try AES.GCM.seal(data, using: key(code), authenticating: header).combined,
              header.count + combined.count <= maximumSize else {
            throw GameMetrikError.message("La connexion est trop volumineuse pour ce transfert.")
        }
        return header + combined
    }
    public static func open(_ data: Data, code: String, now: Date = Date()) throws -> MobileConnectionPayload {
        guard data.count <= maximumSize, data.starts(with: header) else {
            throw GameMetrikError.message("Ce fichier n’est pas un transfert GameMetrik compatible.")
        }
        let secret = try key(code)
        let plaintext: Data
        do { plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(header.count)), using: secret, authenticating: header) }
        catch { throw GameMetrikError.message("Code incorrect ou fichier de transfert endommagé.") }
        let payload = try JSONDecoder().decode(MobileConnectionPayload.self, from: plaintext)
        guard payload.expiresAt.timeIntervalSince(payload.createdAt) <= lifetime,
              NativeConfiguration.validID(payload.organization) else {
            throw GameMetrikError.message("Ce fichier de transfert n’est pas valide. Prépare un nouveau fichier depuis le Mac.")
        }
        guard payload.createdAt <= now.addingTimeInterval(60) else {
            throw GameMetrikError.message("L’heure de cet iPhone retarde sur celle du Mac. Active Réglage automatique dans Réglages → Général → Date et heure, puis réessaie.")
        }
        guard payload.expiresAt > now else {
            throw GameMetrikError.message("Ce transfert a expiré. Prépare un nouveau fichier depuis le Mac.")
        }
        try payload.connections.validate()
        return payload
    }
}
