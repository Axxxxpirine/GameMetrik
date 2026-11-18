import SwiftUI
import Charts
import GameMetrikCore

// THESIS: read the complete collection of Aurora Grove 1.6.0+ with its population, period and coverage beside every number.
// FORM: same open stacks, headlines, callouts, tiles and disclosures as the journey and monetization reports; no new visual identity.
private enum InsightsStyle {
    static let secondaryText = Color.primary.opacity(0.75)
    static let coverage = "Installations dont les statistiques couvrent la collecte étendue (1.6.0+) ; une installation n’est pas une personne ; hors ligne, refus et versions antérieures ne sont pas comptés."
}
private typealias F = AuroraInsightsFormat
private typealias L = AuroraInsightsLabels
private typealias M = AuroraInsightsMath

enum AuroraInsightsSection: String, CaseIterable, Hashable {
    case attendance, sessions, screens, actions, games, progress, technical, privacy
    var title: String {
        switch self {
        case .attendance: "Fréquentation"
        case .sessions: "Sessions"
        case .screens: "Écrans et fenêtres"
        case .actions: "Actions"
        case .games: "Parties"
        case .progress: "Progression et réglages"
        case .technical: "Technique"
        case .privacy: "Confidentialité"
        }
    }
    var kinds: [AuroraInsightsKind] {
        switch self {
        case .attendance: [.activity]
        case .sessions: [.sessions]
        case .screens: [.screens, .dialogs]
        case .actions: [.actions]
        case .games: [.gameplay, .timeline]
        case .progress: [.progress, .settings, .notifications]
        case .technical: [.stability, .diagnostics, .performance, .cloud, .server]
        case .privacy: [.privacy, .consents, .context]
        }
    }
}

struct AuroraInsightsView: View {
    @EnvironmentObject var state: AppState
    @State private var selected: AuroraInsightsSection = .attendance
    var body: some View {
        if let data = state.auroraInsights {
            AuroraInsightsContent(data: data, selected: $selected, population: $state.auroraInsightsPopulation, demo: state.demo,
                                 loading: state.loading, reload: { state.refresh() }, retry: { state.synchronizeSelection() })
        } else {
            ContentUnavailableView {
                Label("Activité et jeu à synchroniser", systemImage: Destination.auroraInsights.symbol)
            } description: {
                Text("Synchronise Aurora Grove pour lire la fréquentation, les sessions, les parties et la technique mesurées par la version 1.6.0 et suivantes.")
            } actions: { Button("Synchroniser") { state.synchronizeSelection() } }
        }
    }
}

struct AuroraInsightsContent: View {
    let data: AuroraInsightsBundle
    @Binding var selected: AuroraInsightsSection
    @Binding var population: AuroraInsightsPopulation
    var demo: Bool
    var loading: Bool
    var reload: () -> Void
    var retry: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Activité et jeu").font(.title2.weight(.semibold))
                Text("Aurora Grove · collecte complète 1.6.0+ · Europe/Zurich" + (demo ? " · données fictives" : " · Administration personnelle"))
                    .font(.callout).foregroundStyle(InsightsStyle.secondaryText)
                HStack(spacing: 16) {
                    Picker("Population", selection: $population) {
                        ForEach(AuroraInsightsPopulation.allCases, id: \.self) { Text($0.title + ($0 == .production ? " (par défaut)" : "")).tag($0) }
                    }.pickerStyle(.menu).fixedSize().disabled(loading)
                    .onChange(of: population) { _, value in if value != data.population { reload() } }
                    ViewThatFits(in: .horizontal) { picker(.segmented); picker(.menu) }
                }
                InsightsContextLine(data: data)
                if data.population != population {
                    Text("Ces chiffres ont été lus pour la population « \(data.population.title) ». La lecture de « \(population.title) » démarre…")
                        .font(.callout).foregroundStyle(InsightsStyle.secondaryText)
                }
                if data.status == .partial {
                    Text("Certaines familles sont indisponibles ; chacune indique son état.").font(.callout).foregroundStyle(InsightsStyle.secondaryText)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            if let failure = sectionFailure {
                ContentUnavailableView {
                    Label(failure.title, systemImage: failure.symbol)
                } description: { Text(failure.detail).frame(maxWidth: 520) }
                actions: { Button("Réessayer") { retry() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        section
                        Divider()
                        InsightsCoverageView(data: data, kinds: selected.kinds)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private func picker<S: PickerStyle>(_ style: S) -> some View {
        Picker("Rubrique", selection: $selected) {
            ForEach(AuroraInsightsSection.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(style).fixedSize(horizontal: style is SegmentedPickerStyle, vertical: false).labelsHidden()
    }
    /// A section fails as a whole only when every one of its families failed with the same cause (presence included for Fréquentation).
    private var sectionFailure: (title: String, detail: String, symbol: String)? {
        var failures = selected.kinds.compactMap { data.errors[$0] }
        if selected == .attendance { failures += AuroraPresenceKind.allCases.compactMap { data.presenceErrors[$0] } }
        let expected = selected.kinds.count + (selected == .attendance ? (data.hourlyRequested ? 3 : 2) : 0)
        guard failures.count == expected, let first = failures.first, failures.allSatisfy({ $0.cause == first.cause }) else { return nil }
        switch first.cause {
        case .missingFunction: return ("Collecte complète non raccordée", first.detail, "puzzlepiece.extension")
        case .denied: return ("Accès refusé", first.detail, "lock")
        case .unreadable: return ("Rapport illisible", first.detail, "exclamationmark.triangle")
        case .server, .network: return ("Rapport indisponible", first.detail, "exclamationmark.triangle")
        }
    }
    @ViewBuilder private var section: some View {
        switch selected {
        case .attendance: AttendanceSection(data: data)
        case .sessions: SessionsSection(data: data)
        case .screens: ScreensSection(data: data)
        case .actions: ActionsSection(data: data)
        case .games: GamesSection(data: data)
        case .progress: ProgressSection(data: data)
        case .technical: TechnicalSection(data: data)
        case .privacy: PrivacySection(data: data)
        }
    }
}

// MARK: Shared pieces

private struct InsightsContextLine: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Population : \(data.population.title) (\(data.population.detail)) · du \(data.filters.fromDay) au \(data.filters.toDayExclusive) exclu, jours Europe/Zurich"
                 + (data.filters.appVersion.map { " · version " + $0 } ?? "") + " · borne de lecture \(data.asOf ?? "non disponible")")
            Text(InsightsStyle.coverage)
        }.font(.callout).foregroundStyle(InsightsStyle.secondaryText)
    }
}
private struct Tile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout).foregroundStyle(InsightsStyle.secondaryText)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let caption { Text(caption).font(.caption).foregroundStyle(InsightsStyle.secondaryText) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct Tiles<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .topLeading)], alignment: .leading, spacing: 18) { content }
    }
}
private struct CountLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) { Text(label); Spacer(minLength: 12); Text(value).monospacedDigit() }.font(.callout)
    }
}
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(InsightsStyle.secondaryText).fixedSize(horizontal: false, vertical: true) }
}
private struct Heading: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).font(.headline) }
}

