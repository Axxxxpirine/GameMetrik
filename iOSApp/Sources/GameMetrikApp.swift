import SwiftUI
import UIKit
import GameMetrikCore

// THESIS: Le Journal du studio, consultable d’une main.
// OWN-WORLD: SF, surfaces iOS et vert GameMetrik ; les chiffres gardent leur contexte.
// STORY: Lire le studio, ouvrir un jeu, inspecter sa période et ses sources.
// FIRST VIEWPORT: Titre Studio, période, provenance puis Acquisition, Activité et Revenus.
// FORM: Adaptation du Journal approuvé ; onglets et navigation iOS système.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
@main struct GameMetrikApp: App {
    @UIApplicationDelegateAdaptor(PrivacyDelegate.self) private var privacy
    @StateObject private var store = MobileStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MobileRoot().environmentObject(store).tint(.metrik)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { store.lock() }
                }
        }
    }
}

/// Covers every window, including presented sheets, before iOS snapshots the app switcher.
@MainActor final class PrivacyDelegate: NSObject, UIApplicationDelegate {
    private var covers: [UIView] = []
    func applicationWillResignActive(_ application: UIApplication) {
        guard covers.isEmpty else { return }
        for scene in application.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                let cover = UIView(frame: window.bounds)
                cover.backgroundColor = .systemBackground
                cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                let label = UILabel(); label.text = "GameMetrik"; label.font = .preferredFont(forTextStyle: .title2)
                label.textColor = .secondaryLabel; label.translatesAutoresizingMaskIntoConstraints = false
                cover.addSubview(label)
                NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: cover.centerXAnchor), label.centerYAnchor.constraint(equalTo: cover.centerYAnchor)])
                window.addSubview(cover); covers.append(cover)
            }
        }
    }
    func applicationDidBecomeActive(_ application: UIApplication) { covers.forEach { $0.removeFromSuperview() }; covers = [] }
}

extension Color {
    static let readableSecondary = Color(uiColor: UIColor { trait in
        // Contrast >= 4.5:1 for small metadata, on the system light/dark surfaces.
        UIColor(white: trait.userInterfaceStyle == .dark ? 0.72 : 0.36, alpha: 1)
    })
    static let metrik = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(red: 0.51, green: 0.83, blue: 0.70, alpha: 1) : UIColor(red: 0.078, green: 0.408, blue: 0.306, alpha: 1)
    })
}

enum Display {
    static func number(_ value: Double?, digits: Int = 0) -> String {
        value.map { $0.formatted(.number.locale(Locale(identifier: "fr_CH")).precision(.fractionLength(0...digits))) } ?? "—"
    }
    static func percent(_ value: Double?) -> String { value.map { number($0, digits: 1) + " %" } ?? "—" }
    static func amount(_ value: Double, currency: String) -> String { number(value, digits: 2) + " " + currency }
    static func metric(_ kpi: KPI, currency: String = "CHF") -> String {
        if let amounts = kpi.amountsByCurrency, !amounts.isEmpty {
            return amounts.keys.sorted().map { amount(amounts[$0]!, currency: $0) }.joined(separator: "\n")
        }
        guard let value = kpi.value else { return "—" }
        switch kpi.unit {
        case "currency": return amount(value, currency: currency)
        case "percent": return percent(value)
        case "minutes": return number(value, digits: 1) + " min"
        default: return number(value, digits: value < 10 ? 1 : 0)
        }
    }
}

struct MobileRoot: View {
    @EnvironmentObject var store: MobileStore
    var body: some View {
        Group {
            if store.unlocked {
                TabView {
                    NavigationStack { DashboardScreen(gameID: nil).navigationTitle("Studio") }
                        .tabItem { Label("Studio", systemImage: "chart.xyaxis.line") }
                    NavigationStack { GamesScreen() }
                        .tabItem { Label("Jeux", systemImage: "gamecontroller") }
                    NavigationStack { MobileSettings() }
                        .tabItem { Label("Réglages", systemImage: "gearshape") }
                }
            } else { WelcomeScreen() }
        }
        .safeAreaInset(edge: .bottom) {
            if store.loading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(store.progress).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Annuler") { store.cancel() }.frame(minHeight: 44)
                }.padding(.horizontal, 20).background(.regularMaterial)
            }
        }
    }
}

