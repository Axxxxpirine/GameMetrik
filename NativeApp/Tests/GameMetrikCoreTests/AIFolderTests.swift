import Foundation
import Testing
@testable import GameMetrikCore

struct AIFolderTests {
    let now = Dates.parse("2026-10-15T08:00:00Z")!
    func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ai-folder-" + UUID().uuidString, isDirectory: true)
    }
    func export(game: Game) throws -> DataExport {
        var export = DataExport(now: now, mode: "Administration personnelle", gameID: game.id, gameName: game.name, timeframe: "7 jours (7d)", scope: "Toutes les données disponibles")
        export.addDashboard(Demo.dashboard(range: .week, gameID: game.id, now: now))
        export.addDirectory(try Demo.directory(range: .week, game: game, now: now), includePlayers: true, jardin: false, timezone: "Europe/Zurich")
        export.finishChecks()
        return export
    }

    @Test func writesAggregatesOnlyWithIndexAndGuides() throws {
        let parent = temporaryRoot(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = AIFolder.root(forChosen: parent)
        #expect(root.lastPathComponent == AIFolder.folderName)
        #expect(AIFolder.root(forChosen: root) == root)
        let game = Demo.games[0]
        let snapshot = try AIFolder(root: root).write(try export(game: game), gameSlug: game.slug, timeframe: .week, demo: false, now: now)
        #expect(snapshot.path == "donnees/" + game.slug + "/7d")
        let folder = root.appendingPathComponent(snapshot.path)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.contains("studio_indicateurs.csv")); #expect(files.contains("rapport.json")); #expect(files.contains("LIRE-MOI.md"))
        #expect(!files.contains { $0.hasPrefix("joueurs") })
        #expect(!snapshot.tables.contains { AIFolder.playerTables.contains($0) })
        let json = try String(contentsOf: folder.appendingPathComponent("rapport.json"), encoding: .utf8)
        #expect(!json.contains("\"public_id\""))
        let index = try AIFolder(root: root).readIndex()
        #expect(index.snapshots == [snapshot])
        let guide = try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(guide.contains("| " + game.name + " | 7 jours (`7d`)"))
        #expect(guide.contains("lecture seule"))
        #expect(try String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8).hasPrefix("@AGENTS.md"))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".ecriture-") })
    }

    @Test func replacesTheSameSnapshotAndKeepsDemoSeparate() throws {
        let root = AIFolder.root(forChosen: temporaryRoot()); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let folder = AIFolder(root: root), game = Demo.games[0]
        try folder.write(try export(game: game), gameSlug: game.slug, timeframe: .week, demo: false, now: now)
        let stale = root.appendingPathComponent("donnees/" + game.slug + "/7d/ancien.csv")
        try Data("x".utf8).write(to: stale)
        let later = now.addingTimeInterval(3600)
        try folder.write(try export(game: game), gameSlug: game.slug, timeframe: .week, demo: false, now: later)
        try folder.write(try export(game: game), gameSlug: game.slug, timeframe: .week, demo: true, now: later)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let index = try folder.readIndex()
        #expect(index.snapshots.count == 2)
        #expect(index.snapshots.first { !$0.demo }?.synchronizedAt == Dates.iso(later))
        #expect(index.snapshots.last?.path == "demonstration/" + game.slug + "/7d")
        let guide = try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(guide.contains("Démonstration (données fictives)"))
    }

    @Test func removalKeepsFilesTheAppDidNotWrite() throws {
        let root = AIFolder.root(forChosen: temporaryRoot()); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let folder = AIFolder(root: root), game = Demo.games[0]
        try folder.write(try export(game: game), gameSlug: game.slug, timeframe: .week, demo: false, now: now)
        let notes = root.appendingPathComponent("mes-notes.md")
        try Data("analyse".utf8).write(to: notes)
        try folder.removeContents()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["mes-notes.md"])
        try FileManager.default.removeItem(at: notes)
        try folder.write(try export(game: game), gameSlug: game.slug, timeframe: .week, demo: false, now: now)
        try folder.removeContents()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func pathsAreSlugged() {
        #expect(AIFolder.relativePath(gameSlug: "Aurora Gröve!", timeframe: .year, demo: false) == "donnees/aurora-grove/1y")
        #expect(AIFolder.relativePath(gameSlug: nil, timeframe: .month, demo: true) == "demonstration/studio/30d")
        #expect(AIFolder.relativePath(gameSlug: "../..", timeframe: .today, demo: false) == "donnees/jeu/today")
    }
}

