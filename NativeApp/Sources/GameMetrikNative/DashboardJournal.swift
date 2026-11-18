import SwiftUI
import GameMetrikCore

// THESIS: A journal of acquisition, engagement and revenue, with the trend beside its figures.
// OWN-WORLD: Native macOS surfaces, SF, fine separators and the existing adaptive green.
// STORY: Read the period, inspect one day, open source details only when needed.
// FIRST VIEWPORT: Acquisition figures and curve, engagement bars, then aligned revenue figures.
// FORM: Journal du studio, candidate 4, seed cb94aa5b; approved 01-journal + on-demand inspector 03-atelier.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @State private var acquisitionMetric: DashboardMetric = .installs
    @State private var selection = DashboardDaySelection()
    @State private var sourcesExpanded = false
    @State private var revenueExpanded = false

    var body: some View {
        Group {
            if let dashboard = state.dashboard {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            header(dashboard)
                            acquisition(dashboard, compact: geometry.size.width < 760)
                            Divider()
                            engagement(dashboard, compact: geometry.size.width < 760)
                            Divider()
                            revenue(dashboard, compact: geometry.size.width < 600)
                            Divider()
                            sources(dashboard)
                            if !dashboard.rankings.isEmpty { rankings(dashboard) }
                            let other = dashboard.kpis.filter { !Self.knownIDs.contains($0.id) }
                            if !other.isEmpty {
                                DisclosureGroup("Autres indicateurs") { MetricGrid(kpis: other, currency: dashboard.currency).padding(.top, 12) }
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                .inspector(isPresented: Binding(get: { selection.point(in: dashboard.trend) != nil }, set: { if !$0 { selection = .init() } })) {
                    if let point = selection.point(in: dashboard.trend) {
                        DashboardDayInspector(point: point, currency: dashboard.currency, timezone: dashboard.timezone,
                            canGoBack: point.date != dashboard.trend.first?.date,
                            canGoForward: point.date != dashboard.trend.last?.date,
                            move: { selection.move($0, in: dashboard.trend) }, close: { selection = .init() })
                            .inspectorColumnWidth(min: 260, ideal: 285, max: 340)
                    }
                }
                .onChange(of: dashboard.trend.map(\.date)) { _, _ in selection.reconcile(with: dashboard.trend) }
            } else {
                ContentUnavailableView {
                    Label("Aucun tableau de bord", systemImage: "chart.xyaxis.line")
                } description: { Text("Synchronise pour charger les données de cette période.") } actions: {
                    Button("Synchroniser") { state.synchronizeSelection() }.disabled(state.loading || state.isLocked)
                }
            }
        }
        .onChange(of: state.refreshKey) { _, _ in selection = .init(); sourcesExpanded = false }
    }

    private static let knownIDs: Set<String> = ["installs", "newPlayers", "dau", "mau", "revenue", "iap", "ads", "adImpressions", "appleIAPNetUnits", "arpdau", "retention"]
    private func kpi(_ id: String, in dashboard: Dashboard) -> KPI? {
        if let value = dashboard.kpis.first(where: { $0.id == id }) { return value }
        if id == "newPlayers" {
            return KPI(id: id, label: "Nouveaux joueurs", value: nil, source: "À synchroniser", hint: "Synchronise pour compter les premières parties terminées observées pendant cette période.")
        }
        if id == "appleIAPNetUnits", state.game?.platforms.contains(where: { $0 == "ios" || $0 == "macos" }) == true || dashboard.alerts.contains(where: { $0.id.hasSuffix(".apple") }) {
            return KPI(id: id, label: "Achats intégrés nets", value: nil, source: "À synchroniser", hint: "Synchronise pour récupérer les unités Apple, remboursements déduits.")
        }
        if id == "adImpressions" {
            return KPI(id: id, label: "Publicités affichées", value: nil, source: "À synchroniser", hint: "Synchronise pour récupérer le nombre d’impressions AdMob sur la période sélectionnée. Une même personne peut voir plusieurs publicités.")
        }
        return nil
    }
    private func header(_ dashboard: Dashboard) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                heading
                Spacer(minLength: 16)
                inspectButton(dashboard)
            }
            VStack(alignment: .leading, spacing: 12) { heading; inspectButton(dashboard) }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.game?.name ?? "Vue d’ensemble").font(.title2.weight(.semibold))
            Text(state.game == nil ? "Aperçu de la performance de ton studio." : "Acquisition, engagement et revenus sur \(state.range.label.lowercased()).")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private func inspectButton(_ dashboard: Dashboard) -> some View {
        Button {
            if selection.date != nil { selection = .init() }
            else { selection.select(dashboard.trend.last?.date, in: dashboard.trend) }
        } label: {
            Label(selection.date == nil ? "Examiner une journée" : "Fermer la journée", systemImage: "sidebar.right")
        }
        .disabled(dashboard.trend.isEmpty)
        .help("Clique sur une date du graphique, ou utilise ses flèches puis Entrée.")
    }
    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(Color.metrik).frame(width: 2, height: 15)
            Text(title).font(.headline)
        }.accessibilityAddTraits(.isHeader)
    }
    private func acquisition(_ dashboard: Dashboard, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Acquisition")
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 28))
            layout {
                HStack(alignment: .top, spacing: 20) {
                    if let value = kpi("installs", in: dashboard) { JournalMetric(kpi: value, currency: dashboard.currency, synchronize: { state.synchronizeSelection() }, canSynchronize: !state.loading && !state.isLocked) }
                    if let value = kpi("newPlayers", in: dashboard) { JournalMetric(kpi: value, currency: dashboard.currency, synchronize: { state.synchronizeSelection() }, canSynchronize: !state.loading && !state.isLocked) }
                }.frame(width: compact ? nil : 286, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Indicateur d’acquisition", selection: $acquisitionMetric) {
                        Text("Installations").tag(DashboardMetric.installs)
                        Text("Nouveaux joueurs").tag(DashboardMetric.newPlayers)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 310)
                    trend(dashboard, metric: acquisitionMetric, height: 142)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func engagement(_ dashboard: Dashboard, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Engagement")
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 28))
            layout {
                VStack(alignment: .leading, spacing: 12) {
                    if let value = kpi("dau", in: dashboard) { JournalMetric(kpi: value, currency: dashboard.currency) }
                    if let value = kpi("mau", in: dashboard) { JournalMetric(kpi: value, currency: dashboard.currency, compact: true) }
                    if let value = kpi("retention", in: dashboard) { JournalMetric(kpi: value, currency: dashboard.currency, compact: true) }
                }.frame(width: compact ? nil : 286, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Joueurs actifs par jour").font(.callout.weight(.medium))
                    trend(dashboard, metric: .players, height: compact ? 132 : 150, bars: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    @ViewBuilder private func trend(_ dashboard: Dashboard, metric: DashboardMetric, height: CGFloat, bars: Bool = false) -> some View {
        if dashboard.trend.contains(where: { metric.value($0) != nil }) {
            DashboardTrendChart(points: dashboard.trend, metric: metric, currency: dashboard.currency,
                highlightedDate: selection.date, bars: bars, onSelect: { selection.select($0, in: dashboard.trend) })
                .frame(height: height)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Historique non disponible", systemImage: "chart.xyaxis.line").font(.callout.weight(.medium))
                Text(metric == .newPlayers ? "Synchronise pour calculer les premières parties observées." : "Les valeurs absentes restent inconnues.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: height, alignment: .center)
        }
    }
    private func revenue(_ dashboard: Dashboard, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionTitle("Revenus")
                Spacer()
                DisclosureGroup("Historique", isExpanded: $revenueExpanded) { EmptyView() }.fixedSize()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: compact ? 1 : 3), alignment: .leading, spacing: 16) {
                ForEach(["revenue", "iap", "ads"].compactMap { kpi($0, in: dashboard) }) { value in
                    VStack(alignment: .leading, spacing: 16) {
                        JournalMetric(kpi: value, currency: dashboard.currency)
                        if value.id == "iap", let count = kpi("appleIAPNetUnits", in: dashboard) {
                            JournalMetric(kpi: count, currency: dashboard.currency, compact: true, synchronize: { state.synchronizeSelection() }, canSynchronize: !state.loading && !state.isLocked)
                        }
                        if value.id == "ads", let count = kpi("adImpressions", in: dashboard) {
                            JournalMetric(kpi: count, currency: dashboard.currency, compact: true, synchronize: { state.synchronizeSelection() }, canSynchronize: !state.loading && !state.isLocked)
                        }
                    }
                }
            }
            if let value = kpi("arpdau", in: dashboard) { JournalMetric(kpi: value, currency: dashboard.currency, compact: true) }
            if revenueExpanded {
                Text("Historique en \(dashboard.currency) · les jours avec des recettes dans une autre devise restent sans point. L’inspecteur affiche les montants par devise.")
                    .font(.caption).foregroundStyle(.secondary)
                trend(dashboard, metric: .revenue, height: 160)
            }
            Divider()
            RevenueBreakdownsView(dashboard: dashboard)
        }
    }
    private func sources(_ dashboard: Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let warnings = dashboard.alerts.filter { $0.severity == "warning" || $0.severity == "critical" }
            if !warnings.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(warnings.count == 1 ? warnings[0].title : "\(warnings.count) sources à vérifier").fontWeight(.medium)
                        Text("Certains indicateurs peuvent être incomplets.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Voir les détails") { sourcesExpanded = true }
                }.font(.callout)
            }
            DisclosureGroup(isExpanded: $sourcesExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(dashboard.alerts) { alert in
                        Label {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(alert.title).fontWeight(.medium)
                                Text(alert.description).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        } icon: {
                            Image(systemName: alert.severity == "critical" ? "exclamationmark.octagon" : alert.severity == "warning" ? "exclamationmark.triangle" : "info.circle")
                                .foregroundStyle(alert.severity == "critical" ? Color.red : alert.severity == "warning" ? .orange : .secondary)
                        }
                    }
                    Text(dashboard.dataQuality.note).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Calendrier : \(dashboard.timezone)").foregroundStyle(.secondary)
                    if let date = Dates.parse(dashboard.generatedAt) {
                        Text("Données calculées le \(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                    }
                }.font(.callout).padding(.top, 14)
            } label: {
                Label("Sources et qualité des données", systemImage: "externaldrive").font(.callout.weight(.medium))
            }
        }
    }
    private func rankings(_ dashboard: Dashboard) -> some View {
        DisclosureGroup("Contribution des jeux") {
            VStack(spacing: 12) {
                ForEach(dashboard.rankings) { row in
                    Button {
                        if let game = state.games.first(where: { $0.id == row.gameId }) { state.selectGame(game) }
                    } label: {
                        HStack(spacing: 12) {
                            if let game = state.games.first(where: { $0.id == row.gameId }) { GameIcon(game: game, size: 28) }
                            Text(row.name).fontWeight(.medium)
                            Spacer()
                            Text("\(row.installs.formatted()) installations").foregroundStyle(.secondary)
                            Text(Display.money(row.revenue, currency: dashboard.currency)).monospacedDigit()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 14)
        }.font(.callout)
    }
}

struct JournalMetric: View {
    let kpi: KPI
    var currency = "CHF"
    var compact = false
    var synchronize: (() -> Void)?
    var canSynchronize = true
    @State private var showingHelp = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(kpi.label).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let hint = kpi.hint {
                    Button { showingHelp.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Définition : \(kpi.label)").help(hint)
                        .popover(isPresented: $showingHelp) {
                            VStack(alignment: .leading, spacing: 10) { Text(kpi.label).font(.headline); Text(hint).fixedSize(horizontal: false, vertical: true) }
                                .padding(18).frame(width: 300)
                        }
                }
                if compact {
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(Display.metricLines(kpi, currency: currency), id: \.self) { line in
                            Text(line).font(.callout.weight(.semibold)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !compact {
                ForEach(Display.metricLines(kpi, currency: currency), id: \.self) { line in
                    Text(line).font(.system(size: 30, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            if let amounts = kpi.amountsByCurrency, amounts.filter({ $0.value != 0 }).count > 1 {
                Text("Devises séparées · sans conversion").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if kpi.state != "available", kpi.source == "À synchroniser", let synchronize {
                Button("À synchroniser", action: synchronize).buttonStyle(.link).font(.callout).disabled(!canSynchronize)
            } else {
                Text(kpi.state == "available" ? kpi.source : "Donnée non disponible").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let change = kpi.change, kpi.state == "available" {
                Text("\(change > 0 ? "+" : "")\(Display.percent(change)) · période précédente").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let coverage = kpi.coverage, coverage.status != "complete" {
                Label(Display.coverage(coverage), systemImage: coverage.status == "pending" ? "clock" : "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(coverage.status == "pending" ? Color.secondary : .orange)
                    .help("Un jour complet dispose de toutes les sources de cet indicateur. Les autres valeurs reçues restent incluses dans le total partiel.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct DashboardDayInspector: View {
    let point: TrendPoint
    let currency: String
    let timezone: String
    let canGoBack: Bool
    let canGoForward: Bool
    let move: (Int) -> Void
    let close: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Journée sélectionnée").font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Fermer la journée")
                }
                HStack {
                    Text(chartFullDate(point.date)).font(.title3.weight(.semibold))
                    Spacer()
                    Button { move(-1) } label: { Image(systemName: "chevron.left") }.disabled(!canGoBack).accessibilityLabel("Journée précédente")
                    Button { move(1) } label: { Image(systemName: "chevron.right") }.disabled(!canGoForward).accessibilityLabel("Journée suivante")
                }
                ForEach(DashboardMetric.allCases) { metric in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(metric.label).foregroundStyle(.secondary)
                        Text(metric == .revenue ? Display.revenue(point, currency: currency) : metric.value(point).map { Display.number($0) } ?? "Non disponible")
                            .font(.title2.weight(.semibold)).monospacedDigit().textSelection(.enabled)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Achats intégrés nets · Apple").foregroundStyle(.secondary)
                    Text(point.appleIAPNetUnits.map { Display.number(Double($0)) } ?? "Non disponible")
                        .font(.title2.weight(.semibold)).monospacedDigit().textSelection(.enabled)
                    Text("Unités du jour, remboursements déduits. Journées Apple (Pacifique).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Nouveaux joueurs").font(.headline)
                Text("Première partie terminée observée dans l’historique conservé. Ce nombre ne mesure ni les installations ni les créations de profils.")
                    .foregroundStyle(.secondary)
                Text("Calendrier : \(timezone)").font(.callout).foregroundStyle(.secondary)
                Text("Une donnée non disponible reste inconnue ; elle ne vaut pas zéro.").font(.callout).foregroundStyle(.secondary)
            }.padding(20)
        }
        .onExitCommand(perform: close)
        .onMoveCommand { direction in if direction == .left { move(-1) }; if direction == .right { move(1) } }
    }
}