private struct TableRow: Identifiable {
    var id: String
    var cells: [String]
    /// Dimensions only: the numbers are replaced by « masqué ».
    var maskedAfter: Int? = nil
}
/// Plain native grid, scrollable horizontally; masked rows keep their dimensions and say why their numbers are absent.
private struct InsightsTable: View {
    let columns: [String]
    let rows: [TableRow]
    var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { ForEach(Array(columns.enumerated()), id: \.offset) { Text($0.element) } }
                        .font(.caption).foregroundStyle(InsightsStyle.secondaryText)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows) { row in
                        GridRow {
                            if let split = row.maskedAfter {
                                ForEach(Array(row.cells.prefix(split).enumerated()), id: \.offset) { Text($0.element) }
                                Text(F.masked).foregroundStyle(InsightsStyle.secondaryText).gridCellColumns(max(1, columns.count - split))
                            } else {
                                ForEach(Array(row.cells.enumerated()), id: \.offset) { Text($0.element) }
                            }
                        }.font(.callout).monospacedDigit()
                    }
                }.fixedSize().padding(.bottom, 5).textSelection(.enabled)
            }
        }
    }
}

/// State of one family where its numbers would be: never a zero for a period without collection.
private struct KindNotice: View {
    let data: AuroraInsightsBundle
    let kind: AuroraInsightsKind
    var body: some View {
        switch data.state(for: kind) {
        case .notLoaded: notice("\(kind.title) à synchroniser", "Cette famille n’a pas encore été lue.", "arrow.clockwise")
        case .notRequested: EmptyView()
        case .failed: notice("\(kind.title) indisponible", data.errors[kind]?.detail ?? "", "exclamationmark.triangle")
        case .notCollected:
            notice("Non collecté", "Aucune installation 1.6.0+ n’avait encore envoyé « \(kind.title) » sur cette période (première réception : \(data.anyReport(kind)?.firstReceivedAt ?? "aucune")). Ce n’est pas un zéro.", "tray")
        case .noData:
            notice("Aucune donnée sur la période", "La collecte a commencé (première réception : \(data.anyReport(kind)?.firstReceivedAt ?? "?")), mais aucune ligne ne couvre ces jours. Ce n’est pas un zéro mesuré.", "tray")
        case .data:
            VStack(alignment: .leading, spacing: 4) {
                if data.archiveUnavailable(for: kind) {
                    Note("Les jours de plus de 60 jours ne sont archivés que pour Production et Tous : ils manquent ici pour la population Interne.")
                } else if data.collectionGap(for: kind) == .partial {
                    Note("La période commence avant la collecte : les jours antérieurs restent non collectés.")
                }
                if let masked = data.anyReport(kind)?.maskedRowCount, masked > 0 {
                    Note("\(masked) ligne(s) archivée(s) \(F.masked), exclue(s) des totaux.")
                }
            }
        }
    }
    private func notice(_ title: String, _ detail: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.callout.weight(.medium))
            Text(detail).font(.callout).foregroundStyle(InsightsStyle.secondaryText)
        }
    }
}
private func hasData(_ data: AuroraInsightsBundle, _ kind: AuroraInsightsKind) -> Bool { data.state(for: kind) == .data }
private func days(_ count: Int) -> String { count == 1 ? "1 jour" : "\(count) jours" }

// MARK: Fréquentation

