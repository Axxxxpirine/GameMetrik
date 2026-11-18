import SwiftUI
import Charts
import GameMetrikCore

// Adapted from the Mac reports; identical contract and definitions, vertical iPhone layout.
struct BallparkOverviewReportView: View {
    let report: BallparkReport<BallparkOverviewRow>
    private var sessions: Int { report.rows.reduce(0) { $0 + $1.sessionsObserved } }
    private var completed: Int { report.rows.reduce(0) { $0 + $1.participationsCompleted } }
    private var started: Int { report.rows.reduce(0) { $0 + $1.participationsStarted } }
    private var playedAverage: Double? { report.rows.isEmpty ? nil : Double(report.rows.reduce(0) { $0 + $1.playedAccounts }) / Double(report.rows.count) }
    private var axisDates: [Date] {
        guard let first = report.rows.first, let last = report.rows.last else { return [] }
        return Array(Set([first, report.rows[report.rows.count / 2], last].map { BallparkFormat.date($0.day) })).sorted()
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 22) {
                BallparkMetricStrip(metrics: [
                    ("Joueurs ayant répondu / jour", Display.number(playedAverage, digits: 1), "Moyenne des comptes distincts quotidiens"),
                    ("Sessions observées", Display.number(Double(sessions)), "Ouvertures de session instrumentées"),
                    ("Séries terminées", Display.number(Double(completed)), "Troisième réponse acceptée"),
                    ("Complétion", BallparkFormat.percent(numerator: completed, denominator: started), "Terminées parmi les séries commencées")
                ])
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ouvert, joué, terminé").font(.headline)
                    Text("Trois signaux distincts par jour civil ; une ouverture n’est pas assimilée à une partie.")
                        .font(.callout).foregroundStyle(Color.readableSecondary)
                    Chart(report.rows, id: \.day) { row in
                        LineMark(x: .value("Jour", BallparkFormat.date(row.day)), y: .value("Comptes", row.openedAccounts), series: .value("Signal", "Ouvert"))
                            .foregroundStyle(by: .value("Signal", "Ouvert"))
                        LineMark(x: .value("Jour", BallparkFormat.date(row.day)), y: .value("Comptes", row.playedAccounts), series: .value("Signal", "Joué"))
                            .foregroundStyle(by: .value("Signal", "Joué"))
                        LineMark(x: .value("Jour", BallparkFormat.date(row.day)), y: .value("Comptes", row.completedAccounts), series: .value("Signal", "Terminé"))
                            .foregroundStyle(by: .value("Signal", "Terminé"))
                    }
                    .chartForegroundStyleScale(["Ouvert": Color.readableSecondary, "Joué": Color.metrik, "Terminé": .indigo])
                    .chartLegend { BallparkChartLegend(entries: [("Ouvert", .readableSecondary), ("Joué", .metrik), ("Terminé", .indigo)]) }
                    .readableCountAxis()
                    .chartXScale(range: .plotDimension(startPadding: 20, endPadding: 20))
                    .chartXAxis {
                        AxisMarks(values: axisDates) { value in
                            AxisGridLine(); AxisTick()
                            if let date = value.as(Date.self) {
                                AxisValueLabel(anchor: date == axisDates.first ? .topLeading : date == axisDates.last ? .topTrailing : .top) {
                                    Text(date.formatted(.dateTime.day().month(.abbreviated))).foregroundStyle(Color.readableSecondary)
                                }
                            }
                        }
                    }
                    .frame(height: 250)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Parcours des séries").font(.headline)
                    Chart(report.rows, id: \.day) { row in
                        BarMark(x: .value("Jour", BallparkFormat.date(row.day)), y: .value("Séries", row.participationsStarted), stacking: .unstacked)
                            .foregroundStyle(by: .value("Étape", "Commencées"))
                            .position(by: .value("Étape", "Commencées"))
                        BarMark(x: .value("Jour", BallparkFormat.date(row.day)), y: .value("Séries", row.participationsCompleted), stacking: .unstacked)
                            .foregroundStyle(by: .value("Étape", "Terminées"))
                            .position(by: .value("Étape", "Terminées"))
                    }
                    .chartForegroundStyleScale(["Commencées": Color.gray.opacity(0.55), "Terminées": Color.metrik])
                    .chartLegend { BallparkChartLegend(entries: [("Commencées", .gray.opacity(0.55)), ("Terminées", .metrik)]) }
                    .readableCountAxis()
                    .chartXScale(range: .plotDimension(startPadding: 20, endPadding: 20))
                    .chartXAxis {
                        AxisMarks(values: axisDates) { value in
                            AxisGridLine(); AxisTick()
                            if let date = value.as(Date.self) {
                                AxisValueLabel(anchor: date == axisDates.first ? .topLeading : date == axisDates.last ? .topTrailing : .top) {
                                    Text(date.formatted(.dateTime.day().month(.abbreviated))).foregroundStyle(Color.readableSecondary)
                                }
                            }
                        }
                    }
                    .frame(height: 210)
                }
                BallparkCoverageView(coverage: report.coverage, generatedAt: report.generatedAt)
            }.padding(20)
        }
    }
}

