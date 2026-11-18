import Foundation
import Security
import Testing
@testable import GameMetrikNative
@testable import GameMetrikCore

extension AppStateTests {
@Suite(.serialized) @MainActor struct AuroraJourneyIntegrationTests {
    private func personalState(status: Int) async throws -> AppState {
        let fixtures = ExportPreparationTests()
        let state = try await fixtures.setup()
        state.accessMode = "personal"; state.personalOrganization = "org"
        state.completeUnlock(connections: try connections(projectID: "fixture"), session: nil)
        state.gameID = "aurora-grove"; state.destination = .players; state.range = .week
        await ExportHTTPStub.shared.setResponse("/token", data: Data("{\"access_token\":\"synthetic-token\",\"expires_in\":3600}".utf8))
        await ExportHTTPStub.shared.setResponse("/organizations", data: try JSONSerialization.data(withJSONObject: ["documents": [fixtures.document(["id": "org", "name": "Synthetic studio"])]]))
        await ExportHTTPStub.shared.setResponse("/gamemetrik_aurora_journey_report_v1", status: status, data: Data())
        return state
    }
    private func connections(projectID: String) throws -> PersonalConnections {
        // Ephemeral synthetic signing key, never stored in the Keychain or a fixture file.
        let key = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let rsa = try #require(SecKeyCopyExternalRepresentation(key, nil)) as Data
        func der(_ tag: UInt8, _ content: Data) -> Data {
            let n = content.count
            return Data([tag] + (n < 128 ? [UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 255)])) + content
        }
        let algorithm = Data([0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00])
        let pem = "-----BEGIN PRIVATE KEY-----\n" + der(0x30, Data([0x02,0x01,0x00]) + algorithm + der(0x04, rsa)).base64EncodedString() + "\n-----END PRIVATE KEY-----"
        return PersonalConnections(projectID: projectID, firebase: .init(project_id: "fixture", client_email: "test@fixture.iam.gserviceaccount.com", private_key: pem),
            supabase: [.init(ref: "aurora-grove", name: "Aurora Grove", url: URL(string: "https://fixture.supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_synthetic_only_test_credential")], importedAt: Date(), notes: [])
    }

    @Test func missingRPCLeavesHistoricalViewsLoadedAndMarksJourneyNotConnected() async throws {
        let state = try await personalState(status: 404)
        await state.synchronizeSelection()?.value
        #expect(state.error == nil)
        #expect(state.directory != nil)
        #expect(state.localViews[state.localViewKey(for: .dashboard)]?.dashboard != nil)
        #expect(state.localViews[state.localViewKey(for: .reviews)] != nil)
        #expect(state.localViews[state.localViewKey(for: .auroraJourney)]?.auroraJourney?.status == .notConnected)
        #expect(state.studioSyncResults.contains { $0.section == "Aurora Grove · Parcours" && $0.status == "not_connected" })
        let before = await ExportHTTPStub.shared.requests.count
        state.destination = .auroraJourney; state.refresh(mode: .local)
        #expect(state.auroraJourney?.status == .notConnected)
        #expect(await ExportHTTPStub.shared.requests.count == before)
        let export = try state.makeExport(scope: .available)
        #expect(export.checks.contains { $0.section == "Abandons et parcours par niveau" && $0.status == "not_connected" })
        #expect(export.checks.contains { $0.section == "Attribution des campagnes" && $0.status == "not_collected" })
        #expect(export.tables.contains { $0.id == "gameplay_resume" })
        // An absent function is not an unread view: exporting must not ask for another sync that cannot fix it.
        #expect(!export.missingViews.contains { $0.hasPrefix("Parcours") })
        state.exportSyncContext = state.exportContextKey
        state.exportSyncResults = [.init(section: "Aurora Grove · Parcours", status: "not_connected", detail: "404")]
        #expect(state.exportReadFailures.isEmpty)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func unreadableJourneyKeepsThePreviousOne() async throws {
        let state = try await personalState(status: 404)
        await state.synchronizeSelection()?.value
        let key = state.localViewKey(for: .auroraJourney)
        #expect(state.localViews[key]?.auroraJourney?.status == .notConnected)
        await ExportHTTPStub.shared.setResponse("/gamemetrik_aurora_journey_report_v1", status: 200, data: Data("{}".utf8))
        await state.synchronizeSelection()?.value
        #expect(state.localViews[key]?.auroraJourney?.status == .notConnected)
        #expect(state.localViewFailures[key]?.contains("illisible") == true)
        state.lock()
    }

