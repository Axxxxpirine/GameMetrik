import SwiftUI
import UniformTypeIdentifiers
import VisionKit
import GameMetrikCore

struct MobileSettings: View {
    @EnvironmentObject var store: MobileStore
    @State private var importing = false
    @State private var removing = false
    var body: some View {
        Form {
            Section("Espace") {
                Text(store.workspaceLabel)
                Button("Importer une connexion du Mac…") { importing = true }
                if store.demo { Button("Quitter la démonstration") { store.exitDemo() } }
                else { Button("Verrouiller maintenant") { store.lock() } }
            }
            Section("Confidentialité") {
                LabeledContent("Déverrouillage", value: "Face ID ou code iPhone")
                Text("Les connexions restent dans le trousseau de cet iPhone, sans synchronisation iCloud. L’app se verrouille en arrière-plan.")
                Text("Seuls les agrégats du tableau de bord sont mis en cache sous chiffrement. Les profils et parties restent en mémoire. Les cinq rapports Ballpark doivent être relus après un verrouillage.")
            }.font(.callout)
            Section("Synchronisation") {
                Text("Synchroniser relit le jeu et la période affichés. Dans Studio, l’action actualise la vue agrégée. Ouvrir une rubrique ne lance aucun appel réseau.")
                Text("Garde l’app ouverte pendant la collecte. Les données absentes ne sont jamais remplacées par zéro ni par des chiffres de démonstration.")
            }.font(.callout)
            if !store.demo {
                Section {
                    Button("Retirer les connexions de cet iPhone", role: .destructive) { removing = true }
                }
            }
            Section("À propos") { LabeledContent("GameMetrik pour iPhone", value: "0.1.0"); Text("Usage personnel · consultation").foregroundStyle(Color.readableSecondary) }
            if let message = store.message { Section { Text(message).foregroundStyle(.red) } }
        }.navigationTitle("Réglages")
            .sheet(isPresented: $importing) { ConnectionImportScreen() }
            .confirmationDialog("Retirer les connexions ?", isPresented: $removing, titleVisibility: .visible) {
                Button("Retirer de cet iPhone", role: .destructive) { store.removeConnection() }
            } message: { Text("Les connexions et le cache local seront supprimés. Les données et les accès distants ne changent pas.") }
    }
}

struct ConnectionImportScreen: View {
    @EnvironmentObject var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var picking = false
    @State private var scanning = false
    @State private var data: Data?
    @State private var source: URL?
    @State private var code = ""
    @State private var error: String?
    @State private var consent = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Depuis GameMetrik sur le Mac") {
                    Text("Dans Réglages → Connexions, choisis Connecter mon iPhone. Prépare le fichier chiffré et envoie-le à ton iPhone, par exemple avec AirDrop.")
                    Text("Le fichier s’importe pendant \(Int(MobileConnectionTransfer.lifetime / 60)) minutes. Le code s’affiche en QR code sur le Mac : scanne-le ici, sans le copier ni l’envoyer.").foregroundStyle(Color.readableSecondary)
                }
                Section("Transfert") {
                    Button { picking = true } label: { Label(data == nil ? "Choisir le fichier chiffré" : "Fichier sélectionné · changer", systemImage: "doc.badge.arrow.up") }
                    if TransferCodeScanner.isAvailable {
                        Button { scanning = true } label: { Label(code.count == 43 ? "Code scanné · scanner à nouveau" : "Scanner le QR code du Mac", systemImage: "qrcode.viewfinder") }
                    }
                    SecureField(TransferCodeScanner.isAvailable ? "Ou saisis le code à la main" : "Code de transfert du Mac", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    Toggle("C’est mon iPhone personnel", isOn: $consent)
                    Text("Ce transfert reprend une identité administrateur, distincte d’un compte membre. Les clés gardent leurs droits actuels. Ne l’importe que sur ton propre iPhone.").font(.caption).foregroundStyle(Color.readableSecondary)
                }
                Section {
                    Button {
                        guard let data else { return }
                        Task {
                            if await store.importConnection(data: data, code: code) {
                                removeImportedFile(); code = ""; self.data = nil; dismiss()
                            }
                        }
                    } label: {
                        if store.authenticating { ProgressView("Protection du trousseau…") }
                        else { Text("Enregistrer et connecter") }
                    }.disabled(data == nil || code.count != 43 || !consent || store.authenticating)
                }
                if let error = error ?? store.message { Section { Text(error).foregroundStyle(.red) } }
                Section { Text("Après l’import, l’app supprime le fichier transféré quand iOS le permet ; sinon, supprime-le dans Fichiers. Puis appuie sur Synchroniser dans Studio.").font(.footnote).foregroundStyle(Color.readableSecondary) }
            }.navigationTitle("Connecter mon studio").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } } }
                .fileImporter(isPresented: $picking, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                    do {
                        guard let url = try result.get().first else { return }
                        let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                        guard size <= MobileConnectionTransfer.maximumSize else { throw GameMetrikError.message("Ce fichier est trop volumineux.") }
                        data = try Data(contentsOf: url); source = url; error = nil
                    } catch { self.error = "Le fichier n’a pas pu être lu. Choisis le transfert .gmconnection préparé sur le Mac." }
                }
                .sheet(isPresented: $scanning) {
                    NavigationStack {
                        TransferCodeScanner { scanned in code = scanned; scanning = false }
                            .ignoresSafeArea()
                            .navigationTitle("QR code du Mac").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { scanning = false } } }
                    }
                }
                .onChange(of: phase) { _, phase in if phase == .background { code = ""; data = nil; source = nil; dismiss() } }
        }
    }

    /// The encrypted file is useless once imported: remove it so it does not linger in Files or a backup.
    private func removeImportedFile() {
        guard let source else { return }
        let granted = source.startAccessingSecurityScopedResource(); defer { if granted { source.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.removeItem(at: source)
        self.source = nil
    }
}

/// Reads the QR code the Mac shows, and only a GameMetrik transfer code: the code never goes through the clipboard.
struct TransferCodeScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue,
                   let code = MobileConnectionTransfer.code(fromScanned: text) {
                    dataScanner.stopScanning(); onCode(code); return
                }
            }
        }
    }
}
