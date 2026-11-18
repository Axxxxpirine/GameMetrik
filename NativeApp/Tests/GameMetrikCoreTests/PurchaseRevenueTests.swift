import Foundation
import Testing
@testable import GameMetrikCore

struct PurchaseRevenueTests {
    let now = Dates.parse("2026-09-13T09:16:00Z")!
    let header = "Apple Identifier\tParent Identifier\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds\n"
    func apple(_ units: Int, currency: String = "USD", price: String = "3.50") throws -> FinancialDay {
        try NativeReports.appleDay(Data((header + "999\taurora\tIA1\t\(units)\t\(price)\t\(currency)\n").utf8), appID: "123", sku: "aurora")
    }
    func dashboard() throws -> Dashboard {
        let window = try SyncWindow(range: .month, now: now), game = Demo.games[0]
        var appleReport = ProviderReport(gameID: game.id, provider: "apple", title: "Apple", note: "", supportsInstalls: true, supportsIAP: true)
        appleReport.days = Dictionary(uniqueKeysWithValues: window.days.dropLast(2).map { ($0, FinancialDay(appleIAPNetUnits: 0)) })
        appleReport.days["2026-09-09"] = try apple(1)
        appleReport.days["2026-09-10"] = try apple(-1)
        appleReport.days["2026-09-11"] = try apple(1)
        appleReport.pendingDays = Set(window.days.suffix(2))
        var ads = ProviderReport(gameID: game.id, provider: "admob", title: "AdMob", note: "")
        ads.days = Dictionary(uniqueKeysWithValues: window.days.dropLast().map { ($0, FinancialDay(adImpressions: 0)) })
        ads.days["2026-09-11"] = FinancialDay(money: ["CHF": Decimal(string: "3.348997")!], adImpressions: 385)
        ads.pendingDays = [window.end]
        return NativeDashboardSync.dashboard(games: [game], gameID: game.id, range: .month, window: window, reports: [appleReport, ads], engagement: [game.id: Engagement(daily: ["2026-09-11": 5], monthly: 5, retained: 0, eligible: 0)], alerts: [])
    }
    @Test func purchasesRefundsAndFreeReportsKeepSignedUnitsIndependentOfCurrency() throws {
        #expect(try apple(1).appleIAPNetUnits == 1)
        #expect(try apple(-1).appleIAPNetUnits == -1)
        #expect(try apple(-1).iap["USD"] == Decimal(string: "-3.50"))
        #expect(try apple(1, price: "0").appleIAPNetUnits == 1)
        let text = header + "123\t\t1F\t8\t0\t\n999\taurora\tIA1\t2\t3.50\tUSD\n999\taurora\tIA1\t-1\t3.50\tUSD\n888\tother\tIA1\t50\t2\tUSD\n"
        let mixed = try NativeReports.appleDay(Data(text.utf8), appID: "123", sku: "aurora")
        #expect(mixed.appleIAPNetUnits == 1)
        #expect(mixed.installs == 8)
        #expect(mixed.iap["USD"] == Decimal(string: "3.50"))
        #expect(try NativeReports.appleDay(Data(header.utf8), appID: "123", sku: "aurora").appleIAPNetUnits == 0)
        let overflow = header + "999\taurora\tIA1\t\(Int.max)\t0\tUSD\n999\taurora\tIA1\t1\t0\tUSD\n"
        #expect(throws: GameMetrikError.self) { try NativeReports.appleDay(Data(overflow.utf8), appID: "123", sku: "aurora") }
    }
    @Test func screenshotScenarioShowsForeignReceiptsAndOneNetPurchaseWithIndependentCoverage() throws {
        let result = try dashboard()
        let total = try #require(result.kpis.first { $0.id == "revenue" })
        #expect(total.state == "available")
        #expect(total.value == nil) // A CHF scalar would require conversion.
        #expect(total.amountsByCurrency?["USD"] == 3.5)
        #expect(abs((total.amountsByCurrency?["CHF"] ?? 0) - 3.348997) < 1e-12)
        #expect(total.coverage?.availableDays == 28) // Foreign currency days ARE received.
        #expect(total.coverage?.status == "pending")
        let iap = try #require(result.kpis.first { $0.id == "iap" })
        #expect(iap.amountsByCurrency == ["USD": 3.5])
        let count = try #require(result.kpis.first { $0.id == "appleIAPNetUnits" })
        #expect(count.value == 1)
        #expect(count.coverage?.availableDays == 28)
        #expect(result.kpis.first { $0.id == "adImpressions" }?.coverage?.status == "pending")
        #expect(result.kpis.first { $0.id == "ads" }?.coverage?.availableDays == 29)
        #expect(result.trend.first { $0.date == "2026-09-10" }?.appleIAPNetUnits == -1)
        #expect(result.trend.first { $0.date == "2026-09-11" }?.revenueByCurrency?["USD"] == 3.5)
        #expect(result.trend.last?.appleIAPNetUnits == nil)
        let arpdau = try #require(result.kpis.first { $0.id == "arpdau" })
        #expect(arpdau.amountsByCurrency?["USD"] == 0.7)
        #expect(arpdau.source == "28 jours comparables")
    }
    @Test func historicalAbsenceStillWarnsAndProvisionalAdValuesStayVisible() throws {
        let window = try SyncWindow(range: .week, now: now), game = Demo.games[0]
        var report = ProviderReport(gameID: game.id, provider: "admob", title: "AdMob", note: "")
        report.days = Dictionary(uniqueKeysWithValues: window.days.map { ($0, FinancialDay(money: ["CHF": 1], adImpressions: 2)) })
        report.pendingDays = [window.end]
        func result() -> Dashboard { NativeDashboardSync.dashboard(games: [game], gameID: game.id, range: .week, window: window, reports: [report], engagement: [:], alerts: []) }
        #expect(result().kpis.first { $0.id == "ads" }?.value == 7)
        #expect(result().kpis.first { $0.id == "ads" }?.coverage?.availableDays == 6)
        #expect(result().kpis.first { $0.id == "adImpressions" }?.coverage?.status == "pending")
        report.days.removeValue(forKey: window.start)
        #expect(result().kpis.first { $0.id == "ads" }?.coverage?.status == "partial")
        report.days = [:]; report.hasError = true
        #expect(result().kpis.first { $0.id == "ads" }?.coverage?.status == "missing")
    }
    @Test func legacyUnitsAreUnknownAndBackfilledWithoutDiscardingMoney() throws {
        let old = try JSONDecoder().decode(FinancialDay.self, from: Data(#"{"money":{"USD":3.5},"iap":{"USD":3.5},"installs":0,"allocations":[]}"#.utf8))
        #expect(old.appleIAPNetUnits == nil)
        let window = try SyncWindow(range: .week, now: now)
        var cache = AggregateCache()
        var report = ProviderReport(gameID: "game", provider: "apple", title: "Apple", days: [window.start: old], note: "", supportsIAP: true)
        _ = cache.merge(report, window: window)
        #expect(cache.requestedWindow(window, gameID: "game", providers: ["apple"], force: false).days.contains(window.start))
        let retained = cache.merge(ProviderReport(gameID: "game", provider: "apple", title: "Apple", note: "", hasError: true), window: window)
        #expect(retained.days[window.start]?.money["USD"] == 3.5)
        #expect(retained.days[window.start]?.appleIAPNetUnits == nil)
        report.days[window.start]?.appleIAPNetUnits = 1
        _ = cache.merge(report, window: window)
        #expect(!cache.requestedWindow(window, gameID: "game", providers: ["apple"], force: false).days.contains(window.start))
        let roundTrip = try JSONDecoder().decode(AggregateCache.self, from: JSONEncoder().encode(cache))
        #expect(roundTrip.reports["game/apple"]?[window.start]?.value.appleIAPNetUnits == 1)
    }
    @Test func exportPreservesCurrencyAmountsAndSignedDailyCounts() throws {
        var export = DataExportTests().report()
        export.addDashboard(try dashboard())
        let totals = try #require(export.tables.first { $0.id == "studio_indicateurs_devises" })
        #expect(totals.rows.contains { $0[0] == .text("iap") && $0[2] == .text("USD") && $0[3] == .number(3.5) })
        let daily = try #require(export.tables.first { $0.id == "studio_historique" })
        let units = try #require(daily.columns.firstIndex(of: "apple_iap_net_units"))
        #expect(daily.rows.first { $0[0] == .text("2026-09-10") }?[units] == .number(-1))
        #expect(daily.rows.last?[units] == .null)
        for table in export.tables { #expect(table.rows.allSatisfy { $0.count == table.columns.count }) }
        _ = try export.jsonData()
    }
}