struct WelcomeScreen: View {
    @EnvironmentObject var store: MobileStore
    @State private var importing = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(Color.metrik).accessibilityHidden(true)
                    Text(store.hasConnection ? "Ton studio, à portée de main." : "Tes jeux.\nLeurs chiffres.\nDans ta poche.")
                        .font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("Acquisition, activité et revenus : retrouve tes données et actualise-les directement depuis l’iPhone.")
                        .font(.body).foregroundStyle(Color.readableSecondary)
                    if store.hasConnection {
                        Button { Task { await store.unlock() } } label: {
                            Label(store.authenticating ? "Déverrouillage…" : "Déverrouiller", systemImage: "lock.open")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).disabled(store.authenticating)
                    }
                    Button { importing = true } label: {
                        Label(store.hasConnection ? "Remplacer la connexion" : "Connecter mon studio", systemImage: "iphone.and.arrow.forward")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered)
                    Button("Explorer la démonstration") { store.exploreDemo() }
                        .frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("exploreDemo")
                    if let message = store.message { Text(message).foregroundStyle(.red).font(.callout) }
                    Label("Connexions protégées sur cet iPhone. Aucun compte à créer pour ton usage personnel.", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(Color.readableSecondary)
                }.padding(24)
            }.navigationTitle("GameMetrik")
                .sheet(isPresented: $importing) { ConnectionImportScreen() }
        }
    }
}

struct ContextToolbar: ToolbarContent {
    @EnvironmentObject var store: MobileStore
    var gameID: String?
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Période", selection: $store.range) {
                    ForEach(Timeframe.allCases.filter { $0 != .all }) { Text($0.label).tag($0) }
                }
            } label: { Label(store.range.label, systemImage: "calendar").labelStyle(.titleAndIcon) }
                .accessibilityIdentifier("periodPicker")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { store.synchronize(gameID: gameID) } label: { Label("Synchroniser", systemImage: "arrow.clockwise") }
                .disabled(store.loading).accessibilityIdentifier("sync")
        }
    }
}

struct WorkspaceCaption: View {
    @EnvironmentObject var store: MobileStore
    var generatedAt: String?
    var gameName: String?
    var period: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(store.workspaceLabel, systemImage: store.demo ? "flask" : "lock.shield")
            if let gameName { Text(gameName).fontWeight(.semibold) }
            Text(period ?? store.range.label).fontWeight(.medium)
            if let date = generatedAt.flatMap(Dates.parse) {
                Text("Données du \(date.formatted(date: .abbreviated, time: .shortened))")
            }
        }.font(.caption).foregroundStyle(Color.readableSecondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SyncEmpty: View {
    @EnvironmentObject var store: MobileStore
    var gameID: String?
    var title = "Prêt à consulter ton studio"
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "chart.bar.xaxis")
        } description: {
            Text("Synchronise pour lire cette période. Les données déjà reçues restent consultables hors ligne ; les joueurs restent en mémoire.")
        } actions: {
            Button("Synchroniser") { store.synchronize(gameID: gameID) }.buttonStyle(.borderedProminent).disabled(store.loading)
        }
    }
}

struct SyncErrors: View {
    var messages: [String]
    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Synchronisation incomplète", systemImage: "exclamationmark.triangle").font(.headline)
                ForEach(Array(messages.enumerated()), id: \.offset) { _, text in Text(text).font(.callout) }
                Text("Les données précédentes gardent leur date. Utilise Synchroniser pour réessayer.").font(.caption)
            }.foregroundStyle(Color(uiColor: .label)).padding(.vertical, 8)
        }
    }
}
