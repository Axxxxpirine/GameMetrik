import SwiftUI
import GameMetrikCore

// THESIS: read measured ads, loads, the Peaceful Grove offer and the Light Paths test with their sample and limits beside them.
// FORM: same open stacks, headlines, callouts and disclosures as the journey reports; no new visual identity.
private enum MonetizationStyle {
    static let secondaryText = Color.primary.opacity(0.75)
}

/// One measured monetization report. Failures are shown by the parent; this view separates "no measure ever received",
/// "no row in the period" and real zeros (rows present with 0).
struct AuroraMonetizationReportView: View {
    let bundle: AuroraMonetizationBundle
    let kind: AuroraMonetizationReportKind
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch bundle.state(for: kind) {
            case .notLoaded:
                Text("Rapport « \(kind.title) » à synchroniser.")
            case .failed:
                EmptyView()
            case .noMeasurement:
                header
                notice("Aucune mesure reçue", "Aucun événement de ce type n’a jamais été reçu : aucun build n’envoie encore ces mesures, ou leur collecte est coupée. Ce n’est pas un zéro.")
            case .noData:
                header
                notice("Aucune donnée sur la période", "La collecte a commencé (première mesure reçue : \(bundle.coverage(for: kind)?.collectionFirstReceivedAt ?? "?")), mais aucune ligne ne couvre ces jours. Ce n’est pas un zéro mesuré."
                       + (kind == .experiment ? " Tant que le test n’attribue aucun groupe, ce rapport reste vide." : ""))
            case .data:
                header
                switch kind {
                case .ads: if let report = bundle.ads { AdsReportView(report: report) }
                case .adLoads: if let report = bundle.adLoads { AdLoadsReportView(report: report) }
                case .premium: if let report = bundle.premium { PremiumReportView(report: report) }
                case .experiment: if let report = bundle.experiment { ExperimentReportView(report: report) }
                }
            }
            if let coverage = bundle.coverage(for: kind) {
                Divider()
                MonetizationCoverageView(kind: kind, coverage: coverage, asOf: bundle.asOf)
            }
        }
    }
    private var title: String {
        switch kind {
        case .ads: "Occasions, affichages et revenus publicitaires mesurés"
        case .adLoads: "Chargements des publicités"
        case .premium: "Parcours de l’offre Jardin paisible"
        case .experiment: "Test des publicités des Chemins de lumière"
        }
    }
    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let filters = bundle.filters(for: kind), let coverage = bundle.coverage(for: kind) {
                Text("Du \(filters.fromDay) au \(filters.toDayExclusive) exclu · jours Europe/Zurich" + (filters.appVersion.map { " · version " + $0 } ?? "")
                     + " · borne de lecture \(bundle.asOf ?? "non disponible") · \(coverage.archivedDaysInWindow) jour(s) archivé(s)")
                    .font(.callout).foregroundStyle(MonetizationStyle.secondaryText)
            }
            Text("Revenu mesuré : échantillon des installations autorisées à être mesurées, distinct du revenu total AdMob (les rapports AdMob font foi). Aucune attribution aux campagnes Meta. La règle de collecte a changé avec ce build : comparer version par version.")
                .font(.callout).foregroundStyle(MonetizationStyle.secondaryText)
        }
    }
    private func notice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "tray").font(.callout.weight(.medium))
            Text(detail).font(.callout).foregroundStyle(MonetizationStyle.secondaryText)
        }
    }
}

private struct CountTile: View {
    let title: String
    let value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout).foregroundStyle(MonetizationStyle.secondaryText)
            Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct CountLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) { Text(label); Spacer(minLength: 12); Text(value).monospacedDigit() }.font(.callout)
    }
}
/// Revenue per currency (then per precision), never one amount across currencies.
private struct RevenueList: View {
    let totals: [AuroraRevenueTotal]
    var body: some View {
        if totals.isEmpty {
            Text("Aucun revenu reçu sur ces lignes.").font(.callout).foregroundStyle(MonetizationStyle.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(totals, id: \.id) { total in
                    CountLine(label: total.currency + (total.precision.map { " · " + $0.title } ?? ""),
                              value: total.amount + " · \(total.paidEvents) événement(s)")
                }
            }
        }
    }
}
private extension AuroraRevenueTotal {
    var id: String { currency + "|" + (precision?.rawValue ?? "") }
}
private func installationsRange(_ values: [Int]) -> String {
    guard let low = values.min(), let high = values.max() else { return "aucune ligne" }
    return "\(values.count) ligne(s) · \(low == high ? "\(low)" : "\(low) à \(high)") installation(s) par ligne, non additionnées"
}

