import AppKit
import GameMetrikCore

/// The AI folder is opt-in: a folder chosen once by the owner, kept as a security-scoped bookmark.
extension AppState {
    static let aiFolderBookmarkKey = "ai.folder.bookmark"

    func resolveAIFolder() -> URL? { Self.resolveAIFolderURL() }

    static func resolveAIFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.aiFolderBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.aiFolderBookmarkKey)
        }
        return url
    }

    func loadAIFolderPreference() {
        let chosen = resolveAIFolder()
        aiFolderPath = chosen.map { AIFolder.root(forChosen: $0).path }
        guard !headless, Bundle.main.bundleURL.pathExtension == "app", let chosen else { return }
        let scoped = chosen.startAccessingSecurityScopedResource()
        defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }
        try? AIFolder(root: AIFolder.root(forChosen: chosen)).updateRefreshScript(appPath: Bundle.main.bundlePath)
    }

    /// Explicit Settings action. Writes the views already loaded right away, without any network read.
    func chooseAIFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.prompt = "Utiliser ce dossier"
        panel.message = "Choisis où créer le dossier « \(AIFolder.folderName) ». Il recevra les statistiques agrégées après chaque synchronisation."
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                if let previous = self.resolveAIFolder(), AIFolder.root(forChosen: previous) != AIFolder.root(forChosen: url) {
                    let scoped = previous.startAccessingSecurityScopedResource()
                    defer { if scoped { previous.stopAccessingSecurityScopedResource() } }
                    try? AIFolder(root: AIFolder.root(forChosen: previous)).removeToken()
                }
                let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: Self.aiFolderBookmarkKey)
                self.aiFolderPath = AIFolder.root(forChosen: url).path
                self.aiFolderMessage = "Dossier IA activé. Il sera mis à jour à la prochaine synchronisation."
                // The trigger token follows the folder, so the assistant still finds it.
                if self.aiSyncEnabled, let token = try? AIVault.read()?.token {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try? AIFolder(root: AIFolder.root(forChosen: url)).writeToken(token, appPath: Bundle.main.bundlePath)
                }
                if self.canExport { self.publishAIFolder(gameIDs: [self.gameID]) }
            } catch {
                self.aiFolderMessage = "Impossible d’enregistrer ce dossier : " + error.localizedDescription
            }
        }
    }

    func disableAIFolder(removeContents: Bool) {
        disableAISync()
        let chosen = resolveAIFolder()
        UserDefaults.standard.removeObject(forKey: Self.aiFolderBookmarkKey)
        aiFolderPath = nil
        guard removeContents, let chosen else { aiFolderMessage = "Dossier IA désactivé. Son contenu est conservé."; return }
        aiFolderMessage = removeAIFolderContents(chosen) ?? "Dossier IA désactivé et son contenu supprimé."
    }

    /// Returns an error message, or nil once only the files written by GameMetrik are removed.
    @discardableResult func removeAIFolderContents(_ chosen: URL? = nil) -> String? {
        guard let chosen = chosen ?? resolveAIFolder() else { return nil }
        let scoped = chosen.startAccessingSecurityScopedResource()
        defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }
        do { try AIFolder(root: AIFolder.root(forChosen: chosen)).removeContents(); return nil }
        catch { return "Suppression du dossier IA impossible : " + error.localizedDescription }
    }

    func revealAIFolder() {
        guard let chosen = resolveAIFolder() else { return }
        let root = AIFolder.root(forChosen: chosen)
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: root.path) ? root : chosen])
    }

    /// Called after a successful manual synchronization. Only aggregated views already in memory are written;
    /// a game whose views all failed keeps its previous snapshot.
    func publishAIFolder(gameIDs: [String]) {
        guard let chosen = resolveAIFolder(), !isLocked, demo || hasLiveIdentity else { return }
        let timeframe = range, isDemo = demo, now = Date()
        let exports: [(DataExport, String?)] = gameIDs.compactMap { id in
            guard let report = try? makeExport(scope: .available, now: now, target: id),
                  report.tables.contains(where: { !["catalogue", "export_bilan"].contains($0.id) }) else { return nil }
            return (report, games.first { $0.id == id }?.slug)
        }
        guard !exports.isEmpty else { return }
        let names = exports.map(\.0.gameName).joined(separator: ", ")
        aiFolderWrite = Task.detached(priority: .utility) { [weak self] in
            let scoped = chosen.startAccessingSecurityScopedResource()
            defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }
            let folder = AIFolder(root: AIFolder.root(forChosen: chosen))
            var failure: String?
            for (report, slug) in exports {
                do { try folder.write(report, gameSlug: slug, timeframe: timeframe, demo: isDemo, now: now) }
                catch { failure = error.localizedDescription }
            }
            let message = failure.map { "Dossier IA non mis à jour : " + $0 }
                ?? "Dossier IA mis à jour · " + names + " · " + timeframe.label + (isDemo ? " · démonstration" : "") + " · " + now.formatted(date: .omitted, time: .shortened)
            await MainActor.run { self?.aiFolderMessage = message }
        }
    }
}