struct BallparkQuestionsReportView: View {
    let report: BallparkReport<BallparkQuestionRow>
    let search: String
    private var rows: [BallparkQuestionRow] {
        report.rows.filter {
            search.isEmpty || [$0.prompt, $0.theme, $0.subject ?? "", $0.dimension ?? ""].joined(separator: " ").localizedStandardContains(search)
        }
    }
    var body: some View {
        Group {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(rows.count) question(s)").font(.headline)
                    Spacer()
                    Text("Médianes et taux calculés côté serveur").font(.caption).foregroundStyle(Color.readableSecondary)
                }.padding(.bottom, 14)
                ForEach(rows, id: \.nativeID) { row in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) { Text("Référence").foregroundStyle(Color.readableSecondary); Text(row.reference + " " + row.unit).textSelection(.enabled) }
                                VStack(alignment: .leading, spacing: 4) { Text("Métadonnées").foregroundStyle(Color.readableSecondary); Text([row.theme, row.subject, row.dimension, row.editorialDifficulty].compactMap { $0 }.joined(separator: " · ")) }
                                VStack(alignment: .leading, spacing: 4) { Text("Facteur Q25 / médiane / Q75").foregroundStyle(Color.readableSecondary); Text(BallparkFormat.factorQuartiles(row)).monospacedDigit() }
                                VStack(alignment: .leading, spacing: 4) { Text("Temps actif médian / P75 / P90").foregroundStyle(Color.readableSecondary); Text(BallparkFormat.timeQuartiles(row)).monospacedDigit() }
                            }
                            BallparkRatioLine(title: "Précision", values: [("≤ 1,5", row.factorLe15), ("≤ 2", row.factorLe2), ("≤ 5", row.factorLe5), ("≤ 10", row.factorLe10)])
                            BallparkRatioLine(title: "Sens", values: [("Exact", row.exact), ("Sous", row.under), ("Sur", row.over)])
                            BallparkRatioLine(title: "Outils et découverte", values: [("Calculatrice", row.calculatorOpened), ("Résultat utilisé", row.calculatorResultUsed), ("Explication", row.explanationOpened), ("Source", row.sourceOpened)])
                            Text("\(row.interruptions) interruption(s) · \(row.resumes) reprise(s) · \(row.completeTimeSample) durée(s) complète(s)")
                                .font(.caption).foregroundStyle(Color.readableSecondary)
                        }.padding(.top, 12)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.prompt).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                Text("Révision \(row.revision) · \(row.locale.rawValue.uppercased()) · \(row.players) joueur(s)")
                                    .font(.caption).foregroundStyle(Color.readableSecondary)
                            }
                            Spacer(minLength: 12)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Facteur médian : " + BallparkFormat.factor(row.factorMedian, reason: row.factorReason)).monospacedDigit()
                                Text("Temps actif médian : " + BallparkFormat.duration(row.activeTimeMedianMs)).font(.caption).foregroundStyle(Color.readableSecondary).monospacedDigit()
                            }
                        }
                    }
                    .padding(.vertical, 13)
                    Divider()
                }
                if rows.isEmpty { ContentUnavailableView.search(text: search).padding(.top, 48) }
                BallparkCoverageView(coverage: report.coverage, generatedAt: report.generatedAt).padding(.top, 22)
            }.padding(20)
        }
    }
}

