import Foundation
import Testing
@testable import GameMetrikCore

struct WebConfigurationTests {
    @Test func dotenvReadsCommentsQuotesAndMultilineKeys() throws {
        let input = #"""
        # A comment
        export PROJECT = studio # trailing comment
        URL="https://example.test/#fragment"
        SECRET='value=with#characters'
        PEM="first\nsecond"
        MULTILINE="first
        second"
        """#
        let values = try DotEnv.parse(input)
        #expect(values["PROJECT"] == "studio")
        #expect(values["URL"] == "https://example.test/#fragment")
        #expect(values["SECRET"] == "value=with#characters")
        #expect(values["PEM"] == "first\nsecond")
        #expect(values["MULTILINE"] == "first\nsecond")
    }
    @Test func dotenvNeverExecutesCommandsOrExpandsEnvironment() throws {
        let values = try DotEnv.parse("VALUE=$(echo secret)\nOTHER=`touch /tmp/should-not-run`\nPATH=${HOME}/private")
        #expect(values["VALUE"] == "$(echo secret)")
        #expect(values["OTHER"] == "touch /tmp/should-not-run")
        #expect(values["PATH"] == "${HOME}/private")
    }
    @Test func dotenvRejectsInvalidSyntaxWithoutExposingValues() {
        #expect(throws: GameMetrikError.self) { try DotEnv.parse("INVALID-NAME=private-value") }
        #expect(throws: GameMetrikError.self) { try DotEnv.parse("VALUE=\"unterminated") }
    }
    @Test func auditReportsMissingFilesAndNeverIncludesSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        FIREBASE_PROJECT_ID=test-project
        GOOGLE_APPLICATION_CREDENTIALS=missing.json
        APPLE_ISSUER_ID=issuer
        APPLE_KEY_ID=key
        APPLE_PRIVATE_KEY_PATH=missing.p8
        ADMOB_CLIENT_ID=private-test-client
        ADMOB_CLIENT_SECRET=secret-canary-value
        ADMOB_REFRESH_TOKEN=private-test-refresh
        ADMOB_PUBLISHER_ID=publisher
        SUPABASE_PROJECTS_JSON='[{"secretEnv":"SUPABASE_TEST_SECRET_KEY"}]'
        SUPABASE_TEST_SECRET_KEY=secret-canary-value
        """.write(to: directory.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        let audit = try WebConfigurationAudit.inspect(directory: directory)
        #expect(audit.connections.first { $0.id == "apple" }?.status == "À compléter")
        #expect(audit.connections.first { $0.id == "admob" }?.status == "Identifiants présents")
        #expect(audit.connections.first { $0.id == "supabase" }?.status == "Identifiants présents")
        #expect(!String(describing: audit).contains("secret-canary-value"))
        #expect(!String(describing: audit).contains("private-test-refresh"))
    }
}
