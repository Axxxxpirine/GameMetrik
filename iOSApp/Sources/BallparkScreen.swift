import SwiftUI
import GameMetrikCore

struct BallparkScreen: View {
    @EnvironmentObject var store: MobileStore
    let game: Game
    @State private var selected: BallparkReportKind = .overview
    @State private var search = ""
    var body: some View {
        ScrollView {
          VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                WorkspaceCaption(generatedAt: store.snapshot(game.id).ballpark?.latestGeneration.map(Dates.iso), gameName: game.name, period: store.demo ? "Exemple Ballpark · période fixe" : nil)
                if store.demo { Text("Exemple fictif · 14–20 septembre 2026 (période fixe)").font(.caption).foregroundStyle(Color.readableSecondary) }
                Picker("Rapport Ballpark", selection: $selected) {
                    ForEach(BallparkReportKind.allCases, id: \.rawValue) { Text($0.frenchTitle).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("ballparkReportPicker")
            }.padding(.horizontal, 20).padding(.vertical, 8)
            Divider()
            if let data = store.snapshot(game.id).ballpark {
                if let error = data.errors[selected] {
                    SyncErrors(messages: [error]).padding(20)
                } else {
                    switch selected {
                    case .overview: if let report = data.overview { BallparkOverviewReportView(report: report) }
                    case .questions: if let report = data.questions { BallparkQuestionsReportView(report: report, search: search) }
                    case .series: if let report = data.series { BallparkSeriesReportView(report: report, search: search) }
                    case .habits: if let report = data.habits { BallparkHabitsReportView(report: report) }
                    case .quality: if let report = data.quality { BallparkQualityReportView(report: report, search: search) }
                    }
                }
            } else {
                SyncErrors(messages: store.snapshot(game.id).errors).padding(.horizontal, 20)
                SyncEmpty(gameID: game.id, title: "Analyse Ballpark à synchroniser")
            }
          }
        }.navigationTitle("Analyse Ballpark").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Filtrer ce rapport")
            .toolbar { ContextToolbar(gameID: game.id) }
            .onChange(of: store.range) { _, _ in store.localSelection(game.id) }
    }
}