private struct AttendanceSection: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            LivePresenceView(data: data)
            Divider()
            PresenceHistoryView(data: data)
            if data.hourlyRequested { Divider(); PresenceHourlyView(data: data) }
            Divider()
            ActivityView(data: data)
        }
    }
}
private struct PresenceNotice: View {
    let data: AuroraInsightsBundle
    let kind: AuroraPresenceKind
    var body: some View {
        switch data.presenceState(for: kind) {
        case .failed: Label(data.presenceErrors[kind]?.detail ?? "", systemImage: "exclamationmark.triangle").font(.callout)
        case .notLoaded: Text("\(kind.title) à synchroniser.").font(.callout)
        case .notCollected: Label("Non collecté : aucun signal de présence reçu (versions antérieures à 1.6.0 ou mesure désactivée). Ce n’est pas un zéro.", systemImage: "tray").font(.callout)
        case .noData: Text(kind == .live ? "Aucune installation présente en ce moment." : "Aucun signal sur la période.").font(.callout)
        case .notRequested, .data: EmptyView()
        }
    }
}
private struct LivePresenceView: View {
    let data: AuroraInsightsBundle
    private var rows: [AuroraPresenceLiveRow] { (data.live?.rows ?? []).filter { $0.belongs(to: data.population) } }
    private var internalRows: [AuroraPresenceLiveRow] { (data.live?.rows ?? []).filter { !$0.isProduction } }
    private var today: AuroraPresenceDayRow? { data.history?.rows.first { $0.day == F.today() } }
    private func peak(_ row: AuroraPresenceDayRow?) -> String {
        guard let row else { return F.unknown }
        switch data.population {
        case .production: return F.count(row.peakInApp)
        case .internalBuilds: return F.count(row.internalPeakInApp)
        case .all: return "\(F.count(row.peakInApp)) · interne \(F.count(row.internalPeakInApp))"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading("En direct")
            PresenceNotice(data: data, kind: .live)
            if let live = data.live {
                Tiles {
                    Tile(title: "En jeu maintenant", value: F.count(rows.reduce(0) { $0 + $1.players }), caption: "lu à \(F.zurichTime(live.generatedAt))")
                    Tile(title: "Sur une grille", value: F.count(rows.filter { $0.state == "grid" }.reduce(0) { $0 + $1.players }))
                    Tile(title: "Pic d’aujourd’hui", value: peak(today), caption: today.map { "à \(F.zurichTime($0.peakAt)) · \($0.minutesObserved.map { "\($0) min observées" } ?? "minutes inconnues")" })
                    if data.population == .production, !internalRows.isEmpty {
                        Tile(title: "Builds internes maintenant", value: F.count(internalRows.reduce(0) { $0 + $1.players }), caption: "TestFlight et développement, non comptés")
                    }
                }
                let modes = Dictionary(grouping: rows.filter { $0.state == "grid" }, by: \.gameMode).map { ($0.key, $0.value.reduce(0) { $0 + $1.players }) }.sorted { $0.1 > $1.1 }
                let versions = Dictionary(grouping: rows, by: \.appVersion).map { ($0.key, $0.value.reduce(0) { $0 + $1.players }) }.sorted { $0.0 > $1.0 }
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sur une grille, par mode").font(.callout.weight(.medium))
                        if modes.isEmpty { Text("Personne sur une grille.").font(.callout) }
                        ForEach(modes, id: \.0) { CountLine(label: L.title($0.0, in: "mode"), value: F.count($0.1)) }
                    }.frame(maxWidth: 280, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Par version").font(.callout.weight(.medium))
                        ForEach(versions, id: \.0) { CountLine(label: "Version " + $0.0, value: F.count($0.1)) }
                    }.frame(maxWidth: 280, alignment: .leading)
                }
                Note("Installations au premier plan dont les statistiques le permettent (1.6.0+) : signal toutes les 30 s, présentes si un signal est arrivé dans les 90 dernières secondes. Une installation n’est pas une personne. Aucun identifiant persistant.")
            }
        }
    }
}
private struct PresenceHistoryView: View {
    let data: AuroraInsightsBundle
    private func peak(_ row: AuroraPresenceDayRow) -> Int? { data.population == .internalBuilds ? row.internalPeakInApp : row.peakInApp }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading("Pics quotidiens de présence")
            PresenceNotice(data: data, kind: .history)
            if let history = data.history, !history.rows.isEmpty {
                let points = history.rows.compactMap { row in peak(row).flatMap { value in F.date(day: row.day).map { ($0, value) } } }
                if points.count > 1 {
                    Chart(points, id: \.0) { BarMark(x: .value("Jour", $0.0, unit: .day), y: .value("Pic", $0.1)).foregroundStyle(Color.accentColor) }
                        .frame(height: 140).accessibilityLabel("Pic quotidien des installations présentes")
                }
                InsightsTable(columns: ["Jour", data.population == .internalBuilds ? "Pic interne" : "Pic production", "Pic sur une grille", "Minute du pic", "Moyenne", "Minutes observées", "Pic interne", "Journée"],
                              rows: history.rows.reversed().map { row in
                    TableRow(id: row.day, cells: [row.day, F.count(peak(row)), F.count(row.peakOnGrid), F.zurichTime(row.peakAt), F.decimal(row.avgInApp, digits: 2),
                                                  F.count(row.minutesObserved), F.count(row.internalPeakInApp), row.complete ? "terminée" : "en cours"])
                })
                Note(data.population == .all
                     ? "Les pics de production (App Store et builds inconnus) et des builds internes sont lus séparément et ne s’additionnent pas : ils ne tombent pas à la même minute. Pic sur une grille et moyenne : production."
                     : "Production = builds App Store et inconnus ; interne = TestFlight et développement. Pic sur une grille et moyenne : production.")
            }
        }
    }
}
private struct PresenceHourlyView: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading("Présence selon l’heure (Zurich)")
            PresenceNotice(data: data, kind: .hourly)
            if let hourly = data.hourly, !hourly.rows.isEmpty {
                let byHour = Dictionary(grouping: hourly.rows.filter { $0.hourOfDay != nil }, by: { $0.hourOfDay! }).sorted { $0.key < $1.key }
                InsightsTable(columns: ["Heure", "Moyenne présente", "Pic", "Moyenne sur une grille", "Minutes observées"], rows: byHour.map { hour, rows in
                    let minutes = M.sum(rows, \.minutesObserved)
                    let weighted = rows.compactMap { r in r.avgInApp.flatMap { a in r.minutesObserved.map { a * Double($0) } } }.reduce(0, +)
                    let grid = rows.compactMap { r in r.avgOnGrid.flatMap { a in r.minutesObserved.map { a * Double($0) } } }.reduce(0, +)
                    return TableRow(id: String(hour), cells: [String(format: "%02d h", hour), F.decimal(minutes.flatMap { $0 > 0 ? weighted / Double($0) : nil }, digits: 2),
                                                             F.count(rows.compactMap(\.peakInApp).max()), F.decimal(minutes.flatMap { $0 > 0 ? grid / Double($0) : nil }, digits: 2), F.count(minutes)])
                })
                Note("Production uniquement, sur les jours de la période (31 jours au plus). Moyenne pondérée par les minutes observées.")
            }
        }
    }
}
private struct ActivityView: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading("Installations actives")
            KindNotice(data: data, kind: .activity)
            if let report = data.activity, hasData(data, .activity) {
                let rows = report.visibleRows
                let last = rows.last
                Tiles {
                    Tile(title: "DAU", value: F.count(last?.dau), caption: last.map { "le " + $0.day })
                    Tile(title: "WAU (7 jours)", value: F.count(last?.wau), caption: last.map { "jusqu’au " + $0.day })
                    Tile(title: "MAU (30 jours)", value: F.count(last?.mau), caption: last.map { "jusqu’au " + $0.day })
                    Tile(title: "Nouvelles installations", value: F.count(M.sum(rows, \.newInstallations)), caption: "sur la période")
                    Tile(title: "Sessions", value: F.count(M.sum(rows, \.sessions)), caption: "ouvertures de l’app")
                    Tile(title: "Comptes connectés", value: F.count(rows.compactMap(\.accounts).max()), caption: "maximum d’un jour")
                }
                let points = rows.compactMap { row in row.dau.flatMap { value in F.date(day: row.day).map { ($0, value) } } }
                if points.count > 1 {
                    Chart(points, id: \.0) { LineMark(x: .value("Jour", $0.0, unit: .day), y: .value("DAU", $0.1)).foregroundStyle(Color.accentColor) }
                        .frame(height: 140).accessibilityLabel("Installations actives par jour")
                }
                DisclosureGroup("Détail par jour") {
                    InsightsTable(columns: ["Jour", "DAU", "WAU", "MAU", "Nouvelles", "Revenues", "Sessions", "Comptes", "Avec contexte"], rows: report.rows.reversed().map { r in
                        TableRow(id: r.stableKey, cells: [r.day, F.count(r.dau), F.count(r.wau), F.count(r.mau), F.count(r.newInstallations), F.count(r.returningInstallations),
                                                          F.count(r.sessions), F.count(r.accounts), F.count(r.installationsWithContext)], maskedAfter: r.suppressed ? 1 : nil)
                    }).padding(.top, 8)
                }
                Note("DAU, WAU et MAU comptent les installations actives toutes versions mesurées par le parcours, y compris antérieures à 1.6.0 ; « avec contexte » = installations couvertes par la collecte étendue. Revenues = déjà vues un jour précédent. Installations distinctes par jour, jamais additionnées entre jours.")
            }
        }
    }
}

