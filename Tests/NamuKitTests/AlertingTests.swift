import XCTest
@testable import Namu

// MARK: - Mock channel

/// Records every payload sent to it. Optionally throws on the next send.
final class MockAlertChannel: AlertChannel, @unchecked Sendable {
    let id: String
    let displayName: String

    private let lock = NSLock()
    private var _sentPayloads: [AlertPayload] = []
    var errorToThrow: Error?

    init(id: String = "mock", displayName: String = "Mock") {
        self.id = id
        self.displayName = displayName
    }

    func send(_ payload: AlertPayload) async throws {
        if let err = errorToThrow {
            throw err
        }
        lock.withLock { _sentPayloads.append(payload) }
    }

    var sentPayloads: [AlertPayload] {
        lock.withLock { _sentPayloads }
    }

    var sendCount: Int { sentPayloads.count }
}

// MARK: - AlertPayload formatting

final class AlertPayloadTests: XCTestCase {

    private var payload: AlertPayload!

    override func setUp() {
        super.setUp()
        payload = AlertPayload(
            ruleName: "CPU Spike",
            event: "cpu.high",
            summary: "CPU usage exceeded 90%",
            workspaceTitle: "Dev",
            timestamp: Date()
        )
    }

    override func tearDown() {
        payload = nil
        super.tearDown()
    }

    func testMarkdownBodyContainsRuleName() {
        XCTAssertTrue(payload.markdownBody.contains("CPU Spike"),
                      "markdownBody should contain the rule name")
    }

    func testMarkdownBodyContainsSummary() {
        XCTAssertTrue(payload.markdownBody.contains("CPU usage exceeded 90%"),
                      "markdownBody should contain the summary")
    }

    func testMarkdownBodyContainsEventAsCode() {
        XCTAssertTrue(payload.markdownBody.contains("`cpu.high`"),
                      "markdownBody should wrap event in backticks")
    }

    func testMarkdownBodyContainsWorkspaceTitle() {
        XCTAssertTrue(payload.markdownBody.contains("Dev"),
                      "markdownBody should contain the workspace title")
    }

    func testMarkdownBodyBoldsRuleName() {
        XCTAssertTrue(payload.markdownBody.contains("**CPU Spike**"),
                      "markdownBody should bold the rule name")
    }

    func testPlainBodyContainsRuleName() {
        XCTAssertTrue(payload.plainBody.contains("CPU Spike"),
                      "plainBody should contain the rule name")
    }

    func testPlainBodyContainsSummary() {
        XCTAssertTrue(payload.plainBody.contains("CPU usage exceeded 90%"),
                      "plainBody should contain the summary")
    }

    func testPlainBodyContainsEventWithoutBackticks() {
        XCTAssertTrue(payload.plainBody.contains("cpu.high"),
                      "plainBody should contain the event name")
        XCTAssertFalse(payload.plainBody.contains("`cpu.high`"),
                       "plainBody should not wrap event in backticks")
    }

    func testPlainBodyContainsWorkspaceTitle() {
        XCTAssertTrue(payload.plainBody.contains("Dev"),
                      "plainBody should contain the workspace title")
    }

    func testPlainBodyHasNoMarkdownBold() {
        XCTAssertFalse(payload.plainBody.contains("**"),
                       "plainBody should not contain markdown bold markers")
    }
}

// MARK: - AlertRouter

final class AlertRouterTests: XCTestCase {

    private var router: AlertRouter!
    private var credentialStore: ChannelCredentialStore!

    override func setUp() {
        super.setUp()
        credentialStore = ChannelCredentialStore()
        router = AlertRouter(credentialStore: credentialStore)
    }

    override func tearDown() {
        router = nil
        credentialStore = nil
        super.tearDown()
    }

    // Helper: inject mock channels directly via the internal inject API.
    private func inject(channels: [any AlertChannel]) async {
        await router.setChannels(channels)
    }

    private func makePayload(ruleName: String = "Test Rule") -> AlertPayload {
        AlertPayload(
            ruleName: ruleName,
            event: "test.event",
            summary: "Test summary",
            workspaceTitle: "TestWS",
            timestamp: Date()
        )
    }

    func testRouteDeliversToAllChannels() async {
        let ch1 = MockAlertChannel(id: "mock1")
        let ch2 = MockAlertChannel(id: "mock2")
        await inject(channels: [ch1, ch2])

        await router.route(makePayload())

        XCTAssertEqual(ch1.sendCount, 1, "First channel should receive exactly one payload")
        XCTAssertEqual(ch2.sendCount, 1, "Second channel should receive exactly one payload")
    }

