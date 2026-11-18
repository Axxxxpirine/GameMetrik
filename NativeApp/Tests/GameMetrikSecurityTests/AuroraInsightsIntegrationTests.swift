import Foundation
import Security
import Testing
@testable import GameMetrikNative
@testable import GameMetrikCore

extension AppStateTests {
@Suite(.serialized) @MainActor struct AuroraInsightsIntegrationTests {
    private func personalState(insights status: Int) async throws -> AppState {
        let fixtures = ExportPreparationTests()
        let state = try await fixtures.setup()
        state.accessMode = "personal"; state.personalOrganization = "org"
        state.completeUnlock(connections: try connections(), session: nil)
        state.gameID = "aurora-grove"; state.destination = .players; state.range = .week
        await ExportHTTPStub.shared.setResponse("/token", data: Data("{\"access_token\":\"synthetic-token\",\"expires_in\":3600}".utf8))
        await ExportHTTPStub.shared.setResponse("/organizations", data: try JSONSerialization.data(withJSONObject: ["documents": [fixtures.document(["id": "org", "name": "Synthetic studio"])]]))
        await ExportHTTPStub.shared.setResponse("/gamemetrik_aurora_journey_report_v1", status: 404, data: Data())
        await ExportHTTPStub.shared.setResponse("/gamemetrik_aurora_journey_steps_v1", status: 404, data: Data())
        await ExportHTTPStub.shared.setResponse("/gamemetrik_aurora_monetization_report_v1", status: 404, data: Data())
        await ExportHTTPStub.shared.setResponse("/gamemetrik_aurora_insights_report_v1", status: status, data: Data())
        await ExportHTTPStub.shared.setResponse("/gamemetrik_aurora_presence_report_v1", status: status, data: Data())
        return state
    }
    private func connections() throws -> PersonalConnections {
        // Ephemeral synthetic signing key, never stored in the Keychain or a fixture file.
        let key = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let rsa = try #require(SecKeyCopyExternalRepresentation(key, nil)) as Data
        func der(_ tag: UInt8, _ content: Data) -> Data {
            let n = content.count
            return Data([tag] + (n < 128 ? [UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 255)])) + content
        }
        let algorithm = Data([0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00])
        let pem = "-----BEGIN PRIVATE KEY-----\n" + der(0x30, Data([0x02,0x01,0x00]) + algorithm + der(0x04, rsa)).base64EncodedString() + "\n-----END PRIVATE KEY-----"
        return PersonalConnections(projectID: "fixture", firebase: .init(project_id: "fixture", client_email: "test@fixture.iam.gserviceaccount.com", private_key: pem),
            supabase: [.init(ref: "aurora-grove", name: "Aurora Grove", url: URL(string: "https://fixture.supabase.co")!, timezone: "Europe/Zurich", secret: "sb_secret_synthetic_only_test_credential")], importedAt: Date(), notes: [])
    }
    private func insightsRequests() async -> Int {
        await ExportHTTPStub.shared.requests.filter { $0.url?.path.contains("insights_report") == true || $0.url?.path.contains("presence_report") == true }.count
    }

    @Test func demoShowsEveryFamilyExportsThemAndFollowsThePopulation() async throws {
        let state = AppState()
        state.isLocked = false; state.demo = true; state.games = Demo.games; state.range = .month
        state.selectGame(Demo.games[0], page: .auroraInsights)
        #expect(state.canNavigate(to: .auroraInsights))
        await state.synchronizeSelection()?.value
        let insights = try #require(state.auroraInsights)
        #expect(insights.loadedKinds == AuroraInsightsKind.allCases)
        #expect(insights.population == state.auroraInsightsPopulation)
        let export = try state.makeExport(scope: .current)
        for id in ["collecte_frequentation", "collecte_presence_jours", "collecte_presence_direct", "collecte_sessions", "collecte_parties", "collecte_serveur", "collecte_couverture"] {
            #expect(export.tables.contains { $0.id == id }, "\(id)")
        }
        #expect(!export.tables.contains { $0.id == "joueurs" })
        #expect(!export.missingViews.contains { $0.hasPrefix("Activité et jeu") })
        let json = String(decoding: try export.jsonData(), as: UTF8.self)
        for forbidden in ["installation_id", "session_id", "presence_id", "user_id"] { #expect(!json.contains(forbidden), "\(forbidden)") }
        let previous = state.auroraInsightsPopulation
        state.auroraInsightsPopulation = previous == .internalBuilds ? .production : .internalBuilds
        await state.refresh()?.value
        #expect(state.auroraInsights?.population == state.auroraInsightsPopulation)
        state.auroraInsightsPopulation = previous
        // Another game cannot keep the page.
        state.gameID = Demo.games[1].id; state.ensureCompatibleDestination()
        #expect(state.destination == .gameplay); #expect(state.auroraInsights == nil)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func absentFunctionsLeaveTheJourneyAndOtherViewsUntouched() async throws {
        let state = try await personalState(insights: 404)
        await state.synchronizeSelection()?.value
        #expect(state.error == nil)
        #expect(state.directory != nil)
        #expect(state.localViews[state.localViewKey(for: .auroraJourney)]?.auroraJourney?.status == .notConnected)
        let insights = try #require(state.localViews[state.localViewKey(for: .auroraInsights)]?.auroraInsights)
        #expect(insights.status == .notConnected)
        #expect(state.studioSyncResults.contains { $0.section == "Aurora Grove · Activité et jeu" && $0.status == "not_connected" })
        // One call per function: an absent function is the same for every family.
        #expect(await insightsRequests() == 2)
        let before = await ExportHTTPStub.shared.requests.count
        state.destination = .auroraInsights; state.refresh(mode: .local)
        #expect(state.auroraInsights?.status == .notConnected); #expect(state.loadedAt != nil)
        #expect(await ExportHTTPStub.shared.requests.count == before)
        let export = try state.makeExport(scope: .available)
        let checks = export.checks.filter { $0.section.hasPrefix("Collecte complète · ") }
        #expect(!checks.isEmpty && checks.allSatisfy { $0.status == "not_connected" })
        #expect(!export.missingViews.contains { $0.hasPrefix("Activité et jeu") })
        #expect(export.checks.first { $0.section == "Sessions et publicité par joueur" }?.detail.contains("collecte_sessions") == true)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test(arguments: [401, 403]) func refusalIsNeverAnIdentityFailure(status: Int) async throws {
        let state = try await personalState(insights: status)
        await state.synchronizeSelection()?.value
        #expect(state.error == nil)
        #expect(state.directory != nil)
        #expect(state.localViews[state.localViewKey(for: .dashboard)]?.dashboard != nil)
        let insights = try #require(state.localViews[state.localViewKey(for: .auroraInsights)]?.auroraInsights)
        #expect(insights.errors.values.allSatisfy { $0.cause == .denied })
        #expect(insights.status == .partial)
        state.lock(); #expect(state.sensitiveStateIsEmpty)
    }

    @Test func memberNeverSchedulesOrCallsTheInsightsRPC() async throws {
        let state = try await ExportPreparationTests().setup()
        #expect(!state.canNavigate(to: .auroraInsights))
        state.destination = .auroraInsights; state.ensureCompatibleDestination()
        #expect(state.destination != .auroraInsights)
        await state.synchronizeSelection()?.value
        #expect(await insightsRequests() == 0)
        state.lock()
    }
}
}