// MARK: Sessions

private struct SessionsSection: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading("Sessions et temps passé")
            KindNotice(data: data, kind: .sessions)
            if let report = data.sessions, hasData(data, .sessions) {
                let rows = report.visibleRows
                let measured = M.sum(rows, \.sessionsMeasured)
                let average = { (path: KeyPath<AuroraSessionsRow, Int?>) -> String in F.duration(seconds: M.ratio(M.sum(rows, path), measured)) }
                Tiles {
                    Tile(title: "Sessions commencées", value: F.count(M.sum(rows, \.sessionsStarted)))
                    Tile(title: "Sessions mesurées", value: F.count(measured), caption: "durée reçue")
                    Tile(title: "Premier plan par session", value: average(\.foregroundSeconds), caption: "moyenne")
                    Tile(title: "Temps actif par session", value: average(\.activeSeconds), caption: "hors publicité et inactivité")
                    Tile(title: "Publicité par session", value: average(\.adSeconds))
                    Tile(title: "Inactivité par session", value: average(\.idleSeconds), caption: "aucun toucher pendant une minute")
                    Tile(title: "Sur une grille par session", value: average(\.gridSeconds))
                    Tile(title: "Temps au premier plan", value: F.duration(M.sum(rows, \.foregroundSeconds)), caption: "total de la période")
                    Tile(title: "Terminées en quittant", value: F.count(M.sum(rows, \.endedByQuit)))
                }
                InsightsTable(columns: ["Jour", "Version", "Installations", "Commencées", "Mesurées", "Médiane", "90e centile", "Médiane active"], rows: report.rows.reversed().map { r in
                    TableRow(id: r.stableKey, cells: [r.day, r.appVersion, F.count(r.installations), F.count(r.sessionsStarted), F.count(r.sessionsMeasured),
                                                      F.duration(seconds: r.medianSessionSeconds), F.duration(seconds: r.p90SessionSeconds), F.duration(seconds: r.medianActiveSeconds)],
                             maskedAfter: r.suppressed ? 2 : nil)
                })
                Note("Une session commence au démarrage, ou à un retour après 30 minutes ou un autre jour ; sa durée est la somme de ses passages au premier plan. Moyennes = sommes ÷ sessions mesurées ; les médianes valent pour leur ligne et ne se combinent pas.")
            }
        }
    }
}

// MARK: Écrans et fenêtres

