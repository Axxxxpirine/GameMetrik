import Foundation

public enum AuroraInsightsExport {
    public static func family(_ kind: AuroraInsightsKind) -> (id: String, title: String) {
        switch kind {
        case .activity: ("collecte_frequentation", "Collecte complète · fréquentation quotidienne (DAU, WAU, MAU, nouvelles installations)")
        case .sessions: ("collecte_sessions", "Collecte complète · sessions et temps passé")
        case .screens: ("collecte_ecrans", "Collecte complète · écrans vus et temps passé")
        case .dialogs: ("collecte_fenetres", "Collecte complète · fenêtres et leurs issues")
        case .actions: ("collecte_actions", "Collecte complète · actions de l’interface")
        case .gameplay: ("collecte_parties", "Collecte complète · détail des parties")
        case .timeline: ("collecte_chronologies", "Collecte complète · chronologies des coups (échantillon)")
        case .progress: ("collecte_progression", "Collecte complète · progression débloquée")
        case .settings: ("collecte_reglages", "Collecte complète · changements de réglages")
        case .stability: ("collecte_stabilite", "Collecte complète · lancements, arrêts au premier plan et erreurs")
        case .diagnostics: ("collecte_erreurs", "Collecte complète · erreurs par signature")
        case .performance: ("collecte_performance", "Collecte complète · fluidité par modèle d’appareil")
        case .cloud: ("collecte_reseau", "Collecte complète · opérations réseau et cloud")
        case .privacy: ("collecte_confidentialite", "Collecte complète · base et source de la mesure")
        case .consents: ("collecte_accords", "Collecte complète · accords explicites et retraits anonymes")
        case .context: ("collecte_contexte", "Collecte complète · contexte des appareils")
        case .notifications: ("collecte_rappels", "Collecte complète · rappels ouverts")
        case .server: ("collecte_serveur", "Collecte complète · volumes reçus par le serveur")
        }
    }
    static func mapSuffix(_ key: String) -> (suffix: String, title: String) {
        switch key {
        case "origins": ("origines", "origine de l’affichage")
        case "outcomes": ("issues", "issue")
        case "screens": ("ecrans", "écran")
        case "by_kind": ("coups", "type de coup")
        case "statuses": ("statuts", "statut HTTP")
        case "rejections": ("refus", "motif de refus")
        default: (key.lowercased().filter { $0.isLetter || $0 == "_" }, key)
        }
    }
    static func value(_ any: Any?) -> ExportValue {
        switch any {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            return .number(number.doubleValue)
        case let text as String: return .text(text)
        default: return .null
        }
    }
    /// Main table and long tables of the maps, only through the documented keys of the row type.
    static func tables(_ report: any AuroraInsightsAnyReport) -> (columns: [String], rows: [[ExportValue]], maps: [(key: String, columns: [String], rows: [[ExportValue]])]) {
        let encoded = report.encodedRows()
        let columns = report.documentedKeys.filter { !report.mapKeys.contains($0) }
        let rows = encoded.map { object in columns.map { value(object[$0]) } }
        let context = report.kind.dimensions + (columns.contains("suppressed") ? ["suppressed"] : [])
        let maps = report.mapKeys.map { key in
            (key, context + ["code", "count"], encoded.flatMap { object -> [[ExportValue]] in
                guard let map = object[key] as? [String: Any] else { return [] }
                return map.keys.sorted().map { code in context.map { value(object[$0]) } + [.text(code), value(map[code])] }
            })
        }
        return (columns, rows, maps)
    }
    public static func status(_ state: AuroraInsightsState, gap: AuroraJourneyAvailability?, failure: AuroraInsightsFailure?) -> String {
        switch state {
        case .failed: failure?.status.rawValue ?? "partial"
        case .notLoaded: "not_loaded"
        case .notRequested: "unavailable"
        case .notCollected: "not_collected"
        case .noData: gap == .partial ? "partial" : "empty"
        case .data: gap == .partial ? "partial" : "loaded"
        }
    }
}

