import AppKit
import GameMetrikCore

/// Receives gamemetrik-native://synchroniser requests from Claude or Codex.
/// The window stays locked: a separate, never-displayed AppState reads the providers with the AI copy
/// of the connections, then writes the AI folder and synchronisation.json.
@MainActor final class AIRemoteSync {
    static let shared = AIRemoteSync()
    private var running: Task<Void, Never>?

    func handle(_ url: URL) {
        // Malformed URLs (or any other scheme use) are ignored without a trace.
        guard let request = AISyncRequest.parse(url), let chosen = AppState.resolveAIFolderURL() else { return }
        let folder = AIFolder(root: AIFolder.root(forChosen: chosen))
        let started = Dates.iso(Date())
        guard let bundle = try? AIVault.read() else {
            write(.init(state: "refusee", request: request.request, startedAt: started, finishedAt: started,
                        message: "Synchronisation par l’IA désactivée. Active-la dans GameMetrik → Réglages → Général → Dossier pour l’IA."), folder, chosen)
            return
        }
        guard request.matches(bundle.token) else {
            write(.init(state: "refusee", request: request.request, startedAt: started, finishedAt: started,
                        message: "Jeton invalide. Relis le fichier .jeton-synchronisation du dossier IA."), folder, chosen)
            return
        }
        // One synchronization at a time; the caller waits for the current one in synchronisation.json.
        guard running == nil else { return }
        running = Task { [weak self] in
            await self?.run(request, bundle: bundle, folder: folder, chosen: chosen, started: started)
            self?.running = nil
        }
    }

    private func run(_ request: AISyncRequest, bundle: AISyncBundle, folder: AIFolder, chosen: URL, started: String) async {
        let worker = AppState(headless: true)
        defer { worker.lock() }
        worker.startHeadless(bundle)
        worker.destination = .dashboard
        var status = AISyncStatus(state: "en_cours", request: request.request, startedAt: started, message: "Synchronisation demandée par l’IA en cours.")
        write(status, folder, chosen)
        var resolved = request.game
        periods: for timeframe in request.timeframes {
            // Without a game: the studio first (it reads the catalog), then every game of the catalog.
            var queue = resolved.map { [$0] } ?? ["all"]
            var expanded = false
            while !queue.isEmpty {
                let id = queue.removeFirst()
                guard !worker.isLocked else {
                    status.steps.append(.init(game: id, timeframe: timeframe.rawValue, status: "echec", detail: "Mac en veille ou session verrouillée : synchronisation interrompue."))
                    break periods
                }
                worker.gameID = id; worker.range = timeframe
                let task = worker.synchronizeSelection()
                await task?.value
                await worker.aiFolderWrite?.value; worker.aiFolderWrite = nil
                // An id absent from the catalog sends the instance back to the studio: match a slug or name once.
                if id != "all", worker.gameID != id {
                    if let match = worker.games.first(where: { [$0.slug.lowercased(), AIFolder.slug($0.name)].contains(id.lowercased()) }), match.id != id {
                        resolved = match.id; queue.insert(match.id, at: 0); continue
                    }
                    status.steps.append(.init(game: id, timeframe: timeframe.rawValue, status: "echec",
                        detail: worker.error ?? ("Jeu inconnu. Jeux disponibles : " + worker.games.map(\.id).joined(separator: ", "))))
                    break periods
                }
                let name = worker.games.first { $0.id == id }?.name ?? (id == "all" ? "Tout le studio" : id == Game.ballpark.id ? Game.ballpark.name : id)
                let failures = worker.studioSyncResults.filter { ["failed", "not_connected", "partial"].contains($0.status) }
                if let error = worker.error {
                    status.steps.append(.init(game: name, timeframe: timeframe.rawValue, status: "echec", detail: error))
                } else if !failures.isEmpty {
                    status.steps.append(.init(game: name, timeframe: timeframe.rawValue, status: "partielle", detail: failures.map { $0.section + " : " + $0.detail }.joined(separator: " ; ")))
                } else {
                    status.steps.append(.init(game: name, timeframe: timeframe.rawValue, status: "terminee", detail: worker.studioSyncSummary ?? "Synchronisation terminée."))
                }
                if let message = worker.aiFolderMessage, message.hasPrefix("Dossier IA non mis à jour") {
                    status.steps.append(.init(game: name, timeframe: timeframe.rawValue, status: "echec", detail: message))
                }
                status.message = "Synchronisation demandée par l’IA en cours · " + name + " · " + timeframe.label
                write(status, folder, chosen)
                if resolved == nil, id == "all", !expanded {
                    expanded = true; queue += worker.games.map(\.id)
                }
            }
        }
        let failed = status.steps.filter { $0.status == "echec" }.count
        status.state = status.steps.isEmpty || failed == status.steps.count ? "echec" : status.steps.contains { $0.status != "terminee" } ? "partielle" : "terminee"
        status.finishedAt = Dates.iso(Date())
        status.message = status.state == "terminee" ? "Synchronisation terminée ; le dossier IA est à jour."
            : status.state == "partielle" ? "Synchronisation partielle ; voir le détail de chaque étape."
            : "Synchronisation impossible ; voir le détail de chaque étape."
        write(status, folder, chosen)
    }

    private func write(_ status: AISyncStatus, _ folder: AIFolder, _ chosen: URL) {
        let scoped = chosen.startAccessingSecurityScopedResource()
        defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }
        try? folder.writeStatus(status)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { for url in urls { AIRemoteSync.shared.handle(url) } }
    }
}
