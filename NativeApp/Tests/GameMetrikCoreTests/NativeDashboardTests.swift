import Foundation
import Testing
@testable import GameMetrikCore

private actor ReadCalls { var count = 0; func next() -> Int { count += 1; return count } }

struct NativeDashboardTests {
    @Test func aSharedReadSurvivesOneCancelledCallerAndIsRetriedOnceAbandoned() async throws {
        let memo = SyncMemo(), calls = ReadCalls()
        let slow: @Sendable () async throws -> Int = { let n = await calls.next(); try await Task.sleep(for: .milliseconds(300)); return n }
        let first = Task { try await memo.value("day", slow) }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { try await memo.value("day", slow) }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        #expect(try await second.value == 1)
        let lone = Task { try await memo.value("other", slow) }
        try await Task.sleep(for: .milliseconds(50))
        lone.cancel()
        _ = try? await lone.value
        // The abandoned read is not kept as a shared failure: the next caller fetches it again.
        #expect(try await memo.value("other", slow) == 3)
        #expect(await calls.count == 3)
    }
    let now = Dates.parse("2026-09-07T12:00:00Z")!
    @Test func fullSelectedHistoryAndLeapDays() throws {
        let window = try SyncWindow(range:.month,now:now)
        #expect(window.days.count == 30); #expect(window.start == "2026-08-09"); #expect(window.end == "2026-09-07")
        #expect(window.months == ["202608","202609"])
        let leap = try SyncWindow(range:.week,now:Dates.parse("2024-03-02T12:00:00Z")!)
        #expect(leap.days.contains("2024-02-29"))
        #expect(throws:GameMetrikError.self) { try SyncWindow(range:.all,now:now) }
    }
    @Test func csvQuotesMultilineUTF16AndMissingColumns() throws {
        let text = "Date,Country,Value\r\n2026-09-01,\"a,\"\"b\"\"\nline\",0\r\n"
        let data = text.data(using:.utf16)!
        let rows = try ReportFormats.table(data,required:["Date","Country","Value"])
        #expect(rows.count == 1); #expect(rows[0]["Country"] == "a,\"b\"\nline"); #expect(rows[0]["Value"] == "0")
        #expect(throws:GameMetrikError.self) { try ReportFormats.table(Data("wrong\n".utf8),required:["Date"]) }
        #expect(throws:GameMetrikError.self) { try ReportFormats.table(Data("a,b\n1,\"open".utf8)) }
        #expect(throws:GameMetrikError.self) { try ReportFormats.decimal("2garbage") }
    }
    @Test func appleSeparatesInstallsPurchasesRefundsAndOtherGames() throws {
        let header = "Apple Identifier\tParent Identifier\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds\n"
        let text = header+"123\t\t1F\t7\t0\tCHF\n123\t\t7F\t20\t0\tCHF\n999\tsku-game\tIA1\t2\t1.20\tCHF\n999\tsku-game\tIA1\t-1\t1.20\tCHF\n888\tother-game\tIA1\t1\t99\tCHF\n"
        let day = try NativeReports.appleDay(Data(text.utf8),appID:"123",sku:"sku-game")
        #expect(day.installs == 7); #expect(day.money["CHF"] == Decimal(string:"1.20")); #expect(day.iap["CHF"] == Decimal(string:"1.20"))
        let empty = try NativeReports.appleDay(Data(header.utf8),appID:"123",sku:"sku-game")
        #expect(empty.money.isEmpty); #expect(empty.installs == 0)
    }
    func admobJSON(count: Int = 1, warnings: [[String:String]] = [], end: Int = 3) throws -> Data {
        try JSONSerialization.data(withJSONObject:[
            ["header":["localizationSettings":["currencyCode":"CHF"],"dateRange":["startDate":["year":2026,"month":9,"day":1],"endDate":["year":2026,"month":9,"day":end]]]],
            ["row":["dimensionValues":["DATE":["value":"20260901"],"APP":["value":"ca-app-pub-1~1"]],"metricValues":["ESTIMATED_EARNINGS":["microsValue":"180000"],"IMPRESSIONS":["integerValue":"42"]]]],
            ["footer":["matchingRowCount":String(count),"warnings":warnings]]
        ])
    }
    @Test func admobDistinguishesCompleteZeroDaysFromUnfinishedToday() throws {
        let result = try NativeReports.admobRows(admobJSON(),requestedDays:["2026-09-01","2026-09-02","2026-09-03"],appIDs:["ca-app-pub-1~1"],completedBefore:"2026-09-03")
        #expect(result["2026-09-01"]?.money["CHF"] == Decimal(string:"0.18"))
        #expect(result["2026-09-01"]?.adImpressions == 42)
        #expect(result["2026-09-02"]?.adImpressions == 0)
        #expect(result["2026-09-02"] != nil); #expect(result["2026-09-03"] == nil)
        #expect(throws:GameMetrikError.self) { try NativeReports.admobRows(admobJSON(count:2,end:1),requestedDays:["2026-09-01"],appIDs:["ca-app-pub-1~1"],completedBefore:"2026-09-03") }
        #expect(throws:GameMetrikError.self) { try NativeReports.admobRows(admobJSON(warnings:[["type":"DATA_DELAYED"]],end:1),requestedDays:["2026-09-01"],appIDs:["ca-app-pub-1~1"],completedBefore:"2026-09-03") }
    }
    @Test func googleCountryRowsSumOnceAndMissingDaysStayUnknown() throws {
        let data = Data("Date,Package Name,Country,Daily User Installs\n2026-09-01,com.test.app,CH,3\n2026-09-01,com.test.app,FR,4\n2026-09-01,com.other.app,CH,99\n".utf8)
        let result = try NativeReports.googleInstalls(data,package:"com.test.app",days:["2026-09-01","2026-09-02"])
        #expect(result["2026-09-01"]?.installs == 7); #expect(result["2026-09-02"] == nil)
        let duplicate = Data("Date,Package Name,Country,Daily User Installs\n2026-09-01,com.test.app,CH,3\n2026-09-01,com.test.app,CH,3\n".utf8)
        #expect(throws:GameMetrikError.self) { try NativeReports.googleInstalls(duplicate,package:"com.test.app",days:["2026-09-01"]) }
    }
    @Test func googleDaysBeforeTheLatestExportRowHadNoInstalls() throws {
        let data = Data("Date,Package Name,Country,Daily User Installs\n2026-09-01,com.test.app,CH,3\n2026-09-03,com.test.app,CH,2\n".utf8)
        let result = try NativeReports.googleInstalls(data,package:"com.test.app",days:["2026-09-01","2026-09-02","2026-09-03","2026-09-04"])
        #expect(result["2026-09-02"]?.installs == 0); #expect(result["2026-09-04"] == nil)
        let empty = try NativeReports.googleInstalls(Data("Date,Package Name,Country,Daily User Installs\n".utf8),package:"com.test.app",days:["2026-09-01"])
        #expect(empty.isEmpty)
    }
    @Test func googleEarningsIncludeFeesAndRefundsInMerchantCurrency() throws {
        let data = Data("Transaction Date,Package ID,Product Type,Merchant Currency,Amount (Merchant Currency)\n\"Sep 1, 2026\",com.test.app,One-time product,CHF,10\n\"Sep 1, 2026\",com.test.app,One-time product,CHF,-1.5\n\"Sep 1, 2026\",com.test.app,One-time product,CHF,-2\n".utf8)
        let rows = try NativeReports.googleEarnings(data,package:"com.test.app",days:["2026-09-01","2026-09-02"],completedMonth:false)
        #expect(rows["2026-09-01"]?.iap["CHF"] == Decimal(string:"6.5")); #expect(rows["2026-09-02"] == nil)
    }
    @Test func activityDeduplicatesAndExcludesImmatureCohorts() throws {
        let window = try SyncWindow(range:.month,now:now), user = UUID().uuidString, other = UUID().uuidString
        let first = ActivityEvent(user_id:user,run_id:UUID().uuidString,completed_at:"2026-08-20T10:00:00Z")
        let events = [first, first, ActivityEvent(user_id:user,run_id:UUID().uuidString,completed_at:"2026-08-27T10:00:00Z"), ActivityEvent(user_id:other,run_id:UUID().uuidString,completed_at:"2026-09-01T10:00:00Z")]
        let value = try Engagement.build(events,window:window,timezone:TimeZone(identifier:"Europe/Zurich")!)
        #expect(value.monthly == 2); #expect(value.eligible == 1); #expect(value.retained == 1); #expect(value.daily["2026-08-20"] == 1)
        let todayCohort = [ActivityEvent(user_id:user,run_id:UUID().uuidString,completed_at:"2026-08-31T10:00:00Z"),ActivityEvent(user_id:user,run_id:UUID().uuidString,completed_at:"2026-09-07T10:00:00Z")]
        #expect(try Engagement.build(todayCohort,window:window,timezone:.gmt).eligible == 0)
    }
    @Test func partialSourcesAndForeignCurrenciesNeverBecomeCompleteTotals() throws {
        let game = Demo.games[0], window = try SyncWindow(range:.week,now:now)
        let a = ProviderReport(gameID:game.id,provider:"admob",title:"AdMob",days:[window.start:FinancialDay(money:["CHF":Decimal(string:"0.18")!])],note:"")
        let b = ProviderReport(gameID:game.id,provider:"apple",title:"Apple",note:"Clé absente",supportsInstalls:true,supportsIAP:true)
        let dashboard = NativeDashboardSync.dashboard(games:[game],gameID:game.id,range:.week,window:window,reports:[a,b],engagement:[:],alerts:[])
        let total = dashboard.kpis.first { $0.id == "revenue" }!
        #expect(total.value == 0.18); #expect(total.coverage?.availableDays == 0); #expect(total.coverage?.status == "partial")
        #expect(dashboard.kpis.first { $0.id == "dau" }?.value == nil)
        #expect(dashboard.trend.last?.revenueAvailable == false)
        var foreign = b; foreign.days[window.start] = FinancialDay(money:["USD":1])
        let mixed = NativeDashboardSync.dashboard(games:[game],gameID:game.id,range:.week,window:window,reports:[a,foreign],engagement:[:],alerts:[])
        #expect(mixed.kpis.first { $0.id == "revenue" }?.value == nil)
    }
    @Test func arpdauOnlyUsesMatchedCompleteDates() throws {
        let game = Demo.games[0], window = try SyncWindow(range:.week,now:now)
        let report = ProviderReport(gameID:game.id,provider:"admob",title:"AdMob",days:[window.start:FinancialDay(money:["CHF":12])],note:"")
        let players = Engagement(daily:[window.start:3,window.end:99],monthly:100,retained:0,eligible:0)
        let dashboard = NativeDashboardSync.dashboard(games:[game],gameID:game.id,range:.week,window:window,reports:[report],engagement:[game.id:players],alerts:[])
        #expect(dashboard.kpis.first { $0.id == "arpdau" }?.value == 4)
    }
}

