import Foundation

public enum Demo {
    public static let timezone = TimeZone(identifier: "Europe/Zurich")!
    public static let games: [Game] = [
        Game(id: "aurora-grove", slug: "aurora-grove", name: "Aurora Grove", icon: "AG", description: "Une aventure de réflexion autour de la lumière rendue à un jardin oublié.", status: "active", platforms: ["ios", "android"], currentVersion: "1.8.2", integrations: .init(bundleId: "studio.aurora.grove", supabaseProjectRef: "aurora-grove")),
        Game(id: "orbit-tactics", slug: "orbit-tactics", name: "Orbit Tactics", icon: "OT", description: "Un jeu de stratégie compact pour des sessions de cinq minutes.", status: "active", platforms: ["android"], currentVersion: "0.9.6", integrations: .init(googlePackageName: "studio.orbit.tactics")),
        Game(id: "paper-trails", slug: "paper-trails", name: "Paper Trails", icon: "PT", description: "Un prototype narratif en lancement progressif.", status: "draft", platforms: ["ios"], currentVersion: "0.3.1", integrations: .init(bundleId: "studio.paper.trails")),
        .ballpark
    ]
    public static func dashboard(range: Timeframe, gameID: String?, now: Date = Date()) -> Dashboard {
        let scale = gameID == nil ? 1.0 : gameID == "aurora-grove" ? 0.72 : gameID == "orbit-tactics" ? 0.2 : gameID == "paper-trails" ? 0.08 : 0
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let count = range.days ?? 730
        let points: [TrendPoint] = (0..<count).map { index in
            let date = calendar.date(byAdding: .day, value: index - count + 1, to: now)!
            let wave = 1 + sin(Double(index) / 3.2) * 0.16
            let portions = gameID == nil ? [0.72, 0.2, 0.08, 0] : [scale]
            return TrendPoint(date: Dates.day(date, timezone: timezone), revenue: portions.reduce(0) { $0 + (12.4 * wave * $1 * 100).rounded() / 100 }, players: portions.reduce(0) { $0 + Int(2850 * wave * $1) }, installs: portions.reduce(0) { $0 + Int(96 * wave * $1) }, newPlayers: portions.reduce(0) { $0 + Int(60 * wave * $1) })
        }
        let revenue = points.reduce(Decimal.zero) { $0 + Decimal($1.revenue) }
        let total = NSDecimalNumber(decimal: revenue).doubleValue
        let installs = points.reduce(0) { $0 + $1.installs }
        let dau = Double(points.reduce(0) { $0 + $1.players }) / Double(count)
        let arpdau = Analytics.arpdau(revenue: points.map { Decimal($0.revenue) }, active: points.map(\.players)).map { NSDecimalNumber(decimal: $0).doubleValue }
        let rankings: [Ranking] = zip(games, [0.72, 0.2, 0.08, 0]).filter { gameID == nil || $0.0.id == gameID }.map { game, portion in
            if gameID == nil {
                let child = dashboard(range: range, gameID: game.id, now: now)
                return Ranking(gameId: game.id, name: game.name, icon: game.icon, revenue: child.kpis.first { $0.id == "revenue" }!.value!, dau: Int(child.kpis.first { $0.id == "dau" }!.value!), installs: Int(child.kpis.first { $0.id == "installs" }!.value!), change: 0)
            }
            return Ranking(gameId: game.id, name: game.name, icon: game.icon, revenue: total, dau: Int(dau), installs: installs, change: 0)
        }
        let iOSShare = gameID == "orbit-tactics" ? 0.0 : gameID == "paper-trails" ? 1.0 : 0.62
        let platforms = [Breakdown(name: "iOS", value: total * iOSShare, share: iOSShare * 100), Breakdown(name: "Android", value: total * (1 - iOSShare), share: (1 - iOSShare) * 100)].filter { $0.share > 0 }
        return Dashboard(scope: gameID == nil ? "portfolio" : "game", gameId: gameID, timeframe: range, generatedAt: Dates.iso(now), timezone: timezone.identifier, currency: "CHF", kpis: [
            KPI(id: "installs", label: "Installations", value: Double(installs), source: "Démonstration · " + range.label),
            KPI(id: "newPlayers", label: "Nouveaux joueurs", value: Double(points.reduce(0) { $0 + ($1.newPlayers ?? 0) }), source: "Démonstration", hint: "Première partie terminée observée pendant la période sélectionnée. Données fictives."),
            KPI(id: "dau", label: "Actifs quotidiens moyens", value: dau, source: "Démonstration", hint: "Moyenne quotidienne ; un joueur peut être compté dans plusieurs jeux."),
            KPI(id: "revenue", label: "Revenu total", value: total, unit: "currency", source: "Démonstration"),
            KPI(id: "arpdau", label: "ARPDAU", value: arpdau, unit: "currency", source: "Calcul natif", hint: "Revenu total / somme des joueurs actifs quotidiens."),
            KPI(id: "iap", label: "Achats intégrés", value: total * 0.64, unit: "currency", source: "Démonstration"),
            KPI(id: "ads", label: "Publicité", value: total * 0.36, unit: "currency", source: "Démonstration"),
            KPI(id: "adImpressions", label: "Publicités affichées", value: Double(points.reduce(0) { $0 + $1.players / 3 }), source: "Démonstration · " + range.label, hint: "Nombre d’impressions publicitaires sur la période sélectionnée. Données fictives ; une personne peut voir plusieurs publicités.")
        ], trend: points, platformBreakdown: platforms, countryBreakdown: [Breakdown(name: "Suisse", value: total * 0.48, share: 48), Breakdown(name: "France", value: total * 0.32, share: 32), Breakdown(name: "Autres pays", value: total * 0.2, share: 20)], rankings: rankings, alerts: [], dataQuality: .init(completeness: 100, note: "Données fictives, calculées sur la période sélectionnée. L’historique de démonstration couvre deux ans."))
    }
    public static func directory(range: Timeframe, game: Game, now: Date = Date()) throws -> PlayerDirectory {
        let names: [String?] = ["Solène", "Milo", "NoxGrove", "Léonie", nil]
        let profiles = names.enumerated().map { index, name in
            Profile(userID: String(format: "00000000-0000-4000-8000-%012d", index + 1), publicID: String(format: "20000000-0000-4000-8000-%012d", index + 1), name: name, step: [18, 12, 27, 8, 1][index])
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let events = profiles.enumerated().flatMap { playerIndex, profile -> [Completion] in
            guard playerIndex < 4 else { return [] }
            return (0..<(10 + playerIndex * 4)).map { index in
                let date = calendar.date(byAdding: .day, value: -index, to: now)!.addingTimeInterval(-Double(playerIndex * 3600))
                let score = Double(720 + ((index * 37 + playerIndex * 41) % 260))
                return Completion(userID: profile.user_id, runID: String(format: "10000000-0000-4000-8000-%012d", playerIndex * 100 + index), mode: ["campaign", "quick", "daily"][index % 3], difficulty: (index + playerIndex) % 5, elapsedMS: Double(150000 + ((index * 19 + playerIndex * 23) % 210) * 1000), score: score, moves: Double(18 + (index + playerIndex) % 17), hints: (index + playerIndex) % 3 == 0 ? 1 : 0, mistakes: Double(index % 4), undos: index % 5 == 0 ? 1 : 0, perfect: score >= 940, date: date)
            }
        }
        return try Analytics.directory(profiles: profiles, events: events, activeEntitlements: game.hasJardinPaisible ? Set([profiles[0].user_id, profiles[2].user_id]) : nil, range: range, timezone: timezone, now: now)
    }
    public static func reviews(now: Date = Date()) -> [Review] {
        [Review(id: "demo-1", provider: "apple", gameId: "aurora-grove", gameName: "Aurora Grove", country: "CH", rating: 5, title: "Une vraie pause", body: "Les défis quotidiens sont devenus mon petit rituel. L’ambiance est très agréable.", version: "1.8.2", publishedAt: Dates.iso(now)), Review(id: "demo-2", provider: "google-play", gameId: "orbit-tactics", gameName: "Orbit Tactics", country: "FR", rating: 4, title: "Bonne stratégie", body: "Les parties sont courtes et intéressantes. J’aimerais pouvoir revoir mon dernier tour.", version: "0.9.6", publishedAt: Dates.iso(now.addingTimeInterval(-86400)))]
    }
}
