import Testing
@testable import GameMetrikNative

extension AppStateTests {
@Suite(.serialized) @MainActor struct MobileTransferSecurityTests {
    @Test func transferRequiresAnAuthenticatedContextNotOnlyVisibleUnlockedState() async {
        let state = AppState()
        var asked = false
        await #expect(throws: Error.self) { try await state.prepareMobileTransfer { asked = true } }
        state.isLocked = false
        await #expect(throws: Error.self) { try await state.prepareMobileTransfer { asked = true } }
        #expect(!asked, "no owner confirmation, and no export, without an authenticated session")
        state.lock()
        #expect(state.sensitiveStateIsEmpty)
    }

    @Test func transferIsRefusedOutsidePersonalAdministrationBeforeAnyConfirmation() async {
        let state = AppState()
        state.isLocked = false
        for (mode, demo) in [("member", false), ("personal", true)] {
            state.accessMode = mode; state.demo = demo
            var asked = false
            await #expect(throws: Error.self) { try await state.prepareMobileTransfer { asked = true } }
            #expect(!asked, "mode \(mode), démo \(demo): refused before asking the owner")
        }
    }
}
}