    func testRouteDeliverscorrectPayload() async {
        let ch = MockAlertChannel()
        await inject(channels: [ch])

        let payload = makePayload(ruleName: "Mem Alert")
        await router.route(payload)

        XCTAssertEqual(ch.sentPayloads.first?.ruleName, "Mem Alert",
                       "Routed payload should preserve the rule name")
    }

    func testRouteDoesNotThrowWhenChannelFails() async {
        let failing = MockAlertChannel(id: "failing")
        failing.errorToThrow = AlertChannelError.sendFailed("failing", underlyingError: nil)
        await inject(channels: [failing])

        // Must not throw — router absorbs errors
        await router.route(makePayload())
        // If we reach here, the router swallowed the error as specified
    }

    func testRouteContinuesToOtherChannelsAfterOneFailure() async {
        let failing = MockAlertChannel(id: "failing")
        failing.errorToThrow = AlertChannelError.sendFailed("failing", underlyingError: nil)
        let succeeding = MockAlertChannel(id: "succeeding")
        await inject(channels: [failing, succeeding])

        await router.route(makePayload())

        XCTAssertEqual(succeeding.sendCount, 1,
                       "Healthy channel should still receive payload after another channel fails")
    }

    func testRouteWithNoChannelsDoesNothing() async {
        await inject(channels: [])
        // Must complete without hanging or crashing
        await router.route(makePayload())
    }

    func testEnabledChannelIDsReflectsInjectedChannels() async {
        let ch1 = MockAlertChannel(id: "alpha")
        let ch2 = MockAlertChannel(id: "beta")
        await inject(channels: [ch1, ch2])

        let ids = await router.enabledChannelIDs
        XCTAssertEqual(Set(ids), ["alpha", "beta"],
                       "enabledChannelIDs should list all injected channel IDs")
    }

    func testTestChannelThrowsWhenChannelNotLoaded() async {
        await inject(channels: [])

        do {
            try await router.testChannel("slack")
            XCTFail("Expected notConfigured error")
        } catch AlertChannelError.notConfigured {
            // expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testTestChannelInvokesCorrectChannel() async throws {
        let ch = MockAlertChannel(id: "slack")
        await inject(channels: [ch])

        try await router.testChannel("slack")

        XCTAssertEqual(ch.sendCount, 1, "testChannel should invoke the matching channel once")
        XCTAssertEqual(ch.sentPayloads.first?.event, "test",
                       "testChannel should send a payload with event == 'test'")
    }
}

// MARK: - ChannelCredentialStore

final class ChannelCredentialStoreTests: XCTestCase {

    private var store: ChannelCredentialStore!
    /// Channel IDs touched in this test run — cleaned up in tearDown.
    private let testChannelIDs = ["test-slack", "test-telegram", "test-discord"]

    override func setUp() {
        super.setUp()
        store = ChannelCredentialStore()
    }

    override func tearDown() {
        // Remove all credentials and enabled state written during tests
        for channelID in testChannelIDs {
            Task { await self.store.removeAllCredentials(channelID) }
        }
        store = nil
        super.tearDown()
    }

    func testSetAndGetCredential() async {
        await store.setCredential("test-slack", "webhookURL", value: "https://hooks.slack.com/test")
        let retrieved = await store.credential("test-slack", "webhookURL")
        XCTAssertEqual(retrieved, "https://hooks.slack.com/test",
                       "Retrieved credential should match stored value")
    }

    func testGetMissingCredentialReturnsNil() async {
        let result = await store.credential("test-slack", "nonexistent")
        XCTAssertNil(result, "Missing credential should return nil")
    }

    func testRemoveCredentialMakesItUnretrievable() async {
        await store.setCredential("test-telegram", "botToken", value: "abc123")
        await store.removeCredential("test-telegram", "botToken")
        let result = await store.credential("test-telegram", "botToken")
        XCTAssertNil(result, "Removed credential should not be retrievable")
    }

    func testOverwriteCredentialReplacesValue() async {
        await store.setCredential("test-slack", "webhookURL", value: "https://old.url")
        await store.setCredential("test-slack", "webhookURL", value: "https://new.url")
        let result = await store.credential("test-slack", "webhookURL")
        XCTAssertEqual(result, "https://new.url",
                       "Second setCredential call should replace the first value")
    }

    func testChannelDisabledByDefault() async {
        let enabled = await store.isEnabled("test-slack")
        XCTAssertFalse(enabled, "Channel should be disabled when never explicitly enabled")
    }