struct AISyncRequestTests {
    let token = String(repeating: "a1", count: 32)
    @Test func parsesBoundedRequests() throws {
        let url = URL(string: "gamemetrik-native://synchroniser?jeton=\(token)&jeu=aurora-grove&periodes=7d,30d,7d&demande=ia-1")!
        let request = try #require(AISyncRequest.parse(url))
        #expect(request.game == "aurora-grove"); #expect(request.timeframes == [.week, .month]); #expect(request.request == "ia-1")
        #expect(request.matches(token)); #expect(!request.matches(token.uppercased())); #expect(!request.matches("a1"))
        let all = try #require(AISyncRequest.parse(URL(string: "gamemetrik-native://synchroniser?jeton=\(token)&jeu=tous")!))
        #expect(all.game == nil); #expect(all.timeframes == [.week, .month, .quarter])
    }
    @Test func rejectsForeignOrUnsafeRequests() {
        for raw in ["https://synchroniser?jeton=\(token)", "gamemetrik-native://autre?jeton=\(token)",
                    "gamemetrik-native://synchroniser?jeton=court", "gamemetrik-native://synchroniser?jeton=\(token)&periodes=all",
                    "gamemetrik-native://synchroniser?jeton=\(token)&periodes=", "gamemetrik-native://synchroniser?jeton=\(token)&jeu=../x",
                    "gamemetrik-native://synchroniser?jeton=\(token)&demande=a%20b"] {
            #expect(AISyncRequest.parse(URL(string: raw)!) == nil, "\(raw)")
        }
        #expect(AISyncRequest.newToken().count == 64)
        #expect(AISyncRequest.newToken() != AISyncRequest.newToken())
    }
    @Test func tokenScriptAndStatusStayPrivateAndRemovable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-sync-" + UUID().uuidString).appendingPathComponent(AIFolder.folderName)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let folder = AIFolder(root: root)
        try folder.writeToken(token, appPath: "/Applications/Game'Metrik Native.app")
        let tokenFile = root.appendingPathComponent(AIFolder.tokenName), script = root.appendingPathComponent(AIFolder.scriptName)
        #expect(try String(contentsOf: tokenFile, encoding: .utf8) == token)
        #expect((try FileManager.default.attributesOfItem(atPath: tokenFile.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int) == 0o700)
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains(#"APP='/Applications/Game'\''Metrik Native.app'"#)); #expect(!text.contains(token))
        let check = Process(); check.executableURL = URL(fileURLWithPath: "/bin/bash"); check.arguments = ["-n", script.path]
        try check.run(); check.waitUntilExit(); #expect(check.terminationStatus == 0)
        try folder.updateRefreshScript(appPath: "/Applications/GameMetrik Native.app")
        #expect(try String(contentsOf: tokenFile, encoding: .utf8) == token)
        #expect(try String(contentsOf: script, encoding: .utf8).contains("APP='/Applications/GameMetrik Native.app'"))
        try folder.writeStatus(.init(state: "en_cours", request: "ia-1", startedAt: "2026-10-15T08:00:00Z", message: "En cours"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("synchronisation.json").path))
        try folder.removeToken()
        #expect(!FileManager.default.fileExists(atPath: tokenFile.path)); #expect(!FileManager.default.fileExists(atPath: script.path))
        try folder.updateRefreshScript(appPath: "/Applications/GameMetrik Native.app")
        #expect(!FileManager.default.fileExists(atPath: script.path))
        try folder.removeContents()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

extension AISyncRequestTests {
    @Test(arguments: [true, false])
    func refreshScriptResolvesMovedAppsWithoutActivatingOrPrintingTokens(appExists: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-launch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("Game'Metrik Native.app")
        if appExists { try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true) }
        try Data(token.utf8).write(to: root.appendingPathComponent(AIFolder.tokenName))
        let script = AIFolder.refreshScript(appPath: app.path)
        let boundary = try #require(script.range(of: #"if [ "${1:-}" = "--attendre" ]; then"#))
        // Intercept open inside the shell. No application or real credential is touched.
        let stub = #"""
        open() {
          [ "$1" = -g ] && [ "$2" = "$EXPECTED_FLAG" ] && [ "$3" = "$EXPECTED_TARGET" ] || return 91
          case "$4" in gamemetrik-native://synchroniser\?jeton=*) return 0;; *) return 92;; esac
        }
        """#
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", stub + "\n" + script[..<boundary.lowerBound] + "\nGAME=ballpark; PERIODS=7d; REQ=test; send", root.appendingPathComponent("actualiser.sh").path]
        var environment = ProcessInfo.processInfo.environment
        environment["EXPECTED_FLAG"] = appExists ? "-a" : "-b"
        environment["EXPECTED_TARGET"] = appExists ? app.path : "ch.gamemetrik.native"
        process.environment = environment
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
