import Foundation
import CryptoKit

public struct ConnectionCheck: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var success: Bool
    public var checkedAt: Date
}

public enum ConnectionChecks {
    // A probe confirms a specific read, not all permissions or a completed provider sync.
    public static func run(_ connections: PersonalConnections, http: HTTPClient = .init(), auroraProjectRefs: Set<String> = []) async -> [ConnectionCheck] {
        await withTaskGroup(of: ConnectionCheck.self) { group in
            group.addTask {
                await check("firebase", name: "Firebase") {
                    let token = try await ServiceAccountTokens().token(account: connections.firebase, scopes: ["https://www.googleapis.com/auth/datastore"], http: http)
                    struct Organization: Decodable { var id: String }
                    let values: [Organization] = try await Firestore(project: connections.projectID, token: token, http: http).list(["organizations"], order: "__name__")
                    return "Lecture confirmée · \(values.count) organisation(s)"
                }
            }
            for project in connections.supabase {
                let normalizedName = project.name.lowercased().filter { $0.isLetter }
                if auroraProjectRefs.contains(project.ref) || normalizedName == "auroragrove" || project.ref == "aurora-grove" {
                    group.addTask { await auroraJourney(project: project, http: http) }
                    group.addTask { await auroraMonetization(project: project, http: http) }
                }
                group.addTask {
                    await check("supabase." + project.ref, name: "Supabase · " + project.name) {
                        try project.validate()
                        if project.ref == Game.ballparkProjectRef {
                            let zone = TimeZone(identifier: "Europe/Zurich")!
                            let interval = Timeframe.today.interval(now: Date(), timezone: zone)
                            let filters = BallparkReportFilters(
                                fromDay: Dates.day(interval.start, timezone: zone),
                                toDayExclusive: Dates.day(interval.end, timezone: zone)
                            )
                            let report = try await BallparkReportReader(personal: project, http: http).overview(filters: filters, limit: 1)
                            return "Lecture administrative Ballpark v1 confirmée · \(report.coverage.participantsMeasured) participant(s) mesuré(s)"
                        }
                        var parts = URLComponents(url: project.url.appendingPathComponent("rest/v1/profiles"), resolvingAgainstBaseURL: false)!
                        parts.queryItems = [URLQueryItem(name: "select", value: "user_id"), URLQueryItem(name: "limit", value: "1")]
                        var request = URLRequest(url: parts.url!); request.httpMethod = "HEAD"
                        project.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                        request.setValue("count=exact", forHTTPHeaderField: "Prefer")
                        let (_, response) = try await http.send(request)
                        let total = response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int($0) }
                        return total.map { "Lecture confirmée · \($0) profil(s)" } ?? "Lecture des profils confirmée"
                    }
                }
            }
            if let admob = connections.admob {
                group.addTask {
                    await check("admob", name: "AdMob") {
                        struct Token: Decodable { var access_token: String }
                        let token: Token = try await http.json(HTTPClient.post(URL(string: "https://oauth2.googleapis.com/token")!, form: ["client_id": admob.clientID, "client_secret": admob.clientSecret, "refresh_token": admob.refreshToken, "grant_type": "refresh_token"]))
                        var request = URLRequest(url: URL(string: "https://admob.googleapis.com/v1/accounts/" + admob.publisherID + "/apps?pageSize=1")!)
                        request.setValue("Bearer " + token.access_token, forHTTPHeaderField: "Authorization")
                        let _: ApplicationPage = try await http.json(request)
                        return "Accès au catalogue confirmé · rapports non synchronisés"
                    }
                }
            }
            if let account = connections.googlePlay {
                group.addTask {
                    await check("googlePlay", name: "Google Play") {
                        let token = try await ServiceAccountTokens().token(account: account, scopes: ["https://www.googleapis.com/auth/playdeveloperreporting"], http: http)
                        var request = URLRequest(url: URL(string: "https://playdeveloperreporting.googleapis.com/v1beta1/apps:search?pageSize=1")!)
                        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                        let page: ApplicationPage = try await http.json(request)
                        return page.apps?.isEmpty != false ? "API accessible · aucune application visible" : "Catalogue Reporting accessible · avis et ventes non vérifiés"
                    }
                }
            }
            if let apple = connections.apple {
                group.addTask {
                    await check("apple", name: "App Store Connect") {
                        let token = try apple.assertion()
                        var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/apps?limit=1")!)
                        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                        struct Page: Decodable { var data: [Application] }
                        let _: Page = try await http.json(request)
                        return "Accès au catalogue confirmé · ventes non vérifiées"
                    }
                }
            }
            var results: [ConnectionCheck] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.name < $1.name }
        }
    }
    public static func auroraJourney(project: PersonalSupabase, http: HTTPClient = .init(), now: Date = Date()) async -> ConnectionCheck {
        do {
            let report = try await AuroraJourneyReportReader(personal: project, http: http).quality(filters: .period(.today, now: now))
            return ConnectionCheck(id: "aurora.journey." + project.ref, name: "Aurora Grove · Parcours", detail: "Lecture administrative quality v1 confirmée · \(report.rows.count) ligne(s) agrégée(s). Comparaison SQL et collecte du jeu à vérifier séparément.", success: true, checkedAt: now)
        } catch {
            let detail: String
            switch error as? GameMetrikError {
            case .http(404): detail = "not_connected · fonction du parcours non disponible (404). Les lectures historiques restent indépendantes."
            case .http(401): detail = "Accès administrateur refusé (401). Vérifie la connexion personnelle."
            case .http(403): detail = "Accès administrateur refusé (403). Le rapport exige les droits service_role."
            default: detail = error is AuroraJourneyError ? error.localizedDescription : "Lecture du parcours impossible. Vérifie le réseau et réessaie."
            }
            return ConnectionCheck(id: "aurora.journey." + project.ref, name: "Aurora Grove · Parcours", detail: detail, success: false, checkedAt: now)
        }
    }
    /// Separate probe: the monetization migration can be absent (404) while the journey answers.
    public static func auroraMonetization(project: PersonalSupabase, http: HTTPClient = .init(), now: Date = Date()) async -> ConnectionCheck {
        let id = "aurora.monetization." + project.ref, name = "Aurora Grove · Monétisation mesurée"
        do {
            let report = try await AuroraJourneyReportReader(personal: project, http: http).ads(filters: .period(.today, now: now))
            let first = report.coverage.collectionFirstReceivedAt.map { "première mesure reçue \($0)" } ?? "aucune mesure reçue pour l’instant"
            return ConnectionCheck(id: id, name: name, detail: "Lecture administrative ads v1 confirmée · \(report.rows.count) ligne(s) agrégée(s) aujourd’hui · \(first). Revenus AdMob à comparer séparément.", success: true, checkedAt: now)
        } catch {
            let detail: String
            switch error as? GameMetrikError {
            case .http(404): detail = "not_connected · fonction de mesure de la monétisation absente (404) : migration non appliquée. Le parcours n’est pas concerné."
            case .http(let status) where status == 401 || status == 403: detail = "Accès administrateur refusé (\(status)). Le rapport exige les droits service_role."
            default: detail = error is AuroraJourneyError ? "Rapport de monétisation illisible : la réponse ne respecte pas le contrat monetization v1." : "Lecture de la monétisation impossible. Vérifie le réseau et réessaie."
            }
            return ConnectionCheck(id: id, name: name, detail: detail, success: false, checkedAt: now)
        }
    }
    private struct Application: Decodable { }
    private struct ApplicationPage: Decodable { var apps: [Application]? }
    private static func check(_ id: String, name: String, operation: () async throws -> String) async -> ConnectionCheck {
        do { return ConnectionCheck(id: id, name: name, detail: try await operation(), success: true, checkedAt: Date()) }
        catch {
            let detail: String
            if let service = error as? GameMetrikError {
                switch service {
                case .http(400): detail = "Requête refusée (400). Vérifie les identifiants ou renouvelle l’autorisation du fournisseur."
                case .http(401): detail = "Identifiants refusés (401). Réimporte des identifiants valides."
                case .http(403): detail = "Accès refusé (403). Vérifie l’activation de l’API et les droits du compte chez le fournisseur."
                default: detail = service.localizedDescription
                }
            } else if error is CancellationError { detail = "Vérification annulée" }
            else { detail = "Vérification impossible. Vérifie le réseau et la configuration." }
            return ConnectionCheck(id: id, name: name, detail: detail, success: false, checkedAt: Date())
        }
    }
}

