import Foundation

struct SyncWindow: Sendable {
    var days: [String]
    var now: Date
    var start: String { days.first! }
    var end: String { days.last! }
    init(range: Timeframe, now: Date) throws {
        guard let count = range.days else { throw GameMetrikError.message("Choisis une période de 1 jour à 1 an pour synchroniser les rapports fournisseurs. « Tout » reste disponible dans les vues joueurs.") }
        self.now = now
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let today = calendar.startOfDay(for: now)
        days = (0..<count).reversed().map { Dates.day(calendar.date(byAdding: .day, value: -$0, to: today)!, timezone: calendar.timeZone) }
    }
    static func date(_ day: String) throws -> Date {
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let value = Dates.parse(day + "T12:00:00Z"), Dates.day(value, timezone: .gmt) == day else { throw ReportFormats.invalid() }
        return value
    }
    static func object(_ day: String) -> [String: Int] {
        let p = day.split(separator: "-").compactMap { Int($0) }; return ["year":p[0],"month":p[1],"day":p[2]]
    }
    var months: [String] { Array(Set(days.map { String($0.prefix(7)).replacingOccurrences(of: "-", with: "") })).sorted() }
}
struct FinancialDay: Codable, Sendable {
    var money: [String: Decimal] = [:]
    var iap: [String: Decimal] = [:]
    var installs: Int = 0
    // Older cached reports contain earnings only; a missing count remains unknown.
    var adImpressions: Int?
    // Nil for old aggregates and providers without an authoritative unit count.
    var appleIAPNetUnits: Int?
    var allocations: [RevenueAllocation]?
    mutating func add(_ amount: Decimal, currency: String, purchase: Bool) throws {
        guard currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else { throw ReportFormats.invalid() }
        money[currency, default: 0] += amount
        if purchase { iap[currency, default: 0] += amount }
    }
}
struct ProviderReport: Sendable {
    var gameID: String
    var provider: String
    var title: String
    var days: [String: FinancialDay] = [:]
    var note: String
    var supportsMoney = true
    var supportsInstalls = false
    var supportsIAP = false
    var pendingDays: Set<String> = []
    var hasError = false
    var reusedDays: Set<String> = []
    var readAt: [String: String] = [:]
    var timezone: String?
}
struct ActivityEvent: Decodable, Sendable {
    var user_id: String
    var run_id: String
    var completed_at: String
}
struct Engagement: Codable, Sendable {
    var daily: [String: Int]
    var monthly: Int
    var retained: Int
    var eligible: Int
    // Optional so older encrypted caches keep their meaning: unknown is not zero.
    var newPlayersDaily: [String: Int]?
    // Rows set aside as invalid or contradictory; nil in caches written before 0.14.
    var ignoredEvents: Int?
    static func build(_ events: [ActivityEvent], window: SyncWindow, timezone: TimeZone) throws -> Self {
        var seen: [String: String] = [:], activity: [String: Set<String>] = [:], first: [String: String] = [:]
        var monthly: Set<String> = [], ignored = 0
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let today = calendar.startOfDay(for: window.now)
        let monthlyStart = calendar.date(byAdding: .day, value: -29, to: today)!
        for event in events {
            // One bad row is set aside and disclosed; it must not hide every other player.
            guard UUID(uuidString: event.user_id) != nil, UUID(uuidString: event.run_id) != nil, let date = Dates.parse(event.completed_at) else { ignored += 1; continue }
            let user = event.user_id.lowercased(), key = user + "/" + event.run_id.lowercased()
            if let previous = seen[key] { if previous != event.completed_at { ignored += 1 }; continue }
            seen[key] = event.completed_at
            guard date <= window.now else { continue }
            let day = Dates.day(date, timezone: timezone)
            activity[day, default: []].insert(user)
            first[user] = min(first[user] ?? day, day)
            if date >= monthlyStart { monthly.insert(user) }
        }
        let todayKey = Dates.day(window.now, timezone: timezone)
        var eligible = 0, retained = 0
        for (user, day) in first where day >= window.start && day <= window.end {
            let seventh = Dates.day(calendar.date(byAdding: .day, value: 7, to: try SyncWindow.date(day))!, timezone: .gmt)
            // Exclude the unfinished seventh day, not just cohorts younger than seven days.
            if seventh < todayKey { eligible += 1; if activity[seventh]?.contains(user) == true { retained += 1 } }
        }
        let newPlayers = first.values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return Self(daily: activity.mapValues(\.count), monthly: monthly.count, retained: retained, eligible: eligible, newPlayersDaily: newPlayers, ignoredEvents: ignored)
    }
}

