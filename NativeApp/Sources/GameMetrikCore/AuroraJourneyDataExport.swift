import Foundation

public extension DataExport {
    mutating func addAuroraJourney(_ bundle: AuroraJourneyBundle) {
        func ratioColumns(_ name: String) -> [String] { ["numerator", "denominator", "value", "reason"].map { name + "_" + $0 } }
        func ratioValues(_ value: AuroraJourneyRatio) -> [ExportValue] {
            [.number(value.numerator.map(Double.init)), .number(value.denominator.map(Double.init)), .number(value.value), .text(value.reason?.rawValue)]
        }
        if let report = bundle.funnel {
            let columns = ["cohort_day", "app_version", "cohort_size", "window", "mature", "anonymous_first_launches", "consent_accepted", "consent_declined"]
                + ["tutorial_started", "tutorial_completed", "first_run_completed", "measured_share"].flatMap(ratioColumns) + ["consent_signals"]
            add("parcours_entonnoir", "Parcours · entonnoir J0–J6", columns, report.rows.map { row in
                // After 1.5.1 the consent card is gone: its zeros are neither refusals nor acceptances.
                let fed = AuroraConsentSignals.fed(appVersion: row.appVersion)
                return [.text(row.cohortDay), .text(row.appVersion), .integer(row.cohortSize), .text(row.window), .boolean(row.mature),
                        .integer(row.anonymousFirstLaunches), fed ? .integer(row.consentAccepted) : .null, fed ? .integer(row.consentDeclined) : .null]
                    + [row.tutorialStarted, row.tutorialCompleted, row.firstRunCompleted, row.measuredShare].flatMap(ratioValues)
                    + [.text(fed ? "fed" : "not_fed")]
            }, generatedAt: report.generatedAt, timezone: report.timezone)
        }
        if let report = bundle.steps {
            let columns = ["cohort_day", "app_version", "first_launches", "steps_open"]
                + (["measured_share"] + AuroraJourneyStepsRow.steps.map(\.key)).flatMap(ratioColumns)
            add("parcours_etapes", "Parcours · étapes anonymes J0–J13", columns, report.rows.map { row in
                [.text(row.cohortDay), .text(row.appVersion), .integer(row.firstLaunches), .integer(row.stepsOpen)]
                + ([row.measuredShare] + AuroraJourneyStepsRow.steps.map { row[keyPath: $0.path] }).flatMap(ratioValues)
            }, generatedAt: report.generatedAt, timezone: report.timezone)
            notes.append("parcours_etapes, contexte de lecture : du \(report.filters.fromDay) au \(report.filters.toDayExclusive) exclu" + (report.filters.appVersion.map { ", version " + $0 } ?? "")
                + " ; as_of = \(report.asOf) ; premier jour des étapes = \(report.coverage.stepsFirstDay ?? "aucun") ; identifier = \(report.coverage.identifier) ; grace_days = \(report.coverage.graceDays). Règle de région du serveur : « \(report.coverage.regionRule) ». Cohorte du serveur : « \(report.coverage.cohortDefinition) ».")
        }
        for (id, title, optional) in [("parcours_retours_ouverture", "Retours depuis la première ouverture", bundle.retentionOpen),
                                      ("parcours_retours_partie", "Retours depuis la première partie terminée", bundle.retentionCompleted)] {
            if let report = optional {
                add(id, title, ["cohort_day", "app_version", "cohort_size"] + ["return_d1", "return_d7", "return_d7_d13"].flatMap(ratioColumns),
                    report.rows.map { row in
                        [.text(row.cohortDay), .text(row.appVersion), .integer(row.cohortSize)]
                        + [row.returnD1, row.returnD7, row.returnD7D13].flatMap(ratioValues)
                    }, generatedAt: report.generatedAt, timezone: report.timezone)
            }
        }
        if let report = bundle.runs {
            add("parcours_parties", "Parcours · issues des parties", [
                "app_version", "mode", "level", "games", "start_observed", "solved", "abandoned_restart", "abandoned_new_puzzle",
                "open_recent", "left_not_resumed", "app_stopped_while_playing", "left_app_returned", "left_app_not_returned", "no_end_observed"
            ], report.rows.map { row in
                [.text(row.appVersion), .text(row.mode.rawValue), .integer(row.level)]
                + AuroraJourneyRunRow.countPaths.map { .integer(row[keyPath: $0]) }
            }, generatedAt: report.generatedAt, timezone: report.timezone)
        }
        if let report = bundle.quality {
            add("parcours_qualite", "Parcours · qualité de collecte", [
                "day", "app_version", "platform", "installations", "events", "first_open_new_install", "first_open_existing_player",
                "first_open_unknown", "first_open_late_consent", "installations_reporting_losses", "lost_events_reported", "launches_after_foreground_stop"
            ], report.rows.map { row in [
                .text(row.day), .text(row.appVersion), .text(row.platform.rawValue), .integer(row.installations), .integer(row.events),
                .integer(row.firstOpenNewInstall), .integer(row.firstOpenExistingPlayer), .integer(row.firstOpenUnknown),
                .integer(row.firstOpenLateConsent), .integer(row.installationsReportingLosses), .integer(row.lostEventsReported), .integer(row.launchesAfterForegroundStop)
            ] }, generatedAt: report.generatedAt, timezone: report.timezone)
            add("parcours_evenements", "Parcours · nombres par événement", ["day", "app_version", "platform", "event_name", "count"],
                report.rows.flatMap { row in row.byEvent.keys.sorted().map { key in
                    [.text(row.day), .text(row.appVersion), .text(row.platform.rawValue), .text(key), .integer(row.byEvent[key]!)]
                } }, generatedAt: report.generatedAt, timezone: report.timezone)
        }
        var coverageRows: [[ExportValue]] = [], rejections: [[ExportValue]] = []
        func context<R>(_ report: AuroraJourneyReport<R>?) {
            guard let report else { return }
            let c = report.coverage
            let signals = bundle.consentSignals
            var anonymous = c.anonymousInWindow.counts.map(ExportValue.integer)
            if signals == .notFed { anonymous[2] = .null; anonymous[3] = .null }
            coverageRows.append([
                .text(report.report.rawValue), .integer(report.contractVersion), .text(report.generatedAt), .text(report.asOf),
                .text(report.filters.fromDay), .text(report.filters.toDayExclusive), .text(report.filters.appVersion), .text(report.filters.population.rawValue),
                .text(c.collectionFirstReceivedAt), .integer(c.archivedDaysInWindow), .integer(c.graceDays), .boolean(c.consentRequired),
                .text(c.attribution), .text(c.cohortDefinition)
            ] + c.firstOpenInWindow.counts.map(ExportValue.integer) + anonymous + [.text(signals.rawValue)])
            rejections += c.rejectionsInWindow.keys.sorted().map { [.text(report.report.rawValue), .text($0), .integer(c.rejectionsInWindow[$0]!)] }
        }
        context(bundle.funnel); context(bundle.retentionOpen); context(bundle.retentionCompleted); context(bundle.runs); context(bundle.quality)
        add("parcours_couverture", "Parcours · contexte et couverture de chaque rapport", [
            "report", "contract_version", "generated_at", "as_of", "from_day", "to_day_exclusive", "app_version", "population",
            "collection_first_received_at", "archived_days_in_window", "grace_days", "consent_required", "attribution", "cohort_definition",
            "first_open_new_install", "first_open_new_install_late_consent", "first_open_new_install_known_account", "first_open_excluded_suspicious",
            "first_open_existing_player", "first_open_unknown", "anonymous_first_launch_new_install", "anonymous_first_launch_existing_player",
            "anonymous_consent_accepted", "anonymous_consent_declined", "consent_signals"
        ], coverageRows, generatedAt: bundle.latestGeneration.map(Dates.iso), timezone: "Europe/Zurich")
        add("parcours_refus_serveur", "Parcours · refus serveur par motif", ["report", "code", "count"], rejections,
            generatedAt: bundle.latestGeneration.map(Dates.iso), timezone: "Europe/Zurich")
        for kind in AuroraJourneyReportKind.allCases {
            checks.append(.init(section: "Parcours · " + kind.title,
                                status: bundle.errors[kind]?.status.rawValue ?? (bundle.coverage(for: kind) == nil ? "not_loaded" : "loaded"),
                                detail: bundle.errors[kind]?.detail ?? "Agrégats administratifs v1. Aucune identité ni événement brut.",
                                updatedAt: bundle.latestGeneration.map(Dates.iso)))
        }
        checks.append(.init(section: "Parcours · Étapes anonymes", status: bundle.stepsAvailability.rawValue,
                            detail: bundle.stepsError?.detail ?? (bundle.steps == nil ? "Rapport des étapes anonymes non chargé."
                                : "Agrégats anonymes steps v1, sans identifiant. Rapport séparé : son absence ne modifie pas les autres rapports du parcours."),
                            updatedAt: bundle.steps.map(\.generatedAt)))
        if let quality = bundle.quality, let windows = try? quality.filters.windows() {
            for window in windows {
                let request: [String: Any] = ["contract_version": 1, "report": "quality", "from_day": window.fromDay,
                    "to_day_exclusive": window.toDayExclusive, "as_of": quality.asOf,
                    "app_version": window.appVersion as Any? ?? NSNull()]
                if let json = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
                   let payload = String(data: json, encoding: .utf8) {
                    notes.append("Comparaison en lecture seule dans SQL Editor, même fenêtre quality (pour une sonde, choisir Aujourd’hui) : SELECT public.gamemetrik_aurora_journey_report_v1('" + payload.replacingOccurrences(of: "'", with: "''") + "'::jsonb);")
                }
            }
        }
        notes += Self.auroraJourneyDefinitions
    }

