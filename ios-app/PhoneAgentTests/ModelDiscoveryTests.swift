import XCTest
import ProviderCore
@testable import PhoneAgent

private final class ModelHTTPStub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let block = Self.lock.withLock { Self.requests.append(request); return Self.handler }
            guard let block else { throw URLError(.notConnectedToInternet) }
            let (status, body) = try block(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ModelDiscoveryTests: XCTestCase {
    func testMissingDefaultSelectsFirstAvailableModelAndPreservesSelection() throws {
        var p = profile()
        p.settings.model = " \n"
        p.models = [" ", "first", "second"]
        p.selectDefaultModelIfNeeded()
        XCTAssertEqual(p.settings.model, "first")
        p.settings.model = "manual"
        p.selectDefaultModelIfNeeded()
        XCTAssertEqual(p.settings.model, "manual")
        p.settings.model = ""; p.models = []
        p.catalog = ModelCatalog(endpoint: try p.catalogEndpoint(), fetchedAt: Date(), models: [.init(id: "catalog-first", name: "First"), .init(id: "catalog-second", name: "Second")])
        p.selectDefaultModelIfNeeded()
        XCTAssertEqual(p.settings.model, "catalog-first")
        p.settings.model = ""; p.settings.baseURL = "https://other.invalid/v1"
        p.selectDefaultModelIfNeeded()
        XCTAssertEqual(p.settings.model, "")
        p.catalog = nil
        p.selectDefaultModelIfNeeded()
        XCTAssertEqual(p.settings.model, "")
    }
    @MainActor func testDefaultModelIsSelectedOnSaveAndLegacyLoad() throws {
        let defaults = UserDefaults(suiteName: "automatic-default-model-\(UUID())")!
        defer { defaults.removeObject(forKey: ProviderStore.storageKey) }
        var p = profile()
        p.settings.model = ""; p.models = ["first", "second"]
        let store = ProviderStore(defaults: defaults)
        try store.save(p)
        XCTAssertEqual(store.profile(p.id)?.settings.model, "first")
        XCTAssertEqual(ProviderStore(defaults: defaults).profile(p.id)?.settings.model, "first")
        struct SavedArchive: Encodable {
            let version = 1
            let profiles: [ProviderProfile]
            let removed: [ProviderProfile]
        }
        defaults.set(try JSONEncoder().encode(SavedArchive(profiles: [p], removed: [])), forKey: ProviderStore.storageKey)
        XCTAssertEqual(ProviderStore(defaults: defaults).profile(p.id)?.settings.model, "first")
    }
    func testModelPreviewKeepsOrderAndAppendsSelectedOutsideLimit() throws {
        var p = profile()
        p.models = ["one", "two", "three", "four", "five", "six", "seven", "one"]
        p.settings.model = "seven"
        XCTAssertEqual(p.previewModels, ["one", "two", "three", "four", "five", "seven"])
        p.settings.model = "two"
        XCTAssertEqual(p.previewModels, ["one", "two", "three", "four", "five"])
        p.settings.model = "manual"
        XCTAssertEqual(p.previewModels, ["one", "two", "three", "four", "five", "manual"])
        p.models = []; p.settings.model = ""
        XCTAssertEqual(p.previewModels, [])
        p.catalog = ModelCatalog(endpoint: try p.catalogEndpoint(), fetchedAt: Date(), models: (1...7).map { .init(id: "model-\($0)", name: "fixture") })
        p.settings.model = "model-7"
        XCTAssertEqual(p.previewModels, ["model-1", "model-2", "model-3", "model-4", "model-5", "model-7"])
        p.settings.baseURL = "https://other.invalid/v1"
        XCTAssertEqual(p.previewModels, ["model-7"])
    }
    @MainActor func testRemovedServiceChoicesKeepExistingArchiveReadable() throws {
        XCTAssertEqual(ProviderKind.selectableKinds, [.openAI, .openRouter, .chatGPTSubscription])
        let defaults = UserDefaults(suiteName: "removed-provider-types-\(UUID())")!
        defer { defaults.removeObject(forKey: ProviderStore.storageKey) }
        let legacy = [ProviderKind.anthropic, .gemini, .ollama].map { kind in
            profile(kind, base: kind.defaultBase)
        }
        let profiles = legacy + [profile(.openRouter, base: ProviderKind.openRouter.defaultBase)]
        struct SavedArchive: Encodable {
            let version = 1
            let profiles: [ProviderProfile]
            let removed: [ProviderProfile]
        }
        defaults.set(try JSONEncoder().encode(SavedArchive(profiles: profiles, removed: [])), forKey: ProviderStore.storageKey)
        let restored = ProviderStore(defaults: defaults)
        XCTAssertNil(restored.warning)
        XCTAssertEqual(restored.profiles, profiles)
        XCTAssertTrue(legacy.allSatisfy { !$0.providerKind.isSelectable })
        XCTAssertTrue(restored.profiles.last!.providerKind.isSelectable)
    }
    override func tearDown() {
        ModelHTTPStub.lock.withLock { ModelHTTPStub.handler = nil; ModelHTTPStub.requests = [] }
        super.tearDown()
    }
    private func client(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> ModelDiscoveryClient {
        ModelHTTPStub.lock.withLock { ModelHTTPStub.handler = handler; ModelHTTPStub.requests = [] }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ModelHTTPStub.self]
        return ModelDiscoveryClient(configuration: config)
    }
    private func profile(_ kind: ProviderKind = .openAI, base: String = "https://fixture.invalid/proxy/v1/") -> ProviderProfile {
        var profile = ProviderProfile(name: "synthetic", settings: .init(baseURL: base, model: "test"))
        profile.protocolKind = kind; return profile
    }
    func testURLRulesKeepPrefixesAndNeverGuessVersionOrAcceptCompletionEndpoint() throws {
        let client = ModelDiscoveryClient()
        for (kind, base, expected) in [
            (ProviderKind.openAI, "https://fixture.invalid/team/v1/", "/team/v1/models"),
            (.openAI, "https://fixture.invalid/custom", "/custom/models"),
            (.anthropic, "https://fixture.invalid/team/", "/team/v1/models"),
            (.anthropic, "https://fixture.invalid/team/v1/", "/team/v1/models"),
            (.gemini, "https://fixture.invalid/team/v1beta/", "/team/v1beta/models"),
            (.ollama, "https://fixture.invalid/team/api/", "/team/api/tags"),
            (.openRouter, "https://fixture.invalid/team/api/v1/", "/team/api/v1/models")
        ] {
            XCTAssertEqual(try client.request(profile: profile(kind, base: base), key: "fixture").url?.path, expected)
        }
        for base in ["https://fixture.invalid/v1/chat/completions/", "https://fixture.invalid/v1/models", "https://name:secret@fixture.invalid/v1", "https://fixture.invalid/v1?key=secret", "http://fixture.invalid/v1"] {
            XCTAssertThrowsError(try ProviderKind.openAI.baseURL(base))
        }
    }
    func testProtocolHeadersAndPaginationTokensNeverGoInCredentialsQuery() throws {
        let client = ModelDiscoveryClient()
        let a = try client.request(profile: profile(.anthropic), key: "synthetic-key", cursor: "a/b?x=y")
        XCTAssertEqual(a.value(forHTTPHeaderField: "x-api-key"), "synthetic-key")
        XCTAssertEqual(a.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(a.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(URLComponents(url: a.url!, resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "a/b?x=y")
        let g = try client.request(profile: profile(.gemini), key: "synthetic-key")
        XCTAssertEqual(g.value(forHTTPHeaderField: "x-goog-api-key"), "synthetic-key")
        XCTAssertFalse(g.url!.absoluteString.contains("synthetic-key"))
    }
    func testAnthropicPagesDeduplicateAndRetainUnknownCapabilities() async throws {
        let client = client { request in
            if request.url!.query!.contains("after_id") {
                return (200, #"{"data":[{"id":"a"},{"id":"b","capabilities":{"image_input":{"supported":false}}}],"has_more":false}"#)
            }
            return (200, #"{"data":[{"id":"a","capabilities":{"image_input":{"supported":true}},"max_tokens":4000}],"has_more":true,"last_id":"a"}"#)
        }
        let result = try await client.fetch(profile: profile(.anthropic), key: "fixture")
        XCTAssertEqual(result.models.map(\.id), ["a", "b"])
        XCTAssertEqual(result.models[0].vision, .unknown)
        XCTAssertEqual(result.models[1].vision, .unsupported)
        XCTAssertEqual(result.models[1].tools, .unknown)
        XCTAssertEqual(ModelHTTPStub.requests.count, 2)
    }
    func testGeminiPaginationMethodsAndTokenMetadataDoNotInventVision() async throws {
        let client = client { request in
            if request.url!.query!.contains("pageToken") { return (200, #"{"models":[{"name":"models/embed","supportedGenerationMethods":["embedContent"]}]}"#) }
            return (200, #"{"models":[{"name":"models/generate","supportedGenerationMethods":["generateContent"],"inputTokenLimit":1000,"outputTokenLimit":200,"maxTemperature":1.5}],"nextPageToken":"next+page"}"#)
        }
        let result = try await client.fetch(profile: profile(.gemini), key: "fixture")
        XCTAssertEqual(result.models[0].inputTokenLimit, 1000)
        XCTAssertEqual(result.models[0].maxTemperature, 1.5)
        XCTAssertEqual(result.models[0].generation, .supported)
        XCTAssertEqual(result.models[0].vision, .unknown)
        XCTAssertEqual(result.models[1].generation, .unsupported)
    }
    func testOpenRouterUsesOffsetAndIgnoresForeignNextLink() async throws {
        let client = client { request in
            XCTAssertEqual(request.url?.host, "fixture.invalid")
            if request.url!.query!.contains("offset=1") { return (200, #"{"data":[{"id":"b"}],"total_count":2}"#) }
            return (200, #"{"data":[{"id":"a","architecture":{"input_modalities":["text","image"]},"supported_parameters":["tools","temperature"],"top_provider":{"max_completion_tokens":300},"pricing":{"prompt":"0.001"}}],"total_count":2,"links":{"next":"https://foreign.invalid/steal"}}"#)
        }
        let result = try await client.fetch(profile: profile(.openRouter), key: "fixture")
        XCTAssertEqual(result.models.count, 2)
        XCTAssertEqual(result.models[0].vision, .supported); XCTAssertEqual(result.models[0].tools, .supported)
        XCTAssertEqual(result.models[0].outputTokenLimit, 300)
        XCTAssertEqual(result.models[0].pricing?["prompt"], "0.001")
        XCTAssertEqual(result.models[1].vision, .unknown)
    }
    func testOllamaFetchesShowMetadataWithoutGenerationAndPartialFailureStaysUnknown() async throws {
        let client = client { request in
            if request.url!.path.hasSuffix("tags") { return (200, #"{"models":[{"name":"vision"},{"name":"unknown"}]}"#) }
            XCTAssertTrue(request.url!.path.hasSuffix("show")); XCTAssertEqual(request.httpMethod, "POST")
            let recordedShows = ModelHTTPStub.lock.withLock { ModelHTTPStub.requests.filter { $0.httpMethod == "POST" }.count }
            if recordedShows == 2 { return (404, "ignored private body") }
            return (200, #"{"capabilities":["vision","tools","completion"],"model_info":{"general.architecture":"sample","sample.context_length":2048},"parameters":"temperature 0.8"}"#)
        }
        let result = try await client.fetch(profile: profile(.ollama, base: "https://fixture.invalid/team"), key: "")
        XCTAssertEqual(result.models[0].vision, .supported); XCTAssertEqual(result.models[0].contextTokenLimit, 2048)
        XCTAssertNil(result.models[0].inputTokenLimit, "A total context window is not an independent input maximum")
        XCTAssertNil(result.models[0].supportedParameters, "Defaults are not a parameter support schema")
        XCTAssertEqual(result.models[1].tools, .unknown); XCTAssertNotNil(result.models[1].detailNotice)
        XCTAssertTrue(ModelHTTPStub.requests.allSatisfy { !$0.url!.path.contains("chat") && $0.value(forHTTPHeaderField: "Authorization") == nil })
    }
    func testErrorsAreActionableAndNeverExposeBodiesOrKey() async {
        for status in [401, 403, 404, 429, 302, 500] {
            let client = client { _ in (status, "synthetic-secret private-response") }
            do { _ = try await client.fetch(profile: profile(), key: "synthetic-secret"); XCTFail("must fail") }
            catch {
                let message = ModelDiscoveryClient.failure(error)
                XCTAssertFalse(message.contains("synthetic-secret")); XCTAssertFalse(message.contains("private-response"))
                if status != 302 { XCTAssertTrue(message.contains(String(status))) }
            }
        }
        XCTAssertTrue(ModelDiscoveryClient.failure(URLError(.timedOut)).contains("超时"))
        XCTAssertTrue(ModelDiscoveryClient.failure(URLError(.notConnectedToInternet)).contains("缓存"))
    }
    func testRepeatedPaginationFailsInsteadOfLoopingOrReturningPartialSuccess() async {
        let client = client { _ in (200, #"{"data":[{"id":"a"}],"has_more":true,"last_id":"same"}"#) }
        do { _ = try await client.fetch(profile: profile(.anthropic), key: ""); XCTFail("must fail") }
        catch { XCTAssertTrue(ModelDiscoveryClient.failure(error).contains("分页")) }
        XCTAssertEqual(ModelHTTPStub.requests.count, 2)
    }
    func testMissingArraysInvalidJSONAndCancellationFailWithoutInference() async {
        for body in ["html", "{}", #"{"data":[{}]}"#] {
            let client = client { _ in (200, body) }
            do { _ = try await client.fetch(profile: profile(), key: ""); XCTFail("must fail") } catch {}
        }
        let client = client { _ in throw URLError(.cancelled) }
        do { _ = try await client.fetch(profile: profile(), key: ""); XCTFail("must cancel") }
        catch { XCTAssertTrue(ModelDiscoveryClient.failure(error).contains("取消")) }
    }
    func testRedirectDelegateNeverForwardsCredentials() {
        let url = URL(string: "https://fixture.invalid/models")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location":"https://foreign.invalid"])!
        var next = URLRequest(url: URL(string: "https://foreign.invalid")!); next.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        NoRedirectDelegate().urlSession(.shared, task: URLSession.shared.dataTask(with: url), willPerformHTTPRedirection: response, newRequest: next) {
            XCTAssertNil($0)
        }
    }
    func testInferenceUsesOnlyExplicitCompatibleParametersAndCorrectEndpoint() throws {
        let parameters = ModelParameters(values: ["temperature":"0.4", "max_tokens":"150", "seed":"2", "unknown":"private"])
        let metadata = DiscoveredModel(id: "a", name: "a", supportedParameters: ["temperature", "max_tokens"])
        let provider = try PrivateVisionProvider(settings: .init(baseURL: "https://fixture.invalid/proxy/api/v1/", model: "a"), apiKey: "synthetic", limits: .init(), providerKind: .openRouter, parameters: parameters, metadata: metadata, sessionID: UUID())
        let request = try provider.prepareRequest(.init(model: "a", messages: [.user("test")], temperature: 1, maxTokens: 999, topP: 0.9), stream: false)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(request.url?.path, "/proxy/api/v1/chat/completions")
        XCTAssertEqual(body["temperature"] as? Double, 0.4); XCTAssertEqual(body["max_tokens"] as? Int, 150)
        XCTAssertNil(body["seed"]); XCTAssertNil(body["top_p"]); XCTAssertNil(body["unknown"])
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, true)
        let ollama = try PrivateVisionProvider(settings: .init(baseURL: "https://fixture.invalid/proxy/api", model: "a"), apiKey: "", limits: .init(), providerKind: .ollama, sessionID: UUID())
        let o = try ollama.prepareRequest(.init(model: "a", messages: [.user("test")]), stream: false)
        XCTAssertEqual(o.url?.path, "/proxy/v1/chat/completions"); XCTAssertNil(o.value(forHTTPHeaderField: "Authorization"))
    }
    func testNativeProtocolsNeverFallBackToOpenAIInferenceAndUnknownIsNotFalse() throws {
        for kind in [ProviderKind.anthropic, .gemini] {
            XCTAssertThrowsError(try profile(kind).requireInference(model: "a"))
            XCTAssertThrowsError(try PrivateVisionProvider(settings: profile(kind).settings, apiKey: "fixture", limits: .init(), providerKind: kind, sessionID: UUID()))
        }
        XCTAssertNoThrow(try profile().requireInference(model: "unknown-manual"))
        XCTAssertEqual(ModelParameter.temperature.support(providerKind: .openAI, model: nil), .unknown)
        XCTAssertThrowsError(try ModelParameters(values: ["temperature":"nan"]).requestFields(providerKind: .openAI, model: nil))
        XCTAssertThrowsError(try ModelParameters(values: ["top_p":"1.5"]).requestFields(providerKind: .openAI, model: nil))
        XCTAssertThrowsError(try ModelParameters(values: ["max_tokens":"2", "max_completion_tokens":"3"]).requestFields(providerKind: .openAI, model: nil))
    }
}

@MainActor final class ModelCatalogPersistenceTests: XCTestCase {
    func testOldProfileDecodesAndCacheOverridesStayIsolatedAcrossRestoreAndEndpointChanges() throws {
        let defaults = UserDefaults(suiteName: "test.modelCatalog.\(UUID())")!
        let store = ProviderStore(defaults: defaults)
        var a = ProviderProfile(name: "a", settings: .init(baseURL: "https://a.invalid/v1", model: "same"))
        let old = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(ProviderProfile.self, from: old).providerKind, .openAI)
        a.catalog = .init(endpoint: try a.catalogEndpoint(), fetchedAt: Date(), models: [.init(id: "found", name: "Found")])
        a.modelParameters = ["same": .init(values: ["temperature":"0.2"])]
        try store.save(a)
        let b = ProviderProfile(name: "b", settings: .init(baseURL: "https://b.invalid/v1", model: "same"))
        try store.save(b); try store.remove(a.id); try store.restore(a.id)
        let restored = ProviderStore(defaults: defaults)
        XCTAssertEqual(restored.profile(a.id)?.availableModels, ["same", "found"])
        XCTAssertEqual(restored.profile(a.id)?.parameters(for: "same").values["temperature"], "0.2")
        XCTAssertTrue(restored.profile(b.id)!.parameters(for: "same").values.isEmpty)
        XCTAssertTrue(restored.profile(a.id)!.parameters(for: "other-model").values.isEmpty)
        let key = restored.profile(a.id)!.keyAccount
        a.protocolKind = .anthropic; try restored.save(a)
        XCTAssertNil(restored.profile(a.id)?.currentCatalog); XCTAssertNil(restored.profile(a.id)?.modelParameters)
        XCTAssertNotEqual(restored.profile(a.id)?.keyAccount, key)
        defaults.removeObject(forKey: ProviderStore.storageKey)
    }
    func testCancelledFetchCannotPublishLateCatalogOrOverwriteExistingDraft() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ModelHTTPStub.self]
        ModelHTTPStub.lock.withLock { ModelHTTPStub.handler = { _ in (200, #"{"data":[{"id":"late"}]}"#) } }
        defer { ModelHTTPStub.lock.withLock { ModelHTTPStub.handler = nil; ModelHTTPStub.requests = [] } }
        let state = ModelDiscoveryState(client: ModelDiscoveryClient(configuration: configuration))
        var profile = ProviderProfile(settings: .init(model: "manual"))
        profile.catalog = .init(endpoint: try profile.catalogEndpoint(), fetchedAt: Date(), models: [.init(id: "cached", name: "Cached")])
        state.refresh(profile: profile, key: "") { profile.catalog = $0 }
        state.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(state.loading); XCTAssertEqual(profile.currentCatalog?.models.first?.id, "cached")
    }
}
