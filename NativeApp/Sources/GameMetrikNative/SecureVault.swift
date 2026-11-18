import Foundation
import Security
import LocalAuthentication
import GameMetrikCore

// The signed, provisioned access group is enforced by macOS, not just a query filter.
final class UnlockContext: @unchecked Sendable {
    let value = LAContext()
    private let mutex = NSLock()
    private var valid = true
    private var authenticated = false
    init() { value.localizedCancelTitle = "Annuler"; value.touchIDAuthenticationAllowableReuseDuration = 0 }
    func authenticate() async throws {
        try await value.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "déverrouiller les connexions privées de GameMetrik")
        try markAuthenticated()
    }
    private func markAuthenticated() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard valid else { throw CancellationError() }; authenticated = true
    }
    func checkAuthorized() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard valid && authenticated else { throw GameMetrikError.message("Le déverrouillage a expiré. Déverrouille GameMetrik pour continuer.") }
    }
    func invalidate() { mutex.lock(); valid = false; authenticated = false; mutex.unlock(); value.invalidate() }
}

/// A separate, fresh owner authentication for the most sensitive action: exporting every key to the iPhone.
/// The session unlock never covers it, whatever its age.
enum OwnerConfirmation {
    static func transfer() async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Annuler"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                         localizedReason: "exporter toutes tes connexions administrateur vers ton iPhone")
    }
    static func aiSync() async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Annuler"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                         localizedReason: "autoriser Claude ou Codex à synchroniser GameMetrik sans Touch ID")
    }
}

enum Vault {
    static let service = "ch.gamemetrik.native.secure"
    static let legacyService = "ch.gamemetrik.native"
    /// The keychain group written into Info.plist by a signed, provisioned build. Absent from a demonstration build.
    static var accessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "GMKeychainAccessGroup") as? String, !group.isEmpty else { return nil }
        return group
    }
    static var isConfigured: Bool { accessGroup != nil }
    static func query(_ account: String) throws -> [String: Any] {
        guard let group = accessGroup else {
            throw GameMetrikError.message("La signature de l’app ne configure pas son trousseau protégé. Recompile avec un profil Apple valide.")
        }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group,
                kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false]
    }
    static func read(_ account: String, context: UnlockContext) throws -> Data? {
        try context.checkAuthorized()
        var request = try query(account)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationContext as String] = context.value
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status); return result as? Data
    }
    static func write(_ data: Data, account: String, context: UnlockContext) throws {
        try context.checkAuthorized()
        var request = try query(account); request[kSecUseAuthenticationContext as String] = context.value
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var accessError: Unmanaged<CFError>?
            guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &accessError) else {
                throw GameMetrikError.message("macOS n’a pas pu créer la protection du trousseau.")
            }
            request[kSecAttrAccessControl as String] = control
            request[kSecValueData as String] = data
            try check(SecItemAdd(request as CFDictionary, nil))
        } else { try check(status) }
    }
    static func remove(_ account: String, context: UnlockContext) throws {
        try context.checkAuthorized()
        var request = try query(account); request[kSecUseAuthenticationContext as String] = context.value
        let status = SecItemDelete(request as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    // Explicit one-time upgrade: old items survive until their protected copies read back exactly.
    static func migrateLegacy(context: UnlockContext) throws {
        try context.checkAuthorized()
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var attributes: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &attributes)
        if status == errSecItemNotFound { return }
        try check(status)
        for item in (attributes as? [[String: Any]] ?? []) {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account == "personal.connections" || account.hasPrefix("firebase.") else { continue }
            var old: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyService, kSecAttrAccount as String: account]
            old[kSecReturnData as String] = true; old[kSecMatchLimit as String] = kSecMatchLimitOne
            try context.checkAuthorized()
            var result: CFTypeRef?; try check(SecItemCopyMatching(old as CFDictionary, &result))
            guard var data = result as? Data else { throw GameMetrikError.message("L’ancienne connexion est illisible.") }
            defer { data.resetBytes(in: 0..<data.count) }
            if let existing = try read(account, context: context), existing != data {
                throw GameMetrikError.message("Les connexions anciennes et protégées diffèrent. La copie ancienne est conservée pour éviter une perte.")
            }
            try write(data, account: account, context: context)
            guard try read(account, context: context) == data else { throw GameMetrikError.message("La vérification de la migration a échoué. La copie ancienne est conservée.") }
            old.removeValue(forKey: kSecReturnData as String); old.removeValue(forKey: kSecMatchLimit as String)
            try check(SecItemDelete(old as CFDictionary))
        }
    }
    static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                throw GameMetrikError.message("Accès au trousseau annulé ou verrouillé. Déverrouille l’app pour réessayer.")
            }
            throw GameMetrikError.message("Le trousseau protégé n’est pas accessible (\(status)). Vérifie la signature et le profil Apple de l’app.")
        }
    }
}

/// What an assistant-triggered synchronization needs while the app stays locked.
/// Explicitly enabled by the owner (15 October 2026): stored without Touch ID, but only for this signed
/// app's access group, on this Mac, and while the Mac session is unlocked. Removed when disabled.
struct AISyncBundle: Codable {
    var connections: PersonalConnections
    var organization: String
    var cacheKey: Data
    var token: String
}

enum AIVault {
    static let account = "ai.sync"
    static func read() throws -> AISyncBundle? {
        var request = try Vault.query(account)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try Vault.check(status)
        guard var data = result as? Data else { return nil }
        defer { data.resetBytes(in: 0..<data.count) }
        let bundle = try JSONDecoder().decode(AISyncBundle.self, from: data)
        try bundle.connections.validate()
        return bundle
    }
    static func write(_ bundle: AISyncBundle) throws {
        var data = try JSONEncoder().encode(bundle)
        defer { data.resetBytes(in: 0..<data.count) }
        let request = try Vault.query(account)
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = request
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecValueData as String] = data
            try Vault.check(SecItemAdd(add as CFDictionary, nil))
        } else { try Vault.check(status) }
    }
    static func remove() throws {
        let status = SecItemDelete(try Vault.query(account) as CFDictionary)
        if status != errSecItemNotFound { try Vault.check(status) }
    }
}
