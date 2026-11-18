import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
import GameMetrikCore

struct MobileTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct MobileTransferView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var document: MobileTransferDocument?
    @State private var saving = false
    @State private var preparing = false
    @State private var message: String?
    private var minutes: Int { Int(MobileConnectionTransfer.lifetime / 60) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connecter mon iPhone").font(.title2.bold())
            Text("Ce transfert copie tes connexions d’Administration personnelle. L’iPhone pourra lire directement les mêmes sources, même avec le Mac éteint. Il ne crée pas de compte membre et ne réduit pas les droits des clés.")
            Text("Le fichier est chiffré et s’importe pendant \(minutes) minutes. Le code ne quitte jamais cet écran : l’iPhone le lit en scannant le QR code. Supprime le fichier après l’import.").foregroundStyle(.secondary)
            if let document {
                HStack(alignment: .top, spacing: 18) {
                    if let qr = Self.qrImage(MobileConnectionTransfer.scanText(for: code)) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 180, height: 180)
                            .accessibilityLabel("QR code du transfert, à scanner avec l’iPhone").privacySensitive()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Code de transfert").font(.headline)
                        Text("Scanne ce QR code dans l’app iPhone. Si la caméra n’est pas disponible, recopie le code à la main : il n’est pas sélectionnable, pour ne jamais passer par le presse-papiers.").font(.callout).foregroundStyle(.secondary)
                        Text(code).font(.body.monospaced()).privacySensitive()
                    }
                }
                Button("Enregistrer le fichier chiffré…") { saving = true }.buttonStyle(.borderedProminent)
                    .fileExporter(isPresented: $saving, document: document, contentType: .data, defaultFilename: "GameMetrik-iPhone.gmconnection") { result in
                        switch result {
                        case .success: message = "Envoie ce fichier à ton iPhone, puis ouvre Réglages → Importer une connexion dans l’app iOS et scanne le QR code."
                        case .failure: message = "Le fichier n’a pas pu être enregistré. Réessaie."
                        }
                    }
            } else {
                Button {
                    preparing = true
                    Task {
                        defer { preparing = false }
                        do {
                            let prepared = try await state.prepareMobileTransfer()
                            code = prepared.code; document = .init(data: prepared.data); message = nil
                        } catch { message = error.localizedDescription }
                    }
                } label: {
                    if preparing { ProgressView("Confirmation de ton identité…") } else { Text("Préparer le transfert chiffré") }
                }.buttonStyle(.borderedProminent).disabled(state.isLocked || preparing)
                Text("Ton mot de passe du Mac ou Touch ID sera demandé à nouveau.").font(.callout).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 560)
            .onChange(of: state.isLocked) { _, locked in if locked { code = ""; document = nil; dismiss() } }
            .onDisappear { code = ""; document = nil }
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
