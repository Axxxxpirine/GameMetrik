import Foundation

// Only publishable keys: privileged keys from the web server are deliberately rejected.
// The project must trust Firebase JWTs and enforce member/admin access through RLS.
public struct SupabaseConfiguration: Codable, Sendable, Identifiable {
    public var ref: String
    public var url: URL
    public var publishableKey: String
    public var timezone: String
    public var id: String { ref }
    public func validate() throws {
        guard !ref.isEmpty, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              publishableKey.hasPrefix("sb_publishable_"), publishableKey.count > 20,
              TimeZone(identifier: timezone) != nil else {
            throw GameMetrikError.message("Configuration Supabase invalide : URL HTTPS, clé sb_publishable_ et fuseau horaire requis. Les clés secrètes et service_role ne sont jamais acceptées.")
        }
    }
    public static func read(_ data: Data) throws -> [Self] {
        let projects = try JSONDecoder().decode([Self].self, from: data)
        guard Set(projects.map(\.ref)).count == projects.count else { throw GameMetrikError.message("Un projet Supabase est déclaré plusieurs fois.") }
        try projects.forEach { try $0.validate() }
        return projects
    }
}
public struct SupabaseReader: Sendable {
    private enum Access: Sendable {
        case member(SupabaseConfiguration, String)
        case personal(PersonalSupabase)
    }
    private let access: Access
    private var endpoint: URL {
        switch access { case .member(let config, _): config.url; case .personal(let config): config.url }
    }
    private var timezone: String {
        switch access { case .member(let config, _): config.timezone; case .personal(let config): config.timezone }
    }
    private func headers() throws -> [String: String] {
        switch access {
        case .member(let config, let token):
            try config.validate()
            return ["apikey": config.publishableKey, "Authorization": "Bearer " + token]
        case .personal(let config):
            try config.validate()
            return config.headers
        }
    }
    public var http: HTTPClient
    public init(config: SupabaseConfiguration, token: String, http: HTTPClient = .init()) { self.access = .member(config, token); self.http = http }
    public init(personal: PersonalSupabase, http: HTTPClient = .init()) { self.access = .personal(personal); self.http = http }
    public func rows<T: Decodable>(_ table: String, select: String, order: String, filters: [URLQueryItem] = [], as: T.Type = T.self) async throws -> [T] {
        let headers = try headers()
        guard ["profiles", "completion_events", "purchase_entitlements", "premium_grants"].contains(table) else { throw GameMetrikError.message("Table non autorisée.") }
        var result: [T] = []; let pageSize = 500
        var total: Int?
        while true {
            try Task.checkCancellation()
            var parts = URLComponents(url: endpoint.appendingPathComponent("rest/v1/" + table), resolvingAgainstBaseURL: false)!
            parts.queryItems = filters + [URLQueryItem(name: "select", value: select), URLQueryItem(name: "order", value: order), URLQueryItem(name: "offset", value: String(result.count)), URLQueryItem(name: "limit", value: String(pageSize))]
            var request = URLRequest(url: parts.url!)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            // An exact count scans the table: ask once, then page until the known total.
            if result.isEmpty { request.setValue("count=exact", forHTTPHeaderField: "Prefer") }
            let (data, response) = try await http.send(request)
            let page = try JSONDecoder().decode([T].self, from: data)
            if result.isEmpty { total = response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int($0) } }
            result += page
            guard result.count <= 100_000 else { throw GameMetrikError.message("Plus de 100 000 lignes à lire. Choisis une période plus courte.") }
            if let total, result.count >= total { return result }
            if page.isEmpty {
                if let total, result.count < total { throw GameMetrikError.message("Lecture Supabase incomplète. Actualise pour réessayer.") }
                return result
            }
            // Do not stop at a short page: server-side caps can be lower than our page size.
        }
    }
    public func directory(game: Game, range: Timeframe, now: Date = Date()) async throws -> PlayerDirectory {
        _ = try headers()
        guard let zone = TimeZone(identifier: timezone) else { throw GameMetrikError.message("Fuseau horaire Supabase invalide.") }
        let interval = range.interval(now: now, timezone: zone)
        var filters = [URLQueryItem(name: "completed_at", value: "lt." + Dates.iso(interval.end))]
        if range != .all { filters.append(URLQueryItem(name: "completed_at", value: "gte." + Dates.iso(interval.start))) }
        async let profiles: [Profile] = rows("profiles", select: "user_id,public_id,display_name,adventure_step", order: "public_id.asc")
        async let events: [Completion] = rows("completion_events", select: "user_id,run_id,mode,difficulty,elapsed_ms,score,maximum_score,moves,hints,mistakes,undos,perfect,completed_at", order: "created_at.asc,run_id.asc", filters: filters)
        let (profileRows, eventRows) = try await (profiles, events)
        var entitlements: Set<String>?; var note: String?
        if game.hasJardinPaisible {
            do { entitlements = try await activeEntitlements() }
            catch is CancellationError { throw CancellationError() }
            catch { note = "Jardin paisible : statut non disponible. Les achats n’ont pas pu être vérifiés." }
        }
        return try Analytics.directory(profiles: profileRows, events: eventRows, activeEntitlements: entitlements, range: range, timezone: zone, now: now, entitlementNote: note)
    }
    private func activeEntitlements() async throws -> Set<String> {
        struct Entitlement: Decodable { var user_id: String }
        let filters = [URLQueryItem(name: "product_id", value: "eq.com.auroragrove.paisible"), URLQueryItem(name: "active", value: "eq.true"), URLQueryItem(name: "user_id", value: "not.is.null")]
        async let purchases: [Entitlement] = rows("purchase_entitlements", select: "user_id", order: "entitlement_id.asc", filters: filters)
        async let grants: [Entitlement] = rows("premium_grants", select: "user_id", order: "grant_id.asc", filters: filters)
        let (p, g) = try await (purchases, grants)
        return Set((p + g).map { $0.user_id.lowercased() })
    }
}
