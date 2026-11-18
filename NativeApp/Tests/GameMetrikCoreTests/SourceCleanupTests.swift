import Foundation
import Testing
@testable import GameMetrikCore

struct SourceCleanupTests {
    private func fixture() throws -> (URL, PersonalConnections) {
        let (account, _) = try PersonalConnectionsTests().keyPair()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(account).write(to: root.appendingPathComponent("service.json"))
        try Data("FIREBASE_PROJECT_ID=test-project\nGOOGLE_APPLICATION_CREDENTIALS=service.json\nCRON_SECRET=fixture-secret\n".utf8).write(to: root.appendingPathComponent(".env.local"))
        return (root, try PersonalConnections.read(directory: root))
    }
    @Test func originalsStayUntilBackupIsVerified() throws {
        let (root, connections) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try SourceCleanup.prepare(directory: root, connections: connections)
        #expect(throws: GameMetrikError.self) { try plan.commit(verifiedBackup: Data()) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("service.json").path))
        #expect(try String(contentsOf: root.appendingPathComponent(".env.local"), encoding: .utf8).contains("fixture-secret"))
    }
    @Test func verifiedBackupPreservesRecoveryAndRemovesPlaintext() throws {
        let (root, connections) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try SourceCleanup.prepare(directory: root, connections: connections)
        let backup = try plan.encodedBackup()
        let recovered = try JSONDecoder().decode(SourceCleanup.self, from: backup)
        #expect(recovered.files.contains { String(data: $0.contents, encoding: .utf8)?.contains("fixture-secret") == true })
        let removed = try plan.commit(verifiedBackup: backup)
        #expect(removed.count == 2)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("service.json").path))
        let sanitized = try String(contentsOf: root.appendingPathComponent(".env.local"), encoding: .utf8)
        #expect(!sanitized.contains("fixture-secret")); #expect(sanitized.contains("APP_MODE=demo"))
    }
    @Test func concurrentEditsPreventAllCleanup() throws {
        let (root, connections) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try SourceCleanup.prepare(directory: root, connections: connections)
        try Data("changed".utf8).write(to: root.appendingPathComponent("service.json"))
        #expect(throws: GameMetrikError.self) { try plan.commit(verifiedBackup: plan.encodedBackup()) }
        #expect(try String(contentsOf: root.appendingPathComponent(".env.local"), encoding: .utf8).contains("fixture-secret"))
    }
    @Test func mismatchedStoredCredentialsPreventCleanup() throws {
        let (root, connections) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var other = connections; other.firebase = try PersonalConnectionsTests().keyPair().0
        #expect(throws: GameMetrikError.self) { try SourceCleanup.prepare(directory: root, connections: other) }
    }
}
