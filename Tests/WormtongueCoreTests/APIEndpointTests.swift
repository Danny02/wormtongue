import Foundation
import Testing

@testable import WormtongueCore

@Suite("API endpoint override")
struct APIEndpointTests {

    @Test("The default is Anthropic's host")
    func defaultEndpoint() {
        #expect(
            APIEndpoint.anthropic.messages.absoluteString == "https://api.anthropic.com/v1/messages"
        )
        #expect(
            APIEndpoint.anthropic.models.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(APIEndpoint.anthropic.isDefault)
        #expect(!APIEndpoint.anthropic.isLoopback)
    }

    @Test("A plain host override rewrites both endpoints")
    func hostOverride() throws {
        let endpoint = try #require(APIEndpoint(base: "https://gateway.example.com"))
        #expect(endpoint.messages.absoluteString == "https://gateway.example.com/v1/messages")
        #expect(endpoint.models.absoluteString == "https://gateway.example.com/v1/models")
        #expect(!endpoint.isDefault)
    }

    @Test("A trailing slash does not produce a double slash")
    func trailingSlash() throws {
        let one = try #require(APIEndpoint(base: "https://gateway.example.com/"))
        #expect(one.messages.absoluteString == "https://gateway.example.com/v1/messages")
        let many = try #require(APIEndpoint(base: "https://gateway.example.com///"))
        #expect(many.messages.absoluteString == "https://gateway.example.com/v1/messages")
    }

    @Test("A path prefix is preserved — gateways mount the API under one")
    func pathPrefix() throws {
        let endpoint = try #require(APIEndpoint(base: "https://gw.example.com/anthropic"))
        #expect(endpoint.messages.absoluteString == "https://gw.example.com/anthropic/v1/messages")
        #expect(endpoint.models.absoluteString == "https://gw.example.com/anthropic/v1/models")
    }

    @Test("A port is preserved")
    func port() throws {
        let endpoint = try #require(APIEndpoint(base: "http://localhost:8080"))
        #expect(endpoint.messages.absoluteString == "http://localhost:8080/v1/messages")
    }

    @Test("Surrounding whitespace is tolerated — it is a hand-edited file")
    func whitespace() throws {
        let endpoint = try #require(APIEndpoint(base: "  https://gateway.example.com \n"))
        #expect(endpoint.messages.absoluteString == "https://gateway.example.com/v1/messages")
    }

    @Test("Loopback hosts are recognised, so a local mock is not flagged as remote")
    func loopback() throws {
        #expect(try #require(APIEndpoint(base: "http://localhost:1234")).isLoopback)
        #expect(try #require(APIEndpoint(base: "http://127.0.0.1:1234")).isLoopback)
        #expect(try #require(APIEndpoint(base: "https://gateway.example.com")).isLoopback == false)
    }

    @Test("Unusable values are rejected so the caller can fall back and say why")
    func rejected() {
        #expect(APIEndpoint(base: "") == nil)
        #expect(APIEndpoint(base: "   ") == nil)
        #expect(APIEndpoint(base: "/") == nil)
        // No scheme.
        #expect(APIEndpoint(base: "gateway.example.com") == nil)
        // Wrong scheme: this would silently not be an HTTP request.
        #expect(APIEndpoint(base: "ftp://gateway.example.com") == nil)
        #expect(APIEndpoint(base: "file:///etc/passwd") == nil)
        // Scheme but no host.
        #expect(APIEndpoint(base: "https://") == nil)
    }

    @Test("Scheme comparison is case-insensitive")
    func schemeCasing() {
        #expect(APIEndpoint(base: "HTTPS://gateway.example.com") != nil)
    }

    @Test("Config exposes the parsed endpoint, and nil for a bad one")
    func throughConfig() throws {
        var config = Config.fallback
        #expect(config.endpoint == .anthropic)

        config.apiBaseURL = "https://gw.example.com/anthropic"
        let endpoint = try #require(config.endpoint)
        #expect(endpoint.messages.absoluteString == "https://gw.example.com/anthropic/v1/messages")

        config.apiBaseURL = "not a url"
        #expect(config.endpoint == nil)
    }

    @Test("The base URL round-trips through the config file")
    func roundTrip() throws {
        let json = #"{ "api_base_url": "http://localhost:4000", "api_headers": {"x-gw": "abc"} }"#
        let config = try Config.decode(Data(json.utf8))
        #expect(config.apiBaseURL == "http://localhost:4000")
        #expect(config.apiHeaders == ["x-gw": "abc"])
        #expect(try #require(config.endpoint).isLoopback)
    }
}

@Suite("Hotkey mode")
struct HotkeyModeTests {

    @Test("Hold is the default")
    func defaultMode() throws {
        #expect(Config.fallback.hotkeyMode == .hold)
        #expect(try Config.decode(Data("{}".utf8)).hotkeyMode == .hold)
    }

    @Test("Toggle can be selected")
    func toggle() throws {
        let config = try Config.decode(Data(#"{ "hotkey_mode": "toggle" }"#.utf8))
        #expect(config.hotkeyMode == .toggle)
    }

    @Test("An unrecognised mode falls back instead of failing the whole config")
    func unknownMode() throws {
        let config = try Config.decode(Data(#"{ "hotkey_mode": "wiggle", "model": "m" }"#.utf8))
        #expect(config.hotkeyMode == .hold)
        #expect(config.model == "m")
    }
}
