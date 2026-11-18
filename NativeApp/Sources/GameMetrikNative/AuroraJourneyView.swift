import SwiftUI
import GameMetrikCore

private enum JourneyStyle {
    // Keep small explanatory text readable in both native appearances.
    static let secondaryText = Color.primary.opacity(0.75)
}

// THESIS: read the observed journey, with maturity and collection coverage beside the numbers.
// OWN-WORLD: the existing macOS Journal, semantic surfaces, SF type, green activity, native controls.
// STORY: compare versions, inspect the two return anchors, then understand game outcomes and losses.
// FIRST VIEWPORT: title and report selector, version groups with effectifs, then daily details.
// FORM: local extension of Ballpark's five-report surface, as explicitly requested; no new visual identity.
/// The five v1 reports, the separate anonymous steps report and the four measured monetization reports, in reading order.
enum AuroraJourneyTab: Hashable, CaseIterable {
    case funnel, steps, retentionOpen, retentionCompleted, runs, quality, ads, adLoads, premium, experiment
    var kind: AuroraJourneyReportKind? {
        switch self {
        case .funnel: .funnel
        case .retentionOpen: .retentionOpen
        case .retentionCompleted: .retentionCompleted
        case .runs: .runs
        case .quality: .quality
        case .steps, .ads, .adLoads, .premium, .experiment: nil
        }
    }
    var monetization: AuroraMonetizationReportKind? {
        switch self {
        case .ads: .ads
        case .adLoads: .adLoads
        case .premium: .premium
        case .experiment: .experiment
        default: nil
        }
    }
    var title: String { kind?.title ?? monetization?.title ?? "Étapes anonymes" }
}

struct AuroraJourneyView: View {
    @EnvironmentObject var state: AppState
    @State private var selected: AuroraJourneyTab = .funnel
    var body: some View {
        if let data = state.auroraJourney {
            AuroraJourneyContent(data: data, selected: $selected, demo: state.demo, retry: { state.synchronizeSelection() })
        } else {
            ContentUnavailableView {
                Label("Parcours à synchroniser", systemImage: Destination.auroraJourney.symbol)
            } description: {
                Text("Synchronise Aurora Grove pour lire ses premières ouvertures, tutoriels, parties et retours.")
            } actions: { Button("Synchroniser") { state.synchronizeSelection() } }
        }
    }
}