private struct ScreensSection: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Heading("Écrans")
                KindNotice(data: data, kind: .screens)
                if let report = data.screens, hasData(data, .screens) {
                    let groups = Dictionary(grouping: report.visibleRows, by: \.screen).sorted { (M.sum($0.value, \.views) ?? 0) > (M.sum($1.value, \.views) ?? 0) }
                    InsightsTable(columns: ["Écran", "Vues", "Temps total", "Par vue", "Sorties de l’app", "Origines principales", "Installations"], rows: groups.map { screen, rows in
                        let views = M.sum(rows, \.views), seconds = M.sum(rows, \.seconds)
                        return TableRow(id: screen, cells: [screen, F.count(views), F.duration(seconds), F.duration(seconds: M.ratio(seconds, views)), F.count(M.sum(rows, \.leftToBackground)),
                                                            M.merge(rows, \.origins).prefix(3).map { "\($0.code) \($0.count)" }.joined(separator: " · "), M.installationsRange(rows.map(\.installations))])
                    })
                    Note("Somme des jours et des versions de la période. Les installations sont distinctes par jour et version, jamais additionnées.")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Heading("Fenêtres")
                KindNotice(data: data, kind: .dialogs)
                if let report = data.dialogs, hasData(data, .dialogs) {
                    let groups = Dictionary(grouping: report.visibleRows, by: \.dialog).sorted { (M.sum($0.value, \.closes) ?? 0) > (M.sum($1.value, \.closes) ?? 0) }
                    InsightsTable(columns: ["Fenêtre", "Fermetures", "Temps moyen", "Issues", "Ouverte depuis", "Installations"], rows: groups.map { dialog, rows in
                        let closes = M.sum(rows, \.closes)
                        return TableRow(id: dialog, cells: [dialog, F.count(closes), F.duration(seconds: M.ratio(M.sum(rows, \.seconds), closes)),
                                                            M.merge(rows, \.outcomes).map { "\($0.code) \($0.count)" }.joined(separator: " · "),
                                                            M.merge(rows, \.screens).prefix(3).map { "\($0.code) \($0.count)" }.joined(separator: " · "), M.installationsRange(rows.map(\.installations))])
                    })
                }
            }
        }
    }
}

// MARK: Actions

private struct ActionsSection: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading("Actions de l’interface")
            KindNotice(data: data, kind: .actions)
            if let report = data.actions, hasData(data, .actions) {
                let groups = Dictionary(grouping: report.visibleRows, by: \.action).sorted { (M.sum($0.value, \.events) ?? 0) > (M.sum($1.value, \.events) ?? 0) }
                InsightsTable(columns: ["Action", "Événements", "Valeur moyenne", "Écrans", "Installations"], rows: groups.map { action, rows in
                    TableRow(id: action, cells: [action, F.count(M.sum(rows, \.events)), F.decimal(M.ratio(M.sum(rows, \.valueSum), M.sum(rows, \.valuedEvents))),
                                                 M.merge(rows, \.screens).prefix(3).map { "\($0.code) \($0.count)" }.joined(separator: " · "), M.installationsRange(rows.map(\.installations))])
                })
                Note("Valeur moyenne = somme des valeurs ÷ événements qui en portent une (inconnue sinon). Les codes d’action sont ceux du jeu.")
            }
        }
    }
}

// MARK: Parties

private struct GamesSection: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Heading("Détail des parties")
                KindNotice(data: data, kind: .gameplay)
                if let report = data.gameplay, hasData(data, .gameplay) {
                    let byMode = Dictionary(grouping: report.visibleRows, by: \.mode).sorted { $0.key < $1.key }
                    ForEach(byMode, id: \.key) { mode, rows in
                        let runs = M.sum(rows, \.runs)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(L.title(mode, in: "mode")) · \(F.count(runs)) partie(s) · \(F.percent(M.ratio(M.sum(rows.filter { $0.outcome == "solved" }, \.runs), runs))) résolues").font(.callout.weight(.medium))
                            let groups = Dictionary(grouping: rows, by: { "\(String(format: "%08d", $0.level))|\($0.difficulty)|\($0.boardSize)|\($0.outcome)" }).sorted { $0.key < $1.key }
                            InsightsTable(columns: ["Étape", "Difficulté", "Taille", "Issue", "Parties", "Temps par partie", "Coups", "Avec indice", "Avec erreur", "Score moyen", "Part du maximum", "Complétion"],
                                          rows: groups.map { key, rows in
                                let first = rows[0], runs = M.sum(rows, \.runs)
                                return TableRow(id: key, cells: [first.level == 0 ? "—" : String(first.level), L.title(first.difficulty, in: "difficulty"), "\(first.boardSize)×\(first.boardSize)",
                                                                 L.title(first.outcome, in: "outcome"), F.count(runs), F.duration(seconds: M.ratio(M.sum(rows, \.activeSeconds), runs)),
                                                                 F.decimal(M.ratio(M.sum(rows, \.moves), runs)), F.percent(M.ratio(M.sum(rows, \.runsWithHints), runs)),
                                                                 F.percent(M.ratio(M.sum(rows, \.runsWithErrors), runs)), F.decimal(M.ratio(M.sum(rows, \.score), M.sum(rows, \.scoredRuns)), digits: 0),
                                                                 F.percent(M.ratio(M.sum(rows, \.score), M.sum(rows, \.maxScore))),
                                                                 F.decimal(M.ratio(M.sum(rows, \.completionPct), M.sum(rows, \.completionKnown)), digits: 0) + " %"])
                            })
                        }
                    }
                    Note("Moyennes = sommes ÷ parties (score : ÷ parties notées ; complétion : ÷ parties dont elle est connue). Une partie quittée par retour ou mise de côté peut compter plusieurs détails. Les valeurs inconnues (-1) sont exclues par le serveur.")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Heading("Chronologies des coups")
                KindNotice(data: data, kind: .timeline)
                if let report = data.timeline, hasData(data, .timeline) {
                    let groups = Dictionary(grouping: report.visibleRows, by: { "\($0.mode)|\(String(format: "%08d", $0.level))|\($0.difficulty)" }).sorted { $0.key < $1.key }
                    InsightsTable(columns: ["Mode", "Étape", "Difficulté", "Chronologies", "Coups", "Premier coup après", "Dernier coup après", "Coups par type"], rows: groups.map { key, rows in
                        let first = rows[0], timelines = M.sum(rows, \.timelines)
                        let complete = timelines.map { $0 - (M.sum(rows, \.partial) ?? 0) }
                        return TableRow(id: key, cells: [L.title(first.mode, in: "mode"), first.level == 0 ? "—" : String(first.level), L.title(first.difficulty, in: "difficulty"),
                                                         F.count(timelines), F.count(M.sum(rows, \.actions)),
                                                         F.duration(seconds: M.ratio(M.sum(rows, \.firstActionDs), complete).map { $0 / 10 }),
                                                         F.duration(seconds: M.ratio(M.sum(rows, \.lastActionDs), timelines).map { $0 / 10 }),
                                                         M.merge(rows, \.byKind).map { "\(L.title($0.code, in: "timeline")) \($0.count)" }.joined(separator: " · ")])
                    })
                    Note("Échantillon de parties. Les temps viennent de l’horloge de la partie (du temps à l’écran pour les Chemins de lumière) ; premier coup : chronologies complètes seulement.")
                }
            }
        }
    }
}