    @Test func leavingPersonalModeLeavesTheJourneyPageInsteadOfPurging() async throws {
        let state = try await personalState(status: 404)
        state.destination = .auroraJourney
        state.accessMode = "member"
        state.refresh(mode: .local)
        #expect(state.destination == .gameplay)
        #expect(state.error == nil)
        state.lock()
    }

    @Test func anotherAdministrationProjectDropsTheViewsOfThePreviousOne() async throws {
        let state = try await personalState(status: 404)
        await state.synchronizeSelection()?.value
        #expect(!state.localViews.isEmpty)
        let before = state.localViewKey(for: .dashboard)
        state.completeUnlock(connections: try connections(projectID: "other-fixture"), session: nil)
        #expect(state.localViews.isEmpty); #expect(state.studioSyncResults.isEmpty)
        #expect(state.dashboard == nil); #expect(state.auroraJourney == nil)
        #expect(state.localViewKey(for: .dashboard) != before)
        state.lock()
    }

    @Test(arguments: [401, 403]) func refusalPurgesEveryProtectedView(status: Int) async throws {
        let state = try await personalState(status: status)
        await state.synchronizeSelection()?.value
        #expect(state.error?.contains("refusé") == true)
        #expect(state.localViews.isEmpty); #expect(state.auroraJourney == nil)
        #expect(state.directory == nil); #expect(state.dashboard == nil); #expect(state.reviews.isEmpty)
        #expect(state.aggregateCache == nil); #expect(state.studioSyncResults.isEmpty)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func demoNavigationExportAndLockKeepTheirContexts() async throws {
        let state = AppState()
        state.isLocked = false; state.demo = true; state.games = Demo.games; state.range = .month
        state.selectGame(Demo.games[0], page: .auroraJourney)
        await state.synchronizeSelection()?.value
        #expect(state.auroraJourney?.loadedKinds == AuroraJourneyReportKind.allCases)
        #expect(state.studioSyncResults.count == 4)
        let export = try state.makeExport(scope: .current)
        #expect(export.tables.contains { $0.id == "parcours_entonnoir" })
        #expect(export.tables.contains { $0.id == "parcours_qualite" })
        #expect(!export.tables.contains { $0.id == "joueurs" })
        state.destination = .gameplay; await state.refresh(mode: .local)?.value
        #expect(state.directory != nil)
        state.gameID = Demo.games[1].id; state.destination = .auroraJourney
        state.ensureCompatibleDestination()
        #expect(state.destination == .gameplay); #expect(state.auroraJourney == nil)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func undeployedStepsReportLeavesTheJourneyAndExportUntouched() async throws {
        let state = try await personalState(status: 404)
        await ExportHTTPStub.shared.setResponse("/gamemetrik_aurora_journey_steps_v1", status: 404, data: Data())
        await state.synchronizeSelection()?.value
        let journey = try #require(state.localViews[state.localViewKey(for: .auroraJourney)]?.auroraJourney)
        #expect(journey.status == .notConnected)
        #expect(journey.stepsError?.status == .notConnected); #expect(journey.steps == nil)
        #expect(state.error == nil)
        #expect(state.studioSyncResults.contains { $0.section == "Aurora Grove · Parcours" && $0.status == "not_connected" })
        let export = try state.makeExport(scope: .available)
        #expect(export.checks.contains { $0.section == "Parcours · Étapes anonymes" && $0.status == "not_connected" })
        #expect(!export.missingViews.contains("Parcours · Étapes anonymes"))
        #expect(export.readme.contains("comptes connectés (Apple ou Google) uniquement"))
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func demoShowsStepsAndTheConnectedAccountsPrecisionOnlyForAurora() async throws {
        let state = AppState()
        state.isLocked = false; state.demo = true; state.games = Demo.games; state.range = .month
        state.selectGame(Demo.games[0], page: .auroraJourney)
        await state.synchronizeSelection()?.value
        let steps = try #require(state.auroraJourney?.steps)
        #expect(steps.rows.contains { $0.appVersion == "1.5.0" && $0.tutorialStarted.reason == .notCollected })
        #expect(steps.rows.contains { $0.appVersion == "1.5.1" && $0.measuredShare.value != nil })
        let export = try state.makeExport(scope: .current)
        #expect(export.tables.contains { $0.id == "parcours_etapes" })
        #expect(state.connectedAccountsNote == "Comptes connectés uniquement (Apple ou Google) — les invités sont mesurés dans Parcours.")
        state.selectGame(Demo.games[1], page: .players)
        #expect(state.connectedAccountsNote == nil)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test(arguments: [404, 403]) func monetizationFailureKeepsTheJourneyAndEveryView(status: Int) async throws {
        let state = try await personalState(status: 404)
        await ExportHTTPStub.shared.setResponse("/gamemetrik_aurora_journey_steps_v1", status: 404, data: Data())
        await ExportHTTPStub.shared.setResponse("/gamemetrik_aurora_monetization_report_v1", status: status, data: Data())
        await state.synchronizeSelection()?.value
        // A refused or absent monetization report is never an identity failure: nothing is purged.
        #expect(state.error == nil)
        #expect(state.directory != nil)
        #expect(state.localViews[state.localViewKey(for: .dashboard)]?.dashboard != nil)
        let journey = try #require(state.localViews[state.localViewKey(for: .auroraJourney)]?.auroraJourney)
        #expect(journey.status == .notConnected); #expect(journey.stepsError?.status == .notConnected)
        for kind in AuroraMonetizationReportKind.allCases {
            #expect(journey.monetization.errors[kind]?.cause == (status == 404 ? .missingFunction : .denied))
        }
        #expect(await ExportHTTPStub.shared.requests.filter { $0.url?.path.hasSuffix("gamemetrik_aurora_monetization_report_v1") == true }.count == 4)
        let export = try state.makeExport(scope: .available)
        #expect(export.checks.filter { $0.section.hasPrefix("Monétisation mesurée · ") }.count == 4)
        #expect(export.checks.filter { $0.section.hasPrefix("Monétisation mesurée · ") }.allSatisfy { $0.status == (status == 404 ? "not_connected" : "partial") })
        #expect(!export.missingViews.contains { $0.contains("Monétisation") })
        #expect(!export.tables.contains { $0.id.hasPrefix("monetisation_") })
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func demoJourneyCarriesFictitiousMonetizationIntoTheExport() async throws {
        let state = AppState()
        state.isLocked = false; state.demo = true; state.games = Demo.games; state.range = .month
        state.selectGame(Demo.games[0], page: .auroraJourney)
        await state.synchronizeSelection()?.value
        let monetization = try #require(state.auroraJourney?.monetization)
        #expect(monetization.loadedKinds == AuroraMonetizationReportKind.allCases)
        let export = try state.makeExport(scope: .current)
        for id in ["monetisation_pubs", "monetisation_revenus", "monetisation_chargements_erreurs", "monetisation_paisible", "monetisation_test", "monetisation_couverture"] {
            #expect(export.tables.contains { $0.id == id }, "\(id)")
        }
        #expect(!export.tables.contains { $0.id == "joueurs" })
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func memberNeverSchedulesOrCallsTheAdministrativeRPC() async throws {
        let state = try await ExportPreparationTests().setup()
        #expect(!state.canNavigate(to: .auroraJourney))
        #expect(!state.synchronizationPages(for: Demo.games[0], range: .month).contains(.auroraJourney))
        await state.synchronizeSelection()?.value
        #expect(!(await ExportHTTPStub.shared.requests).contains { $0.url?.path.contains("journey_report") == true || $0.url?.path.contains("monetization_report") == true })
        state.lock()
    }
}
}
