import Foundation

public extension DataExport {
    /// Measured monetization of Aurora Grove: aggregates only, revenue per currency × precision, never converted or added up.
    mutating func addAuroraMonetization(_ bundle: AuroraMonetizationBundle) {
        let adContext = ["day", "app_version", "platform", "format", "placement", "game_mode", "variant"]
        func context(_ row: AuroraAdRow) -> [ExportValue] {
            [.text(row.day), .text(row.appVersion), .text(row.platform.rawValue), .text(row.format.rawValue),
             .text(row.placement.rawValue), .text(row.gameMode.rawValue), .text(row.variant.rawValue)]
        }
        if let report = bundle.ads {
            add("monetisation_pubs", "Monétisation mesurée · occasions et affichages publicitaires", adContext + ["installations"] + AuroraAdRow.counts.map(\.key),
                report.rows.map { row in context(row) + [.integer(row.installations)] + AuroraAdRow.counts.map { .integer(row[keyPath: $0.path]) } },
                generatedAt: report.generatedAt, timezone: report.timezone)
            add("monetisation_pubs_motifs", "Monétisation mesurée · décision de chaque occasion", adContext + ["decision", "count"],
                report.rows.flatMap { row in AuroraMonetizationContract.decisions.map(\.key).compactMap { code in
                    row.decisions[code].map { context(row) + [.text(code), .integer($0)] }
                } }, generatedAt: report.generatedAt, timezone: report.timezone)
            add("monetisation_revenus", "Monétisation mesurée · revenus OnAdPaid par devise et précision", adContext + ["currency", "precision", "value_micros", "paid_events"],
                report.rows.flatMap { row in row.revenue.map { item in
                    context(row) + [.text(item.currency), .text(item.precision.rawValue), .integer(item.valueMicros), .integer(item.paidEvents)]
                } }, generatedAt: report.generatedAt, timezone: report.timezone)
        }
        if let report = bundle.adLoads {
            let columns = ["day", "app_version", "platform", "format"]
            func context(_ row: AuroraAdLoadRow) -> [ExportValue] { [.text(row.day), .text(row.appVersion), .text(row.platform.rawValue), .text(row.format.rawValue)] }
            add("monetisation_chargements", "Monétisation mesurée · chargements publicitaires", columns + ["installations", "requested", "loaded", "failed"],
                report.rows.map { context($0) + [.integer($0.installations), .integer($0.requested), .integer($0.loaded), .integer($0.failed)] },
                generatedAt: report.generatedAt, timezone: report.timezone)
            add("monetisation_chargements_erreurs", "Monétisation mesurée · échecs de chargement par code d’erreur Google", columns + ["error_code", "count"],
                report.rows.flatMap { row in row.sortedErrorCodes.map { context(row) + [.text($0), .integer(row.errors[$0]!)] } },
                generatedAt: report.generatedAt, timezone: report.timezone)
        }
        if let report = bundle.premium {
            add("monetisation_paisible", "Monétisation mesurée · étapes de l’offre Jardin paisible",
                ["day", "app_version", "platform", "placement", "installations", "step", "events", "installations_step"],
                report.rows.flatMap { row in row.orderedSteps.map { step in
                    [.text(row.day), .text(row.appVersion), .text(row.platform.rawValue), .text(row.placement.rawValue), .integer(row.installations),
                     .text(step), .integer(row.steps[step]!), .integer(row.installationsByStep[step]!)]
                } }, generatedAt: report.generatedAt, timezone: report.timezone)
        }
        if let report = bundle.experiment {
            let context = ["cohort_day", "experiment", "variant", "app_version"]
            func values(_ row: AuroraExperimentRow) -> [ExportValue] { [.text(row.cohortDay), .text(row.experiment), .text(row.variant.rawValue), .text(row.appVersion)] }
            func ratio(_ value: AuroraJourneyRatio) -> [ExportValue] {
                [.number(value.numerator.map(Double.init)), .number(value.denominator.map(Double.init)), .number(value.value), .text(value.reason?.rawValue)]
            }
            add("monetisation_test", "Monétisation mesurée · test des publicités des Chemins de lumière",
                context + ["cohort_size", "window", "mature"] + ["return_d1", "return_d7"].flatMap { name in ["numerator", "denominator", "value", "reason"].map { name + "_" + $0 } }
                + AuroraExperimentRow.sums.map(\.key),
                report.rows.map { row in
                    values(row) + [.integer(row.cohortSize), .text(row.window), .boolean(row.mature)] + ratio(row.returnD1) + ratio(row.returnD7)
                    + AuroraExperimentRow.sums.map { .number(row[keyPath: $0.path].map(Double.init)) }
                }, generatedAt: report.generatedAt, timezone: report.timezone)
            add("monetisation_test_revenus", "Monétisation mesurée · revenus J0–J6 des cohortes mûres du test, par devise", context + ["currency", "value_micros", "paid_events"],
                report.rows.flatMap { row in (row.revenue ?? []).map { values(row) + [.text($0.currency), .integer($0.valueMicros), .integer($0.paidEvents)] } },
                generatedAt: report.generatedAt, timezone: report.timezone)
        }
        if !bundle.loadedKinds.isEmpty {
            add("monetisation_couverture", "Monétisation mesurée · contexte et couverture de chaque rapport", [
                "report", "contract_version", "generated_at", "as_of", "from_day", "to_day_exclusive", "app_version", "rows",
                "collection_first_received_at", "archived_days_in_window", "grace_days", "collection", "collection_rule", "consent_signals",
                "revenue_scope", "revenue_source", "authoritative_revenue", "currencies_converted", "attribution", "experiment_rows_from_raw_events"
            ], bundle.loadedKinds.compactMap { kind -> [ExportValue]? in
                guard let c = bundle.coverage(for: kind), let f = bundle.filters(for: kind) else { return nil }
                return [.text(kind.rawValue), .integer(1), .text(bundle.generatedAt(for: kind)), .text(bundle.asOf), .text(f.fromDay), .text(f.toDayExclusive),
                        .text(f.appVersion), .integer(bundle.rowCount(for: kind) ?? 0), .text(c.collectionFirstReceivedAt), .integer(c.archivedDaysInWindow), .integer(c.graceDays),
                        .text(c.collection), .text(c.collectionRule), .text(c.consentSignals), .text(c.revenueScope), .text(c.revenueSource),
                        .text(c.authoritativeRevenue), .boolean(c.currenciesConverted), .text(c.attribution), .boolean(c.experimentRowsFromRawEvents)]
            }, generatedAt: bundle.generations.compactMap(Dates.parse).max().map(Dates.iso), timezone: "Europe/Zurich")
        }
        for kind in AuroraMonetizationReportKind.allCases {
            let status: String, detail: String
            switch bundle.state(for: kind) {
            case .failed: status = bundle.availability(for: kind).rawValue; detail = bundle.errors[kind]!.detail
            case .notLoaded: status = "not_loaded"; detail = "Rapport non chargé : synchronise la vue Parcours."
            case .noMeasurement: status = "not_collected"; detail = "Aucune mesure reçue : aucun build n’envoie encore ces événements, ou leur collecte est coupée."
            case .noData: status = "empty"; detail = "Collecte commencée le \(bundle.coverage(for: kind)?.collectionFirstReceivedAt ?? "?"), mais aucune ligne sur la période."
            case .data: status = "loaded"; detail = "Agrégats monetization v1, sans identifiant. Rapport séparé : son état ne modifie pas les autres rapports du parcours."
            }
            checks.append(.init(section: "Monétisation mesurée · " + kind.title, status: status, detail: detail, updatedAt: bundle.generatedAt(for: kind)))
        }
        if let report = bundle.ads {
            notes.append("monetisation_*, contexte de lecture : du \(report.filters.fromDay) au \(report.filters.toDayExclusive) exclu" + (report.filters.appVersion.map { ", version " + $0 } ?? "")
                + " ; as_of = \(report.asOf) ; première mesure reçue = \(report.coverage.collectionFirstReceivedAt ?? "aucune") ; jours archivés = \(report.coverage.archivedDaysInWindow). Règle de collecte du serveur : « \(report.coverage.collectionRule) ».")
            if let windows = try? AuroraJourneyFilters(fromDay: report.filters.fromDay, toDayExclusive: report.filters.toDayExclusive, appVersion: report.filters.appVersion).windows() {
                for window in windows {
                    var request: [String: Any] = ["contract_version": 1, "report": "ads", "from_day": window.fromDay, "to_day_exclusive": window.toDayExclusive, "as_of": report.asOf]
                    if let version = window.appVersion { request["app_version"] = version }
                    if let json = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), let payload = String(data: json, encoding: .utf8) {
                        notes.append("Comparaison en lecture seule dans SQL Editor, même fenêtre ads : SELECT public.\(AuroraMonetizationContract.function)('" + payload.replacingOccurrences(of: "'", with: "''") + "'::jsonb);")
                    }
                }
            }
        }
        if !bundle.loadedKinds.isEmpty { notes += Self.auroraMonetizationDefinitions }
    }

    static var auroraMonetizationDefinitions: [String] { [
        "Monétisation mesurée (monetisation_*) : agrégats du RPC gamemetrik_aurora_monetization_report_v1, sans aucun identifiant d’installation, d’affichage ni de compte. Jours civils Europe/Zurich, from_day inclus, to_day_exclusive exclu ; fenêtres disjointes d’au plus 366 jours concaténées sous un même as_of. Un vrai zéro est une ligne présente avec 0 ; une absence de ligne n’est pas un zéro.",
        "Le revenu mesuré est un échantillon : seules les installations autorisées à être mesurées l’envoient (revenue_scope = consenting_installations_only, source = OnAdPaid de Google). Il est distinct du revenu total AdMob, dont la source d’autorité reste les rapports AdMob (authoritative_revenue = admob_reports). Ne pas le comparer ni le substituer au revenu AdMob du studio.",
        "Ce n’est pas une attribution aux campagnes Meta : l’attribution n’est pas collectée (attribution = not_collected). Aucun lien campagne → installation → revenu.",
        "Revenus : montant = value_micros / 1 000 000 dans la devise indiquée (code ISO à 3 lettres), sans aucune conversion (currencies_converted = false). Ne jamais additionner deux devises ; sommer seulement au sein d’une même devise. precision : unknown, estimated, publisher_provided ou precise, telle que fournie par Google. Les annonces de test rapportent 0 avec la précision unknown.",
        "Rupture de couverture : la règle de collecte (collection_rule) a changé avec le build qui envoie ces mesures. Il n’y a plus de carte d’accord ; la mesure est activée par défaut hors EEE et Royaume-Uni quand la boutique App Store est connue, désactivée dans l’EEE, au Royaume-Uni ou si la boutique est inconnue (Android, éditeur) ; un choix explicite dans les Réglages est conservé. Ne pas comparer brutement avant/après les parts mesurées, retours ou étapes : comparer version par version.",
        "Signaux d’accord : consent_signals = not_fed. Les compteurs anonymes consent_accepted et consent_declined ne sont plus alimentés après la version 1.5.1 (comparaison numérique des versions) ; leurs zéros ne sont ni des refus ni des acceptations, et aucun taux d’acceptation ne doit en être tiré.",
        "monetisation_pubs : une ligne par jour × version × plateforme × format × emplacement × mode × variante. installations = installations distinctes de la ligne, jamais additionnées entre lignes comme des joueurs uniques. opportunities = occasions d’afficher une publicité ; show_requested, opened, impressions, closed, display_failed = étapes d’affichage ; rewards_granted / rewards_not_granted = vidéos récompensées terminées avec ou sans récompense ; paid_events = revenus OnAdPaid reçus. Les étapes ne forment pas un entonnoir garanti (ouvertures et demandes peuvent différer). Formats : interstitial (interstitielle), rewarded (vidéo récompensée, emplacement hint uniquement). Emplacements : next, replay, home, hint. Modes : campaign, quick, daily, lightpaths, none (hors partie). Variantes : none hors test, lp_control témoin, lp_treatment test.",
        "monetisation_pubs_motifs : format long de decisions, une ligne par décision ; la somme des count d’une ligne vaut opportunities. show = affichage décidé, offered = vidéo proposée ; les autres codes sont des motifs de non-affichage (premium, disabled, mode_disabled, placement_disabled, discovery, minimum_victories, minimum_play, session_cap, day_cap, rewarded_cooldown, frequency, time_gap, not_in_test, not_ready, busy, daily_limit, cancelled).",
        "monetisation_revenus : une ligne par ligne de monetisation_pubs × devise × précision ; la somme de paid_events vaut celle de la ligne de monetisation_pubs.",
        "monetisation_chargements : demandes, chargements réussis et échecs par jour × version × plateforme × format ; monetisation_chargements_erreurs détaille les échecs par code d’erreur Google brut (texte, par exemple 3 ou -1), propre au SDK de chaque plateforme ; la somme vaut failed.",
        "monetisation_paisible : format long des étapes de l’offre Jardin paisible, par jour × version × plateforme × emplacement. events = événements de l’étape, installations_step = installations distinctes ayant atteint l’étape dans la ligne, installations = installations distinctes de la ligne. entitlement_unknown = vérification du droit impossible ; account_changed = compte changé pendant la vérification.",
        "monetisation_test : test lightpaths_ads_v1, une ligne par jour d’attribution × groupe × version ; J0 = jour Europe/Zurich de l’attribution, cohort_size = installations attribuées (une seule fois chacune, sauf parcours suspects). return_d1 / return_d7 = au moins un événement le jour exact J1 / J7 ; fractions (0,25 = 25 %) ; immature_cohort tant que la journée n’est pas écoulée plus 3 jours. Les sommes J0–J6 (lightpaths_solved, interstitial_impressions, lightpaths_interstitials, rewarded_impressions) et monetisation_test_revenus restent vides tant que mature = false : jamais 0. Lu depuis les événements bruts, conservés 25 mois. Tant qu’aucun groupe n’est attribué, ce rapport reste vide.",
        "monetisation_couverture : contexte de chaque rapport (période, as_of, jours archivés, première mesure reçue sur l’ensemble de la collecte, règle de collecte et constantes du contrat). collection_first_received_at vide = aucune mesure reçue : aucun build n’envoie encore ces événements, ou leur collecte est coupée."
    ] }
}