    func testSetEnabledTrue() async {
        await store.setEnabled("test-slack", enabled: true)
        let enabled = await store.isEnabled("test-slack")
        XCTAssertTrue(enabled, "Channel should be enabled after setEnabled(true)")
    }

    func testSetEnabledFalse() async {
        await store.setEnabled("test-slack", enabled: true)
        await store.setEnabled("test-slack", enabled: false)
        let enabled = await store.isEnabled("test-slack")
        XCTAssertFalse(enabled, "Channel should be disabled after setEnabled(false)")
    }

    func testRemoveAllCredentialsClearsEnabledState() async {
        await store.setEnabled("test-discord", enabled: true)
        await store.setCredential("test-discord", "webhookURL", value: "https://discord.com/api/webhooks/test")
        await store.removeAllCredentials("test-discord")

        let enabled = await store.isEnabled("test-discord")
        XCTAssertFalse(enabled, "Enabled state should be cleared by removeAllCredentials")
    }

    func testRemoveAllCredentialsDeletesStoredSecret() async {
        await store.setCredential("test-discord", "webhookURL", value: "https://discord.com/api/webhooks/test")
        await store.removeAllCredentials("test-discord")
        let result = await store.credential("test-discord", "webhookURL")
        // Note: removeAllCredentials deletes ALL keychain items for the service,
        // so the secret should be gone.
        XCTAssertNil(result, "Credential should be nil after removeAllCredentials")
    }

    func testIndependentChannelsDoNotInterfere() async {
        await store.setCredential("test-slack", "webhookURL", value: "slack-url")
        await store.setCredential("test-telegram", "botToken", value: "tg-token")

        let slackURL = await store.credential("test-slack", "webhookURL")
        let tgToken = await store.credential("test-telegram", "botToken")
        let crossCheck = await store.credential("test-slack", "botToken")

        XCTAssertEqual(slackURL, "slack-url")
        XCTAssertEqual(tgToken, "tg-token")
        XCTAssertNil(crossCheck, "Different channel credentials should not bleed across channels")
    }
}

// MARK: - Channel request construction (no real HTTP calls)
//
// Strategy: subclass URLProtocol to intercept URLSession calls so the channel
// adapters execute their full request-building code path and we can assert on
// the outbound URLRequest without touching the network.

final class CapturingURLProtocol: URLProtocol {
    static var capturedRequests: [URLRequest] = []
    /// Body bytes read from the request stream, keyed by request index.
    static var capturedBodies: [Data] = []
    static var stubbedStatusCode: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Drain httpBodyStream so body bytes are accessible — URLSession moves
        // the body to a stream before handing the request to the protocol handler.
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n > 0 { bodyData.append(contentsOf: buf[..<n]) }
            }
            stream.close()
        }
        Self.capturedRequests.append(request)
        Self.capturedBodies.append(bodyData)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.stubbedStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Base class that installs/uninstalls CapturingURLProtocol around each test.
class ChannelAdapterTestCase: XCTestCase {
    var session: URLSession!

    override func setUp() {
        super.setUp()
        CapturingURLProtocol.capturedRequests = []
        CapturingURLProtocol.capturedBodies = []
        CapturingURLProtocol.stubbedStatusCode = 200
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session = nil
        CapturingURLProtocol.capturedRequests = []
        CapturingURLProtocol.capturedBodies = []
        super.tearDown()
    }

    func makePayload() -> AlertPayload {
        AlertPayload(
            ruleName: "Rule A",
            event: "disk.full",
            summary: "Disk usage > 95%",
            workspaceTitle: "Production",
            timestamp: Date()
        )
    }

    /// Decode the first captured request body as JSON.
    func capturedBodyJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(
            CapturingURLProtocol.capturedBodies.first,
            "No request body was captured"
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Captured body was not a JSON object"
        )
    }
}

// MARK: - SlackChannel adapter tests

final class SlackChannelTests: ChannelAdapterTestCase {