private struct AdsReportView: View {
    let report: AuroraMonetizationReport<AuroraAdRow>
    private var groups: [(format: AuroraAdFormat, placement: AuroraAdPlacement)] {
        AuroraAdFormat.allCases.flatMap { format in AuroraAdPlacement.allCases.map { (format, $0) } }
            .filter { group in report.rows.contains { $0.format == group.0 && $0.placement == group.1 } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Revenus mesurés par devise et précision").font(.headline)
                RevenueList(totals: report.revenueTotals())
                Text("Montant = value_micros / 1 000 000 dans sa devise, sans conversion. Les devises ne s’additionnent jamais. Une annonce de test rapporte 0 avec une précision inconnue.")
                    .font(.caption).foregroundStyle(MonetizationStyle.secondaryText)
            }
            Divider()
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                let rows = report.rows.filter { $0.format == group.format && $0.placement == group.placement }
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(group.format.title) · \(group.placement.title)").font(.headline)
                    Text(installationsRange(rows.map(\.installations))).font(.callout).foregroundStyle(MonetizationStyle.secondaryText)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .topLeading)], alignment: .leading, spacing: 18) {
                        ForEach(AuroraAdRow.counts.filter { group.format == .rewarded || !$0.key.hasPrefix("rewards") }, id: \.key) { count in
                            CountTile(title: count.title, value: rows.reduce(0) { $0 + $1[keyPath: count.path] })
                        }
                    }
                    Text("Les étapes ne forment pas un entonnoir garanti : une ouverture peut être signalée sans demande correspondante, et inversement.")
                        .font(.caption).foregroundStyle(MonetizationStyle.secondaryText)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Décision de chaque occasion").font(.callout.weight(.medium))
                        ForEach(AuroraAdRow.decisionTotals(rows), id: \.code) { item in
                            CountLine(label: AuroraAdRow.decisionTitle(item.code) + " (" + item.code + ")", value: item.count.formatted())
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Revenus mesurés").font(.callout.weight(.medium))
                        RevenueList(totals: AuroraRevenueTotal.totals(rows.flatMap(\.revenue), byPrecision: true))
                    }
                    DisclosureGroup("Détail par jour, version, plateforme, mode et variante") {
                        ForEach(rows, id: \.stableKey) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(row.day) · \(row.appVersion) · \(row.platform.rawValue) · \(row.gameMode.title) · \(row.variant.title) · \(row.installations) installation(s)")
                                    .font(.callout.weight(.medium))
                                Text(AuroraAdRow.counts.filter { group.format == .rewarded || !$0.key.hasPrefix("rewards") }
                                    .map { "\($0.title) : \(row[keyPath: $0.path])" }.joined(separator: " · "))
                                    .font(.callout).monospacedDigit()
                                Text("Motifs : " + AuroraAdRow.decisionTotals([row]).map { "\(AuroraAdRow.decisionTitle($0.code)) \($0.count)" }.joined(separator: " · "))
                                    .font(.callout).foregroundStyle(MonetizationStyle.secondaryText)
                                if !row.revenue.isEmpty {
                                    Text("Revenus : " + row.revenue.map { "\($0.amount) (\($0.precision.title), \($0.paidEvents))" }.joined(separator: " · "))
                                        .font(.callout).monospacedDigit()
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }
}

private struct AdLoadsReportView: View {
    let report: AuroraMonetizationReport<AuroraAdLoadRow>
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(AuroraAdFormat.allCases.filter { format in report.rows.contains { $0.format == format } }, id: \.self) { format in
                let rows = report.rows.filter { $0.format == format }
                if format == .rewarded && report.rows.contains(where: { $0.format == .interstitial }) { Divider() }
                VStack(alignment: .leading, spacing: 16) {
                    Text(format.title).font(.headline)
                    Text(installationsRange(rows.map(\.installations))).font(.callout).foregroundStyle(MonetizationStyle.secondaryText)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .topLeading)], alignment: .leading, spacing: 18) {
                        CountTile(title: "Chargements demandés", value: rows.reduce(0) { $0 + $1.requested })
                        CountTile(title: "Chargements réussis", value: rows.reduce(0) { $0 + $1.loaded })
                        CountTile(title: "Chargements échoués", value: rows.reduce(0) { $0 + $1.failed })
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Échecs par code d’erreur Google").font(.callout.weight(.medium))
                        let codes = rows.flatMap { row in row.errors.map { (platform: row.platform.rawValue, code: $0.key, count: $0.value) } }
                        if codes.isEmpty { Text("Aucun échec sur ces lignes.").font(.callout) }
                        ForEach(Dictionary(grouping: codes) { $0.platform + "|" + $0.code }.sorted { $0.key < $1.key }, id: \.key) { key, items in
                            CountLine(label: "\(items[0].platform) · code \(items[0].code)", value: items.reduce(0) { $0 + $1.count }.formatted())
                        }
                        Text("Codes bruts du SDK Google Mobile Ads, propres à chaque plateforme.").font(.caption).foregroundStyle(MonetizationStyle.secondaryText)
                    }
                    DisclosureGroup("Détail par jour, version et plateforme") {
                        ForEach(rows, id: \.stableKey) { row in
                            Text("\(row.day) · \(row.appVersion) · \(row.platform.rawValue) · \(row.installations) installation(s) · \(row.requested) demandés · \(row.loaded) réussis · \(row.failed) échoués"
                                 + (row.errors.isEmpty ? "" : " · codes " + row.sortedErrorCodes.map { "\($0) : \(row.errors[$0]!)" }.joined(separator: ", ")))
                                .font(.callout).monospacedDigit().padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }
}