// MARK: Progression et réglages

private struct ProgressSection: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Heading("Progression débloquée")
                KindNotice(data: data, kind: .progress)
                if let report = data.progress, hasData(data, .progress) {
                    let groups = Dictionary(grouping: report.visibleRows, by: { $0.kind + "|" + $0.code }).sorted { $0.key < $1.key }
                    InsightsTable(columns: ["Type", "Code", "Événements", "Valeur maximale", "Installations"], rows: groups.map { key, rows in
                        TableRow(id: key, cells: [L.title(rows[0].kind, in: "kind"), rows[0].code, F.count(M.sum(rows, \.events)), F.count(rows.compactMap(\.valueMax).max()), M.installationsRange(rows.map(\.installations))])
                    })
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Heading("Réglages changés")
                KindNotice(data: data, kind: .settings)
                if let report = data.settings, hasData(data, .settings) {
                    let groups = Dictionary(grouping: report.visibleRows, by: { $0.setting + "|" + $0.value }).sorted { $0.key < $1.key }
                    InsightsTable(columns: ["Réglage", "Nouvelle valeur", "Changements", "Installations"], rows: groups.map { key, rows in
                        TableRow(id: key, cells: [L.title(rows[0].setting, in: "setting"), rows[0].value, F.count(M.sum(rows, \.changes)), M.installationsRange(rows.map(\.installations))])
                    })
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Heading("Rappels ouverts")
                KindNotice(data: data, kind: .notifications)
                if let report = data.notifications, hasData(data, .notifications) {
                    let groups = Dictionary(grouping: report.visibleRows, by: { $0.kind + "|" + $0.destination }).sorted { $0.key < $1.key }
                    InsightsTable(columns: ["Rappel", "Destination", "Ouvertures", "Installations"], rows: groups.map { key, rows in
                        TableRow(id: key, cells: [L.title(rows[0].kind, in: "kind"), rows[0].destination, F.count(M.sum(rows, \.opens)), M.installationsRange(rows.map(\.installations))])
                    })
                }
            }
        }
    }
}

// MARK: Technique