    func testSlackSendsToCorrectURL() async throws {
        let channel = SlackChannel(webhookURL: "https://hooks.slack.com/services/T/B/token",
                                   session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://hooks.slack.com/services/T/B/token")
    }

    func testSlackUsesPostMethod() async throws {
        let channel = SlackChannel(webhookURL: "https://hooks.slack.com/services/T/B/token",
                                   session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertEqual(req.httpMethod, "POST")
    }

    func testSlackSetsContentTypeJSON() async throws {
        let channel = SlackChannel(webhookURL: "https://hooks.slack.com/services/T/B/token",
                                   session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testSlackBodyContainsTextFallback() async throws {
        let channel = SlackChannel(webhookURL: "https://hooks.slack.com/services/T/B/token",
                                   session: session)
        try await channel.send(makePayload())

        let json = try capturedBodyJSON()
        XCTAssertNotNil(json["text"], "Slack body must include a 'text' fallback field")
    }

    func testSlackBodyContainsBlocks() async throws {
        let channel = SlackChannel(webhookURL: "https://hooks.slack.com/services/T/B/token",
                                   session: session)
        try await channel.send(makePayload())

        let json = try capturedBodyJSON()
        let blocks = json["blocks"] as? [[String: Any]]
        XCTAssertNotNil(blocks, "Slack body must include a 'blocks' array")
        XCTAssertFalse(blocks!.isEmpty, "Slack blocks array must not be empty")
    }

    func testSlackThrowsOnInvalidURL() async {
        let channel = SlackChannel(webhookURL: "not a url", session: session)
        do {
            try await channel.send(makePayload())
            XCTFail("Expected notConfigured error for invalid URL")
        } catch AlertChannelError.notConfigured(_) {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSlackThrowsOnNonSuccessHTTPStatus() async {
        CapturingURLProtocol.stubbedStatusCode = 500
        let channel = SlackChannel(webhookURL: "https://hooks.slack.com/services/T/B/token",
                                   session: session)
        do {
            try await channel.send(makePayload())
            XCTFail("Expected invalidResponse error")
        } catch AlertChannelError.invalidResponse(let code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - TelegramChannel adapter tests
//
// TelegramChannel validates token format: ^\d+:[A-Za-z0-9_-]{35}$
// Use a conforming fake token in all tests.

final class TelegramChannelTests: ChannelAdapterTestCase {

    /// A syntactically valid fake bot token (matches ^\d+:[A-Za-z0-9_-]{35}$).
    private let fakeToken = "123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    private let fakeChatID = "CHAT456"

    func testTelegramURLContainsBotToken() async throws {
        let channel = TelegramChannel(botToken: fakeToken, chatID: fakeChatID, session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertTrue(req.url?.absoluteString.contains(fakeToken) == true,
                      "Telegram URL must include the bot token")
    }

    func testTelegramURLPointsToSendMessage() async throws {
        let channel = TelegramChannel(botToken: fakeToken, chatID: fakeChatID, session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertTrue(req.url?.absoluteString.contains("sendMessage") == true,
                      "Telegram URL must end with sendMessage")
    }

    func testTelegramUsesPostMethod() async throws {
        let channel = TelegramChannel(botToken: fakeToken, chatID: fakeChatID, session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertEqual(req.httpMethod, "POST")
    }

    func testTelegramBodyIncludesChatID() async throws {
        let channel = TelegramChannel(botToken: fakeToken, chatID: fakeChatID, session: session)
        try await channel.send(makePayload())

        let json = try capturedBodyJSON()
        XCTAssertEqual(json["chat_id"] as? String, fakeChatID)
    }

    func testTelegramBodyUsesMarkdownParseMode() async throws {
        let channel = TelegramChannel(botToken: fakeToken, chatID: fakeChatID, session: session)
        try await channel.send(makePayload())

        let json = try capturedBodyJSON()
        XCTAssertEqual(json["parse_mode"] as? String, "Markdown",
                       "Telegram body should request Markdown parse mode")
    }

    func testTelegramBodyTextIsMarkdown() async throws {
        let channel = TelegramChannel(botToken: fakeToken, chatID: fakeChatID, session: session)
        let payload = makePayload()
        try await channel.send(payload)

        let json = try capturedBodyJSON()
        let text = json["text"] as? String
        XCTAssertEqual(text, payload.markdownBody,
                       "Telegram body 'text' field should be the markdownBody")
    }

    func testTelegramThrowsRateLimited() async {
        CapturingURLProtocol.stubbedStatusCode = 429
        let channel = TelegramChannel(botToken: fakeToken, chatID: fakeChatID, session: session)
        do {
            try await channel.send(makePayload())
            XCTFail("Expected rateLimited error")
        } catch AlertChannelError.rateLimited {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTelegramThrowsNotConfiguredForInvalidTokenFormat() async {
        let channel = TelegramChannel(botToken: "bad-token", chatID: fakeChatID, session: session)
        do {
            try await channel.send(makePayload())
            XCTFail("Expected notConfigured error for malformed token")
        } catch AlertChannelError.notConfigured(_) {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - DiscordChannel adapter tests

final class DiscordChannelTests: ChannelAdapterTestCase {

    func testDiscordSendsToCorrectURL() async throws {
        let channel = DiscordChannel(webhookURL: "https://discord.com/api/webhooks/123/abc",
                                     session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://discord.com/api/webhooks/123/abc")
    }

    func testDiscordUsesPostMethod() async throws {
        let channel = DiscordChannel(webhookURL: "https://discord.com/api/webhooks/123/abc",
                                     session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertEqual(req.httpMethod, "POST")
    }

    func testDiscordBodyContainsEmbeds() async throws {
        let channel = DiscordChannel(webhookURL: "https://discord.com/api/webhooks/123/abc",
                                     session: session)
        try await channel.send(makePayload())

        let json = try capturedBodyJSON()
        let embeds = json["embeds"] as? [[String: Any]]
        XCTAssertNotNil(embeds, "Discord body must include an 'embeds' array")
        XCTAssertFalse(embeds!.isEmpty, "Discord embeds array must not be empty")
    }

    func testDiscordEmbedTitleIsRuleName() async throws {
        let channel = DiscordChannel(webhookURL: "https://discord.com/api/webhooks/123/abc",
                                     session: session)
        let payload = makePayload()
        try await channel.send(payload)

        let json = try capturedBodyJSON()
        let embed = (json["embeds"] as? [[String: Any]])?.first
        XCTAssertEqual(embed?["title"] as? String, payload.ruleName,
                       "Discord embed title should be the rule name")
    }

    func testDiscordThrowsRateLimited() async {
        CapturingURLProtocol.stubbedStatusCode = 429
        let channel = DiscordChannel(webhookURL: "https://discord.com/api/webhooks/123/abc",
                                     session: session)
        do {
            try await channel.send(makePayload())
            XCTFail("Expected rateLimited error")
        } catch AlertChannelError.rateLimited {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - WebhookChannel adapter tests

final class WebhookChannelTests: ChannelAdapterTestCase {

    func testWebhookSendsToCorrectURL() async throws {
        let channel = WebhookChannel(url: "https://my.server.io/hook", session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://my.server.io/hook")
    }

    func testWebhookUsesPostMethod() async throws {
        let channel = WebhookChannel(url: "https://my.server.io/hook", session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertEqual(req.httpMethod, "POST")
    }

    func testWebhookSetsContentTypeJSON() async throws {
        let channel = WebhookChannel(url: "https://my.server.io/hook", session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testWebhookWithBearerTokenSetsAuthorizationHeader() async throws {
        let channel = WebhookChannel(url: "https://my.server.io/hook",
                                     bearerToken: "secret-token",
                                     session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testWebhookWithoutBearerTokenOmitsAuthorizationHeader() async throws {
        let channel = WebhookChannel(url: "https://my.server.io/hook", session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"),
                     "Authorization header must be absent when no bearer token is configured")
    }

    func testWebhookWithEmptyBearerTokenOmitsAuthorizationHeader() async throws {
        let channel = WebhookChannel(url: "https://my.server.io/hook",
                                     bearerToken: "",
                                     session: session)
        try await channel.send(makePayload())

        let req = try XCTUnwrap(CapturingURLProtocol.capturedRequests.first)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"),
                     "Authorization header must be absent when bearer token is empty string")
    }

    func testWebhookBodyIsEncodedPayload() async throws {
        let channel = WebhookChannel(url: "https://my.server.io/hook", session: session)
        let payload = makePayload()
        try await channel.send(payload)

        let reqBody = try XCTUnwrap(
            CapturingURLProtocol.capturedBodies.first,
            "No request body was captured"
        )
        let decoded = try JSONDecoder().decode(AlertPayload.self, from: reqBody)
        XCTAssertEqual(decoded.ruleName, payload.ruleName,
                       "Webhook body should be a JSON-encoded AlertPayload")
        XCTAssertEqual(decoded.event, payload.event)
    }

    func testWebhookThrowsOnInvalidURL() async {
        let channel = WebhookChannel(url: "not a url", session: session)
        do {
            try await channel.send(makePayload())
            XCTFail("Expected notConfigured error for invalid URL")
        } catch AlertChannelError.notConfigured {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWebhookThrowsOnNonSuccessHTTPStatus() async {
        CapturingURLProtocol.stubbedStatusCode = 403
        let channel = WebhookChannel(url: "https://my.server.io/hook", session: session)
        do {
            try await channel.send(makePayload())
            XCTFail("Expected invalidResponse error")
        } catch AlertChannelError.invalidResponse(let code) {
            XCTAssertEqual(code, 403)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
