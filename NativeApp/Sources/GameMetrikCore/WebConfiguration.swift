import Foundation

/// Reads dotenv as data. Shell substitutions are never evaluated.
public enum DotEnv {
    public static func parse(_ text: String) throws -> [String: String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var values: [String: String] = [:]
        var index = 0
        while index < lines.count {
            var line = lines[index].trimmingCharacters(in: .whitespaces); index += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let separator = line.firstIndex(of: "=") else { throw GameMetrikError.message("Ligne \(index) du fichier de configuration invalide.") }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { throw GameMetrikError.message("Nom de variable invalide à la ligne \(index).") }
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if let quote = value.first, ["\"", "'", "`"].contains(quote) {
                value.removeFirst()
                var result = ""; var closed = false; var escaped = false
                while !closed {
                    for char in value {
                        if char == quote && !escaped { closed = true; break }
                        result.append(char)
                        escaped = char == "\\" && !escaped
                    }
                    if !closed {
                        guard index < lines.count else { throw GameMetrikError.message("Une valeur entre guillemets n’est pas terminée dans la configuration.") }
                        result += "\n"; value = lines[index]; index += 1; escaped = false
                    }
                }
                values[key] = quote == "\"" ? result.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\\"", with: "\"") : result
            } else {
                values[key] = String(value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces)
            }
        }
        return values
    }
}

public struct ConnectionAudit: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let detail: String
}
public struct WebConfigurationAudit: Sendable {
    public var connections: [ConnectionAudit]
    public var firebaseProjectID: String?

    /// Only the diagnostic leaves this function; credentials are neither returned nor persisted.
    public static func inspect(directory: URL) throws -> Self {
        let file = directory.appendingPathComponent(".env.local")
        let data = try Data(contentsOf: file)
        guard data.count < 2_000_000, let contents = String(data: data, encoding: .utf8) else { throw GameMetrikError.message("Le fichier .env.local est trop volumineux ou son encodage est invalide.") }
        let values = try DotEnv.parse(contents)
        func populated(_ key: String) -> Bool { values[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        func fileExists(_ key: String) -> Bool {
            guard let value = values[key], !value.isEmpty else { return false }
            let expanded = (value as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        let firebase = populated("FIREBASE_CLIENT_EMAIL") && populated("FIREBASE_PRIVATE_KEY") || fileExists("GOOGLE_APPLICATION_CREDENTIALS")
        let google = populated("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64") || fileExists("GOOGLE_PLAY_SERVICE_ACCOUNT_PATH") || fileExists("GOOGLE_APPLICATION_CREDENTIALS")
        let apple = populated("APPLE_ISSUER_ID") && populated("APPLE_KEY_ID") && (populated("APPLE_PRIVATE_KEY") || fileExists("APPLE_PRIVATE_KEY_PATH"))
        let admob = ["ADMOB_CLIENT_ID", "ADMOB_CLIENT_SECRET", "ADMOB_REFRESH_TOKEN", "ADMOB_PUBLISHER_ID"].allSatisfy(populated)
        struct Project: Decodable { var secretEnv: String }
        var supabaseDetail = "Aucun projet déclaré."
        var supabase = false
        if let json = values["SUPABASE_PROJECTS_JSON"], let data = json.data(using: .utf8) {
            do {
                let projects = try JSONDecoder().decode([Project].self, from: data)
                let count = projects.filter { populated($0.secretEnv) }.count
                supabase = !projects.isEmpty && count == projects.count
                supabaseDetail = "\(count) projet(s) sur \(projects.count) avec un identifiant présent."
            } catch { supabaseDetail = "La liste des projets Supabase est invalide." }
        }
        func result(_ id: String, _ name: String, _ available: Bool, _ detail: String) -> ConnectionAudit {
            .init(id: id, name: name, status: available ? "Identifiants présents" : "À compléter", detail: detail)
        }
        return Self(connections: [
            result("firebase", "Firebase / Firestore", firebase, firebase ? "Identité administrateur retrouvée. Accès distant à valider." : "Configuration publique récupérable ; identité administrateur absente ou fichier introuvable."),
            result("supabase", "Supabase", supabase, supabaseDetail),
            result("apple", "App Store Connect", apple, apple ? "Identité Apple retrouvée. Accès distant à valider." : "Configuration incomplète ou fichier de clé Apple introuvable."),
            result("admob", "AdMob", admob, admob ? "Client OAuth et jeton de renouvellement présents. Validité à vérifier." : "Client OAuth ou jeton de renouvellement manquant."),
            result("google-play", "Google Play", google, google ? "Compte de service disponible ; ses droits Google Play restent à vérifier." : "Aucun compte de service accessible.")
        ], firebaseProjectID: values["FIREBASE_PROJECT_ID"] ?? values["NEXT_PUBLIC_FIREBASE_PROJECT_ID"])
    }
}
