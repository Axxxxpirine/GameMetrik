import Foundation
import CryptoKit

// A protected, verified backup is mandatory before removing any original credential file.
public struct SourceCleanup: Codable, Sendable, CustomStringConvertible {
    public struct File: Codable, Sendable {
        public var url: URL
        var contents: Data
        public var sha256: String { SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined() }
    }
    public var files: [File]
    public var environmentURL: URL
    public var createdAt: Date
    public var description: String { "SourceCleanup(contents: redacted)" }
    public static func referencedKeys(directory: URL) throws -> [URL] {
        let values = try environment(directory: directory)
        return Array(Set(["GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_PLAY_SERVICE_ACCOUNT_PATH", "APPLE_PRIVATE_KEY_PATH"].compactMap { key in
            guard let path = values[key], !path.isEmpty else { return nil }
            let expanded = (path as NSString).expandingTildeInPath
            return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded).standardizedFileURL : directory.appendingPathComponent(expanded).standardizedFileURL
        })).sorted { $0.path < $1.path }
    }
    public static func prepare(directory: URL, connections: PersonalConnections) throws -> Self {
        let imported = try PersonalConnections.read(directory: directory)
        guard imported.projectID == connections.projectID,
              imported.firebase.private_key == connections.firebase.private_key,
              imported.firebase.client_email == connections.firebase.client_email,
              imported.supabase.count == connections.supabase.count,
              imported.supabase.allSatisfy({ original in connections.supabase.contains { $0.ref == original.ref && $0.url == original.url && $0.secret == original.secret } }),
              imported.admob?.refreshToken == connections.admob?.refreshToken,
              imported.admob?.clientSecret == connections.admob?.clientSecret,
              imported.googlePlay?.private_key == connections.googlePlay?.private_key,
              imported.apple?.hasKey != true || imported.apple?.privateKey == connections.apple?.privateKey else {
            throw GameMetrikError.message("Les identifiants du dossier diffèrent des connexions protégées. Réimporte le bon dossier avant le nettoyage.")
        }
        let env = directory.appendingPathComponent(".env.local").standardizedFileURL
        var files: [File] = []
        for url in [env] + (try referencedKeys(directory: directory)) {
            if !FileManager.default.fileExists(atPath: url.path) { continue }
            let resource = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard resource.isSymbolicLink == false, resource.isRegularFile == true,
                  (resource.fileSize ?? Int.max) <= 2_000_000 else { throw GameMetrikError.message("Le nettoyage n’accepte que des fichiers ordinaires de connexion, sans lien symbolique.") }
            files.append(File(url: url, contents: try Data(contentsOf: url)))
        }
        return Self(files: files, environmentURL: env, createdAt: Date())
    }
    public func encodedBackup() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    public func commit(verifiedBackup: Data) throws -> [String] {
        guard try encodedBackup() == verifiedBackup else { throw GameMetrikError.message("La sauvegarde protégée n’a pas été vérifiée. Aucun fichier n’est retiré.") }
        // Check every source before touching any of them; concurrent edits must not be lost.
        for file in files {
            let resources = try file.url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard resources.isSymbolicLink == false, resources.isRegularFile == true,
                  try Data(contentsOf: file.url) == file.contents else {
                throw GameMetrikError.message("Un fichier d’origine a changé. Relance la préparation du nettoyage.")
            }
        }
        let notice = "# Les connexions ont été transférées dans le trousseau protégé de GameMetrik Native.\n# L’ancienne configuration et les clés sont sauvegardées dans ce trousseau, sous authentification macOS.\n# La web app ne dispose plus d’identifiants de production.\nAPP_MODE=demo\nNEXT_PUBLIC_APP_MODE=demo\n"
        var removed: [String] = []
        // Sanitize the web configuration first, so it cannot start with a partially removed setup.
        try Data(notice.utf8).write(to: environmentURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: environmentURL.path)
        removed.append(environmentURL.lastPathComponent)
        for file in files where file.url != environmentURL {
            try FileManager.default.removeItem(at: file.url)
            removed.append(file.url.lastPathComponent)
        }
        return removed
    }
    private static func environment(directory: URL) throws -> [String: String] {
        let url = directory.appendingPathComponent(".env.local")
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2_000_000,
              let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw GameMetrikError.message("Configuration d’origine illisible.") }
        return try DotEnv.parse(text)
    }
}