public extension DataExport {
    /// Complete collection of Aurora Grove 1.6.0+: aggregates only, every family with its own check.
    mutating func addAuroraInsights(_ bundle: AuroraInsightsBundle) {
        let zone = "Europe/Zurich"
        var coverageRows: [[ExportValue]] = []
        for kind in AuroraInsightsKind.allCases {
            let family = AuroraInsightsExport.family(kind)
            if let report = bundle.anyReport(kind) {
                let tables = AuroraInsightsExport.tables(report)
                add(family.id, family.title, tables.columns, tables.rows, generatedAt: report.generatedAt, timezone: zone)
                for map in tables.maps {
                    let suffix = AuroraInsightsExport.mapSuffix(map.key)
                    add(family.id + "_" + suffix.suffix, family.title + " · par " + suffix.title, map.columns, map.rows, generatedAt: report.generatedAt, timezone: zone)
                }
                let c = report.standardCoverage
                coverageRows.append([.text(kind.rawValue), .text(report.generatedAt), .text(report.asOf), .text(report.filters.fromDay), .text(report.filters.toDayExclusive),
                                     .text(report.filters.appVersion), .text(report.filters.population.rawValue), .integer(report.rowCount), .integer(report.maskedRowCount),
                                     .text(report.firstReceivedAt), .integer(report.archivedDays), c.map { .boolean($0.archiveAvailableForPopulation) } ?? .null,
                                     .number(c?.rawRetentionDays.map(Double.init)), .number(c.map { Double($0.smallGroupThreshold) }), .text(c?.smallGroupsMaskedIn),
                                     .text(c?.collection), .text(c?.collectionRule), c.map { .boolean($0.installationsArePeople) } ?? .null, .text(c?.attribution), .text(c?.productionDefinition)])
            }
            let state = bundle.state(for: kind), gap = bundle.collectionGap(for: kind)
            let detail: String
            switch state {
            case .failed: detail = bundle.errors[kind]!.detail
            case .notLoaded: detail = "Famille non chargée : synchronise la vue Activité et jeu."
            case .notRequested: detail = "Non demandée pour cette période."
            case .notCollected: detail = "Non collecté sur cette période : aucun build 1.6.0+ n’avait encore envoyé ces mesures (première réception : \(bundle.anyReport(kind)?.firstReceivedAt ?? "aucune")). Ce n’est pas un zéro."
            case .noData: detail = gap == .partial ? "Aucune ligne ; la période commence avant la collecte ou couvre des jours archivés absents pour cette population." : "Collecte commencée (\(bundle.anyReport(kind)?.firstReceivedAt ?? "?")), mais aucune ligne sur la période."
            case .data:
                let masked = bundle.anyReport(kind)?.maskedRowCount ?? 0
                detail = (gap == .partial
                    ? (bundle.archiveUnavailable(for: kind) ? "Jours archivés (plus de 60 jours) indisponibles pour la population interne. " : "La période commence avant la collecte : les jours antérieurs restent non collectés. ")
                    : "") + "Agrégats sans identifiant, population \(bundle.population.rawValue)." + (masked > 0 ? " \(masked) ligne(s) archivée(s) masquée(s) (moins de 5 installations)." : "")
            }
            checks.append(.init(section: "Collecte complète · " + kind.title, status: AuroraInsightsExport.status(state, gap: gap, failure: bundle.errors[kind]),
                                detail: detail, updatedAt: bundle.anyReport(kind)?.generatedAt))
        }
        if let live = bundle.live {
            add("collecte_presence_direct", "Collecte complète · installations présentes maintenant (signal de moins de 90 s)",
                ["distribution", "population", "app_version", "state", "game_mode", "players"],
                live.rows.map { [.text($0.distribution), .text($0.isProduction ? "production" : "internal"), .text($0.appVersion), .text($0.state), .text($0.gameMode), .integer($0.players)] },
                generatedAt: live.generatedAt, timezone: zone)
        }
        if let history = bundle.history {
            add("collecte_presence_jours", "Collecte complète · pics quotidiens de présence",
                ["day", "peak_in_app", "peak_on_grid", "peak_at", "avg_in_app", "minutes_observed", "internal_peak_in_app", "complete"],
                history.rows.map { [.text($0.day), .number($0.peakInApp.map(Double.init)), .number($0.peakOnGrid.map(Double.init)), .text($0.peakAt), .number($0.avgInApp),
                                    .number($0.minutesObserved.map(Double.init)), .number($0.internalPeakInApp.map(Double.init)), .boolean($0.complete)] },
                generatedAt: history.generatedAt, timezone: zone)
        }
        if let hourly = bundle.hourly {
            add("collecte_presence_heures", "Collecte complète · présence moyenne et pic par heure (heure locale de Zurich)",
                ["hour", "avg_in_app", "peak_in_app", "avg_on_grid", "peak_on_grid", "minutes_observed"],
                hourly.rows.map { [.text($0.hour), .number($0.avgInApp), .number($0.peakInApp.map(Double.init)), .number($0.avgOnGrid), .number($0.peakOnGrid.map(Double.init)), .number($0.minutesObserved.map(Double.init))] },
                generatedAt: hourly.generatedAt, timezone: zone)
        }
        for kind in AuroraPresenceKind.allCases {
            let state = bundle.presenceState(for: kind)
            let detail: String
            switch state {
            case .failed: detail = bundle.presenceErrors[kind]!.detail
            case .notLoaded: detail = "Présence non chargée : synchronise la vue Activité et jeu."
            case .notRequested: detail = "Présence par heure lue seulement pour une période de 31 jours au plus."
            case .notCollected: detail = "Aucun signal de présence reçu sur cette période (versions antérieures à 1.6.0 ou mesure désactivée). Ce n’est pas un zéro."
            case .noData: detail = "Signaux reçus depuis \(bundle.live?.coverage.firstSignalAt ?? bundle.history?.coverage.firstSignalAt ?? "?"), mais aucune ligne."
            case .data: detail = "Comptes par minute sans identifiant ; présence = signal reçu dans les 90 dernières secondes."
            }
            checks.append(.init(section: "Collecte complète · " + kind.title, status: AuroraInsightsExport.status(state, gap: nil, failure: bundle.presenceErrors[kind]), detail: detail,
                                updatedAt: kind == .live ? bundle.live?.generatedAt : kind == .history ? bundle.history?.generatedAt : bundle.hourly?.generatedAt))
        }
        if let server = bundle.server {
            add("collecte_serveur_stockage", "Collecte complète · taille du stockage Supabase (valeurs du moment)", ["item", "value", "unit"],
                AuroraInsightsServerCoverage.Storage.fields.map { [.text($0.key), .number(server.coverage.storage[keyPath: $0.path].flatMap { $0 >= 0 ? Double($0) : nil }), .text($0.bytes ? "bytes" : "rows")] },
                generatedAt: server.generatedAt, timezone: zone)
            add("collecte_serveur_fonctions", "Collecte complète · appels des fonctions du jeu (pg_stat_statements)", ["function", "calls", "mean_ms"],
                (server.coverage.functions ?? []).map { [.text($0.function), .number($0.calls.map(Double.init)), .number($0.meanMs)] },
                generatedAt: server.generatedAt, timezone: zone)
        }
        if !coverageRows.isEmpty {
            add("collecte_couverture", "Collecte complète · contexte et couverture de chaque famille", [
                "report", "generated_at", "as_of", "from_day", "to_day_exclusive", "app_version", "population", "rows", "masked_rows",
                "collection_first_received_at", "archived_days_in_window", "archive_available_for_population", "raw_retention_days",
                "small_group_threshold", "small_groups_masked_in", "collection", "collection_rule", "installations_are_people", "attribution", "production_definition"
            ], coverageRows, generatedAt: bundle.latestGeneration.map(Dates.iso), timezone: zone)
            notes.append("collecte_*, contexte de lecture : population \(bundle.population.rawValue) (\(bundle.population.detail)), du \(bundle.filters.fromDay) au \(bundle.filters.toDayExclusive) exclu"
                + (bundle.filters.appVersion.map { ", version " + $0 } ?? "") + " ; as_of = \(bundle.asOf ?? "aucun").")
            notes += Self.auroraInsightsDefinitions
        }
    }