extension PersonalApple {
    public static func importingKey(_ data: Data, fileName: String, issuerID: String, keyID: String, vendor: String?) throws -> Self {
        // Apple's download name identifies the key; the PEM itself contains no Key ID.
        let detectedID: String?
        if fileName.range(of: #"^AuthKey_[A-Z0-9]{10}\.p8$"#, options: .regularExpression) != nil {
            detectedID = String(fileName.dropFirst(8).dropLast(3))
        } else { detectedID = nil }
        let vendor = vendor?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard vendor == nil || vendor!.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw GameMetrikError.message("Le numéro vendeur Apple doit être numérique.")
        }
        let configuration = try configured(
            issuerID: issuerID.trimmingCharacters(in: .whitespacesAndNewlines),
            keyID: detectedID ?? keyID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            vendor: vendor?.isEmpty == true ? nil : vendor, previous: nil)
        return try configuration.replacingKey(data)
    }

    public static func configured(issuerID: String, keyID: String, vendor: String?, previous: Self?) throws -> Self {
        guard UUID(uuidString: issuerID) != nil, keyID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw GameMetrikError.message("Recopie l’Issuer ID et le Key ID de la clé d’équipe App Store Connect.")
        }
        let sameKey = previous?.issuerID.caseInsensitiveCompare(issuerID) == .orderedSame && previous?.keyID == keyID
        return Self(issuerID: issuerID, keyID: keyID, privateKey: sameKey ? previous?.privateKey : nil, vendor: vendor)
    }

    public func replacingKey(_ data: Data) throws -> Self {
        guard data.count < 20_000, let pem = String(data: data, encoding: .utf8) else { throw GameMetrikError.message("Le fichier Apple doit être une clé .p8 au format texte.") }
        do { _ = try P256.Signing.PrivateKey(pemRepresentation: pem) }
        catch { throw GameMetrikError.message("La clé Apple n’est pas une clé privée P-256 valide.") }
        var copy = self; copy.privateKey = pem; return copy
    }
    public func assertion(now: Date = Date()) throws -> String {
        guard let privateKey else { throw GameMetrikError.message("Clé .p8 manquante. Utilise Choisir la clé Apple dans les réglages.") }
        let key: P256.Signing.PrivateKey
        do { key = try P256.Signing.PrivateKey(pemRepresentation: privateKey) }
        catch { throw GameMetrikError.message("Clé Apple invalide. Réimporte la clé .p8 associée à cet identifiant.") }
        let header = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let claims: [String: Any] = ["iss": issuerID, "iat": Int(now.timeIntervalSince1970), "exp": Int(now.timeIntervalSince1970) + 900, "aud": "appstoreconnect-v1"]
        let input = JWTEncoding.encode(try JSONSerialization.data(withJSONObject: header, options: .sortedKeys)) + "." + JWTEncoding.encode(try JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
        return input + "." + JWTEncoding.encode(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
}
