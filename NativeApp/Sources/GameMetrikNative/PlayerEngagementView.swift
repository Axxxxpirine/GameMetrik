import SwiftUI
import Charts
import GameMetrikCore

struct PlayerEngagementView: View {
    let directory: PlayerDirectory
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Régularité et retours").font(.headline)
            Text("\(directory.returningPlayers) profils actifs sur plusieurs jours, sur \(directory.profiledActivePlayers) profils actifs dans la période.")
                .font(.callout)
            if let share = directory.topThreeShare {
                Text("Les \(min(3, directory.profiledActivePlayers)) profils les plus actifs concentrent \(Display.percent(share)) des parties reliées aux profils.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Chart(directory.activityGroups) { group in
                BarMark(x: .value("Profils", group.players), y: .value("Activité", group.group.label)).foregroundStyle(Color.metrik)
            }.frame(height: 145).chartYAxis { AxisMarks(position: .leading) }
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 12) {
                    GridRow {
                        Text("Jours actifs"); Text("Profils"); Text("Parties"); Text("Durée moy."); Text("Indices / partie"); Text("Erreurs / partie")
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(directory.activityGroups) { group in
                        GridRow {
                            Text(group.group.label)
                            Text(group.players.formatted())
                            Text(group.completions.formatted())
                            Text(Display.duration(group.averageMinutes))
                            Text(Display.number(group.hints, digits: 1))
                            Text(Display.number(group.mistakes, digits: 1))
                        }.font(.callout).monospacedDigit()
                    }
                }.fixedSize(horizontal: true, vertical: false).padding(.bottom, 5)
            }
            Text("Groupes calculés sur la période choisie : ils ne décrivent pas l’ancienneté. Un retour signifie une partie terminée sur au moins deux jours distincts, pas une rétention J7.")
                .font(.caption).foregroundStyle(.secondary)
            if directory.profiledCompletions != directory.completions {
                Text("\(directory.profiledCompletions)/\(directory.completions) parties reliées aux profils disponibles. Les parties sans profil sont incluses uniquement dans l’activité globale.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            CompletionHoursView(hours: directory.completionHours, timezone: directory.timezone)
        }
    }
}
struct CompletionHoursView: View {
    let hours: [CompletionHour]
    var timezone: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heures de fin des parties").font(.headline)
            if hours.contains(where: { $0.completions > 0 }) {
                Chart(hours) { row in
                    BarMark(x: .value("Heure", row.hour), y: .value("Parties terminées", row.completions), width: .fixed(8)).foregroundStyle(Color.metrik)
                        .accessibilityLabel("\(row.hour) h : \(row.completions) parties terminées")
                }.chartXScale(domain: -0.5...23.5)
                    .chartXAxis { AxisMarks(values: [0, 6, 12, 18]) { value in AxisValueLabel(anchor: .top) { if let hour = value.as(Int.self) { Text("\(hour) h") } } } }
                    .frame(height: 145)
            } else { Text("Aucune partie terminée à répartir.").foregroundStyle(.secondary).font(.callout) }
            Text("Heure locale de fin\(timezone.map { " · " + $0 } ?? ""). Ce graphique ne mesure ni les sessions ni le temps passé dans chaque heure.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