extension NativeDashboardTests {
    @Test func compressedReportsValidateCRCAndRejectTruncation() throws {
        let gzip = Data(base64Encoded: "H4sIAAAAAAAC/3NJLEnVCUvMKU3lMjIwMtM1sNQ1MNQx5wIA8hYtdRgAAAA=")!
        let zip = Data(base64Encoded: "UEsDBBQAAAAIAPBKJ13yFi11GgAAABgAAAAKAAAAcmVwb3J0LmNzdnNJLEnVCUvMKU3lMjIwMtM1sNQ1MNQx5wIAUEsBAhQDFAAAAAgA8EonXfIWLXUaAAAAGAAAAAoAAAAAAAAAAAAAAIABAAAAAHJlcG9ydC5jc3ZQSwUGAAAAAAEAAQA4AAAAQgAAAAAA")!
        let expected = Data("Date,Value\n2026-09-01,7\n".utf8)
        #expect(try ReportFormats.files(gzip) == [expected])
        #expect(try ReportFormats.files(zip) == [expected])
        #expect(throws:GameMetrikError.self) { try ReportFormats.files(Data(gzip.dropLast(4))) }
        var damaged = zip; damaged[45] ^= 0xff
        #expect(throws:GameMetrikError.self) { try ReportFormats.files(damaged) }
    }
}