struct BallparkSeriesReportView: View {
    let report: BallparkReport<BallparkSeriesRow>
    let search: String
    private var rows: [BallparkSeriesRow] {
        report.rows.filter { row in
            search.isEmpty || row.gameDay.localizedStandardContains(search)
                || row.mode.rawValue.localizedStandardContains(search)
                || row.questions.contains { [$0.theme, $0.subject ?? "", $0.dimension ?? ""].joined(separator: " ").localizedStandardContains(search) }
        }
    }
    var body: some View {
        Group {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) { Text("\(rows.count) série(s)").font(.headline); Spacer(); Text("Jour de jeu à 09:00 Europe/Zurich").font(.caption).foregroundStyle(Color.readableSecondary) }
                    .padding(.bottom, 14)
                ForEach(rows, id: \.nativeID) { row in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(row.questions.sorted { $0.position < $1.position }, id: \.position) { question in
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(question.position)").font(.caption.weight(.semibold)).foregroundStyle(Color.readableSecondary).frame(width: 18)
                                    Text([question.theme, question.subject, question.dimension, question.editorialDifficulty].compactMap { $0 }.joined(separator: " · "))
                                }
                            }
                            Text("\(row.exactlyOneAnswer) avec 1 réponse · \(row.exactlyTwoAnswers) avec 2 · \(row.exactlyThreeAnswers) avec 3 · \(row.resumed) reprise(s)")
                                .font(.caption).foregroundStyle(Color.readableSecondary)
                            Text("Ouvertes \(row.statusCounts.openIncomplete) · expirées incomplètes \(row.statusCounts.expiredIncomplete) · terminées \(row.statusCounts.completed) · annulées \(row.statusCounts.cancelled)")
                                .font(.caption).foregroundStyle(Color.readableSecondary)
                        }.padding(.top, 10)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(BallparkFormat.date(row.gameDay).formatted(date: .abbreviated, time: .omitted)).font(.body.weight(.medium))
                                Text(row.mode == .daily ? "Daily" : "Groupe privé").font(.caption).foregroundStyle(Color.readableSecondary)
                            }
                            Spacer()
                            Text("\(row.started) commencée(s)").monospacedDigit()
                            Text("Complétion : " + BallparkFormat.ratio(row.completion)).monospacedDigit()
                        }
                    }.padding(.vertical, 13)
                    Divider()
                }
                if rows.isEmpty { ContentUnavailableView.search(text: search).padding(.top, 48) }
                BallparkCoverageView(coverage: report.coverage, generatedAt: report.generatedAt).padding(.top, 22)
            }.padding(20)
        }
    }
}

struct BallparkHabitsReportView: View {
    let report: BallparkReport<BallparkHabitRow>
    private var days: [BallparkHabitDay] { report.rows.compactMap { if case .day(let value) = $0 { value } else { nil } } }
    private var weeks: [BallparkHabitWeek] { report.rows.compactMap { if case .week(let value) = $0 { value } else { nil } } }
    private var hours: [BallparkHabitHour] { report.rows.compactMap { if case .hour(let value) = $0 { value } else { nil } } }
    private var axisDates: [Date] {
        guard let first = days.first, let last = days.last else { return [] }
        return Array(Set([first, days[days.count / 2], last].map { BallparkFormat.date($0.day) })).sorted()
    }
    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Activité glissante").font(.headline)
                    Text("DAU, WAU et MAU sont des unions de comptes ayant une réponse acceptée, jamais des sommes de journées.")
                        .font(.callout).foregroundStyle(Color.readableSecondary)
                    Chart(days, id: \.day) { row in
                        LineMark(x: .value("Jour", BallparkFormat.date(row.day)), y: .value("Comptes", row.dau), series: .value("Fenêtre", "DAU"))
                            .foregroundStyle(by: .value("Fenêtre", "DAU"))
                        LineMark(x: .value("Jour", BallparkFormat.date(row.day)), y: .value("Comptes", row.wau), series: .value("Fenêtre", "WAU"))
                            .foregroundStyle(by: .value("Fenêtre", "WAU"))
                        LineMark(x: .value("Jour", BallparkFormat.date(row.day)), y: .value("Comptes", row.mau), series: .value("Fenêtre", "MAU"))
                            .foregroundStyle(by: .value("Fenêtre", "MAU"))
                    }
                    .chartForegroundStyleScale(["DAU": .blue, "WAU": Color.metrik, "MAU": .purple])
                    .chartLegend { BallparkChartLegend(entries: [("DAU", .blue), ("WAU", .metrik), ("MAU", .purple)]) }
                    .readableCountAxis()
                    .chartXScale(range: .plotDimension(startPadding: 20, endPadding: 20))
                    .chartXAxis {
                        AxisMarks(values: axisDates) { value in
                            AxisGridLine(); AxisTick()
                            if let date = value.as(Date.self) {
                                AxisValueLabel(anchor: date == axisDates.first ? .topLeading : date == axisDates.last ? .topTrailing : .top) {
                                    Text(date.formatted(.dateTime.day().month(.abbreviated))).foregroundStyle(Color.readableSecondary)
                                }
                            }
                        }
                    }
                    .frame(height: 250)
                }
                if let latest = days.last {
                    BallparkMetricStrip(metrics: [
                        ("Rétention J1", BallparkFormat.ratio(latest.retentionJ1), "Retour avec réponse au jour civil exact"),
                        ("Rétention J7", BallparkFormat.ratio(latest.retentionJ7), "Cohortes arrivées à maturité + délai de grâce"),
                        ("Rétention J30", BallparkFormat.ratio(latest.retentionJ30), "Minimum de cinq comptes au dénominateur"),
                        ("Nouveaux observés", Display.number(Double(latest.newObservedAccounts)), "Première activité autorisée observée")
                    ])
                }
                if !hours.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Heures de réponse").font(.headline)
                        Text("Heure locale Europe/Zurich ; elle ne prétend pas connaître le fuseau du joueur.").font(.callout).foregroundStyle(Color.readableSecondary)
                        Chart(hours, id: \.hour) { row in
                            BarMark(x: .value("Heure", row.hour), y: .value("Réponses", row.responses)).foregroundStyle(Color.metrik)
                        }.readableCountAxis().readableIntegerXAxis().frame(height: 190)
                    }
                }
                if let week = weeks.last {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Jours joués dans la semaine").font(.headline)
                        Chart(Array(week.daysPlayedDistribution.enumerated()), id: \.offset) { index, count in
                            BarMark(x: .value("Jours", index + 1), y: .value("Comptes", count)).foregroundStyle(Color.metrik)
                        }.readableCountAxis().readableIntegerXAxis().frame(height: 190)
                    }
                }
                BallparkCoverageView(coverage: report.coverage, generatedAt: report.generatedAt)
            }.padding(20)
        }
    }
}