private struct PremiumReportView: View {
    let report: AuroraMonetizationReport<AuroraPremiumRow>
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Chaque étape compte ses événements ; les installations sont distinctes dans chaque ligne jour × version × plateforme × emplacement et ne s’additionnent pas entre lignes.")
                .font(.callout).foregroundStyle(MonetizationStyle.secondaryText)
            ForEach(Array(AuroraPremiumPlacement.allCases.filter { placement in report.rows.contains { $0.placement == placement } }.enumerated()), id: \.offset) { index, placement in
                let rows = report.rows.filter { $0.placement == placement }
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Emplacement : \(placement.title)").font(.headline)
                    Text(installationsRange(rows.map(\.installations))).font(.callout).foregroundStyle(MonetizationStyle.secondaryText)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow { Text("Étape"); Text("Événements").gridColumnAlignment(.trailing) }
                            .font(.caption).foregroundStyle(MonetizationStyle.secondaryText)
                        ForEach(AuroraPremiumRow.stepOrder.filter { step in rows.contains { $0.steps[step] != nil } }, id: \.self) { step in
                            GridRow {
                                Text(AuroraPremiumRow.stepTitle(step))
                                Text(rows.reduce(0) { $0 + ($1.steps[step] ?? 0) }.formatted())
                            }.font(.callout).monospacedDigit()
                        }
                    }
                    DisclosureGroup("Installations par étape, par jour, version et plateforme") {
                        ForEach(rows, id: \.stableKey) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(row.day) · \(row.appVersion) · \(row.platform.rawValue) · \(row.installations) installation(s)").font(.callout.weight(.medium))
                                Text(row.orderedSteps.map { "\(AuroraPremiumRow.stepTitle($0)) : \(row.steps[$0]!) événement(s), \(row.installationsByStep[$0]!) installation(s)" }.joined(separator: "\n"))
                                    .font(.callout).monospacedDigit()
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }
}

