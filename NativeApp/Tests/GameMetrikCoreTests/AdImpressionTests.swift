import Foundation
import Testing
@testable import GameMetrikCore

struct AdImpressionTests {
    let now = Dates.parse("2026-09-07T12:00:00Z")!

    func payload(_ counts: [String?]) throws -> Data {
        var messages: [[String: Any]] = [["header": ["localizationSettings": ["currencyCode": "CHF"], "dateRange": ["startDate": SyncWindow.object("2026-09-07"), "endDate": SyncWindow.object("2026-09-07")]]]]
        for (index, count) in counts.enumerated() {
            var metrics = ["ESTIMATED_EARNINGS": ["microsValue": "180000"]]
            if let count { metrics["IMPRESSIONS"] = ["integerValue": count] }
            messages.append(["row": ["dimensionValues": ["DATE": ["value": "20260907"], "APP": ["value": "ca-app-pub-1~\(index)"]], "metricValues": metrics]])
        }
        messages.append(["footer": ["matchingRowCount": String(counts.count)]])
        return try JSONSerialization.data(withJSONObject: messages)
    }

    @Test func sumsMultipleAppsIncludingProvisionalToday() throws {
        let days = try NativeReports.admobRows(payload(["42", "8"]), requestedDays: ["2026-09-07"], appIDs: ["ca-app-pub-1~0", "ca-app-pub-1~1"], completedBefore: "2026-09-07")
        #expect(days["2026-09-07"]?.adImpressions == 50)
        #expect(days["2026-09-07"]?.money["CHF"] == Decimal(string: "0.36"))
    }

    @Test func missingMalformedAndOverflowCountsRejectTheBlock() throws {
        for count: String? in [nil, "", "-1", "1.5", "abc", "9223372036854775808"] {
            #expect(throws: GameMetrikError.self) {
                try NativeReports.admobRows(payload([count]), requestedDays: ["2026-09-07"], appIDs: ["ca-app-pub-1~0"], completedBefore: "2026-09-08")
            }
        }
        #expect(throws: GameMetrikError.self) {
            try NativeReports.admobRows(payload([String(Int.max), "1"]), requestedDays: ["2026-09-07"], appIDs: ["ca-app-pub-1~0", "ca-app-pub-1~1"], completedBefore: "2026-09-08")
        }
    }

    @Test func partialPortfolioCountsReceivedDaysWithoutInventingZeros() throws {
        let window = try SyncWindow(range: .week, now: now), games = Array(Demo.games.prefix(2))
        let first = ProviderReport(gameID: games[0].id, provider: "admob", title: "AdMob", days: [window.start: FinancialDay(adImpressions: 42), window.end: FinancialDay(adImpressions: 0)], note: "")
        var second = ProviderReport(gameID: games[1].id, provider: "admob", title: "AdMob", days: [window.start: FinancialDay(adImpressions: 8), window.end: FinancialDay(money: ["CHF": 1])], note: "")
        func metric(_ reports: [ProviderReport]) throws -> KPI {
            let result = NativeDashboardSync.dashboard(games: games, gameID: nil, range: .week, window: window, reports: reports, engagement: [:], alerts: [])
            return try #require(result.kpis.first { $0.id == "adImpressions" })
        }
        let partial = try metric([first, second])
        #expect(partial.value == 50)
        #expect(partial.unit == "number")
        #expect(partial.coverage?.availableDays == 1)
        #expect(partial.coverage?.status == "partial")
        #expect(try metric([first]).coverage?.availableDays == 0)
        second.days = [window.end: FinancialDay(money: ["CHF": 1])]
        #expect(try metric([second]).value == nil)
        #expect(try metric([second]).coverage?.status == "missing")
        second.days = [window.end: FinancialDay(adImpressions: 0)]
        #expect(try metric([second]).value == 0)
    }

    @Test func oldCacheStaysReadableAndBackfillsCountsOnNextSync() throws {
        let old = try JSONDecoder().decode(FinancialDay.self, from: Data(#"{"money":{"CHF":1},"iap":{},"installs":0}"#.utf8))
        #expect(old.adImpressions == nil)
        let window = try SyncWindow(range: .today, now: now)
        var cache = AggregateCache()
        let report = ProviderReport(gameID: "game", provider: "admob", title: "AdMob", days: [window.end: old], note: "")
        _ = cache.merge(report, window: window)
        #expect(cache.requestedWindow(window, gameID: "game", providers: ["admob"], force: false).days == window.days)
        var fresh = report; fresh.days[window.end]?.adImpressions = 42
        fresh.days[window.end]?.allocate(1, currency: "CHF", country: "CH", platform: "ios")
        _ = cache.merge(fresh, window: window)
        #expect(cache.requestedWindow(window, gameID: "game", providers: ["admob"], force: false).days.isEmpty)
        var failed = report; failed.days = [:]; failed.hasError = true
        #expect(cache.merge(failed, window: window).days[window.end]?.adImpressions == 42)
        let restored = try JSONDecoder().decode(AggregateCache.self, from: JSONEncoder().encode(cache))
        #expect(restored.reports["game/admob"]?[window.end]?.value.adImpressions == 42)
    }
}
