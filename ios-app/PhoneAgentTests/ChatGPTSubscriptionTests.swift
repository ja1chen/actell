import XCTest
import CryptoKit
import Network
import ProviderCore
@testable import PhoneAgent

final class ChatGPTSubscriptionTests: XCTestCase {
    /// Proves only an in-process, foreground iOS loopback listener. It does not
    /// prove Safari keeps the app alive or can return to an OAuth session.
    func testForegroundLoopbackHTTPCallbackFixture() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "loopback listener ready")
        let queue = DispatchQueue(label: "subscription.callback.fixture")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue); defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port)
        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback?code=fixture")!
        let configuration = URLSessionConfiguration.ephemeral; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "OK")
    }
    func testPKCEFreshnessCallbackStateNonceAndRegistration() throws {
        let redirect = URL(string: "http://127.0.0.1:54321/auth/callback")!
        let a = try ChatGPTAuthorizationAttempt(redirect: redirect)
        let b = try ChatGPTAuthorizationAttempt(redirect: redirect)
        XCTAssertNotEqual(a.state, b.state); XCTAssertNotEqual(a.nonce, b.nonce); XCTAssertNotEqual(a.verifier, b.verifier)
        let digest = Data(SHA256.hash(data: Data(a.verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(a.challenge, digest)
        let url = a.authorizationURL(hostID: UUID())
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertTrue(url.absoluteString.contains("dynamic_agent_client"))
        XCTAssertFalse(a.description.contains(a.verifier)); XCTAssertFalse(a.description.contains(a.nonce))
        let good = URL(string: redirect.absoluteString + "?code=fixture&state=\(a.state)&client_id=oaiapp_fixture")!
        XCTAssertEqual(try a.validateCallback(good).issuedClientID, "oaiapp_fixture")
        XCTAssertNoThrow(try a.validateVerifiedNonce(a.nonce))
        XCTAssertThrowsError(try a.validateVerifiedNonce(b.nonce))
        for suffix in ["?code=x&state=wrong&client_id=oaiapp_fixture", "?code=x&state=\(a.state)", "?code=x&state=\(a.state)&client_id=dynamic_agent_client", "?state=\(a.state)&error=access_denied", "?code=x&state=\(a.state)&state=\(a.state)&client_id=oaiapp_fixture"] {
            XCTAssertThrowsError(try a.validateCallback(URL(string: redirect.absoluteString + suffix)!))
        }
        XCTAssertThrowsError(try a.validateCallback(URL(string: "http://127.0.0.1:12345/auth/callback?code=x&state=\(a.state)&client_id=oaiapp_fixture")!))
        for url in ["actell://auth/callback", "http://localhost:54321/auth/callback", "http://127.0.0.1:54321/callback", "https://127.0.0.1:54321/auth/callback"] {
            XCTAssertThrowsError(try ChatGPTAuthorizationAttempt(redirect: URL(string: url)!))
        }
    }
    func testReturningRegistrationCannotReplaceAnotherAccount() throws {
        let a = try ChatGPTAuthorizationAttempt(redirect: URL(string: "http://127.0.0.1:1455/auth/callback")!, clientID: "oaiapp_A")
        XCTAssertFalse(a.authorizationURL(hostID: UUID()).absoluteString.contains("agent_name_hint"))
        XCTAssertEqual(try a.validateCallback(URL(string: a.redirect.absoluteString + "?code=x&state=\(a.state)")!).issuedClientID, "oaiapp_A")
        XCTAssertThrowsError(try a.validateCallback(URL(string: a.redirect.absoluteString + "?code=x&state=\(a.state)&client_id=oaiapp_B")!))
    }
    func testPermissionsAndDisplayStatesDoNotPromiseInferenceOrExposeCredentials() {
        XCTAssertEqual(ChatGPTConnectionStatus.granted(tokenResponseScopes: ["openid", "email"], expired: false), .identityOnly)
        XCTAssertEqual(ChatGPTConnectionStatus.granted(tokenResponseScopes: ["chatgpt.tokens.use.direct"], expired: false), .identityOnly)
        XCTAssertEqual(ChatGPTConnectionStatus.granted(tokenResponseScopes: ["chatgpt.tokens.use.direct", "resource.invoke"], expired: false), .planAuthorized)
        XCTAssertEqual(ChatGPTConnectionStatus.granted(tokenResponseScopes: ["chatgpt.tokens.use.direct", "resource.invoke"], expired: true), .expired)
        for state: ChatGPTConnectionStatus in [.disconnected, .identityOnly, .expired, .refreshFailed, .revoked, .usageLimited, .noModels] { XCTAssertFalse(state.message.isEmpty) }
    }
    @MainActor func testSubscriptionConfigurationMigrationAndCredentialFence() throws {
        let store = ProviderStore(defaults: nil)
        var p = ProviderProfile(name: "ChatGPT")
        p.protocolKind = .chatGPTSubscription; p.settings.model = "fixture"
        let saved = try store.prepared(p)
        XCTAssertEqual(saved.inferenceAPI, .responses)
        XCTAssertEqual(saved.contextPolicy, .stateless)
        XCTAssertThrowsError(try saved.requireInference(model: "fixture"))
        XCTAssertThrowsError(try PrivateVisionProvider(settings: saved.settings, apiKey: "fixture_key", limits: AgentLimits(), providerKind: .chatGPTSubscription, inferenceAPI: .responses, sessionID: UUID()))
        p.settings.baseURL = "https://other.invalid/v1"
        XCTAssertThrowsError(try store.prepared(p))
        p.settings.baseURL = ProviderKind.chatGPTSubscription.defaultBase; p.contextKind = .responseChain
        XCTAssertThrowsError(try store.prepared(p))
        let old = ProviderProfile(name: "existing")
        XCTAssertEqual(try JSONDecoder().decode(ProviderProfile.self, from: JSONEncoder().encode(old)), old)
        XCTAssertEqual(old.inferenceAPI, .chatCompletions)
    }
    func testSubscriptionCatalogUsesVisibleSlugInServerOrder() throws {
        let rows: [String: Any] = ["models": [
            ["slug": "second", "display_name": "Second", "visibility": "list", "supported_reasoning_levels": [["effort":"low"],["effort":"high"]], "default_reasoning_level":"low"],
            ["slug": "hidden", "visibility":"hidden"], ["slug": "first", "display_name":"First", "visibility":"list"]
        ]]
        let models = try ModelDiscoveryClient.parseList(rows, providerKind: .chatGPTSubscription)
        XCTAssertEqual(models.map(\.id), ["second", "first"]); XCTAssertEqual(models.map(\.name), ["Second", "First"])
        XCTAssertEqual(models[0].reasoningEfforts, ["low", "high"]); XCTAssertNil(models[1].reasoningEfforts)
        XCTAssertThrowsError(try ModelDiscoveryClient.parseList(["data": [["id":"ordinary"]]], providerKind: .chatGPTSubscription))
    }
    func testDocumentedEffortIsExactModelEndpointAndWireScoped() {
        var p = ProviderProfile(); p.settings.model = "gpt-6.1-sol"; p.inferenceKind = .responses
        XCTAssertEqual(p.metadata(for: "gpt-6.1-sol")?.reasoningEfforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(p.metadata(for: "gpt-6.1-sol")?.defaultReasoningEffort, "medium")
        XCTAssertNil(p.metadata(for: "gpt-6.1-sol-future"))
        p.settings.baseURL = "https://proxy.invalid/v1"; XCTAssertNil(p.metadata(for: "gpt-6.1-sol"))
        p.settings.baseURL = ProviderKind.openAI.defaultBase; p.inferenceKind = .chatCompletions
        XCTAssertNil(p.metadata(for: "gpt-6.1-sol"))
    }
    func testEffortRequiresModelDeclarationAndMapsResponsesWire() throws {
        var metadata = DiscoveredModel(id: "fixture", name: "fixture")
        metadata.reasoningEfforts = ["low", "high"]; metadata.defaultReasoningEffort = "low"
        var parameters = ModelParameters(); parameters.reasoningEffort = "high"
        XCTAssertEqual(try parameters.requestFields(providerKind: .openAI, model: metadata)["reasoning_effort"] as? String, "high")
        var settings = ProviderSettings(); settings.model = "fixture"
        let provider = try PrivateVisionProvider(settings: settings, apiKey: "fixture", limits: AgentLimits(), parameters: parameters, metadata: metadata, inferenceAPI: .responses, sessionID: UUID())
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(provider.prepareRequest(ModelRequest(model: "fixture", messages: [.user("fixture")]), stream: true).httpBody)) as! [String: Any]
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "high"); XCTAssertNil(body["reasoning_effort"])
        let chat = try PrivateVisionProvider(settings: settings, apiKey: "fixture", limits: AgentLimits(), parameters: parameters, metadata: metadata, sessionID: UUID())
        let chatBody = try JSONSerialization.jsonObject(with: XCTUnwrap(chat.prepareRequest(ModelRequest(model: "fixture", messages: [.user("fixture")]), stream: true).httpBody)) as! [String: Any]
        XCTAssertEqual(chatBody["reasoning_effort"] as? String, "high"); XCTAssertNil(chatBody["reasoning"])
        XCTAssertThrowsError(try parameters.requestFields(providerKind: .openAI, model: nil))
        parameters.reasoningEffort = "ultra"; XCTAssertThrowsError(try parameters.requestFields(providerKind: .openAI, model: metadata))
        parameters.reasoningEffort = nil; XCTAssertNil(try parameters.requestFields(providerKind: .openAI, model: nil)["reasoning_effort"])
    }
}