struct AuroraJourneyContent: View {
    let data: AuroraJourneyBundle
    @Binding var selected: AuroraJourneyTab
    var demo: Bool
    var retry: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Parcours des joueurs").font(.title2.weight(.semibold))
                Text("Aurora Grove · Europe/Zurich" + (demo ? " · données fictives" : " · Administration personnelle"))
                    .font(.callout).foregroundStyle(JourneyStyle.secondaryText)
                ViewThatFits(in: .horizontal) {
                    picker(.segmented)
                    picker(.menu)
                }
                if let filters = data.filters, data.collectionGap(for: filters) == .notCollected {
                    Text("Collecte non disponible sur cette période. Aucun parcours historique n’est reconstitué.").font(.callout).foregroundStyle(JourneyStyle.secondaryText)
                } else if let filters = data.filters, data.collectionGap(for: filters) == .partial {
                    Text("La période commence avant la collecte : les jours antérieurs restent non collectés.").font(.callout).foregroundStyle(JourneyStyle.secondaryText)
                }
                if data.status == .partial {
                    Text("Certains rapports sont indisponibles. Chaque volet indique son état.").font(.callout).foregroundStyle(JourneyStyle.secondaryText)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            if let failure {
                ContentUnavailableView {
                    Label(failure.title, systemImage: failure.symbol)
                } description: { Text(failure.detail).frame(maxWidth: 520) }
                actions: { Button("Réessayer") { retry() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        report
                        if let coverage = selected.kind.flatMap(data.coverage(for:)) {
                            Divider()
                            AuroraJourneyCoverageView(coverage: coverage, asOf: data.asOf, consentSignals: data.consentSignals)
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    /// Each tab shows only its own failure: a missing steps or monetization report never hides the others.
    private var failure: (title: String, detail: String, symbol: String)? {
        if let kind = selected.kind, let failure = data.errors[kind] {
            return (failure.status == .notConnected ? "Parcours non connecté" : "Rapport indisponible", failure.detail, "exclamationmark.triangle")
        }
        if selected == .steps, let failure = data.stepsError {
            return (failure.status == .notConnected ? "Étapes anonymes non disponibles" : "Rapport indisponible", failure.detail, "exclamationmark.triangle")
        }
        if let kind = selected.monetization, let failure = data.monetization.errors[kind] {
            switch failure.cause {
            case .missingFunction: return ("Mesure de la monétisation non raccordée", failure.detail, "puzzlepiece.extension")
            case .denied: return ("Accès refusé", failure.detail, "lock")
            case .unreadable: return ("Rapport illisible", failure.detail, "exclamationmark.triangle")
            case .server, .network: return ("Rapport indisponible", failure.detail, "exclamationmark.triangle")
            }
        }
        return nil
    }
    private func picker<S: PickerStyle>(_ style: S) -> some View {
        Picker("Rapport du parcours", selection: $selected) {
            ForEach(AuroraJourneyTab.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(style).fixedSize(horizontal: style is SegmentedPickerStyle, vertical: false)
    }
    @ViewBuilder private var report: some View {
        switch selected {
        case .funnel: if let report = data.funnel { AuroraJourneyFunnelView(report: report) }
        case .retentionOpen: if let report = data.retentionOpen { AuroraJourneyRetentionView(report: report) }
        case .retentionCompleted: if let report = data.retentionCompleted { AuroraJourneyRetentionView(report: report) }
        case .runs: if let report = data.runs { AuroraJourneyRunsView(report: report) }
        case .quality: if let report = data.quality { AuroraJourneyQualityView(report: report) }
        case .steps: if let report = data.steps { AuroraJourneyStepsView(report: report) } else { Text("Étapes anonymes à synchroniser.") }
        case .ads, .adLoads, .premium, .experiment:
            if let kind = selected.monetization { AuroraMonetizationReportView(bundle: data.monetization, kind: kind) }
        }
    }
}

private struct JourneyPeriod: View {
    let filters: AuroraJourneyFilters
    var body: some View {
        Text("Du \(filters.fromDay) au \(filters.toDayExclusive) exclu · jours Europe/Zurich")
            .font(.callout).foregroundStyle(JourneyStyle.secondaryText)
    }
}
private struct JourneyRatioView: View {
    let title: String
    let total: AuroraJourneyRatioTotal
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout).foregroundStyle(JourneyStyle.secondaryText)
            Text(total.ratio.formatted).font(.title3.weight(.semibold)).monospacedDigit()
            Text(total.ratio.sample).font(.callout).monospacedDigit()
            if total.excludedRows > 0 {
                Text("\(total.excludedRows) cohorte(s) sans taux, exclue(s) du calcul")
                    .font(.caption).foregroundStyle(JourneyStyle.secondaryText)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct AuroraJourneyFunnelView: View {
    let report: AuroraJourneyReport<AuroraJourneyFunnelRow>
    private var versions: [String] { Set(report.rows.map(\.appVersion)).sorted().reversed() }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("De la première ouverture à la première partie").font(.headline)
            JourneyPeriod(filters: report.filters)
            Text("J0–J6 : nouvelles installations mesurées dès leur premier lancement, après exclusions. Les étapes attendent la fin de J6 et 3 jours de délai. Chaque taux additionne uniquement les numérateurs et dénominateurs disponibles, par version.")
                .font(.callout).foregroundStyle(JourneyStyle.secondaryText)
            if versions.isEmpty { Text("Aucune cohorte reçue sur cette période.") }
            ForEach(versions, id: \.self) { version in
                let rows = report.rows.filter { $0.appVersion == version }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Version \(version) · \(rows.reduce(0) { $0 + $1.cohortSize }) installations mesurées").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .topLeading)], alignment: .leading, spacing: 18) {
                        JourneyRatioView(title: "Tutoriel commencé", total: .sum(rows.map(\.tutorialStarted)))
                        JourneyRatioView(title: "Tutoriel terminé", total: .sum(rows.map(\.tutorialCompleted)))
                        JourneyRatioView(title: "Première partie terminée", total: .sum(rows.map(\.firstRunCompleted)))
                        JourneyRatioView(title: "Part des nouveaux mesurés", total: .sum(rows.map(\.measuredShare)))
                    }
                    // After 1.5.1 the consent card is gone: its counters stay at zero without meaning refusal or acceptance.
                    Text("Premiers lancements anonymes : \(rows.reduce(0) { $0 + $1.anonymousFirstLaunches }) · "
                         + (AuroraConsentSignals.fed(appVersion: version)
                            ? "Accords : \(rows.reduce(0) { $0 + $1.consentAccepted }) · Refus : \(rows.reduce(0) { $0 + $1.consentDeclined })"
                            : "Signaux d’accord : non alimentés (carte d’accord retirée après la 1.5.1)"))
                        .font(.callout).monospacedDigit()
                    Text("La part mesurée n’attend pas la maturité du tutoriel. Les réponses à la carte sont comptées le jour de la réponse ; une réponse tardive peut concerner un autre jour de lancement. Une part supérieure à 100 % signale des comptes anonymes perdus.")
                        .font(.caption).foregroundStyle(JourneyStyle.secondaryText)
                    DisclosureGroup("Détail par jour de première ouverture") {
                        ForEach(rows, id: \.stableKey) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(row.cohortDay) · \(row.cohortSize) installations" + (row.mature ? " · mûre" : " · en attente")).font(.callout.weight(.medium))
                                Text("Tutoriel commencé : \(row.tutorialStarted.formatted) (\(row.tutorialStarted.sample))\nTutoriel terminé : \(row.tutorialCompleted.formatted) (\(row.tutorialCompleted.sample))\nPremière partie : \(row.firstRunCompleted.formatted) (\(row.firstRunCompleted.sample))\nPart mesurée : \(row.measuredShare.formatted) (\(row.measuredShare.sample))")
                                    .font(.callout).monospacedDigit()
                            }.padding(.vertical, 8)
                        }
                    }
                }
                Divider()
            }
        }
    }
}
struct AuroraJourneyStepsView: View {
    let report: AuroraJourneyStepsReport
    private static let columns = ["Jour de cohorte", "Version", "Premiers lancements", "Installations mesurées", "Part mesurée"]
        + AuroraJourneyStepsRow.steps.map(\.title)
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Étapes anonymes des nouvelles installations").font(.headline)
            JourneyPeriod(filters: .init(fromDay: report.filters.fromDay, toDayExclusive: report.filters.toDayExclusive, appVersion: report.filters.appVersion))
            Text("J0 est le jour du premier lancement (Europe/Zurich). Chaque étape est comptée une fois par installation, sans aucun identifiant, et rapportée aux installations mesurées de la même ligne. Une étape attend la fin de sa fenêtre plus 3 jours : J0–J6 pour le tutoriel et les jardins résolus, J1 pour le retour J1, J7–J13 pour le dernier retour.")
                .font(.callout).foregroundStyle(JourneyStyle.secondaryText)
            if report.rows.isEmpty {
                Text("Aucune étape anonyme reçue sur cette période.")
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow { ForEach(Self.columns, id: \.self) { Text($0) } }
                            .font(.caption).foregroundStyle(JourneyStyle.secondaryText)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(report.rows, id: \.stableKey) { row in
                            GridRow {
                                Text(row.cohortDay)
                                Text(row.appVersion)
                                Text(row.firstLaunches.formatted()).gridColumnAlignment(.trailing)
                                Text(row.stepsOpen.formatted()).gridColumnAlignment(.trailing)
                                StepRatioCell(ratio: row.measuredShare)
                                ForEach(AuroraJourneyStepsRow.steps, id: \.key) { StepRatioCell(ratio: row[keyPath: $0.path]) }
                            }.font(.callout).monospacedDigit()
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text("Total").fontWeight(.semibold)
                            Text("")
                            Text(report.firstLaunches.formatted())
                            Text(report.stepsOpen.formatted())
                            StepRatioCell(ratio: report.total(\.measuredShare).ratio)
                            ForEach(AuroraJourneyStepsRow.steps, id: \.key) { StepRatioCell(ratio: report.total($0.path).ratio) }
                        }.font(.callout.weight(.semibold)).monospacedDigit()
                    }.fixedSize().padding(.bottom, 5)
                }
            }
            Text("Le total additionne les numérateurs et dénominateurs des seules lignes dont le taux est publié, jamais les pourcentages ; les lignes en attente de maturité ou non collectées en sont exclues. Comparer les versions séparément.")
                .font(.caption).foregroundStyle(JourneyStyle.secondaryText)
            Text("La part mesurée rapporte les installations mesurées aux premiers lancements : elle mêle refus dans l’EEE, mesure coupée et envois perdus, ce n’est pas un taux de refus. « Non collecté » signale une version sans étapes anonymes, comme la 1.5.0. Depuis la 1.5.1, lire ici le tutoriel et les premiers jardins plutôt que dans l’entonnoir.")
                .font(.caption).foregroundStyle(JourneyStyle.secondaryText)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Identifiant : aucun").font(.callout.weight(.medium))
                DisclosureGroup("Couverture et limites de lecture") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Premier jour des étapes : \(report.coverage.stepsFirstDay ?? "aucun")")
                        Text("Borne de lecture : \(report.asOf)")
                        Text("Dans l’EEE et au Royaume-Uni, une installation n’envoie ses étapes qu’avec l’accord du joueur ; ailleurs, le joueur peut les désactiver. Leurs taux ne se comparent donc pas directement.")
                        Text("Règle du serveur : \(report.coverage.regionRule)")
                        Text("Cohorte du serveur : \(report.coverage.cohortDefinition)")
                        Text("Un premier lancement n’est pas une personne unique. Les retours J1 et J7–J13 suivent le calendrier du téléphone, la cohorte le jour Europe/Zurich.")
                    }.font(.callout).foregroundStyle(JourneyStyle.secondaryText).textSelection(.enabled).padding(.top, 10)
                }
            }
        }
    }
}
private struct StepRatioCell: View {
    let ratio: AuroraJourneyRatio
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(ratio.formatted).foregroundStyle(ratio.value == nil ? JourneyStyle.secondaryText : Color.primary)
            if ratio.value != nil { Text(ratio.sample).font(.caption).foregroundStyle(JourneyStyle.secondaryText) }
        }.gridColumnAlignment(.trailing)
        .help(ratio.value == nil ? ratio.formatted : "\(ratio.formatted) · \(ratio.sample)")
    }
}
private struct AuroraJourneyRetentionView: View {
    let report: AuroraJourneyReport<AuroraJourneyRetentionRow>
    private var fromOpen: Bool { report.report == .retentionOpen }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(fromOpen ? "Retours depuis la première ouverture" : "Retours depuis la première partie terminée").font(.headline)
            JourneyPeriod(filters: report.filters)
            Text(fromOpen
                 ? "J0 est la première ouverture. Un retour est au moins un événement ce jour-là, y compris une session qui franchit minuit."
                 : "J0 est la première partie résolue des nouvelles installations de la cohorte. Un retour est une autre partie résolue ce jour-là.")
                .font(.callout).foregroundStyle(JourneyStyle.secondaryText)
            Text("J1 et J7 sont des jours exacts. J7–J13 couvre au moins un retour dans cette fenêtre. Chaque mesure attend la fin de sa fenêtre plus 3 jours ; ses effectifs mûrs sont calculés séparément.")
                .font(.callout).foregroundStyle(JourneyStyle.secondaryText)
            if report.rows.isEmpty { Text("Aucune cohorte reçue sur cette période.") }
            ForEach(Set(report.rows.map(\.appVersion)).sorted().reversed(), id: \.self) { version in
                let rows = report.rows.filter { $0.appVersion == version }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Version \(version) · \(rows.reduce(0) { $0 + $1.cohortSize }) installations").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .topLeading)], spacing: 18) {
                        JourneyRatioView(title: "J1 exact", total: .sum(rows.map(\.returnD1)))
                        JourneyRatioView(title: "J7 exact", total: .sum(rows.map(\.returnD7)))
                        JourneyRatioView(title: "J7–J13", total: .sum(rows.map(\.returnD7D13)))
                    }
                    DisclosureGroup("Détail des cohortes") {
                        ForEach(rows, id: \.stableKey) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(row.cohortDay) · \(row.cohortSize) installations").fontWeight(.medium)
                                Text("J1 : \(row.returnD1.formatted) (\(row.returnD1.sample))\nJ7 : \(row.returnD7.formatted) (\(row.returnD7.sample))\nJ7–J13 : \(row.returnD7D13.formatted) (\(row.returnD7D13.sample))")
                            }.font(.callout).monospacedDigit().padding(.vertical, 8)
                        }
                    }
                }
                Divider()
            }
        }
    }
}
private struct AuroraJourneyRunsView: View {
    let report: AuroraJourneyReport<AuroraJourneyRunRow>
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Issues des parties par mode et étape").font(.headline)
            JourneyPeriod(filters: report.filters)
            Text("Toutes les installations mesurées. La période porte sur le premier événement observé de la partie ; chaque partie compte une seule fois. Une partie récente peut encore être reprise. Les interruptions décrivent des faits observés.")
                .font(.callout).foregroundStyle(JourneyStyle.secondaryText)
            if report.rows.isEmpty { Text("Aucune partie reçue sur cette période.") }
            ForEach(report.rows, id: \.stableKey) { row in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        countLine("Début observé", row.startObserved)
                        ForEach(row.outcomes, id: \.key) { item in countLine(item.label, item.count) }
                    }.padding(.vertical, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(row.mode.title)" + (row.level > 0 ? " · étape \(row.level)" : "") + " · version \(row.appVersion)").fontWeight(.medium)
                        Text("\(row.games) parties · \(row.solved) résolues · \(row.openRecent) encore récentes").font(.callout).foregroundStyle(JourneyStyle.secondaryText)
                    }
                }
                Divider()
            }
        }
    }
    private func countLine(_ label: String, _ value: Int) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label); Spacer(minLength: 12); Text(String(value)).monospacedDigit() }.font(.callout)
    }
}
private struct AuroraJourneyQualityView: View {
    let report: AuroraJourneyReport<AuroraJourneyQualityRow>
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Qualité de la collecte").font(.headline)
            JourneyPeriod(filters: report.filters)
            Text("Pertes déclarées : \(report.rows.reduce(0) { $0 + $1.lostEventsReported }) · Refus du serveur : \(report.coverage.rejectionsInWindow.values.reduce(0, +)) · Relancements après arrêt affiché : \(report.rows.reduce(0) { $0 + $1.launchesAfterForegroundStop })")
                .font(.headline).monospacedDigit()
            Text("Les pertes sont déclarées par les téléphones. Un arrêt alors que l’app était affichée peut être un plantage ou un arrêt forcé. Les refus du serveur concernent toute la fenêtre, sans filtre de version.")
                .font(.callout).foregroundStyle(JourneyStyle.secondaryText)
            if report.rows.isEmpty { Text("Aucun événement reçu sur cette période.") }
            ForEach(report.rows, id: \.stableKey) { row in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Premières ouvertures : \(row.firstOpenNewInstall) nouvelles · \(row.firstOpenExistingPlayer) existantes · \(row.firstOpenUnknown) inconnues · \(row.firstOpenLateConsent) accords tardifs parmi les nouvelles")
                        Text("\(row.installationsReportingLosses) installations déclarant \(row.lostEventsReported) événements perdus")
                        Text("\(row.launchesAfterForegroundStop) lancements après un arrêt de l’app affichée")
                        ForEach(row.byEvent.keys.sorted(), id: \.self) { key in Text("\(key) : \(row.byEvent[key]!)").monospacedDigit() }
                    }.font(.callout).padding(.vertical, 10)
                } label: {
                    Text("\(row.day) · \(row.appVersion) · \(row.platform.rawValue) · \(row.installations) installations actives · \(row.events) événements").font(.callout)
                }
                Divider()
            }
            Text("Les installations actives sont distinctes dans chaque ligne jour × version × plateforme. Leur somme n’est pas un nombre de joueurs uniques sur la période.")
                .font(.caption).foregroundStyle(JourneyStyle.secondaryText)
        }
    }
}
private struct AuroraJourneyCoverageView: View {
    let coverage: AuroraJourneyCoverage
    let asOf: String?
    let consentSignals: AuroraJourneyBundle.ConsentSignals
    private var anonymous: String {
        let a = coverage.anonymousInWindow
        let launches = "\(a.firstLaunchNewInstall) premiers lancements nouveaux · \(a.firstLaunchExistingPlayer) existants"
        switch consentSignals {
        case .fed: return launches + " · \(a.consentAccepted) accords · \(a.consentDeclined) refus"
        case .mixed: return launches + " · \(a.consentAccepted) accords · \(a.consentDeclined) refus, venant uniquement des versions jusqu’à 1.5.1 (signaux non alimentés au-delà)"
        case .notFed: return launches + " · signaux d’accord non alimentés pour cette version (carte d’accord retirée après la 1.5.1)"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attribution : non collectée").font(.callout.weight(.medium))
            DisclosureGroup("Couverture et limites de lecture") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Premières ouvertures dans la période") .fontWeight(.medium)
                    Text("\(coverage.firstOpenInWindow.newInstall) nouvelles mesurées · \(coverage.firstOpenInWindow.newInstallLateConsent) accords tardifs · \(coverage.firstOpenInWindow.newInstallKnownAccount) comptes déjà connus · \(coverage.firstOpenInWindow.excludedSuspicious) parcours suspects · \(coverage.firstOpenInWindow.existingPlayer) joueurs existants · \(coverage.firstOpenInWindow.unknown) inconnues")
                    Text("Les motifs d’exclusion peuvent se recouvrir ; ils ne s’additionnent pas en joueurs uniques.").foregroundStyle(JourneyStyle.secondaryText)
                    Text("Décompte anonyme dans la période").fontWeight(.medium)
                    Text(anonymous)
                    Text("Refus serveur par motif").fontWeight(.medium)
                    if coverage.rejectionsInWindow.isEmpty { Text("Aucun refus reçu sur la période.") }
                    ForEach(coverage.rejectionsInWindow.keys.sorted(), id: \.self) { code in
                        Text("\(AuroraJourneyCoverage.rejectionLabel(for: code)) : \(coverage.rejectionsInWindow[code]!)")
                    }
                    Text("Premier événement reçu : \(coverage.collectionFirstReceivedAt ?? "aucun")")
                    Text("Borne de lecture : \(asOf ?? "non disponible")")
                    Text("\(coverage.archivedDaysInWindow) jours archivés dans la période. Les jours figés après 60 jours restent anonymes et immuables ; la borne de lecture ne s’applique qu’aux jours non figés.")
                    Text("Collecte avec accord. Les joueurs existants, accords tardifs, comptes connus et parcours suspects sont exclus des cohortes. Une installation ne représente pas nécessairement une personne unique.")
                }.font(.callout).foregroundStyle(JourneyStyle.secondaryText).textSelection(.enabled).padding(.top, 10)
            }
        }
    }
}
