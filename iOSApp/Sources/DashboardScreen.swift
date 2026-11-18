import SwiftUI
import Charts
import GameMetrikCore

struct DashboardScreen: View {
    @EnvironmentObject var store: MobileStore
    var gameID: String?
    @State private var selectedDay: TrendPoint?
    private var snapshot: MobileSnapshot { store.snapshot(gameID) }
    var body: some View {
        Group {
            if let dashboard = snapshot.dashboard {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        WorkspaceCaption(generatedAt: dashboard.generatedAt, gameName: store.games.first { $0.id == gameID }?.name)
                        SyncErrors(messages: snapshot.errors)
                        metrics("Acquisition", ids: ["installs", "newPlayers"], dashboard: dashboard)
                        DashboardTrend(dashboard: dashboard, selectedDay: $selectedDay)
                        Divider()
                        metrics("Activité", ids: ["dau", "mau", "retention"], dashboard: dashboard)
                        Divider()
                        metrics("Revenus", ids: ["revenue", "iap", "ads", "arpdau", "appleIAPNetUnits", "adImpressions"], dashboard: dashboard)
                        if let details = dashboard.revenueDetails {
                            RevenueMobile(details: details)
                        }
                        DisclosureGroup("Sources et couverture") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(dashboard.dataQuality.note)
                                Text("Fuseau : " + dashboard.timezone)
                                ForEach(dashboard.alerts) { alert in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(alert.title).font(.headline)
                                        Text(alert.description)
                                    }
                                }
                            }.font(.callout).foregroundStyle(Color.readableSecondary).padding(.top, 12)
                        }
                        let others = dashboard.kpis.filter { !["installs", "newPlayers", "dau", "mau", "retention", "revenue", "iap", "ads", "arpdau", "appleIAPNetUnits", "adImpressions"].contains($0.id) }
                        if !others.isEmpty {
                            DisclosureGroup("Autres indicateurs") { ForEach(others) { MetricRow(metric: $0, currency: dashboard.currency) } }
                        }
                    }.padding(20)
                }
                .refreshable { await store.synchronize(gameID: gameID)?.value }
                .sheet(item: $selectedDay) { day in
                    NavigationStack {
                        List {
                            Section { WorkspaceCaption(generatedAt: dashboard.generatedAt, gameName: store.games.first { $0.id == gameID }?.name ?? "Tout le studio", period: dashboard.timeframe.label) }
                            LabeledContent("Installations", value: day.installsAvailable == false ? "—" : String(day.installs))
                            LabeledContent("Joueurs actifs", value: day.playersAvailable == false ? "—" : String(day.players))
                            LabeledContent("Nouveaux joueurs", value: day.newPlayers.map(String.init) ?? "—")
                            if let amounts = day.revenueByCurrency, !amounts.isEmpty {
                                ForEach(amounts.keys.sorted(), id: \.self) { currency in LabeledContent("Revenus " + currency, value: Display.amount(amounts[currency]!, currency: currency)) }
                            } else { LabeledContent("Revenus CHF", value: day.revenueAvailable == false ? "—" : Display.amount(day.revenue, currency: "CHF")) }
                            Text("Une donnée indisponible reste indiquée par —.").font(.caption).foregroundStyle(Color.readableSecondary)
                        }.navigationTitle(day.date).navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { selectedDay = nil } } }
                    }.presentationDetents([.medium, .large])
                }
            } else {
                ScrollView { VStack { SyncErrors(messages: snapshot.errors).padding(.horizontal, 20); SyncEmpty(gameID: gameID) } }
            }
        }
        .toolbar { ContextToolbar(gameID: gameID) }
        .onAppear { store.localSelection(gameID) }
        .onChange(of: store.range) { _, _ in selectedDay = nil; store.localSelection(gameID) }
    }
    private func metrics(_ title: String, ids: [String], dashboard: Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ForEach(dashboard.kpis.filter { ids.contains($0.id) }) { metric in MetricRow(metric: metric, currency: dashboard.currency) }
        }
    }
}

struct MetricRow: View {
    var metric: KPI
    var currency = "CHF"
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(metric.source)
                if let hint = metric.hint { Text(hint) }
                if let coverage = metric.coverage { Text("\(coverage.availableDays) jour(s) reçu(s) sur \(coverage.expectedDays) · \(coverage.status)") }
                if (metric.amountsByCurrency?.count ?? 0) > 1 { Text("Devises séparées, sans conversion.") }
            }.font(.caption).foregroundStyle(Color.readableSecondary).padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.label).multilineTextAlignment(.leading).font(.subheadline).foregroundStyle(Color.readableSecondary)
                Text(Display.metric(metric, currency: currency)).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(Color(uiColor: .label))
            }.padding(.vertical, 4)
        }.accessibilityIdentifier("metric-" + metric.id)
    }
}

struct DashboardTrend: View {
    var dashboard: Dashboard
    @Binding var selectedDay: TrendPoint?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installations par jour").font(.headline)
            Chart(dashboard.trend.filter { $0.installsAvailable != false }) { point in
                BarMark(x: .value("Jour", point.date), y: .value("Installations", point.installs)).foregroundStyle(Color.metrik)
            }
            .chartXScale(domain: dashboard.trend.map(\.date), range: .plotDimension(startPadding: 12, endPadding: 12))
            .chartXAxis {
                AxisMarks(values: axisDays) { value in
                    if let day = value.as(String.self) {
                        AxisValueLabel(anchor: day == axisDays.first ? .topLeading : day == axisDays.last ? .topTrailing : .top) {
                            Text(String(day.suffix(5))).foregroundStyle(Color.readableSecondary)
                        }
                    }
                }
            }
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let count = value.as(Int.self) { Text(count.formatted()).foregroundStyle(Color.readableSecondary) } } } }
            .frame(height: 200)
            .accessibilityLabel("Installations par jour. Les journées absentes ne sont pas représentées.")
            Menu {
                ForEach(dashboard.trend.reversed()) { day in Button(day.date) { selectedDay = day } }
            } label: { Label("Examiner une journée", systemImage: "calendar").frame(minHeight: 44) }
            Text("Les journées sans rapport restent absentes du graphique.").font(.caption).foregroundStyle(Color.readableSecondary)
        }
    }
    private var axisDays: [String] {
        let days = dashboard.trend.map(\.date)
        guard !days.isEmpty else { return [] }
        return Array(Set([days[0], days[days.count / 2], days[days.count - 1]])).sorted()
    }
}
