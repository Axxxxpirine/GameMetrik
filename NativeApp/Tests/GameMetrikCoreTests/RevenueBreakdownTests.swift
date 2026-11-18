import Foundation
import Testing
@testable import GameMetrikCore

struct RevenueBreakdownTests {
    let now = Dates.parse("2026-09-09T12:00:00Z")!
    func ads(_ dimensions: [(String, String, String, String, String)]) throws -> [String: FinancialDay] {
        var payload: [[String: Any]] = [["header": ["localizationSettings": ["currencyCode": "CHF"], "dateRange": ["startDate": SyncWindow.object("2026-09-09"), "endDate": SyncWindow.object("2026-09-09")]]]]
        for (app, country, platform, amount, count) in dimensions {
            payload.append(["row": ["dimensionValues": ["DATE": ["value": "20260909"], "APP": ["value": app], "COUNTRY": ["value": country], "PLATFORM": ["value": platform]], "metricValues": ["ESTIMATED_EARNINGS": ["microsValue": amount], "IMPRESSIONS": ["integerValue": count]]]])
        }
        payload.append(["footer": ["matchingRowCount": String(dimensions.count)]])
        return try NativeReports.admobRows(JSONSerialization.data(withJSONObject: payload), requestedDays: ["2026-09-09"], appIDs: ["app-ios", "app-android"], completedBefore: "2026-09-10")
    }
    @Test func adCountryAndPlatformRowsReconcileWithoutDoubleCountingImpressions() throws {
        let rows = try ads([("app-ios", "CH", "iOS", "100123", "10"), ("app-ios", "FR", "iOS", "200456", "20"), ("app-android", "CH", "Android", "300789", "30")])
        let day = try #require(rows["2026-09-09"])
        #expect(day.money["CHF"] == Decimal(string: "0.601368"))
        #expect(day.adImpressions == 60)
        let window = try SyncWindow(range: .today, now: now)
        let dashboard = NativeDashboardSync.dashboard(games: [Demo.games[0]], gameID: "aurora-grove", range: .today, window: window,
            reports: [.init(gameID: "aurora-grove", provider: "admob", title: "AdMob", days: rows, note: "")], engagement: [:], alerts: [])
        #expect(abs(try #require(dashboard.kpis.first { $0.id == "ads" }?.value) - 0.601368) < 1e-12)
        #expect(abs(dashboard.countryBreakdown.reduce(0) { $0 + $1.value } - 0.601368) < 1e-12)
        #expect(abs(dashboard.platformBreakdown.reduce(0) { $0 + $1.value } - 0.601368) < 1e-12)
        #expect(day.allocations?.count == 3)
        #expect(day.allocations?.reduce(Decimal.zero) { $0 + $1.amount } == day.money["CHF"])
        #expect(throws: GameMetrikError.self) { try ads([("app-ios", "CH", "iOS", "1", "1"), ("app-ios", "CH", "iOS", "1", "1")]) }
    }
    @Test func appleUsesSaleCountryAndActualDeviceWithoutGuessingUniversalPlatforms() throws {
        let text = "Apple Identifier\tParent Identifier\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds\tCountry Code\tDevice\tSupported Platforms\n"
            + "123\t\t1F\t2\t1.20\tCHF\tCH\tiPhone\tiOS, macOS\n"
            + "999\tsku\tIA1\t-1\t0.30\tCHF\tFR\tDesktop\tiOS, macOS\n"
            + "999\tsku\tIA1\t1\t4\tUSD\tUS\t\tiOS, macOS\n"
            + "888\tother\tIA1\t1\t999\tCHF\tCH\tiPhone\tiOS\n"
        let day = try NativeReports.appleDay(Data(text.utf8), appID: "123", sku: "sku")
        #expect(day.money["CHF"] == Decimal(string: "2.10"))
        #expect(day.money["USD"] == 4)
        let rows = try #require(day.allocations)
        #expect(rows.count == 3)
        #expect(rows.contains { $0.country == "CH" && $0.platform == "ios" && $0.amount == Decimal(string: "2.4") })
        #expect(rows.contains { $0.country == "FR" && $0.platform == "macos" && $0.amount == Decimal(string: "-0.3") })
        #expect(rows.contains { $0.currency == "USD" && $0.platform == "unknown" })
    }
    @Test func googleKeepsBuyerCountryCurrencyFeesAndRefunds() throws {
        let text = "Transaction Date,Package ID,Product Type,Merchant Currency,Amount (Merchant Currency),Buyer Country\n"
            + "2026-09-09,game,In-app,CHF,10,CH\n2026-09-09,game,In-app,CHF,-2,CH\n"
            + "2026-09-09,game,In-app,EUR,3,FR\n2026-09-09,game,In-app,CHF,-1,\n"
        let day = try #require(NativeReports.googleEarningsFiles([Data(text.utf8)], package: "game", days: ["2026-09-09"], completedMonth: false)["2026-09-09"])
        #expect(day.money["CHF"] == 7); #expect(day.money["EUR"] == 3)
        #expect(day.allocations?.count == 3)
        #expect(day.allocations?.allSatisfy { $0.platform == "android" } == true)
        #expect(day.allocations?.contains { $0.country == "unknown" && $0.amount == -1 } == true)
    }
    @Test func aggregationSeparatesCurrenciesAndLeavesMissingDaysUnknown() throws {
        let window = try SyncWindow(range: .week, now: now)
        var first = FinancialDay(money: ["CHF": 3, "USD": 5], allocations: [])
        first.allocate(1, currency: "CHF", country: "CH", platform: "ios")
        first.allocate(2, currency: "CHF", country: "FR", platform: "android")
        first.allocate(5, currency: "USD", country: "US", platform: "ios")
        let report = ProviderReport(gameID: "aurora-grove", provider: "apple", title: "Apple", days: [window.start: first], note: "")
        let dashboard = NativeDashboardSync.dashboard(games: [Demo.games[0]], gameID: "aurora-grove", range: .week, window: window, reports: [report], engagement: [:], alerts: [])
        let detail = try #require(dashboard.revenueDetails)
        #expect(detail.status == "partial"); #expect(detail.receivedSourceDays == 1); #expect(detail.expectedSourceDays == 7)
        #expect(detail.currencies == ["CHF", "USD"])
        #expect(detail.rows.allSatisfy { $0.date == window.start })
        #expect(detail.breakdown(.country, currency: "CHF").map(\.value) == [2, 1])
        #expect(detail.breakdown(.platform, currency: "USD").first?.value == 5)
        #expect(dashboard.kpis.first { $0.id == "revenue" }?.value == nil)
        #expect(dashboard.countryBreakdown.reduce(0) { $0 + $1.value } == 3)
        #expect(abs(detail.breakdown(.country, currency: "CHF").compactMap(\.share).reduce(0,+) - 100) < 1e-9)
    }
    @Test func oldCacheIsUnallocatedThenBackfilledAndOfflineDataKeepsItsDimensions() throws {
        let window = try SyncWindow(range: .today, now: now)
        var cache = AggregateCache()
        let old = try JSONDecoder().decode(FinancialDay.self, from: Data(#"{"money":{"CHF":1},"iap":{},"installs":0,"adImpressions":10}"#.utf8))
        let oldReport = ProviderReport(gameID: "game", provider: "admob", title: "AdMob", days: [window.end: old], note: "")
        let merged = cache.merge(oldReport, window: window)
        let legacy = RevenueDetails.build(reports: [merged], window: window)
        #expect(legacy.legacySourceDays == 1); #expect(legacy.breakdown(.country, currency: "CHF").first?.code == "unknown")
        #expect(cache.requestedWindow(window, gameID: "game", providers: ["admob"], force: false).days == window.days)
        var newReport = oldReport; newReport.days[window.end]?.allocate(1, currency: "CHF", country: "CH", platform: "ios")
        _ = cache.merge(newReport, window: window)
        #expect(cache.requestedWindow(window, gameID: "game", providers: ["admob"], force: false).days.isEmpty)
        var later = window; later.now = now.addingTimeInterval(3600)
        newReport.days = [:]; newReport.hasError = true
        let offline = RevenueDetails.build(reports: [cache.merge(newReport, window: later)], window: later)
        #expect(offline.rows.first?.country == "CH"); #expect(offline.rows.first?.cached == true)
        #expect(offline.rows.first?.readAt == Dates.iso(now))
        #expect(offline.status == "partial")
        let restored = try JSONDecoder().decode(AggregateCache.self, from: JSONEncoder().encode(cache))
        #expect(restored.reports["game/admob"]?[window.end]?.value.allocations?.first?.country == "CH")
    }
    @Test func zeroAndNegativeTotalsDoNotInventPercentages() throws {
        let window = try SyncWindow(range: .today, now: now)
        var day = FinancialDay(allocations: [])
        day.allocate(5, currency: "CHF", country: "CH", platform: "ios")
        day.allocate(-5, currency: "CHF", country: "FR", platform: "android")
        let details = RevenueDetails.build(reports: [.init(gameID: "g", provider: "apple", title: "Apple", days: [window.end: day], note: "")], window: window)
        #expect(details.breakdown(.country, currency: "CHF").allSatisfy { $0.share == nil })
        #expect(details.breakdown(.platform, currency: "CHF").map(\.value) == [5, -5])
        let empty = RevenueDetails.build(reports: [.init(gameID: "g", provider: "apple", title: "Apple", days: [window.end: FinancialDay(allocations: [])], note: "")], window: window)
        #expect(empty.status == "loaded"); #expect(empty.rows.isEmpty)
    }
    @Test func exportsIncludeEveryCurrencyAndDailyAllocationEvenWhenUIShowsTopEight() throws {
        let window = try SyncWindow(range: .today, now: now)
        var day = FinancialDay(allocations: [])
        for country in ["CH", "FR", "US", "DE", "IT", "ES", "BE", "NL", "GB", "CA"] { day.allocate(1, currency: "CHF", country: country, platform: "ios") }
        day.allocate(3, currency: "USD", country: "US", platform: "android")
        var dashboard = Demo.dashboard(range: .today, gameID: "aurora-grove", now: now)
        dashboard.revenueDetails = RevenueDetails.build(reports: [.init(gameID: "aurora-grove", provider: "admob", title: "AdMob", days: [window.end: day], note: "")], window: window)
        var export = DataExport(now: now, mode: "test", gameID: "aurora-grove", gameName: "Aurora Grove", timeframe: "1 jour", scope: "test")
        export.addDashboard(dashboard); export.finishChecks()
        let countries = try #require(export.tables.first { $0.id == "studio_pays" })
        #expect(countries.rows.count == 11); #expect(countries.columns.contains("currency"))
        #expect(export.tables.first { $0.id == "studio_revenus_detail" }?.rows.count == 11)
        #expect(export.checks.contains { $0.section == "Revenus par pays et plateforme" && $0.status == "loaded" })
        let json = try #require(JSONSerialization.jsonObject(with: export.jsonData()) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 6)
        #expect(String(data: countries.csvData(), encoding: .utf8)?.contains("USD") == true)
    }
}