private struct BallparkChartLegend: View {
    let entries: [(String, Color)]
    private var labels: some View {
        ForEach(entries.indices, id: \.self) { index in
            HStack(spacing: 5) {
                Circle().fill(entries[index].1).frame(width: 8, height: 8)
                Text(entries[index].0).foregroundStyle(Color.readableSecondary)
            }
        }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { labels }
            VStack(alignment: .leading, spacing: 8) { labels }
        }.font(.caption).padding(.top, 8)
    }
}

private extension View {
    func readableCountAxis() -> some View {
        chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text(count.formatted()).foregroundStyle(Color.readableSecondary) }
                }
            }
        }
    }
    func readableIntegerXAxis() -> some View {
        chartXAxis {
            AxisMarks { value in
                AxisGridLine(); AxisTick()
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text(count.formatted()).foregroundStyle(Color.readableSecondary) }
                }
            }
        }
    }
}

struct BallparkQualityReportView: View {
    let report: BallparkReport<BallparkQualityRow>
    let search: String
    private var rows: [BallparkQualityRow] {
        report.rows.filter { search.isEmpty || [$0.operation, $0.appVersion, $0.buildNumber, $0.osVersion].joined(separator: " ").localizedStandardContains(search) }
    }
    var body: some View {
        Group {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) { Text("\(rows.count) opération(s) et environnement(s)").font(.headline); Spacer(); Text("Échecs contrôlés, pas joueurs bloqués").font(.caption).foregroundStyle(Color.readableSecondary) }
                    .padding(.bottom, 14)
                ForEach(rows, id: \.nativeID) { row in
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                        VStack(alignment: .leading, spacing: 4) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.operation).font(.body.weight(.medium))
                                Text("App \(row.appVersion) (\(row.buildNumber)) · \(row.osVersion)").font(.caption).foregroundStyle(Color.readableSecondary)
                            }.gridCellColumns(2)
                            Text("\(row.operationsObserved) essais").monospacedDigit()
                            Text("Taux d’échec : " + BallparkFormat.ratio(row.failure)).monospacedDigit()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Latence médiane / P95").foregroundStyle(Color.readableSecondary)
                            Text(BallparkFormat.latency(row.latencyMedianMs) + " / " + BallparkFormat.latency(row.latencyP95Ms)).monospacedDigit()
                            Text("\(row.controlledErrors) erreur(s)").foregroundStyle(row.controlledErrors > 0 ? .orange : .secondary)
                            Text("\(row.suspectTimelines) chronologie(s) suspecte(s)").foregroundStyle(Color.readableSecondary)
                        }.font(.caption)
                    }.padding(.vertical, 13)
                    Divider()
                }
                if rows.isEmpty { ContentUnavailableView.search(text: search).padding(.top, 48) }
                BallparkCoverageView(coverage: report.coverage, generatedAt: report.generatedAt).padding(.top, 22)
            }.padding(20)
        }
    }
}

