import Foundation
import Testing
@testable import GameMetrikCore

struct MobileConnectionTransferTests {
    func payload(now: Date) throws -> MobileConnectionPayload {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        let connection = PersonalConnections(projectID: account.project_id, firebase: account, supabase: [], importedAt: now, notes: [])
        return .init(connections: connection, organization: "studio", googlePlayOverrides: ["aurora-grove": false], now: now)
    }
    @Test func roundTripKeepsCredentialsOutOfFile() throws {
        let now = Date(); let value = try payload(now: now); let code = MobileConnectionTransfer.newCode()
        let encrypted = try MobileConnectionTransfer.seal(value, code: code)
        #expect(encrypted.range(of: Data("PRIVATE KEY".utf8)) == nil)
        #expect(encrypted.range(of: Data(value.connections.firebase.client_email.utf8)) == nil)
        let received = try MobileConnectionTransfer.open(encrypted, code: code, now: now)
        #expect(received.connections.firebase.private_key == value.connections.firebase.private_key)
        #expect(received.organization == "studio")
        #expect(received.googlePlayOverrides["aurora-grove"] == false)
    }
    @Test func rejectsTamperingWrongCodeAndExpiry() throws {
        let now = Date(); let code = MobileConnectionTransfer.newCode()
        let encrypted = try MobileConnectionTransfer.seal(payload(now: now), code: code)
        #expect(throws: Error.self) { try MobileConnectionTransfer.open(encrypted, code: MobileConnectionTransfer.newCode(), now: now) }
        var corrupt = encrypted; corrupt[corrupt.count - 1] ^= 1
        #expect(throws: Error.self) { try MobileConnectionTransfer.open(corrupt, code: code, now: now) }
        #expect(throws: Error.self) { try MobileConnectionTransfer.open(encrypted, code: code, now: now.addingTimeInterval(MobileConnectionTransfer.lifetime + 1)) }
        #expect(throws: Error.self) { try MobileConnectionTransfer.open(encrypted, code: code, now: now.addingTimeInterval(-120)) }
        #expect(throws: Error.self) { try MobileConnectionTransfer.open(encrypted, code: "human-password", now: now) }
        #expect(throws: Error.self) { try MobileConnectionTransfer.open(Data("{}".utf8), code: code, now: now) }
    }
    @Test func refusesMissingOrganizationAndOversizedFile() throws {
        let now = Date(); var value = try payload(now: now); value.organization = ""
        #expect(throws: Error.self) { try MobileConnectionTransfer.seal(value, code: MobileConnectionTransfer.newCode()) }
        #expect(throws: Error.self) { try MobileConnectionTransfer.open(Data(count: MobileConnectionTransfer.maximumSize + 1), code: MobileConnectionTransfer.newCode()) }
    }
    @Test func expiresAfterTenMinutesAndExplainsAClockBehind() throws {
        let now = Date(); let code = MobileConnectionTransfer.newCode()
        let encrypted = try MobileConnectionTransfer.seal(payload(now: now), code: code)
        #expect(MobileConnectionTransfer.lifetime == 600)
        _ = try MobileConnectionTransfer.open(encrypted, code: code, now: now.addingTimeInterval(599))
        #expect { try MobileConnectionTransfer.open(encrypted, code: code, now: now.addingTimeInterval(601)) } throws: {
            ($0 as? GameMetrikError).map { "\($0.localizedDescription)".contains("expiré") } ?? false
        }
        #expect { try MobileConnectionTransfer.open(encrypted, code: code, now: now.addingTimeInterval(-120)) } throws: {
            ($0 as? GameMetrikError).map { "\($0.localizedDescription)".contains("Date et heure") } ?? false
        }
    }
    @Test func theQRCodeCarriesOnlyAValidTransferCode() {
        let code = MobileConnectionTransfer.newCode()
        #expect(MobileConnectionTransfer.code(fromScanned: MobileConnectionTransfer.scanText(for: code)) == code)
        #expect(MobileConnectionTransfer.code(fromScanned: code) == nil, "a bare string is not a GameMetrik QR code")
        #expect(MobileConnectionTransfer.code(fromScanned: "https://example.com") == nil)
        #expect(MobileConnectionTransfer.code(fromScanned: MobileConnectionTransfer.scanPrefix + "short") == nil)
    }
}
