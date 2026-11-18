import Foundation
import LocalAuthentication
import Security
import GameMetrikCore

struct MobileStoredConnection: Codable {
    var payload: MobileConnectionPayload
    var cacheKey: Data
}

enum MobileVault {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ch.gamemetrik.ios.private",
         kSecAttrAccount as String: "owner",
         kSecAttrSynchronizable as String: false]
    }
    static func read(context: LAContext) throws -> Data? {
        var request = query
        request[kSecUseAuthenticationContext as String] = context
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return result as? Data
    }
    static func save(_ data: Data, context: LAContext) throws {
        var request = query; request[kSecUseAuthenticationContext as String] = context
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else {
                throw GameMetrikError.message("Active un code de verrouillage sur l’iPhone pour protéger les connexions.")
            }
            request[kSecAttrAccessControl as String] = access
            request[kSecValueData as String] = data
            try check(SecItemAdd(request as CFDictionary, nil))
        } else { try check(status) }
        guard try read(context: context) == data else {
            throw GameMetrikError.message("La connexion n’a pas pu être relue dans le trousseau. Réessaie l’import.")
        }
    }
    static func remove(context: LAContext) throws {
        var request = query; request[kSecUseAuthenticationContext as String] = context
        let status = SecItemDelete(request as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw GameMetrikError.message("Le trousseau est verrouillé ou son accès a été annulé. Déverrouille l’iPhone et réessaie (\(status)).")
        }
    }
}