struct BallparkMetricStrip: View {
    let metrics: [(String, String, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
    }
    @ViewBuilder private var content: some View {
        ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
            if index > 0 { Divider() }
            VStack(alignment: .leading, spacing: 5) {
                Text(metric.1).font(.title2.weight(.semibold)).monospacedDigit()
                Text(metric.0).font(.callout.weight(.semibold))
                Text(metric.2).font(.caption).foregroundStyle(Color.readableSecondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BallparkRatioLine: View {
    let title: String
    let values: [(String, BallparkRatio)]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { items }
                VStack(alignment: .leading, spacing: 6) { items }
            }
        }
    }
    @ViewBuilder private var items: some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, item in
            Text(item.0 + " " + BallparkFormat.ratio(item.1)).monospacedDigit()
        }
    }
}

struct BallparkCoverageView: View {
    let coverage: BallparkCoverage
    let generatedAt: String
    var body: some View {
        Divider()
        DisclosureGroup("Couverture et limites") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(coverage.participantsMeasured) participant(s) mesuré(s) sur \(coverage.participantsEligible) éligible(s) · \(coverage.excludedTestAccounts) compte(s) de test exclu(s)")
                Text("Événements v2 : \(coverage.v2Events) · anciens événements v1 : \(coverage.v1Events) · durées complètes : \(BallparkFormat.ratio(coverage.completeDuration))")
                if !coverage.warnings.isEmpty { Text(coverage.warnings.map(BallparkFormat.warning).joined(separator: " · ")) }
                Text("Calculé " + (Dates.parse(generatedAt)?.formatted(date: .abbreviated, time: .shortened) ?? generatedAt))
            }.font(.caption).foregroundStyle(Color.readableSecondary).padding(.top, 8)
        }.font(.callout.weight(.medium))
    }
}

private enum BallparkFormat {
    static func date(_ value: String) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let pieces = value.split(separator: "-").compactMap { Int($0) }
        return pieces.count == 3 ? calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])) ?? .distantPast : .distantPast
    }
    static func percent(numerator: Int, denominator: Int) -> String {
        guard denominator > 0 else { return "—" }
        return Display.percent(Double(numerator) * 100 / Double(denominator))
    }
    static func ratio(_ ratio: BallparkRatio) -> String {
        ratio.value.map { Display.percent($0 * 100) } ?? "—"
    }
    static func factor(_ value: Double?, reason: BallparkUnavailableReason?) -> String {
        value.map { "×" + Display.number($0, digits: 2) } ?? (reason == .insufficientSample ? "Échantillon insuffisant" : "—")
    }
    static func factorQuartiles(_ row: BallparkQuestionRow) -> String {
        [row.factorQ25, row.factorMedian, row.factorQ75].map { factor($0, reason: row.factorReason) }.joined(separator: " / ")
    }
    static func duration(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        let seconds = milliseconds / 1_000
        return seconds < 60 ? Display.number(seconds, digits: 1) + " s" : Display.number(seconds / 60, digits: 1) + " min"
    }
    static func timeQuartiles(_ row: BallparkQuestionRow) -> String {
        [row.activeTimeMedianMs, row.activeTimeP75Ms, row.activeTimeP90Ms].map(duration).joined(separator: " / ")
    }
    static func latency(_ milliseconds: Double?) -> String { milliseconds.map { Display.number($0, digits: 0) + " ms" } ?? "—" }
    static func warning(_ value: BallparkCoverageWarning) -> String {
        switch value {
        case .optionalCollectionBias: "Collecte facultative : biais possible"
        case .v1PartialCoverage: "Couverture v1 partielle"
        case .partialDurationCoverage: "Durées partiellement mesurées"
        case .limitedSample: "Échantillon limité"
        case .immatureCohort: "Cohortes non arrivées à maturité"
        case .suspectClientTime: "Horloges client douteuses détectées"
        }
    }
}

private extension BallparkQuestionRow {
    var nativeID: String { questionID + ":" + String(revision) + ":" + locale.rawValue + ":" + metadataFingerprint }
}
private extension BallparkSeriesRow {
    var nativeID: String { gameDay + ":" + seriesID }
}
private extension BallparkQualityRow {
    var nativeID: String { [appVersion, buildNumber, osVersion, operation].joined(separator: ":") }
}