public struct NativeDashboardSync: Sendable {
    public var http: HTTPClient
    public var tokens: ServiceAccountTokens
    public init(http: HTTPClient = .init(), tokens: ServiceAccountTokens = .init()) { self.http = http; self.tokens = tokens }
    public func run(games: [Game], gameID: String?, range: Timeframe, connections: PersonalConnections, now: Date = Date(), googlePlayGameIDs: Set<String>? = nil, progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> Dashboard {
        var cache = AggregateCache()
        return try await runCached(games: games, gameID: gameID, range: range, connections: connections, cache: &cache, now: now, googlePlayGameIDs: googlePlayGameIDs, progress: progress)
    }
    public func runCached(games: [Game], gameID: String?, range: Timeframe, connections: PersonalConnections, cache: inout AggregateCache, force: Bool = false, entireStudio: Bool = false, refreshRecent: Bool = false, now: Date = Date(), googlePlayGameIDs: Set<String>? = nil, progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> Dashboard {
        cache.reconcile(games: games)
        let window = try SyncWindow(range: range, now: now)
        // Ballpark has its own versioned RPC contract and must never be routed to the Aurora tables.
        let candidates = entireStudio ? games : games.filter { gameID == nil ? $0.status == "active" : $0.id == gameID }
        let selected = candidates.filter { !$0.usesBallparkAnalytics }
        guard !selected.isEmpty else { throw GameMetrikError.message("Ce jeu utilise la rubrique Analyse Ballpark dédiée.") }
        var reports: [ProviderReport] = [], engagement: [String: Engagement] = [:], alerts: [DashboardAlert] = []
        let providers = NativeReports(http: http, tokens: tokens)
        for game in selected {
            try Task.checkCancellation()
            await progress("\(game.name) · collecte des sources")
            let collectsApple = game.integrations.appleAppId != nil || game.platforms.contains("ios") || game.platforms.contains("macos")
            let collectsGoogle = googlePlayGameIDs?.contains(game.id) ?? (game.integrations.googlePackageName != nil || game.platforms.contains("android"))
            let adWindow = cache.requestedWindow(window, gameID: game.id, providers: ["admob"], force: force, refreshRecent: refreshRecent || entireStudio)
            let appleWindow = cache.requestedWindow(window, gameID: game.id, providers: ["apple"], force: force, refreshRecent: refreshRecent || entireStudio)
            var googleWindow = cache.requestedWindow(window, gameID: game.id, providers: ["google-installs", "google-earnings"], force: force, refreshRecent: refreshRecent || entireStudio)
            let months = Set(googleWindow.months)
            googleWindow.days = window.days.filter { months.contains(String($0.prefix(7)).replacingOccurrences(of: "-", with: "")) }
            // Sources of one game are independent: read them together, then merge in a fixed order.
            async let ads = providers.admob(game: game, connections: connections, window: adWindow)
            async let apple: ProviderReport? = collectsApple ? providers.apple(game: game, connections: connections, window: appleWindow, progress: progress) : nil
            async let google: [ProviderReport] = collectsGoogle ? providers.google(game: game, connections: connections, window: googleWindow, progress: progress) : []
            async let activity = Self.activity(game: game, connections: connections, window: window, now: now, http: http)
            let (adReport, appleReport, googleReports, players) = try await (ads, apple, google, activity)
            reports.append(cache.merge(adReport, window: window))
            if let appleReport { reports.append(cache.merge(appleReport, window: window)) }
            reports += googleReports.map { cache.merge($0, window: window) }
            switch players {
            case .success(let value):
                engagement[game.id] = value
                cache.engagement[AggregateCache.snapshotID(gameID: game.id, range: range)] = .init(value: value, fetchedAt: now)
                if let ignored = value.ignoredEvents, ignored > 0 {
                    alerts.append(.init(id: game.id+".players", severity: "warning", title: game.name+" · Joueurs", description: "\(ignored) partie(s) ignorée(s) : identifiant, date ou doublon incohérent. Les autres parties sont comptées ; les indicateurs joueurs peuvent être légèrement sous-estimés."))
                }
            case .failure(let error):
                try Task.checkCancellation()
                var detail = Self.safe(error)
                if let saved = cache.engagement[AggregateCache.snapshotID(gameID: game.id, range: range)],
                   now.timeIntervalSince(saved.fetchedAt) < 30 * 86400 {
                    engagement[game.id] = saved.value
                    detail += " Statistiques agrégées conservées du \(Dates.iso(saved.fetchedAt))."
                }
                alerts.append(.init(id: game.id+".players", severity: "warning", title: game.name+" · Joueurs", description: detail))
            }
        }
        try Task.checkCancellation()
        for report in reports {
            let amounts = report.days.values.reduce(into: [String: Decimal]()) { total, day in
                for (currency, amount) in day.money { total[currency, default: 0] += amount }
            }
            let amountNote = amounts.isEmpty ? "" : " Montants reçus : "+amounts.sorted { $0.key < $1.key }.map { $0.key+" "+NSDecimalNumber(decimal: $0.value).stringValue }.joined(separator: ", ")+"."
            alerts.append(.init(id: report.gameID+"."+report.provider, severity: report.hasError || (report.days.isEmpty && !Set(window.days).isSubset(of: report.pendingDays)) ? "warning" : "info", title: (selected.first(where: { $0.id == report.gameID })?.name ?? "")+" · "+report.title, description: "\(report.days.count)/\(window.days.count) jours reçus. "+report.note+amountNote))
        }
        // One collection feeds every game and the active studio; no repeated provider reads.
        if entireStudio {
            for game in selected {
                let snapshot = Self.dashboard(games: [game], gameID: game.id, range: range, window: window,
                    reports: reports.filter { $0.gameID == game.id }, engagement: engagement.filter { $0.key == game.id },
                    alerts: alerts.filter { $0.id.hasPrefix(game.id + ".") })
                cache.save(snapshot, now: now)
            }
        }
        let portfolioGames = entireStudio ? selected.filter { $0.status == "active" } : selected
        let ids = Set(portfolioGames.map(\.id))
        let result = Self.dashboard(games: portfolioGames, gameID: gameID, range: range, window: window,
            reports: reports.filter { ids.contains($0.gameID) }, engagement: engagement.filter { ids.contains($0.key) },
            alerts: alerts.filter { alert in portfolioGames.contains { alert.id.hasPrefix($0.id + ".") } })
        cache.save(result, now: now)
        return result
    }
    static func activity(game: Game, connections: PersonalConnections, window: SyncWindow, now: Date, http: HTTPClient) async -> Result<Engagement, Error> {
        do {
            guard let project = connections.supabase.first(where: { $0.ref == game.integrations.supabaseProjectRef }), let zone = TimeZone(identifier: project.timezone) else {
                throw GameMetrikError.message("Aucune connexion joueurs configurée pour ce jeu.")
            }
            let events: [ActivityEvent] = try await SupabaseReader(personal: project, http: http).rows("completion_events", select: "user_id,run_id,completed_at", order: "created_at.asc,user_id.asc,run_id.asc", filters: [.init(name: "completed_at", value: "lte." + Dates.iso(now))])
            return .success(try Engagement.build(events, window: window, timezone: zone))
        } catch { return .failure(error) }
    }
    static func safe(_ error: Error) -> String {
        if let error = error as? GameMetrikError { return error.localizedDescription }
        if error is CancellationError { return "Collecte annulée." }
        return "La collecte a échoué. Vérifie le réseau, puis réessaie."
    }
    static func dashboard(games: [Game], gameID: String?, range: Timeframe, window: SyncWindow, reports: [ProviderReport], engagement: [String: Engagement], alerts: [DashboardAlert]) -> Dashboard {
        let currency = "CHF"
        func sum(_ values: [[String: Decimal]]) -> Double? {
            guard !values.isEmpty, !values.contains(where: { $0.contains { $0.key != currency && $0.value != 0 } }) else { return nil }
            return NSDecimalNumber(decimal: values.reduce(Decimal(0)) { $0 + ($1[currency] ?? 0) }).doubleValue
        }
        func amounts(_ values: [[String: Decimal]]) -> [String: Double]? {
            guard !values.isEmpty else { return nil }
            let totals = values.reduce(into: [String: Decimal]()) { total, day in
                for (code, amount) in day { total[code, default: 0] += amount }
            }
            // Preserve explicitly reported zero currencies; a free-sales report may have no currency.
            return totals.mapValues { NSDecimalNumber(decimal: $0).doubleValue }
        }
        func coverage(_ sources: [ProviderReport], hasValue: (FinancialDay) -> Bool = { _ in true }) -> KPI.Coverage {
            let full = window.days.filter { day in
                !sources.isEmpty && sources.allSatisfy { report in
                    !report.pendingDays.contains(day) && report.days[day].map(hasValue) == true
                }
            }.count
            let onlyPending = !sources.isEmpty && sources.allSatisfy { report in
                !report.hasError && window.days.allSatisfy { day in
                    report.days[day].map(hasValue) == true || report.pendingDays.contains(day)
                }
            }
            let anyValue = sources.contains { $0.days.values.contains(where: hasValue) }
            return .init(status: full == window.days.count ? "complete" : onlyPending ? "pending" : anyValue ? "partial" : "missing", availableDays: full, expectedDays: window.days.count)
        }
        func financial(_ id: String, _ label: String, _ sources: [ProviderReport], iap: Bool = false, installs: Bool = false) -> KPI {
            let values = sources.flatMap { $0.days.values }
            let moneyValues = values.map { iap ? $0.iap : $0.money }
            var kpi = KPI(id: id, label: label, value: installs ? (values.isEmpty ? nil : Double(values.reduce(0) { $0 + $1.installs })) : sum(moneyValues), unit: installs ? "number" : "currency", source: Array(Set(sources.map(\.title))).sorted().joined(separator: " + "), hint: "Somme des rapports reçus uniquement. Les journées manquantes et les sources en erreur ne valent pas zéro. Les devises sont affichées séparément, sans conversion. Ces rapports décrivent des recettes, pas des virements bancaires.")
            kpi.coverage = coverage(sources)
            if !installs {
                kpi.amountsByCurrency = amounts(moneyValues)
                if kpi.amountsByCurrency != nil { kpi.state = "available" }
            }
            return kpi
        }
        let revenueReports = reports.filter(\.supportsMoney), storeReports = reports.filter(\.supportsIAP), installReports = reports.filter(\.supportsInstalls), adReports = reports.filter { $0.provider == "admob" }
        var installations = financial("installs", "Installations", installReports, installs: true)
        installations.source = range.label + " · " + installations.source
        installations.hint = "Nouvelles acquisitions déclarées par les boutiques sur la période sélectionnée, hors mises à jour et retéléchargements Apple. Ce n’est pas le nombre d’appareils sur lesquels le jeu est actuellement installé. Les rapports manquants restent inconnus."
        var kpis = [installations]
        let completePlayers = engagement.count == games.count
        let daily = window.days.map { day in engagement.values.reduce(0) { $0 + ($1.daily[day] ?? 0) } }
        let completeNewPlayers = completePlayers && engagement.values.allSatisfy { $0.newPlayersDaily != nil }
        let newPlayers = window.days.map { day in engagement.values.reduce(0) { $0 + ($1.newPlayersDaily?[day] ?? 0) } }
        kpis.append(KPI(id: "newPlayers", label: "Nouveaux joueurs", value: completeNewPlayers ? Double(newPlayers.reduce(0,+)) : nil, source: "Première partie terminée", hint: "Joueurs dont la première partie terminée observée dans l’historique conservé se situe dans la période sélectionnée. Chaque joueur compte une fois par jeu. Ne mesure ni les installations ni les créations de profils. Synchroniser actualise cet indicateur."))
        let hint = "Activité = au moins une partie terminée. Le simple lancement du jeu n’est pas mesuré. Pour le studio, un même joueur présent dans deux jeux compte dans chacun."
        kpis.append(KPI(id: "dau", label: "Joueurs actifs / jour", value: completePlayers ? Double(daily.reduce(0,+))/Double(window.days.count) : nil, source: "Parties terminées · moyenne", hint: hint+" La journée en cours est provisoire."))
        kpis.append(KPI(id: "mau", label: "Joueurs actifs · 30 jours", value: completePlayers ? Double(engagement.values.reduce(0) { $0+$1.monthly }) : nil, source: "30 jours glissants", hint: hint+" Cette fenêtre reste de 30 jours, quelle que soit la période sélectionnée."))
        kpis += [financial("revenue", "Revenus reçus", revenueReports), financial("iap", "Achats intégrés reçus", storeReports, iap: true), financial("ads", "Revenus publicitaires", adReports)]
        let appleReports = storeReports.filter { $0.provider == "apple" }
        let netUnits = appleReports.flatMap { $0.days.values.compactMap(\.appleIAPNetUnits) }
        var purchases = KPI(id: "appleIAPNetUnits", label: "Achats intégrés nets", value: netUnits.isEmpty ? nil : netUnits.reduce(0) { $0 + Double($1) }, source: "Apple · " + range.label, hint: "Unités d’achats intégrés Apple, remboursements déduits, selon les journées des rapports Apple (Pacifique). Le solde peut être négatif. Seuls les rapports reçus sont comptés ; les anciens rapports sans compteur doivent être resynchronisés. Google Play n’est pas inclus.")
        purchases.coverage = coverage(appleReports, hasValue: { $0.appleIAPNetUnits != nil })
        if !appleReports.isEmpty { kpis.append(purchases) }
        let impressions = adReports.flatMap { report in window.days.compactMap { report.days[$0]?.adImpressions } }
        var adCount = KPI(id: "adImpressions", label: "Publicités affichées", value: impressions.isEmpty ? nil : impressions.reduce(0) { $0 + Double($1) }, source: "AdMob · " + range.label, hint: "Nombre d’impressions déclarées par AdMob pour les jeux et la période sélectionnés, tous formats confondus. Une même personne peut voir plusieurs publicités. Journées selon le fuseau du compte AdMob ; la journée en cours est provisoire. Les rapports absents restent inconnus et les valeurs reçues sont incluses dans le total partiel.")
        adCount.coverage = coverage(adReports + games.filter { game in !adReports.contains { $0.gameID == game.id } }.map { ProviderReport(gameID: $0.id, provider: "admob", title: "AdMob", note: "") }, hasValue: { $0.adImpressions != nil })
        kpis.append(adCount)
        // ARPDAU uses exactly the same complete days for numerator and denominator.
        let paired = window.days.filter { day in completePlayers && !revenueReports.isEmpty && revenueReports.allSatisfy { $0.days[day] != nil && !$0.pendingDays.contains(day) } }
        let active = paired.reduce(0) { total, day in total + engagement.values.reduce(0) { $0+($1.daily[day] ?? 0) } }
        let revenue = sum(paired.flatMap { day in revenueReports.compactMap { $0.days[day]?.money } })
        var arpdau = KPI(id: "arpdau", label: "Revenu / joueur actif", value: active > 0 ? revenue.map { $0/Double(active) } : nil, unit: "currency", source: "\(paired.count) jours comparables", hint: hint+" Seulement les jours complets pour toutes les sources financières, avec le même dénominateur pour chaque devise. Les devises restent séparées.")
        if active > 0 {
            arpdau.amountsByCurrency = amounts(paired.flatMap { day in revenueReports.compactMap { $0.days[day]?.money } })?.mapValues { $0 / Double(active) }
            if arpdau.amountsByCurrency != nil { arpdau.state = "available" }
        }
        kpis.append(arpdau)
        let eligible = engagement.values.reduce(0) { $0+$1.eligible }, retained = engagement.values.reduce(0) { $0+$1.retained }
        kpis.append(KPI(id: "retention", label: "Retour à J7", value: completePlayers && eligible > 0 ? Double(retained)*100/Double(eligible) : nil, unit: "percent", source: "\(eligible) joueurs admissibles", hint: "Partie terminée exactement 7 jours après la première partie observée dans l’historique conservé. Cohortes commencées dans la période sélectionnée, septième journée entièrement écoulée. Ce n’est pas une rétention depuis l’installation."))
        let trend = window.days.enumerated().map { i, day in
            let moneyValues = revenueReports.compactMap { $0.days[day]?.money }
            let installsValues = installReports.compactMap { $0.days[day]?.installs }
            let money = sum(moneyValues)
            return TrendPoint(date: day, revenue: money ?? 0, players: daily[i], installs: installsValues.reduce(0,+), revenueAvailable: money != nil, playersAvailable: completePlayers, installsAvailable: !installsValues.isEmpty, newPlayers: completeNewPlayers ? newPlayers[i] : nil, revenueByCurrency: amounts(moneyValues), appleIAPNetUnits: !appleReports.isEmpty && appleReports.allSatisfy { $0.days[day]?.appleIAPNetUnits != nil } ? appleReports.reduce(0) { $0 + ($1.days[day]?.appleIAPNetUnits ?? 0) } : nil)
        }
        let coverages = kpis.compactMap(\.coverage)
        let denominator = coverages.reduce(0) { $0+$1.expectedDays }
        let sourceDays = reports.flatMap { report in window.days.map { day in
            let value = report.days[day]
            return SourceDay(gameID: report.gameID, provider: report.provider, date: day,
                status: value != nil ? (report.reusedDays.contains(day) ? "cached" : "received") : report.pendingDays.contains(day) ? "pending" : "missing",
                readAt: report.readAt[day], timezone: report.timezone,
                revenueCHF: report.supportsMoney ? value.flatMap { sum([$0.money]) } : nil,
                adImpressions: value?.adImpressions, sourceHasError: report.hasError, appleIAPNetUnits: value?.appleIAPNetUnits)
        } }
        let details = RevenueDetails.build(reports: reports, window: window)
        func breakdown(_ dimension: RevenueDimension) -> [Breakdown] {
            details.breakdown(dimension, currency: currency).map { Breakdown(name: $0.name, value: $0.value, share: $0.share ?? 0) }
        }
        return Dashboard(scope: gameID == nil ? "portfolio" : "game", gameId: gameID, timeframe: range, generatedAt: Dates.iso(window.now), timezone: "Journées des fournisseurs · activité selon le fuseau du jeu", currency: currency, kpis: kpis, trend: trend, platformBreakdown: breakdown(.platform), countryBreakdown: breakdown(.country), rankings: [], alerts: alerts, dataQuality: .init(completeness: denominator > 0 ? Double(coverages.reduce(0) { $0+$1.availableDays })*100/Double(denominator) : 0, note: "Collecte native directe du \(window.start) au \(window.end). Aucune dépendance aux bilans web. Les rapports peuvent arriver en retard ; les totaux partiels ne représentent pas la période complète."), sourceDays: sourceDays, revenueDetails: details)
    }
}
