import Foundation
import Testing
@testable import GameMetrikCore

struct AuthenticationTests {
    var config: NativeConfiguration { .init(apiKey: "test", projectID: "test-project", clientID: "123-example.apps.googleusercontent.com", callbackScheme: "com.googleusercontent.apps.123-example") }
    @Test func pkceMatchesRFC7636Vector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "test")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE().verifier.count == 43)
        #expect(PKCE().state != PKCE().state)
    }
    @Test func callbackRequiresExactStateAndScheme() throws {
        let pkce = PKCE(verifier: "verifier", state: "state-123")
        let valid = URL(string: config.redirectURI + "?state=state-123&code=abc")!
        #expect(try pkce.code(callback: valid, config: config) == "abc")
        for url in [config.redirectURI + "?state=wrong&code=abc", config.redirectURI + "?state=state-123&state=other&code=abc", "evil:/oauth2redirect?state=state-123&code=abc", config.redirectURI + "?state=state-123&code=abc&error=denied"] {
            #expect(throws: GameMetrikError.self) { try pkce.code(callback: URL(string: url)!, config: config) }
        }
    }
    @Test func tokenFormsEscapeReservedCharacters() {
        let form = String(data: HTTPClient.form(["token": "a+b&c=d/x"]), encoding: .utf8)
        #expect(form == "token=a%2Bb%26c%3Dd%2Fx")
    }
    @Test func nativePlistChecksBundleAndGoogleClient() throws {
        let values = ["API_KEY": "public-test", "PROJECT_ID": "project-test", "CLIENT_ID": config.clientID, "REVERSED_CLIENT_ID": config.callbackScheme, "BUNDLE_ID": "ch.gamemetrik.native"]
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        #expect(try NativeConfiguration.readPlist(data).projectID == "project-test")
        var invalid = values; invalid["BUNDLE_ID"] = "web-app"
        let wrong = try PropertyListSerialization.data(fromPropertyList: invalid, format: .xml, options: 0)
        #expect(throws: GameMetrikError.self) { try NativeConfiguration.readPlist(wrong) }
    }
    @Test func privilegedSupabaseKeysAreRejected() {
        for key in ["sb_secret_test", "eyJserviceRoleKey"] {
            let config = SupabaseConfiguration(ref: "test", url: URL(string: "https://test.supabase.co")!, publishableKey: key, timezone: "Europe/Zurich")
            #expect(throws: GameMetrikError.self) { try config.validate() }
        }
    }
    @Test func unsafeURLsAreRejected() {
        for url in ["http://test.supabase.co", "https://user:password@test.supabase.co", "https://test.supabase.co?token=test", "https://test.supabase.co/path"] {
            let config = SupabaseConfiguration(ref: "test", url: URL(string: url)!, publishableKey: "sb_publishable_test_long_enough", timezone: "Europe/Zurich")
            #expect(throws: GameMetrikError.self) { try config.validate() }
        }
        #expect(!NativeConfiguration.validID("../secret"))
        #expect(!NativeConfiguration.validID("%2Fusers"))
    }
}