extension NativeDashboardTests {
    @Test func appleFreeAcquisitionsAllowBlankCurrencyOnlyForKnownZeroProceeds() throws {
        let header = "Apple Identifier\tParent Identifier\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds\n"
        let free = try NativeReports.appleDay(Data((header + "123\t\t1F\t6\t0.00\t \n").utf8), appID: "123", sku: "game")
        #expect(free.installs == 6)
        #expect(free.money.isEmpty)
        #expect(throws: GameMetrikError.self) {
            try NativeReports.appleDay(Data((header + "123\t\t1F\t6\t1.00\t \n").utf8), appID: "123", sku: "game")
        }
        #expect(throws: GameMetrikError.self) {
            try NativeReports.appleDay(Data((header + "123\t\t1F\t6\t\t \n").utf8), appID: "123", sku: "game")
        }
    }
    @Test func appleUnfinishedDayIsPendingButMissingPastReportStillWarns() throws {
        let window = try SyncWindow(range: .week, now: now), game = Demo.games[0]
        var report = ProviderReport(gameID: game.id, provider: "apple", title: "Apple", note: "", supportsInstalls: true, supportsIAP: true)
        report.days = Dictionary(uniqueKeysWithValues: window.days.dropLast().map { ($0, FinancialDay()) })
        report.pendingDays = [window.end]
        var result = NativeDashboardSync.dashboard(games: [game], gameID: game.id, range: .week, window: window, reports: [report], engagement: [:], alerts: [])
        #expect(result.kpis.first { $0.id == "installs" }?.coverage?.status == "pending")
        #expect(result.kpis.first { $0.id == "installs" }?.coverage?.availableDays == 6)
        report.days.removeValue(forKey: window.start)
        result = NativeDashboardSync.dashboard(games: [game], gameID: game.id, range: .week, window: window, reports: [report], engagement: [:], alerts: [])
        #expect(result.kpis.first { $0.id == "installs" }?.coverage?.status == "partial")
    }
}