    static var auroraJourneyDefinitions: [String] { [
        "Parcours Aurora Grove v1 : tous les jours sont civils Europe/Zurich ; from_day est inclus, to_day_exclusive exclu. Les grandes périodes sont découpées en fenêtres disjointes d’au plus 366 jours, puis additionnées. Tout couvre le contrat v1 introduit en 2026, sans historique reconstitué.",
        "Les colonnes de taux du parcours (*_value) sont des fractions (0,25 = 25 %), et non des points de pourcentage. Chaque taux conserve numerator, denominator, value et reason. Un null reste vide : immature_cohort = attente de maturité, empty_cohort = cohorte vide, not_collected = décompte absent. Pour agréger, sommer uniquement les numérateurs et dénominateurs dont value est disponible, jamais les pourcentages ; signaler les cohortes exclues.",
        "Cohorte : nouvelles installations observées dès le premier lancement avec accord, hors comptes déjà connus et parcours suspects. La version est celle de la première ouverture. Comparer les versions séparément. Les installations ne sont pas des personnes uniques ; accords tardifs, joueurs existants et statuts inconnus sont hors cohorte. Les motifs de couverture peuvent se recouvrir.",
        "parcours_entonnoir : tutoriel commencé, tutoriel terminé et première partie résolue entre J0 et J6 inclus ; dénominateur = cohort_size. Maturité après la fin de J6 et 3 jours de délai d’envoi. measured_share = cohort_size / anonymous_first_launches du même jour et de la même version, disponible sans attendre la maturité ; au-dessus de 1, les comptes anonymes ont subi des pertes. Sans compte anonyme : not_collected.",
        "Carte d’accord : consent_accepted et consent_declined sont des signaux anonymes, comptés le jour de leur réponse. Premiers lancements moins accords moins refus donne un solde, pas un suivi individuel des non-réponses ; les réponses tardives peuvent venir de jours précédents.",
        "Signaux d’accord après la 1.5.1 : la carte d’accord a disparu, les compteurs consent_accepted et consent_declined ne sont plus alimentés par les versions postérieures à 1.5.1 (comparaison numérique : 1.10.0 est postérieure à 1.5.1). consent_signals = not_fed et cellules vides pour ces versions : ce ne sont ni des refus ni des acceptations. Dans parcours_couverture, les compteurs couvrent toute la fenêtre : fed = seules des versions jusqu’à 1.5.1 sont lues, mixed = ils ne concernent que les versions jusqu’à 1.5.1, not_fed = version filtrée postérieure à 1.5.1. Aucun taux d’acceptation ne doit être calculé à partir de ces signaux.",
        "parcours_etapes : étapes anonymes des nouvelles installations (jeu 1.5.1 et suivants), sans aucun identifiant, comptées une fois par installation. J0 = jour Europe/Zurich du premier lancement ; une ligne par jour de cohorte × version. first_launches = premiers lancements anonymes, steps_open = installations autorisées à déclarer leurs étapes ; measured_share = steps_open / first_launches (part des nouvelles installations mesurées, pas un taux de refus). Chaque étape (tutorial_started, tutorial_completed, solved_1, solved_3, solved_10, return_d1, return_d7_d13) a pour dénominateur steps_open de la même ligne. immature_cohort jusqu’à la fin de la fenêtre plus 3 jours (J0–J6 pour le tutoriel et les jardins résolus, J1 pour return_d1, J7–J13 pour return_d7_d13) ; not_collected si steps_open = 0 (version sans étapes anonymes, par exemple 1.5.0). Dans l’EEE et au Royaume-Uni, une installation n’envoie ses étapes qu’avec l’accord du joueur ; ailleurs, le joueur peut les désactiver. Un premier lancement n’est pas une personne unique. Depuis la 1.5.1, l’accord est demandé après le premier jardin : lire le tutoriel et les premiers jardins de ces versions dans parcours_etapes plutôt que dans parcours_entonnoir. Les fenêtres de 366 jours sont concaténées, sans additionner de taux.",
        "parcours_retours_ouverture : J0 = première ouverture ; retour = au moins un événement le jour exact J1, exact J7, ou entre J7 et J13 inclus. parcours_retours_partie : J0 = première partie résolue, cohorte restreinte à ces installations ; retour = partie résolue. Dénominateur = cohort_size de la ligne mûre pour chaque mesure séparément. Chaque dernière journée doit être écoulée, plus 3 jours de délai.",
        "parcours_parties : premier événement de la partie dans la fenêtre, par version/mode/étape. Modes campaign = Aventure, quick = partie rapide, daily = défi quotidien, lightpaths = Chemins de lumière ; level = étape ou grille, 0 pour quick/daily. start_observed = début vu, parfois absent pour une partie antérieure à la collecte. Population all = toutes les installations mesurées, new_installs = installations de la cohorte.",
        "Issues, une seule par partie et dans cet ordre : solved = résolue ; abandoned_restart = recommencée explicitement ; abandoned_new_puzzle = remplacée par une nouvelle grille ; open_recent = dernier événement de moins de 7 jours ; left_not_resumed = sortie explicite sans reprise ; app_stopped_while_playing = app arrêtée affichée (plantage ou arrêt forcé) ; left_app_returned = app quittée pendant la partie puis retour sous 7 jours sans reprise ; left_app_not_returned = app quittée pendant la partie, pas de retour sous 7 jours ; no_end_observed = aucune fin observée. Aucune intention n’est déduite des interruptions et aucune notion d’échec de partie n’est créée.",
        "parcours_qualite : installations actives et installations_reporting_losses sont distinctes dans chaque ligne jour × version × plateforme, jamais uniques sur toute la période. events et parcours_evenements comptent les événements reçus ; lost_events_reported compte les pertes déclarées par les téléphones ; launches_after_foreground_stop compte les relancements après plantage ou arrêt forcé alors que l’app était affichée. first_open_late_consent est inclus dans first_open_new_install.",
        "parcours_couverture conserve first_open_in_window et anonymous_in_window, ainsi que collection_first_received_at. Les périodes antérieures à la collecte sont not_collected ; les périodes qui la chevauchent sont partielles. Les refus serveur concernent toute la fenêtre, indépendamment du filtre de version ; parcours_refus_serveur les répète par rapport, ne pas les additionner entre rapports.",
        "Les rapports partagent as_of pour les événements reçus des jours non figés. Les jours de plus de 60 jours sont lus dans une archive anonyme immuable, disponible après effacement des événements à 25 mois ; as_of ne reconstitue pas le passé des jours archivés. Les décomptes anonymes et les refus serveur suivent leurs compteurs courants : as_of ne les fige pas. collection_first_received_at vient des événements encore conservés, l’archive peut être plus ancienne.",
        "Attribution : non collectée. Aucun rattachement joueur/campagne, aucune assimilation à du trafic organique. Les rapports historiques completion_events restent distincts, limités aux parties terminées des joueurs connectés."
    ] }
}
