import Foundation
import Testing
@testable import GameMetrikNative
@testable import GameMetrikCore

struct RevenueDisplayTests {
    @Test func originalCurrenciesAreExplicitAndZeroCurrencyDoesNotHideTheSale() throws {
        var iap = KPI(id: "iap", label: "Achats intégrés reçus", value: nil, unit: "currency")
        iap.amountsByCurrency = ["USD": 3.5, "CAD": 0]; iap.state = "available"
        #expect(Display.metricLines(iap, currency: "CHF") == ["USD 3.50"])
        iap.amountsByCurrency = ["USD": 3.5, "CHF": 3.348997]
        #expect(Display.metricLines(iap, currency: "CHF") == ["CHF 3.35", "USD 3.50"])
        iap.amountsByCurrency = ["USD": -3.5]
        #expect(Display.kpi(iap, currency: "CHF").contains("-3.50"))
        iap.amountsByCurrency = [:]; iap.value = 0
        #expect(Display.kpi(iap, currency: "CHF") != "—")
        let legacy = KPI(id: "iap", label: "Achats intégrés reçus", value: nil, unit: "currency")
        #expect(Display.metricLines(legacy, currency: "CHF") == ["—"])
    }
    @Test func dayInspectionRetainsForeignReceiptsAndPendingCoverageIsExplicit() throws {
        var point = Demo.dashboard(range: .week, gameID: nil).trend[0]
        point.revenueAvailable = false; point.revenueByCurrency = ["USD": 3.5]
        #expect(Display.revenue(point, currency: "CHF") == "USD 3.50")
        let coverage = try JSONDecoder().decode(KPI.Coverage.self, from: Data(#"{"status":"pending","availableDays":29,"expectedDays":30}"#.utf8))
        #expect(Display.coverage(coverage) == "Rapports récents en attente · 29/30 jours complets")
    }
}
