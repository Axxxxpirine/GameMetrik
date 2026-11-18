import XCTest
@testable import GameMetrik
import GameMetrikCore

@MainActor final class MobileStoreTests: XCTestCase {
    func testLaunchNeverDisplaysSyntheticDataAsLive() {
        let store = MobileStore()
        XCTAssertFalse(store.demo); XCTAssertFalse(store.unlocked)
        XCTAssertTrue(store.games.isEmpty); XCTAssertNil(store.snapshot(nil).dashboard)
    }
    func testDemoContextIsolationAndLockPurge() {
        let store = MobileStore(); store.exploreDemo()
        XCTAssertNotNil(store.snapshot(nil).dashboard)
        XCTAssertNil(store.snapshot("aurora-grove").dashboard)
        store.localSelection("aurora-grove")
        XCTAssertEqual(store.snapshot("aurora-grove").dashboard?.gameId, "aurora-grove")
        XCTAssertNotNil(store.snapshot("aurora-grove").directory)
        store.range = .week
        XCTAssertNil(store.snapshot("aurora-grove").dashboard)
        store.localSelection("aurora-grove")
        XCTAssertEqual(store.snapshot("aurora-grove").dashboard?.timeframe, .week)
        store.localSelection("ballpark")
        XCTAssertNotNil(store.snapshot("ballpark").ballpark?.questions)
        store.lock()
        XCTAssertTrue(store.snapshots.isEmpty); XCTAssertTrue(store.games.isEmpty)
        XCTAssertFalse(store.unlocked); XCTAssertFalse(store.loading)
        XCTAssertNil(store.snapshot("aurora-grove").directory)
    }
    func testLeavingDemoClearsAllResults() {
        let store = MobileStore(); store.exploreDemo(); store.localSelection("ballpark"); store.exitDemo()
        XCTAssertFalse(store.demo); XCTAssertFalse(store.unlocked); XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(store.snapshot(nil).dashboard)
    }
    func testLockedStoreDoesNotStartSynchronization() {
        let store = MobileStore()
        XCTAssertNil(store.synchronize(gameID: nil))
        XCTAssertFalse(store.loading)
    }
    func testUnavailableAndMultipleCurrenciesArePreserved() {
        let unknown = KPI(id: "revenue", label: "Revenu", value: nil, unit: "currency")
        XCTAssertEqual(Display.metric(unknown), "—")
        var multi = KPI(id: "revenue", label: "Revenu", value: 10, unit: "currency")
        multi.amountsByCurrency = ["CHF": 10, "USD": 20]
        XCTAssertTrue(Display.metric(multi).contains("CHF"))
        XCTAssertTrue(Display.metric(multi).contains("USD"))
    }
}
