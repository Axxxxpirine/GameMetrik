import XCTest

@MainActor final class MobileFlowTests: XCTestCase {
    func testDemoBrowsing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_CH"]
        app.launch()
        app.buttons["exploreDemo"].tap()
        XCTAssertTrue(app.navigationBars["Studio"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Acquisition"].exists)
        app.buttons["periodPicker"].tap()
        app.buttons["7 jours"].tap()
        XCTAssertTrue(app.buttons["periodPicker"].exists)
        capture("studio-light")
        app.tabBars.buttons["Jeux"].tap()
        app.buttons["game-aurora-grove"].tap()
        app.buttons["Joueurs"].tap()
        XCTAssertTrue(app.navigationBars["Joueurs"].waitForExistence(timeout: 3))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "NoxGrove")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Parties terminées"].exists)
        capture("player")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["game-ballpark"].tap()
        app.buttons["Analyse Ballpark"].tap()
        XCTAssertTrue(app.buttons["ballparkReportPicker"].waitForExistence(timeout: 3))
        app.buttons["ballparkReportPicker"].tap()
        app.buttons["Questions"].tap()
        capture("ballpark-questions")
        app.tabBars.buttons["Réglages"].tap()
        app.buttons["Quitter la démonstration"].tap()
        XCTAssertTrue(app.buttons["exploreDemo"].waitForExistence(timeout: 3))
        app.buttons["Connecter mon studio"].tap()
        XCTAssertFalse(app.buttons["Enregistrer et connecter"].isEnabled)
        capture("connection")
    }
    func testAllBallparkReportsAndDayInspection() {
        let app = XCUIApplication(); app.launchArguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_CH"]; app.launch()
        app.buttons["exploreDemo"].tap()
        app.buttons["Examiner une journée"].tap()
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{4}-[0-9]{2}-[0-9]{2}")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Joueurs actifs"].waitForExistence(timeout: 3))
        app.buttons["Fermer"].tap()
        app.tabBars.buttons["Jeux"].tap(); app.buttons["game-ballpark"].tap(); app.buttons["Analyse Ballpark"].tap()
        for report in ["Aperçu", "Séries", "Habitudes", "Qualité"] {
            app.buttons["ballparkReportPicker"].tap(); app.buttons[report].tap()
            XCTAssertTrue(app.buttons["ballparkReportPicker"].exists)
            capture("ballpark-" + report)
        }
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["exploreDemo"].waitForExistence(timeout: 3))
    }
    func testAppearanceSnapshot() {
        let app = XCUIApplication(); app.launchArguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_CH"]; app.launch()
        for _ in 0..<4 { if app.buttons["exploreDemo"].isHittable { break }; app.swipeUp() }
        app.buttons["exploreDemo"].tap()
        XCTAssertTrue(app.navigationBars["Studio"].waitForExistence(timeout: 5))
        capture("studio-appearance")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78)).press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.43)))
        capture("studio-appearance-scrolled")
        app.tabBars.buttons["Jeux"].tap()
        for _ in 0..<5 { if app.buttons["game-ballpark"].isHittable { break }; app.swipeUp() }
        app.buttons["game-ballpark"].tap()
        for _ in 0..<5 { if app.buttons["Analyse Ballpark"].isHittable { break }; app.swipeUp() }
        app.buttons["Analyse Ballpark"].tap(); capture("ballpark-appearance"); app.swipeUp(); capture("ballpark-appearance-scrolled")
    }
    func testEngagementAndPlayerContext() {
        let app = XCUIApplication(); app.launchArguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_CH"]; app.launch()
        app.buttons["exploreDemo"].tap(); app.tabBars.buttons["Jeux"].tap(); app.buttons["game-aurora-grove"].tap()
        app.buttons["Gameplay"].tap()
        for _ in 0..<8 { if app.buttons["engagement"].isHittable { break }; app.swipeUp() }
        app.buttons["engagement"].tap()
        XCTAssertTrue(app.staticTexts["Profils revenus un autre jour"].exists)
        capture("engagement")
        for _ in 0..<5 { if app.buttons["4 jours actifs ou plus"].isHittable { break }; app.swipeUp() }
        app.buttons["4 jours actifs ou plus"].tap()
        XCTAssertTrue(app.staticTexts["Indices par partie"].exists)
        capture("engagement-groups")
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["Joueurs"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "NoxGrove")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Démonstration · données fictives"].exists)
        capture("player-engagement-top")
        let streak = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Série de jours")).firstMatch
        for _ in 0..<8 {
            if streak.exists { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70)).press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50)))
        }
        XCTAssertTrue(streak.exists, app.debugDescription)
        capture("player-engagement")
        let difficulties = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[cd] %@", "Difficultés")).firstMatch
        scrollTo(difficulties, in: app)
        capture("player-difficulties")
        let daily = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[cd] %@", "Activité quotidienne")).firstMatch
        scrollTo(daily, in: app)
        capture("player-daily")
        let hours = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Heures de fin des parties")).firstMatch
        scrollTo(hours, in: app)
        hours.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70)).press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40)))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Heure locale de fin")).firstMatch.exists)
        capture("player-hours")
    }
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<24 {
            if element.exists && element.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70)).press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48)))
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
