import Foundation

/// Export only the presentation models, never credentials, raw profiles or completion events.
public enum ExportValue: Encodable, Sendable, Equatable {
    case text(String), number(Double), boolean(Bool), null
    public static func number(_ value: Double?) -> Self {
        value.flatMap { $0.isFinite ? .number($0) : nil } ?? .null
    }
    public static func text(_ value: String?) -> Self { value.map(Self.text) ?? .null }
    public static func integer(_ value: Int) -> Self { .number(Double(value)) }
    public static func date(_ value: Date?) -> Self { .text(value.map(Dates.iso)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .number(let value): if value.isFinite { try container.encode(value) } else { try container.encodeNil() }
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    var csv: String {
        switch self {
        case .text(let value):
            // CSV quoting alone does not prevent a spreadsheet from executing a formula.
            let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
            let safe = first.map { "=+-@".contains($0) } == true || value.first == "\t" || value.first == "\r" ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .number(let value): return value.isFinite ? String(value) : ""
        case .boolean(let value): return value ? "true" : "false"
        case .null: return ""
        }
    }
}

public struct ExportTable: Encodable, Sendable {
    public var id: String
    public var title: String
    public var generatedAt: String?
    public var timezone: String?
    public var currency: String?
    public var columns: [String]
    public var rows: [[ExportValue]]
    public func csvData() -> Data {
        let lines = [columns.map { ExportValue.text($0).csv }.joined(separator: ",")]
            + rows.map { $0.map(\.csv).joined(separator: ",") }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
    public func encode(to encoder: any Encoder) throws {
        enum Keys: String, CodingKey { case id, title, generatedAt, timezone, currency, columns, rows }
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id); try container.encode(title, forKey: .title)
        try container.encodeIfPresent(generatedAt, forKey: .generatedAt)
        try container.encodeIfPresent(timezone, forKey: .timezone)
        try container.encodeIfPresent(currency, forKey: .currency)
        try container.encode(columns, forKey: .columns)
        try container.encode(rows.map { Dictionary(uniqueKeysWithValues: zip(columns, $0)) }, forKey: .rows)
    }
}

public struct ExportCheck: Codable, Sendable {
    public var section: String
    public var status: String
    public var detail: String
    public var updatedAt: String?
    public init(section: String, status: String, detail: String, updatedAt: String? = nil) {
        self.section = section; self.status = status; self.detail = detail; self.updatedAt = updatedAt
    }
}

public struct DataExport: Encodable, Sendable {
    public let schemaVersion = 6
    public var exportedAt: String
    public var mode: String
    public var gameID: String?
    public var gameName: String
    public var timeframe: String
    public var scope: String
    public var notes: [String] = []
    public var missingViews: [String] = []
    public var checks: [ExportCheck] = []
    public var tables: [ExportTable] = []
    public init(now: Date = Date(), mode: String, gameID: String?, gameName: String, timeframe: String, scope: String) {
        exportedAt = Dates.iso(now); self.mode = mode; self.gameID = gameID; self.gameName = gameName
        self.timeframe = timeframe; self.scope = scope
    }
    public mutating func add(_ id: String, _ title: String, _ columns: [String], _ rows: [[ExportValue]], generatedAt: String? = nil, timezone: String? = nil, currency: String? = nil) {
        tables.append(ExportTable(id: id, title: title, generatedAt: generatedAt, timezone: timezone, currency: currency, columns: columns, rows: rows))
    }
    mutating func addKPIs(_ kpis: [KPI], prefix: String, date: String, timezone: String?, currency: String?) {
        add(prefix + "_indicateurs", prefix == "studio" ? "Indicateurs de la vue d’ensemble" : "Indicateurs de gameplay",
            ["id", "label", "value", "unit", "state", "source", "definition", "change_percent", "change_direction", "coverage_status", "available_days", "expected_days"],
            kpis.map { k in [.text(k.id), .text(k.label), k.state == "available" ? .number(k.value) : .null, .text(k.unit), .text(k.state), .text(k.source), .text(k.hint), .number(k.change), .text(k.changeDirection), .text(k.coverage?.status), .number(k.coverage.map { Double($0.availableDays) }), .number(k.coverage.map { Double($0.expectedDays) })] }, generatedAt: date, timezone: timezone, currency: currency)
    }
    mutating func addBreakdown(_ rows: [Breakdown], id: String, date: String, currency: String? = nil) {
        let titles = ["studio_plateformes": "Revenus par plateforme", "studio_pays": "Revenus par pays", "gameplay_modes": "Modes de jeu", "gameplay_difficultes": "Difficultés"]
        add(id, titles[id] ?? "Répartition", ["name", "value", "share_percent"], rows.map { [.text($0.name), .number($0.value), .number($0.share)] }, generatedAt: date, currency: currency)
    }
    public mutating func addDashboard(_ dashboard: Dashboard) {
        let date = dashboard.generatedAt, zone = dashboard.timezone, currency = dashboard.currency
        var kpis = dashboard.kpis
        for (id, label) in [("newPlayers", "Nouveaux joueurs"), ("adImpressions", "Publicités affichées")] where !kpis.contains(where: { $0.id == id }) {
            kpis.append(KPI(id: id, label: label, value: nil, source: "À synchroniser"))
        }
        addKPIs(kpis, prefix: "studio", date: date, timezone: zone, currency: currency)
        add("studio_historique", "Historique quotidien", ["date", "revenue", "active_players", "installs", "new_players", "apple_iap_net_units"], dashboard.trend.map { p in
            [.text(p.date), .number(DashboardMetric.revenue.value(p)), .number(DashboardMetric.players.value(p)), .number(DashboardMetric.installs.value(p)), .number(DashboardMetric.newPlayers.value(p)), .number(p.appleIAPNetUnits.map(Double.init))]
        }, generatedAt: date, timezone: zone, currency: currency)
        let currencyRows: [[ExportValue]] = kpis.flatMap { k in
            (k.amountsByCurrency ?? [:]).sorted { $0.key < $1.key }.map { code, value in
                [.text(k.id), .text(k.label), .text(code), .number(value)]
            }
        }
        if !currencyRows.isEmpty {
            add("studio_indicateurs_devises", "Montants des indicateurs par devise", ["indicator_id", "label", "currency", "value"], currencyRows, generatedAt: date, timezone: zone)
            let dailyRows: [[ExportValue]] = dashboard.trend.flatMap { point in
                (point.revenueByCurrency ?? [:]).sorted { $0.key < $1.key }.map { code, value in
                    [.text(point.date), .text(code), .number(value)]
                }
            }
            add("studio_historique_devises", "Recettes quotidiennes par devise", ["date", "currency", "revenue"], dailyRows, generatedAt: date, timezone: zone)
            notes.append("Les montants d’origine sont dans studio_indicateurs_devises et studio_historique_devises. Les colonnes monétaires des tableaux historiques restent en CHF et sont vides si un total demanderait une conversion. Achats intégrés nets : unités Apple uniquement, remboursements déduits ; une valeur absente reste inconnue.")
        }
        if let details = dashboard.revenueDetails {
            for dimension in RevenueDimension.allCases {
                let rows: [[ExportValue]] = details.currencies.flatMap { code in details.breakdown(dimension, currency: code).map {
                    [.text($0.code), .text($0.name), .number($0.value), .number($0.share), .text(code)]
                } }
                add(dimension == .country ? "studio_pays" : "studio_plateformes", "Revenus par " + dimension.title.lowercased(), ["code", "name", "value", "share_percent", "currency"], rows, generatedAt: date)
            }
            add("studio_revenus_detail", "Revenus quotidiens par pays et plateforme", ["game_id", "provider", "date", "country_code", "platform", "currency", "revenue", "read_at", "cached"], details.rows.map {
                [.text($0.gameID), .text($0.provider), .text($0.date), .text($0.country), .text($0.platform), .text($0.currency), .number(NSDecimalNumber(decimal: $0.amount).doubleValue), .text($0.readAt), .boolean($0.cached)]
            }, generatedAt: date, timezone: zone)
            checks.append(ExportCheck(section: "Revenus par pays et plateforme", status: details.status, detail: details.note, updatedAt: date))
            notes.append("Ventilations : AdMob utilise le pays de diffusion et la plateforme de l’app ; Apple le pays de vente et l’appareil ; Google Play le pays de l’acheteur et Android. Les sources gardent leurs calendriers. Les devises ne sont pas additionnées. Les parts sont absentes si le total est nul ou négatif, ou si un groupe présente un montant négatif (remboursements/frais).")
        } else {
            addBreakdown(dashboard.platformBreakdown, id: "studio_plateformes", date: date, currency: currency)
            addBreakdown(dashboard.countryBreakdown, id: "studio_pays", date: date, currency: currency)
        }
        add("studio_jeux", "Contribution des jeux", ["game_id", "name", "revenue", "dau", "installs", "change_percent"], dashboard.rankings.map { [.text($0.gameId), .text($0.name), .number($0.revenue), .integer($0.dau), .integer($0.installs), .number($0.change)] }, generatedAt: date, currency: currency)
        add("studio_sources", "Sources et alertes", ["id", "severity", "title", "description"], dashboard.alerts.map { [.text($0.id), .text($0.severity), .text($0.title), .text($0.description)] }, generatedAt: date)
        add("studio_qualite", "Qualité des données", ["completeness_percent", "note"], [[.number(dashboard.dataQuality.completeness), .text(dashboard.dataQuality.note)]], generatedAt: date, timezone: zone)
        let incomplete = dashboard.kpis.filter { $0.coverage.map { $0.status != "complete" } ?? false }
        checks.append(ExportCheck(section: "Vue d’ensemble", status: incomplete.isEmpty ? "loaded" : "partial", detail: incomplete.isEmpty ? "Vue chargée ; consulter les définitions et la provenance de chaque indicateur." : "Couverture incomplète : " + incomplete.map(\.label).joined(separator: ", ") + ". Les valeurs reçues restent des totaux partiels.", updatedAt: date))
        if let sourceDays = dashboard.sourceDays {
            add("studio_jours_sources", "Détail quotidien des sources", ["game_id", "provider", "date", "status", "read_at", "timezone", "revenue_chf", "ad_impressions", "source_has_error", "apple_iap_net_units"], sourceDays.map {
                [.text($0.gameID), .text($0.provider), .text($0.date), .text($0.status), .text($0.readAt), .text($0.timezone), .number($0.revenueCHF), .number($0.adImpressions.map(Double.init)), .boolean($0.sourceHasError), .number($0.appleIAPNetUnits.map(Double.init))]
            }, generatedAt: date)
            for provider in Set(sourceDays.map(\.provider)).sorted() {
                let rows = sourceDays.filter { $0.provider == provider }
                let missing = Set(rows.filter { $0.status == "missing" }.map(\.date)).sorted()
                let pending = Set(rows.filter { $0.status == "pending" }.map(\.date)).sorted()
                let cached = rows.filter { $0.status == "cached" }.count
                let issues = !missing.isEmpty || !pending.isEmpty || rows.contains { $0.sourceHasError }
                var detail = "\(rows.filter { $0.status == "received" }.count) journée(s) source reçue(s), \(cached) conservée(s) du cache."
                if !missing.isEmpty { detail += " Non reçues : " + missing.joined(separator: ", ") + "." }
                if !pending.isEmpty { detail += " En attente : " + pending.joined(separator: ", ") + "." }
                if rows.contains(where: { $0.sourceHasError }) { detail += " La dernière collecte de cette source signale une erreur ; voir Sources et alertes." }
                checks.append(ExportCheck(section: provider, status: issues ? "partial" : cached > 0 ? "cached" : "loaded", detail: detail, updatedAt: date))
            }
        } else {
            checks.append(ExportCheck(section: "Détail quotidien des sources", status: "unavailable", detail: "Ce tableau ne contient pas le suivi de réception par source et par jour. Une synchronisation native récente est nécessaire ; le nombre global de jours ne permet pas de déduire les dates absentes."))
        }
    }
    public mutating func addDirectory(_ directory: PlayerDirectory, includePlayers: Bool, jardin: Bool, timezone: String?, connectedAccountsOnly: Bool = false) {
        let date = Dates.iso(directory.generatedAt), timezone = directory.timezone ?? timezone
        if connectedAccountsOnly {
            notes.append("Joueurs et Gameplay : comptes connectés (Apple ou Google) uniquement. profiles, les statistiques par joueur et les parties terminées ne concernent que ces comptes ; depuis la 1.3.0, la plupart des joueurs jouent sans compte. Les invités sont mesurés dans Parcours (rapports parcours_*), sans identifiant.")
        }
        notes.append("Activité joueurs : jours distincts avec une partie terminée dans la période ; un retour signifie une activité sur au moins deux jours, pas une rétention J7. Les groupes (0, 1, 2–3, 4+ jours) décrivent la période choisie, pas l’ancienneté du joueur. Première/dernière partie désignent les bornes observées dans cette période. Les heures sont celles de fin des parties, dans le fuseau du jeu ; elles ne reconstituent pas les sessions ni le temps passé dans chaque heure.")
        checks.append(ExportCheck(section: "Raccordement aux profils joueurs", status: directory.profiledCompletions == directory.completions ? "loaded" : "partial", detail: "\(directory.profiledCompletions)/\(directory.completions) parties reliées aux profils disponibles. Les groupes et la concentration portent sur les profils ; l’activité globale inclut aussi les parties sans profil correspondant.", updatedAt: date))
        checks.append(ExportCheck(section: "Gameplay et joueurs", status: directory.players.isEmpty ? "empty" : "loaded", detail: "Statistiques calculées sur les parties terminées ; pas de journal brut de parcours.", updatedAt: date))
        if let note = directory.dataNote { checks.append(ExportCheck(section: "Parties ignorées", status: "partial", detail: note, updatedAt: date)) }
        addKPIs(directory.kpis, prefix: "gameplay", date: date, timezone: timezone, currency: nil)
        add("gameplay_resume", "Résumé de l’activité", ["profiles", "active_players", "completions", "entitlement_note"], [[.integer(directory.players.count), .integer(directory.activePlayers), .integer(directory.completions), .text(directory.entitlementNote)]], generatedAt: date, timezone: timezone)
        add("gameplay_historique", "Activité quotidienne", ["date", "completions", "play_minutes"], directory.trend.map { [.text($0.id), .integer($0.completions), .number($0.minutes)] }, generatedAt: date, timezone: timezone)
        addBreakdown(directory.modes, id: "gameplay_modes", date: date)
        addBreakdown(directory.difficulties, id: "gameplay_difficultes", date: date)
        add("gameplay_groupes_activite", "Comparaison des groupes d’activité", ["group", "definition", "players", "completions", "play_minutes", "average_minutes", "hints_per_game", "mistakes_per_game"], directory.activityGroups.map {
            [.text($0.group.id), .text($0.group.label), .integer($0.players), .integer($0.completions), .number($0.minutes), .number($0.averageMinutes), .number($0.hints), .number($0.mistakes)]
        }, generatedAt: date, timezone: timezone)
        add("gameplay_retours", "Retours et concentration sur la période", ["active_profiled_players", "returning_profiled_players", "top_three_completion_share_percent", "profiled_completions", "all_completions"], [[.integer(directory.profiledActivePlayers), .integer(directory.returningPlayers), .number(directory.topThreeShare), .integer(directory.profiledCompletions), .integer(directory.completions)]], generatedAt: date, timezone: timezone)
        add("gameplay_heures", "Heures de fin des parties", ["hour", "completions"], directory.completionHours.map { [.integer($0.hour), .integer($0.completions)] }, generatedAt: date, timezone: timezone)
        guard includePlayers else { return }
        add("joueurs", "Statistiques des joueurs", ["public_id", "name", "has_name", "adventure_step", "jardin_paisible", "completions", "play_minutes", "average_minutes", "score_percent", "perfect_percent", "first_played", "last_played", "moves_per_game", "hints_per_game", "mistakes_per_game", "undos_per_game", "active_days", "returned_in_period", "longest_streak_days", "completions_per_active_day", "activity_group"], directory.players.map { p in
            [.text(p.id), .text(p.name), .boolean(p.hasName), .integer(p.adventureStep), jardin ? (p.jardinPaisible.map { .boolean($0) } ?? .null) : .null, .integer(p.completions), .number(p.playMinutes), .number(p.averageMinutes), .number(p.scoreRatio), .number(p.perfectRate), .date(p.firstPlayed), .date(p.lastPlayed), .number(p.moves), .number(p.hints), .number(p.mistakes), .number(p.undos), .integer(p.activeDays), .boolean(p.returnedInPeriod), .integer(p.longestStreak), .number(p.completionsPerActiveDay), .text(p.activityGroup.id)]
        }, generatedAt: date, timezone: timezone)
        add("joueurs_heures", "Heures de fin des parties par joueur", ["public_id", "hour", "completions"], directory.players.flatMap { p in p.completionHours.map { [.text(p.id), .integer($0.hour), .integer($0.completions)] } }, generatedAt: date, timezone: timezone)
        add("joueurs_historique", "Activité quotidienne des joueurs", ["public_id", "date", "completions", "play_minutes"], directory.players.flatMap { p in p.trend.map { [.text(p.id), .text($0.id), .integer($0.completions), .number($0.minutes)] } }, generatedAt: date, timezone: timezone)
        for (id, keyPath) in [("joueurs_modes", \Player.modes), ("joueurs_difficultes", \Player.difficulties)] {
            add(id, id == "joueurs_modes" ? "Modes préférés par joueur" : "Difficultés par joueur", ["public_id", "name", "value", "share_percent"], directory.players.flatMap { p in p[keyPath: keyPath].map { [.text(p.id), .text($0.name), .number($0.value), .number($0.share)] } }, generatedAt: date)
        }
    }
    public mutating func addGames(_ games: [Game], generatedAt: Date?) {
        add("catalogue", "Catalogue des jeux", ["game_id", "name", "description", "status", "platforms", "version"], games.map { [.text($0.id), .text($0.name), .text($0.description), .text($0.status), .text($0.platforms.joined(separator: " | ")), .text($0.currentVersion)] }, generatedAt: generatedAt.map(Dates.iso))
    }
    public mutating func addReviews(_ reviews: [Review], generatedAt: Date?) {
        checks.append(ExportCheck(section: "Avis", status: reviews.isEmpty ? "empty" : "loaded", detail: "Avis lus dans les documents GameMetrik. La date de lecture n’atteste pas d’une collecte récente dans les boutiques.", updatedAt: generatedAt.map(Dates.iso)))
        add("avis", "Avis disponibles · toutes dates", ["id", "game_id", "game_name", "provider", "country", "rating", "title", "body", "version", "published_at"], reviews.map { [.text($0.id), .text($0.gameId), .text($0.gameName), .text($0.provider), .text($0.country), .integer($0.rating), .text($0.title), .text($0.body), .text($0.version), .text($0.publishedAt)] }, generatedAt: generatedAt.map(Dates.iso))
    }
    public mutating func finishChecks() {
        for view in missingViews { checks.append(ExportCheck(section: view, status: "not_loaded", detail: "Vue absente pour ce jeu et cette période.")) }
        tables.removeAll { $0.id == "export_bilan" }
        add("export_bilan", "Bilan de disponibilité", ["section", "status", "detail", "updated_at"], checks.map { [.text($0.section), .text($0.status), .text($0.detail), .text($0.updatedAt)] })
    }
    public func jsonData() throws -> Data {
        for table in tables {
            guard Set(table.columns).count == table.columns.count,
                  table.rows.allSatisfy({ $0.count == table.columns.count }) else {
                throw GameMetrikError.message("Le format de l’export est invalide.")
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public var readme: String {
        """
        # Export GameMetrik

        Jeu : \(gameName) · Période : \(timeframe) · Mode : \(mode)
        Exporté le : \(exportedAt)
        Périmètre : \(scope)

        \(notes.map { "- " + $0 }.joined(separator: "\n"))

        ## Disponibilité et limites

        \(checks.map { "- " + $0.section + " [" + $0.status + "] : " + $0.detail }.joined(separator: "\n"))
        Statuts : loaded = lu, empty = lu sans lignes, partial = incomplet, cached = conservé du cache, not_loaded = vue non chargée, not_collected = non collecté par ce client, not_connected = source non raccordée, unavailable = information indisponible, failed = échec, cancelled = annulé, pending = en attente.
        Dans studio_jours_sources : received = rapport reçu lors de la collecte, cached = agrégat conservé avec sa date de lecture, pending = attente connue, missing = rapport absent. Ces états ne garantissent pas que le fournisseur a finalisé ses chiffres.

        CSV : UTF-8 avec BOM, séparateur virgule, décimales avec point, dates ISO 8601.
        Valeur absente : cellule vide dans les CSV, null dans rapport.json ; un vrai zéro reste 0.
        Les nombres sont exportés sans l’arrondi d’affichage. Les pourcentages génériques sont en points de pourcentage (25 = 25 %), les durées en minutes. Exception : les taux des rapports Ballpark et du parcours Aurora sont des fractions (0,25 = 25 %).
        Le JSON conserve les types, la définition des colonnes et les dates, devises et fuseaux de chaque tableau.
        Les textes CSV susceptibles d’être interprétés comme une formule sont préfixés d’une apostrophe ; le JSON conserve le texte original.
        Le catalogue décrit l’état courant des jeux. Les avis chargés couvrent toutes les dates, comme la vue Avis.
        Les statistiques joueurs sont calculées sur la période sélectionnée ; l’aventure et Jardin paisible décrivent leur état courant. Aucune partie brute, aucun identifiant d’authentification ni identifiant de connexion n’est exporté.
        Ce dossier contient une copie locale explicite des données sélectionnées ; il est indépendant du cache de l’application.

        ## Fichiers

        \(tables.map { "- " + $0.id + ".csv : " + $0.title + " (" + String($0.rows.count) + " lignes)" }.joined(separator: "\n"))
        - rapport.json : mêmes tableaux avec le contexte complet.
        """
    }
    /// Build the entire folder in memory first. The caller writes only to a user-chosen location.
    public func fileWrapper() throws -> FileWrapper {
        var files = ["rapport.json": FileWrapper(regularFileWithContents: try jsonData()), "LIRE-MOI.md": FileWrapper(regularFileWithContents: Data(readme.utf8))]
        for table in tables {
            guard table.id.range(of: #"^[a-z_]+$"#, options: .regularExpression) != nil,
                  Set(table.columns).count == table.columns.count,
                  table.rows.allSatisfy({ $0.count == table.columns.count }), files[table.id + ".csv"] == nil else {
                throw GameMetrikError.message("Le format de l’export est invalide.")
            }
            files[table.id + ".csv"] = FileWrapper(regularFileWithContents: table.csvData())
        }
        return FileWrapper(directoryWithFileWrappers: files)
    }
}