private struct ExperimentReportView: View {
    let report: AuroraMonetizationReport<AuroraExperimentRow>
    private static let variants: [AuroraAdVariant] = [.lpControl, .lpTreatment]
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Test lightpaths_ads_v1. J0 est le jour d’attribution du groupe (Europe/Zurich). J1 et J7 sont des jours exacts ; les sommes J0–J6 attendent la fin de J6 et 3 jours de délai. Une cohorte en attente n’est jamais comptée comme 0.")
                .font(.callout).foregroundStyle(MonetizationStyle.secondaryText)
            ForEach(Array(Set(report.rows.map(\.appVersion)).sorted().reversed().enumerated()), id: \.offset) { index, version in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Version \(version)").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .topLeading)], alignment: .leading, spacing: 22) {
                        ForEach(Self.variants, id: \.self) { variant in
                            group(report.rows.filter { $0.appVersion == version && $0.variant == variant }, variant: variant)
                        }
                    }
                    DisclosureGroup("Détail des cohortes") {
                        ForEach(report.rows.filter { $0.appVersion == version }, id: \.stableKey) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(row.cohortDay) · \(row.variant.title) · \(row.cohortSize) installation(s)" + (row.mature ? " · mûre" : " · en attente de maturité"))
                                    .font(.callout.weight(.medium))
                                Text("J1 : \(row.returnD1.formatted) (\(row.returnD1.sample)) · J7 : \(row.returnD7.formatted) (\(row.returnD7.sample))")
                                Text(AuroraExperimentRow.sums.map { "\($0.title) : \(row[keyPath: $0.path].map(String.init) ?? "En attente de maturité")" }.joined(separator: " · "))
                                Text("Revenus : " + (row.revenue.map { $0.isEmpty ? "aucun" : $0.map(\.amount).joined(separator: " · ") } ?? "En attente de maturité"))
                            }.font(.callout).monospacedDigit().padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder private func group(_ rows: [AuroraExperimentRow], variant: AuroraAdVariant) -> some View {
        let mature = rows.filter(\.mature)
        VStack(alignment: .leading, spacing: 8) {
            Text("\(variant.title) · \(rows.reduce(0) { $0 + $1.cohortSize }) installation(s) attribuée(s)").font(.callout.weight(.semibold))
            if rows.isEmpty { Text("Aucune cohorte.").font(.callout) } else {
                let d1 = AuroraJourneyRatioTotal.sum(rows.map(\.returnD1)), d7 = AuroraJourneyRatioTotal.sum(rows.map(\.returnD7))
                CountLine(label: "Retour J1", value: d1.ratio.formatted + (d1.ratio.value == nil ? "" : " (\(d1.ratio.sample))"))
                CountLine(label: "Retour J7", value: d7.ratio.formatted + (d7.ratio.value == nil ? "" : " (\(d7.ratio.sample))"))
                Text("Cohortes mûres : \(mature.reduce(0) { $0 + $1.cohortSize }) installation(s)" + (rows.count > mature.count ? " · \(rows.count - mature.count) cohorte(s) en attente, exclue(s)" : ""))
                    .font(.caption).foregroundStyle(MonetizationStyle.secondaryText)
                ForEach(AuroraExperimentRow.sums, id: \.key) { sum in
                    CountLine(label: sum.title, value: mature.isEmpty ? "En attente de maturité" : mature.reduce(0) { $0 + ($1[keyPath: sum.path] ?? 0) }.formatted())
                }
                if mature.isEmpty { CountLine(label: "Revenus J0–J6", value: "En attente de maturité") }
                else {
                    Text("Revenus J0–J6 par devise").font(.callout)
                    RevenueList(totals: report.revenueTotals(variant: variant))
                }
            }
        }
    }
}

private struct MonetizationCoverageView: View {
    let kind: AuroraMonetizationReportKind
    let coverage: AuroraMonetizationCoverage
    let asOf: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attribution : non collectée · Revenus : échantillon, AdMob fait foi").font(.callout.weight(.medium))
            DisclosureGroup("Couverture et limites de lecture") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Première mesure reçue : \(coverage.collectionFirstReceivedAt ?? "aucune")")
                    Text("Borne de lecture : \(asOf ?? "non disponible") · \(coverage.archivedDaysInWindow) jour(s) archivé(s) dans la période · délai d’envoi de \(coverage.graceDays) jours")
                    Text("Le revenu mesuré vient de l’événement OnAdPaid de Google, envoyé uniquement par les installations autorisées à être mesurées. C’est un échantillon, distinct du revenu total AdMob : la source d’autorité reste les rapports AdMob.")
                    Text("Ce n’est pas une attribution aux campagnes Meta : l’attribution n’est pas collectée, aucun lien entre une campagne, une installation et un revenu.")
                    Text("Les devises ne sont ni converties ni additionnées entre elles. Les annonces de test rapportent 0 avec une précision inconnue.")
                    Text("Rupture de couverture : la règle de collecte a changé avec le build qui envoie ces mesures. Il n’y a plus de carte d’accord ; la mesure est activée par défaut hors EEE et Royaume-Uni quand la boutique App Store est connue, désactivée dans l’EEE, au Royaume-Uni ou si la boutique est inconnue. Ne compare pas brutement avant et après les parts mesurées, retours ou étapes : compare version par version.")
                    Text("Signaux d’accord : non alimentés. Les compteurs d’accords et de refus ne sont plus alimentés après la 1.5.1 ; leurs zéros ne sont ni des refus ni des acceptations.")
                    Text("Installations distinctes dans chaque ligne : leur somme n’est pas un nombre de joueurs uniques. Une ligne présente avec 0 est un vrai zéro ; une absence de ligne n’en est pas un.")
                    if kind == .experiment { Text("Les cohortes du test sont lues dans les événements bruts, conservés 25 mois.") }
                    Text("Règle du serveur : \(coverage.collectionRule)")
                }.font(.callout).foregroundStyle(MonetizationStyle.secondaryText).textSelection(.enabled).padding(.top, 10)
            }
        }
    }
}
