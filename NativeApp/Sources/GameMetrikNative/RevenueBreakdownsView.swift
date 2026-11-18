import SwiftUI
import Charts
import GameMetrikCore

struct RevenueBreakdownsView: View {
    let dashboard: Dashboard
    @State private var dimension: RevenueDimension = .country
    @State private var selectedCurrency = "CHF"
    @State private var showAll = false
    private var currencies: [String] { dashboard.revenueDetails?.currencies ?? [dashboard.currency] }
    private var currency: String { currencies.contains(selectedCurrency) ? selectedCurrency : currencies[0] }
    private var rows: [RevenueBreakdownRow] {
        if let details = dashboard.revenueDetails { return details.breakdown(dimension, currency: currency) }
        return []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Répartition des revenus").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack { controls; Spacer() }
                VStack(alignment: .leading, spacing: 10) { controls }
            }
            if let details = dashboard.revenueDetails {
                Text(details.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if rows.isEmpty {
                    Text(details.receivedSourceDays == 0 ? "Aucun rapport de revenus reçu pour cette période." : "Aucun montant à répartir dans les rapports reçus.")
                        .foregroundStyle(.secondary).padding(.vertical, 12)
                } else {
                    let visible = showAll ? rows : Array(rows.prefix(8))
                    Chart(visible) { row in
                        BarMark(x: .value("Revenus", row.value), y: .value(dimension.title, row.name))
                            .foregroundStyle(row.value < 0 ? Color.orange : Color.metrik)
                            .accessibilityLabel(row.name)
                            .accessibilityValue(Display.money(row.value, currency: currency))
                    }.chartYAxis { AxisMarks(position: .leading) }
                        .chartXAxisLabel("Revenus · " + currency)
                        .frame(height: CGFloat(visible.count * 30 + 35))
                    VStack(spacing: 9) {
                        ForEach(visible) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.name)
                                Spacer(minLength: 12)
                                Text(row.value.formatted(.currency(code: currency).precision(.fractionLength(2...5))))
                                    .monospacedDigit().textSelection(.enabled)
                                Text(row.share.map { Display.percent($0) } ?? "—")
                                    .foregroundStyle(.secondary).monospacedDigit().frame(width: 65, alignment: .trailing)
                            }.font(.callout)
                        }
                    }
                    if rows.count > 8 {
                        Button(showAll ? "Réduire la liste" : "Afficher les \(rows.count) " + dimension.title.lowercased()) { showAll.toggle() }
                            .buttonStyle(.link)
                    }
                    if rows.contains(where: { $0.share == nil }) {
                        Text("Parts non calculées lorsque le total est nul ou qu’une valeur est négative. Les remboursements et frais restent inclus.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Les pourcentages portent sur tous les revenus reçus dans cette devise. L’export contient toutes les lignes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                let legacy = dimension == .country ? dashboard.countryBreakdown : dashboard.platformBreakdown
                if !legacy.isEmpty { BreakdownView(title: "Par " + dimension.title.lowercased(), rows: legacy, currency: currency) }
                else { Text("Synchronise pour charger la ventilation des revenus.").foregroundStyle(.secondary) }
            }
            Text("Pays : lieu de diffusion AdMob ou pays de vente déclaré par la boutique. Plateforme : système déclaré par AdMob, appareil Apple ou Android pour Google Play.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: dimension) { _, _ in showAll = false }
        .onChange(of: currency) { _, _ in showAll = false }
        .onChange(of: dashboard.gameId) { _, _ in showAll = false }
        .onChange(of: dashboard.timeframe) { _, _ in showAll = false }
    }
    @ViewBuilder private var controls: some View {
        Picker("Ventilation", selection: $dimension) {
            ForEach(RevenueDimension.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
        if currencies.count > 1 {
            Picker("Devise", selection: Binding(get: { currency }, set: { selectedCurrency = $0 })) {
                ForEach(currencies, id: \.self) { Text($0).tag($0) }
            }.fixedSize()
        } else { Text(currency).font(.callout).foregroundStyle(.secondary) }
    }
}