private struct TechnicalSection: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StabilityView(data: data)
            Divider()
            PerformanceView(data: data)
            Divider()
            CloudView(data: data)
            Divider()
            ServerView(data: data)
        }
    }
}
private struct StabilityView: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading("Stabilité")
            KindNotice(data: data, kind: .stability)
            if let report = data.stability, hasData(data, .stability) {
                let rows = report.visibleRows
                Tiles {
                    Tile(title: "Lancements", value: F.count(M.sum(rows, \.launches)), caption: "\(F.count(M.sum(rows, \.coldStarts))) démarrage(s) à froid")
                    Tile(title: "Arrêts au premier plan", value: F.count(M.sum(rows, \.stopsWhileOnScreen)), caption: "plantage ou arrêt forcé, indiscernables")
                    Tile(title: "Part des lancements", value: F.percent(M.ratio(M.sum(rows, \.stopsWhileOnScreen), M.sum(rows, \.launches))), caption: "après un arrêt au premier plan")
                    Tile(title: "Erreurs consignées", value: F.count(M.sum(rows, \.errorEvents)), caption: "\(F.count(M.sum(rows, \.sessionsWithErrors))) session(s) touchée(s)")
                }
                InsightsTable(columns: ["Jour", "Version", "Installations", "Lancements", "Arrêts au premier plan", "Installations concernées", "Erreurs", "Sessions avec erreur"], rows: report.rows.reversed().map { r in
                    TableRow(id: r.stableKey, cells: [r.day, r.appVersion, F.count(r.installations), F.count(r.launches), F.count(r.stopsWhileOnScreen), F.count(r.installationsWithStops),
                                                      F.count(r.errorEvents), F.count(r.sessionsWithErrors)], maskedAfter: r.suppressed ? 2 : nil)
                })
                Note("Lancements : toutes les versions mesurées par le parcours. Un arrêt au premier plan est un lancement dont l’exécution précédente s’est arrêtée alors que l’app était affichée.")
            }
            Heading("Erreurs par signature")
            KindNotice(data: data, kind: .diagnostics)
            if let report = data.diagnostics, hasData(data, .diagnostics) {
                let groups = Dictionary(grouping: report.visibleRows, by: \.fingerprint).sorted { (M.sum($0.value, \.events) ?? 0) > (M.sum($1.value, \.events) ?? 0) }
                InsightsTable(columns: ["Type", "Exception", "Signature", "Événements", "Sessions", "Jours", "Écrans", "Versions"], rows: groups.map { fingerprint, rows in
                    TableRow(id: fingerprint, cells: [L.title(rows[0].kind, in: "kind"), rows[0].exceptionType, fingerprint, F.count(M.sum(rows, \.events)), F.count(M.sum(rows, \.sessions)),
                                                      String(Set(rows.map(\.day)).count), M.merge(rows, \.screens).prefix(3).map { "\($0.code) \($0.count)" }.joined(separator: " · "),
                                                      Set(rows.map(\.appVersion)).sorted().joined(separator: ", ")])
                })
                Note("La signature est une empreinte de l’erreur, pas un identifiant de personne ou d’appareil.")
            }
        }
    }
}
private struct PerformanceView: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading("Fluidité par modèle d’appareil")
            KindNotice(data: data, kind: .performance)
            if let report = data.performance, hasData(data, .performance) {
                let groups = Dictionary(grouping: report.visibleRows, by: \.deviceModel).sorted { (M.sum($0.value, \.frames) ?? 0) > (M.sum($1.value, \.frames) ?? 0) }
                InsightsTable(columns: ["Modèle", "Systèmes", "Passages", "Images", "Lentes", "Très lentes", "Images/s moy.", "Image la plus longue", "Mémoire max.", "Démarrage médian", "Chauffe", "Économie d’énergie"],
                              rows: groups.map { model, rows in
                    let frames = M.sum(rows, \.frames)
                    let startups = rows.compactMap(\.startupMsMedian)
                    return TableRow(id: model, cells: [model, Set(rows.map(\.osMajor)).sorted().joined(separator: ", "), F.count(M.sum(rows, \.stretches)), F.count(frames),
                                                       F.percent(M.ratio(M.sum(rows, \.slowFrames), frames)), F.percent(M.ratio(M.sum(rows, \.verySlowFrames), frames)),
                                                       F.decimal(M.ratio(M.sum(rows, \.fpsFrames), frames)), F.count(rows.compactMap(\.maxFrameMs).max()).appending(" ms"),
                                                       F.count(rows.compactMap(\.memoryPeakMbMax).max()).appending(" Mo"),
                                                       startups.isEmpty ? F.unknown : startups.min() == startups.max() ? F.milliseconds(startups[0]) : "\(F.milliseconds(startups.min()))–\(F.milliseconds(startups.max()))",
                                                       F.count(M.sum(rows, \.thermalSerious)), F.count(M.sum(rows, \.lowPower))])
                })
                Note("Par passage au premier plan. Images/s moyennes pondérées par les images ; le démarrage médian vaut par jour et par version (étendue affichée). Chauffe = passages en état thermique sérieux ou plus.")
            }
        }
    }
}
private struct CloudView: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading("Réseau et cloud")
            KindNotice(data: data, kind: .cloud)
            if let report = data.cloud, hasData(data, .cloud) {
                InsightsTable(columns: ["Jour", "Version", "Opération", "Issue", "Opérations", "Médiane (p50)", "p90", "Maximum", "Statuts HTTP"], rows: report.rows.reversed().map { r in
                    TableRow(id: r.stableKey, cells: [r.day, r.appVersion, r.op, L.title(r.outcome, in: "outcome"), F.count(r.ops), F.milliseconds(r.medianMs), F.milliseconds(r.p90Ms),
                                                      F.milliseconds(r.maxMs.map(Double.init)), (r.statuses ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")],
                             maskedAfter: r.suppressed ? 4 : nil)
                })
                Note("Les centiles valent pour leur ligne (jour × version × opération × issue) et ne se combinent pas.")
            }
        }
    }
}
private struct ServerView: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading("Serveur")
            KindNotice(data: data, kind: .server)
            if let report = data.server {
                if !report.rows.isEmpty {
                    Tiles {
                        Tile(title: "Événements reçus", value: F.count(M.sum(report.rows, \.eventsReceived)), caption: "dont \(F.count(M.sum(report.rows, \.extendedEvents))) de la collecte complète")
                        Tile(title: "Refus du serveur", value: F.count(report.rows.reduce(0) { $0 + ($1.rejections ?? [:]).values.reduce(0, +) }))
                        Tile(title: "Pic de présence", value: F.count(report.rows.compactMap(\.presencePeak).max()), caption: "production et interne, une minute")
                    }
                    InsightsTable(columns: ["Jour de réception", "Événements", "Base", "Collecte complète", "Installations émettrices", "Refus", "Minutes de présence", "Pic"], rows: report.rows.reversed().map { r in
                        TableRow(id: r.day, cells: [r.day, F.count(r.eventsReceived), F.count(r.coreEvents), F.count(r.extendedEvents), F.count(r.installationsSending),
                                                    (r.rejections ?? [:]).sorted { $0.key < $1.key }.map { "\(AuroraJourneyCoverage.rejectionLabel(for: $0.key)) \($0.value)" }.joined(separator: " · "),
                                                    F.count(r.presenceMinutes), F.count(r.presencePeak)])
                    })
                }
                Text("Stockage (valeurs du moment)").font(.callout.weight(.medium))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AuroraInsightsServerCoverage.Storage.fields, id: \.key) { field in
                        let value = report.coverage.storage[keyPath: field.path]
                        CountLine(label: field.title, value: field.bytes ? F.bytes(value) : F.count(value.flatMap { $0 >= 0 ? $0 : nil }))
                    }
                }.frame(maxWidth: 420, alignment: .leading)
                if let functions = report.coverage.functions, !functions.isEmpty {
                    Text("Appels des fonctions du jeu").font(.callout.weight(.medium))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(functions, id: \.function) { CountLine(label: $0.function, value: "\(F.count($0.calls)) appel(s) · \(F.decimal($0.meanMs, digits: 2)) ms en moyenne") }
                    }.frame(maxWidth: 520, alignment: .leading)
                } else {
                    Note("Statistiques d’appel indisponibles (pg_stat_statements non lisible).")
                }
                Note("Toutes populations et versions, par jour de réception. Aucun coût n’est calculé : Supabase facture le projet entier. Les journaux d’API de Supabase (avec adresses IP) ne sont pas lus ici.")
            }
        }
    }
}