    static var auroraInsightsDefinitions: [String] { [
        "Collecte complète (collecte_*) : agrégats des RPC gamemetrik_aurora_insights_report_v1 et gamemetrik_aurora_presence_report_v1 (Aurora Grove 1.6.0 et suivants), sans aucun identifiant d’installation, de session, de présence ni de compte. Jours civils Europe/Zurich, from_day inclus, to_day_exclusive exclu ; fenêtres disjointes d’au plus 366 jours concaténées sous un même as_of (la présence n’a pas d’as_of : valeurs du moment de la lecture).",
        "Qui est compté : les installations 1.6.0+ dont les statistiques couvrent la collecte étendue (par défaut hors EEE et Royaume-Uni quand la boutique App Store est connue ; ailleurs seulement après un oui explicite). Les installations hors ligne, les refus et les versions antérieures ne sont pas comptés. Exception : collecte_frequentation et les lancements de collecte_stabilite comptent aussi les événements de base du parcours des versions antérieures mesurées. Une installation n’est pas une personne : une même personne peut en avoir plusieurs, une réinstallation est nouvelle (installations_are_people = false).",
        "Population : production = installations jamais vues sur un build TestFlight ou de développement ; internal = les autres ; all = toutes. Pour la présence, production = builds App Store et inconnus, internal = TestFlight et développement (internal_peak_in_app). Ne pas additionner un pic de production et un pic interne : ils ne tombent pas à la même minute.",
        "Valeurs nulles : null = inconnu ou masqué, jamais zéro ; un vrai zéro est écrit 0. suppressed = true : ligne d’un jour archivé (plus de 60 jours) dont le groupe compte moins de 5 installations ; ses dimensions restent, tous ses nombres sont null. Le masquage ne concerne que les jours archivés (small_groups_masked_in = archived_days_only) ; les jours archivés n’existent pas pour la population internal (archive_available_for_population = false).",
        "Non collecté : une période antérieure à collection_first_received_at (null = rien reçu) et sans jour archivé n’est pas mesurée ; ses absences de ligne ne sont pas des zéros. Une période qui commence avant la collecte est partielle (export_bilan = partial).",
        "Unités : durées en secondes sauf mention (contrairement aux autres tableaux de l’export, en minutes) ; *_ms en millisecondes ; *_ds de collecte_chronologies en dixièmes de seconde (first_action_ds = somme sur les chronologies complètes, timelines − partial ; last_action_ds = somme sur toutes) ; memory_peak_mb_* en mégaoctets ; collecte_serveur_stockage en octets ou en lignes. Les médianes (median_*, p90_*) valent pour leur ligne et ne se combinent pas entre lignes.",
        "Installations : distinctes dans chaque ligne, jamais additionnées entre lignes ou entre jours comme des personnes. Les sommes des autres colonnes (vues, secondes, parties, coups…) s’additionnent entre lignes non masquées. Moyennes = sommes ÷ effectifs : temps par partie = active_seconds / runs, coups par partie = moves / runs, taux d’indice = runs_with_hints / runs, taux d’erreur = runs_with_errors / runs, score moyen = score / scored_runs, part du score maximal = score / max_score, complétion moyenne = completion_pct / completion_known (en points), fps moyen = fps_frames / frames.",
        "collecte_frequentation : dau = installations actives le jour, wau = sur les 7 jours finissant ce jour, mau = sur 30 jours ; new_installations = premières ouvertures de nouvelles installations ; returning_installations = installations déjà vues un jour précédent ; sessions = ouvertures de l’app ; accounts = comptes connectés distincts ; installations_with_context = installations ayant envoyé leur contexte (collecte étendue).",
        "collecte_sessions : une session est une ouverture (démarrage à froid, ou retour après 30 minutes ou un autre jour) ; foreground_seconds = temps au premier plan, active_seconds = premier plan − publicité − inactivité (aucun toucher pendant une minute), grid_seconds = temps sur une grille ; sessions_measured = sessions dont la durée a été reçue. collecte_ecrans : vues, secondes et origine de chaque écran (collecte_ecrans_origines) ; left_to_background = vues terminées par une sortie de l’app. collecte_fenetres : fermetures, secondes, issues (collecte_fenetres_issues) et écran d’ouverture. collecte_actions : value_sum / valued_events = valeur moyenne quand l’action en porte une.",
        "collecte_parties : une ligne par jour × version × mode × étape × difficulté × taille × issue (solved, restart, new_puzzle, back, parked) ; une partie quittée par retour ou mise de côté peut avoir plusieurs détails. collecte_chronologies : échantillon de parties ; coups par type dans collecte_chronologies_coups (f luciole, x croix, e effacement, u annulation, h indice, r refusé, t rotation des Chemins). Les valeurs -1 envoyées par le jeu (inconnues) sont exclues des sommes.",
        "collecte_stabilite : stops_while_on_screen = lancements dont l’exécution précédente s’est arrêtée alors que l’app était affichée : plantage ou arrêt forcé, indiscernables. error_events = erreurs consignées par le jeu ; collecte_erreurs les regroupe par signature (fingerprint = empreinte de l’erreur, pas un identifiant de personne ni d’appareil). collecte_performance : par modèle d’appareil et version majeure du système. collecte_reseau : opérations cloud par issue, median_ms / p90_ms / max_ms, statuts HTTP dans collecte_reseau_statuts.",
        "collecte_confidentialite : installations qui envoient leur contexte, par base (statistics_basis), source du choix, classe de région et statut ATT. collecte_accords : oui/non explicites enregistrés avec le parcours, et retraits anonymes des statistiques (source = anonymous_count, installations = null : aucune installation connue). collecte_contexte : installations du jour par dimension et valeur (une installation présente deux jours compte deux fois si l’on additionne les jours) ; ad_config_revision = révision des réglages publicitaires distants ; une dimension inconnue garde son code brut.",
        "collecte_presence_* : présence = installations au premier plan dont les statistiques le permettent, signal toutes les 30 s, présente si un signal est arrivé dans les 90 dernières secondes ; aucun identifiant persistant (un identifiant aléatoire par passage au premier plan, effacé après 5 minutes). collecte_presence_direct = maintenant ; collecte_presence_jours = pic, minute du pic et moyenne par jour (complete = journée terminée) ; collecte_presence_heures = par heure locale de Zurich, seulement pour 31 jours au plus.",
        "collecte_serveur : événements reçus par jour de réception (toutes populations et versions), dont core_events (parcours de base) et extended_events (collecte complète), refus par motif (collecte_serveur_refus), minutes de présence et pic. collecte_serveur_stockage et collecte_serveur_fonctions : tailles et appels du moment ; un coût n’est pas calculé (Supabase facture le projet entier). Les journaux d’API de Supabase (avec adresses IP) ne sont pas lus.",
        "Attribution : non collectée. Aucun lien campagne → installation, aucune donnée par joueur."
    ] }
}
