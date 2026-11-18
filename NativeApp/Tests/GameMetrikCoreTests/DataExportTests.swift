import Foundation
import Testing
@testable import GameMetrikCore

struct DataExportTests {
    let now = Dates.parse("2026-09-09T12:00:00Z")!
    func report() -> DataExport {
        DataExport(now: now, mode: "Démonstration", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "7 jours", scope: "Toutes les données disponibles")
    }
    @Test func dashboardPreservesPrecisionCoverageAndUnknowns() throws {
        var dashboard = Demo.dashboard(range: .week, gameID: "aurora-grove", now: now)
        dashboard.trend[0].revenue = 0.00012345
        dashboard.trend[1].revenueAvailable = false
        dashboard.trend[2].revenue = 0
        dashboard.kpis[0].state = "unknown"; dashboard.kpis[0].value = 999
        dashboard.kpis[1].coverage = .init(status: "partial", availableDays: 3, expectedDays: 7)
        dashboard.kpis.removeAll { $0.id == "adImpressions" }
        var export = report(); export.addDashboard(dashboard)
        let object = try #require(JSONSerialization.jsonObject(with: export.jsonData()) as? [String: Any])
        let tables = try #require(object["tables"] as? [[String: Any]])
        let history = try #require(tables.first { $0["id"] as? String == "studio_historique" })
        let rows = try #require(history["rows"] as? [[String: Any]])
        #expect(rows[0]["revenue"] as? Double == 0.00012345)
        #expect(rows[1]["revenue"] is NSNull)
        #expect(rows[2]["revenue"] as? Double == 0)
        #expect(history["currency"] as? String == "CHF")
        #expect(history["generatedAt"] as? String == Dates.iso(now))
        let kpis = try #require(tables.first { $0["id"] as? String == "studio_indicateurs" }?["rows"] as? [[String: Any]])
        #expect(kpis.first { $0["id"] as? String == "installs" }?["value"] is NSNull)
        #expect(kpis.first { $0["id"] as? String == "newPlayers" }?["available_days"] as? Int == 3)
        #expect(kpis.first { $0["id"] as? String == "adImpressions" }?["value"] is NSNull)
        #expect(export.tables.first { $0.id == "studio_historique" }?.rows.count == 7)
    }
    @Test func csvEscapesMultilineTextAndNeutralizesFormulasOnlyInText() throws {
        var export = report()
        export.add("test", "Test", ["text", "value", "missing"], [[.text("Été, \"bleu\"\nvert"), .number(-0.123456789), .null], [.text("  =HYPERLINK(\"https://example.invalid\")"), .number(42), .null], [.text("\t@SUM(1)"), .number(0), .null]])
        let table = try #require(export.tables.first)
        let text = String(decoding: table.csvData(), as: UTF8.self)
        #expect(text.hasPrefix("\u{FEFF}"))
        #expect(text.contains("\"Été, \"\"bleu\"\"\nvert\",-0.123456789,\r\n"))
        #expect(text.contains("\"'  =HYPERLINK"))
        #expect(text.contains("\"'\t@SUM(1)\""))
        let object = try #require(JSONSerialization.jsonObject(with: export.jsonData()) as? [String: Any])
        let rows = try #require((object["tables"] as? [[String: Any]])?.first?["rows"] as? [[String: Any]])
        #expect(rows[1]["text"] as? String == "  =HYPERLINK(\"https://example.invalid\")")
    }
    @Test func exportsComputedPlayerDetailsAndCatalogueWithoutConnectionFields() throws {
        let game = Demo.games[0], directory = try Demo.directory(range: .week, game: Demo.games[0], now: now)
        var export = report(); export.addDirectory(directory, includePlayers: true, jardin: true, timezone: "Europe/Zurich")
        var configuredGame = game
        configuredGame.integrations.admobAppId = "private-admob-connection-marker"
        configuredGame.integrations.supabaseProjectRef = "private-project-marker"
        export.addGames([configuredGame], generatedAt: now)
        let json = String(decoding: try export.jsonData(), as: UTF8.self)
        #expect(!json.contains("private-admob-connection-marker")); #expect(!json.contains("private-project-marker"))
        #expect(!json.contains("user_id")); #expect(!json.contains("run_id")); #expect(!json.contains("access_token"))
        #expect(export.tables.first { $0.id == "joueurs" }?.rows.count == directory.players.count)
        #expect(export.tables.first { $0.id == "joueurs_historique" }?.rows.count == directory.players.reduce(0) { $0 + $1.trend.count })
        #expect(json.contains(directory.players[0].id))
        var gameplay = report(); gameplay.addDirectory(directory, includePlayers: false, jardin: false, timezone: nil)
        #expect(!gameplay.tables.contains { $0.id.hasPrefix("joueurs") })
        #expect(!String(decoding: try gameplay.jsonData(), as: UTF8.self).contains(directory.players[0].id))
    }
    @Test func dossierRoundTripContainsEveryTableAndGuide() throws {
        var export = report(); export.addDashboard(Demo.dashboard(range: .week, gameID: "aurora-grove", now: now)); export.addReviews([], generatedAt: now)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        try export.fileWrapper().write(to: parent, options: .atomic, originalContentsURL: nil)
        #expect(try Data(contentsOf: parent.appendingPathComponent("rapport.json")) == export.jsonData())
        for table in export.tables { #expect(try Data(contentsOf: parent.appendingPathComponent(table.id + ".csv")) == table.csvData()) }
        let readme = try String(contentsOf: parent.appendingPathComponent("LIRE-MOI.md"), encoding: .utf8)
        #expect(readme.contains("Démonstration")); #expect(readme.contains("null"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).count == export.tables.count + 2)
    }
    @Test func invalidTableIsRejectedWithoutTrapping() {
        var export = report(); export.add("test", "Test", ["duplicate", "duplicate"], [[.number(1), .number(2)]])
        #expect(throws: GameMetrikError.self) { try export.fileWrapper() }
        var path = report(); path.add("../outside", "Invalid", ["value"], [[.number(1)]])
        #expect(throws: GameMetrikError.self) { try path.fileWrapper() }
    }
    @Test func sourceAuditPreservesCachedDatesAndDistinguishesMissingFromZero() throws {
        let window = try SyncWindow(range: .week, now: now)
        let oldDate = now.addingTimeInterval(-86400)
        var cache = AggregateCache()
        cache.reports["aurora-grove/admob"] = [window.days[0]: CachedFinancialDay(value: FinancialDay(money: ["CHF": 1], adImpressions: 12), fetchedAt: oldDate)]
        let fresh = ProviderReport(gameID: "aurora-grove", provider: "admob", title: "AdMob", days: [window.days[1]: FinancialDay(money: ["CHF": 0], adImpressions: 0)], note: "", pendingDays: [window.end], hasError: true, timezone: "Europe/Zurich")
        let merged = cache.merge(fresh, window: window)
        let dashboard = NativeDashboardSync.dashboard(games: [Demo.games[0]], gameID: "aurora-grove", range: .week, window: window, reports: [merged], engagement: [:], alerts: [])
        let days = try #require(dashboard.sourceDays)
        #expect(days.count == 7)
        #expect(days[0].status == "cached"); #expect(days[0].readAt == Dates.iso(oldDate))
        #expect(days[1].status == "received"); #expect(days[1].readAt == Dates.iso(now))
        #expect(days[1].adImpressions == 0); #expect(days[1].revenueCHF == 0)
        #expect(days[2].status == "missing"); #expect(days[2].adImpressions == nil)
        #expect(days.last?.status == "pending"); #expect(days.last?.revenueCHF == nil)
        var export = report(); export.addDashboard(dashboard); export.missingViews = ["Avis"]; export.finishChecks()
        #expect(export.checks.contains { $0.section == "admob" && $0.status == "partial" && $0.detail.contains(window.end) })
        #expect(export.checks.contains { $0.section == "Avis" && $0.status == "not_loaded" })
        #expect(export.tables.first { $0.id == "studio_jours_sources" }?.rows.count == 7)
        #expect(export.readme.contains("cached = conservé du cache"))
        let encoded = try JSONEncoder().encode(Demo.dashboard(range: .week, gameID: "aurora-grove", now: now))
        #expect(try JSONDecoder().decode(Dashboard.self, from: encoded).sourceDays == nil)
    }

}