// MARK: Confidentialité

private struct PrivacySection: View {
    let data: AuroraInsightsBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Heading("Base de la mesure")
                KindNotice(data: data, kind: .privacy)
                if let report = data.privacy, hasData(data, .privacy) {
                    let groups = Dictionary(grouping: report.visibleRows, by: { [$0.statisticsBasis, $0.statisticsSource, $0.regionClass, $0.attStatus].joined(separator: "|") }).sorted { $0.key < $1.key }
                    InsightsTable(columns: ["Base", "Source du choix", "Région", "ATT", "Sessions", "Installations-jours", "Installations"], rows: groups.map { key, rows in
                        let r = rows[0]
                        return TableRow(id: key, cells: [L.title(r.statisticsBasis, in: "statistics_basis"), L.title(r.statisticsSource, in: "statistics_source"), L.title(r.regionClass, in: "region_class"),
                                                         L.title(r.attStatus, in: "att_status"), F.count(M.sum(rows, \.sessions)), F.count(M.sum(rows, \.installations)), M.installationsRange(rows.map(\.installations))])
                    })
                    Note("Seules les installations qui envoient leur contexte figurent ici : leurs statistiques couvrent la collecte étendue. Les refus ne sont visibles que comme décomptes anonymes (ci-dessous). Installations-jours : une installation présente deux jours compte deux fois.")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Heading("Accords et retraits")
                KindNotice(data: data, kind: .consents)
                if let report = data.consents, hasData(data, .consents) {
                    let groups = Dictionary(grouping: report.visibleRows, by: { [$0.purpose, $0.state, $0.source].joined(separator: "|") }).sorted { $0.key < $1.key }
                    InsightsTable(columns: ["Finalité", "État", "Source", "Événements", "Installations"], rows: groups.map { key, rows in
                        let r = rows[0]
                        return TableRow(id: key, cells: [L.title(r.purpose, in: "purpose"), L.title(r.state, in: "state"), L.title(r.source, in: "source"), F.count(M.sum(rows, \.events)),
                                                         r.anonymous ? "anonyme, aucune installation connue" : M.installationsRange(rows.map(\.installations))])
                    })
                    Note("Oui et non explicites enregistrés avec le parcours, et retraits anonymes des statistiques (décompte sans identifiant, absent de la population Interne).")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Heading("Contexte des appareils")
                KindNotice(data: data, kind: .context)
                if let report = data.context, hasData(data, .context) {
                    let byDimension = Dictionary(grouping: report.visibleRows, by: \.dimension).sorted { $0.key < $1.key }
                    ForEach(byDimension, id: \.key) { dimension, rows in
                        DisclosureGroup(L.dimension(dimension)) {
                            let values = Dictionary(grouping: rows, by: { $0.value ?? "" }).sorted { (M.sum($0.value, \.installations) ?? 0) > (M.sum($1.value, \.installations) ?? 0) }
                            InsightsTable(columns: ["Valeur", "Maximum d’un jour", "Installations-jours"], rows: values.map { value, rows in
                                TableRow(id: value, cells: [value.isEmpty ? "non renseigné" : L.title(value, in: ["signed_in", "premium"].contains(dimension) ? "boolean" : dimension),
                                                            F.count(rows.compactMap(\.installations).max()), F.count(M.sum(rows, \.installations))])
                            }).padding(.top, 8)
                        }
                    }
                    Note("Installations du jour par dimension et valeur. Une dimension inconnue de cette version de GameMetrik garde son code brut.")
                }
            }
        }
    }
}

// MARK: Coverage

private struct InsightsCoverageView: View {
    let data: AuroraInsightsBundle
    let kinds: [AuroraInsightsKind]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attribution : non collectée · aucun identifiant").font(.callout.weight(.medium))
            DisclosureGroup("Couverture et limites de lecture") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(InsightsStyle.coverage)
                    Text("Population \(data.population.title) : \(data.population.detail). Borne de lecture : \(data.asOf ?? "non disponible").")
                    ForEach(kinds, id: \.self) { kind in
                        if let report = data.anyReport(kind) {
                            if let c = report.standardCoverage {
                                Text("\(kind.title) : première réception \(c.collectionFirstReceivedAt ?? "aucune") · \(days(c.archivedDaysInWindow)) archivé(s) dans la période"
                                     + (c.archiveAvailableForPopulation ? "" : " (archive indisponible pour cette population)")
                                     + " · événements bruts conservés \(c.rawRetentionDays.map { days($0) } ?? "durée inconnue") · groupes de moins de \(c.smallGroupThreshold) installations masqués dans les jours archivés.")
                            } else {
                                Text("\(kind.title) : toutes populations et versions, par jour de réception.")
                            }
                        }
                    }
                    if kinds.contains(.activity), let presence = data.live?.coverage ?? data.history?.coverage {
                        Text("Présence : premier signal \(presence.firstSignalAt ?? "aucun") · fenêtre de \(presence.windowSeconds) s · signal toutes les \(presence.signalIntervalSeconds) s · \(presence.samplerMinutesToday.map { "\($0) minute(s) échantillonnée(s) aujourd’hui" } ?? "échantillonnage du jour inconnu").")
                    }
                    if let c = kinds.lazy.compactMap({ data.anyReport($0)?.standardCoverage }).first {
                        Text("Règle de collecte du serveur : \(c.collectionRule)")
                        Text("Production selon le serveur : \(c.productionDefinition)")
                    }
                    Text("Les jours de plus de 60 jours sont lus dans une archive anonyme ; la borne de lecture ne s’applique qu’aux jours non figés. Une période antérieure à la collecte reste « non collecté », jamais zéro.")
                }.font(.callout).foregroundStyle(InsightsStyle.secondaryText).textSelection(.enabled).padding(.top, 10)
            }
        }
    }
}
