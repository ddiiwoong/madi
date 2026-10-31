import AppKit
import XCTest

/// LLM 교정 키 — 서비스별 요청 모양(`LLMService`, Core).
final class LLMServiceTests: XCTestCase {

    func testEveryServiceAsksForTheModelListWithoutABody() throws {
        for service in LLMService.allCases {
            let request = try XCTUnwrap(service.modelListRequest(key: "secret-key", region: "us-west-2"),
                                        service.rawValue)
            XCTAssertEqual(request.httpMethod, "GET", service.rawValue)
            XCTAssertNil(request.httpBody, "키 확인은 몸통이 없다 — 문서를 싣지 않는다: \(service)")
            XCTAssertEqual(request.url?.scheme, "https", service.rawValue)
            // 키는 주소에 싣지 않는다 — 주소는 로그에 남는다.
            XCTAssertFalse(request.url?.absoluteString.contains("secret-key") == true, service.rawValue)
        }
    }

    func testEachServiceUsesItsOwnAuthHeader() throws {
        let anthropic = try XCTUnwrap(LLMService.anthropic.modelListRequest(key: "k"))
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01", "없으면 400")
        XCTAssertNil(anthropic.value(forHTTPHeaderField: "Authorization"))

        let gemini = try XCTUnwrap(LLMService.gemini.modelListRequest(key: "k"))
        XCTAssertEqual(gemini.value(forHTTPHeaderField: "x-goog-api-key"), "k")

        for service in [LLMService.openai, .groq, .bedrock] {
            let request = try XCTUnwrap(service.modelListRequest(key: "k"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k", service.rawValue)
        }
    }

    func testEndpoints() {
        XCTAssertEqual(LLMService.anthropic.modelListRequest(key: "k")?.url?.host, "api.anthropic.com")
        XCTAssertEqual(LLMService.openai.modelListRequest(key: "k")?.url?.absoluteString,
                       "https://api.openai.com/v1/models")
        XCTAssertEqual(LLMService.groq.modelListRequest(key: "k")?.url?.path, "/openai/v1/models")
        XCTAssertEqual(LLMService.gemini.modelListRequest(key: "k")?.url?.host,
                       "generativelanguage.googleapis.com")
        XCTAssertEqual(LLMService.bedrock.modelListRequest(key: "k", region: "ap-northeast-2")?.url?.absoluteString,
                       "https://bedrock.ap-northeast-2.amazonaws.com/foundation-models")
        XCTAssertEqual(LLMService.bedrock.modelListRequest(key: "k")?.url?.host,
                       "bedrock.us-east-1.amazonaws.com", "리전이 없으면 기본값")
    }

    /// 리전은 호스트 이름에 들어간다 — 아무 글자나 받으면 다른 호스트로 키를 보낼 수 있다.
    func testRegionIsValidatedBeforeItBecomesAHost() {
        XCTAssertNil(LLMService.bedrock.modelListRequest(key: "k", region: "evil.example.com/x"))
        XCTAssertNil(LLMService.bedrock.modelListRequest(key: "k", region: "US-EAST-1"))
        XCTAssertNil(LLMService.bedrock.modelListRequest(key: "k", region: ""))
        XCTAssertTrue(LLMService.isValidRegion("eu-central-2"))
    }

    func testBlankKeyMakesNoRequest() {
        XCTAssertNil(LLMService.openai.modelListRequest(key: "  \n"))
        // 붙여 넣은 키 끝의 줄바꿈은 뗀다.
        XCTAssertEqual(LLMService.openai.modelListRequest(key: "sk-1\n")?
            .value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
    }

    func testModelListsAreReadPerService() {
        let openAIStyle = Data(#"{"data":[{"id":"gpt-5.5"},{"id":"gpt-5.4"}]}"#.utf8)
        XCTAssertEqual(LLMService.openai.modelIDs(from: openAIStyle), ["gpt-5.5", "gpt-5.4"])
        XCTAssertEqual(LLMService.anthropic.modelIDs(from: openAIStyle).count, 2)
        XCTAssertEqual(LLMService.groq.modelIDs(from: openAIStyle).count, 2)

        let gemini = Data(#"{"models":[{"name":"models/gemini-3.5-flash-lite"},{"name":"models/x"}]}"#.utf8)
        XCTAssertEqual(LLMService.gemini.modelIDs(from: gemini), ["gemini-3.5-flash-lite", "x"])

        let bedrock = Data(#"{"modelSummaries":[{"modelId":"amazon.nova-lite-v1:0"}]}"#.utf8)
        XCTAssertEqual(LLMService.bedrock.modelIDs(from: bedrock), ["amazon.nova-lite-v1:0"])

        XCTAssertEqual(LLMService.openai.modelIDs(from: Data("nope".utf8)), [])
    }

    func testErrorMessagesAreRead() {
        XCTAssertEqual(LLMService.errorMessage(from: Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8)),
                       "invalid x-api-key")
        XCTAssertEqual(LLMService.errorMessage(from: Data(#"{"message":"bad token"}"#.utf8)), "bad token")
        XCTAssertEqual(LLMService.errorMessage(from: Data(#"{"Message":"denied"}"#.utf8)), "denied")
        XCTAssertNil(LLMService.errorMessage(from: Data("<html>".utf8)))
    }
}

/// 응답을 정해 두는 URL 프로토콜. 네트워크에 나가지 않는다.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (status: Int, body: Data)? = (200, Data())
    nonisolated(unsafe) static var failure: URLError?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.append(request)
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let reply = Self.reply ?? (200, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 키 확인(`LiveKeyChecker`) — 응답을 어떻게 읽는가.
@MainActor
final class LiveKeyCheckerTests: XCTestCase {

    private var checker: LiveKeyChecker!

    override func setUp() async throws {
        StubURLProtocol.reply = (200, Data())
        StubURLProtocol.failure = nil
        StubURLProtocol.seen = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        checker = LiveKeyChecker(session: URLSession(configuration: configuration))
    }

    func testAcceptedKeyReportsModelsAndTheRecommendedOne() async {
        StubURLProtocol.reply = (200, Data(#"{"data":[{"id":"claude-haiku-5-5"},{"id":"claude-opus-5-5"}]}"#.utf8))
        let result = await checker.check(.anthropic, key: "sk-ant-x", region: nil)
        XCTAssertEqual(result, .accepted(models: 2, hasRecommended: true))
        XCTAssertEqual(StubURLProtocol.seen.first?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-x")

        StubURLProtocol.reply = (200, Data(#"{"data":[{"id":"other"}]}"#.utf8))
        let without = await checker.check(.anthropic, key: "k", region: nil)
        XCTAssertEqual(without, .accepted(models: 1, hasRecommended: false))
        XCTAssertTrue(without.line(for: .anthropic).contains("claude-haiku-5-5"))
    }

    func testRejectedKeyCarriesTheServiceMessage() async {
        StubURLProtocol.reply = (401, Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8))
        let result = await checker.check(.anthropic, key: "bad", region: nil)
        XCTAssertEqual(result, .rejected(status: 401, message: "invalid x-api-key"))
    }

    func testOtherFailuresAreNotCalledRejections() async {
        StubURLProtocol.reply = (500, Data("oops".utf8))
        guard case let .failed(message) = await checker.check(.groq, key: "k", region: nil) else {
            return XCTFail("500을 키 거절로 읽었다")
        }
        XCTAssertTrue(message.contains("500"))

        StubURLProtocol.reply = (200, Data("{}".utf8))
        guard case .failed = await checker.check(.groq, key: "k", region: nil) else {
            return XCTFail("빈 목록을 키가 맞다고 읽었다")
        }
    }

    func testNetworkErrorIsUnreachable() async {
        StubURLProtocol.failure = URLError(.notConnectedToInternet)
        guard case .unreachable = await checker.check(.openai, key: "k", region: nil) else {
            return XCTFail("네트워크 오류가 아니라고 읽었다")
        }
    }

    func testBedrockAsksTheGivenRegion() async {
        StubURLProtocol.reply = (200, Data(#"{"modelSummaries":[{"modelId":"amazon.nova-lite-v1:0"}]}"#.utf8))
        let result = await checker.check(.bedrock, key: "k", region: "eu-west-1")
        XCTAssertEqual(result, .accepted(models: 1, hasRecommended: true))
        XCTAssertEqual(StubURLProtocol.seen.first?.url?.host, "bedrock.eu-west-1.amazonaws.com")
    }
}

/// 실제 키체인 — 만들고, 있는지 묻고, 꺼내고, 고치고, 지운다. 이 시험만 쓰는 service 이름이라
/// 사용자의 항목에 닿지 않고, 끝나면 지운다.
@MainActor
final class KeychainSecretStoreTests: XCTestCase {

    func testRoundTripInTheLoginKeychain() throws {
        let store = KeychainSecretStore(service: "dev.jinwoong.md.tests.\(UUID().uuidString)")
        addTeardownBlock { @MainActor in store.removeSecret(for: "anthropic") }

        XCTAssertFalse(store.hasSecret(for: "anthropic"))
        XCTAssertNil(store.secret(for: "anthropic"))

        try store.setSecret("sk-ant-1", for: "anthropic", label: "마디 시험")
        XCTAssertTrue(store.hasSecret(for: "anthropic"))
        XCTAssertEqual(store.secret(for: "anthropic"), "sk-ant-1")

        try store.setSecret("sk-ant-2", for: "anthropic", label: "마디 시험")
        XCTAssertEqual(store.secret(for: "anthropic"), "sk-ant-2", "있으면 고친다")

        store.removeSecret(for: "anthropic")
        XCTAssertFalse(store.hasSecret(for: "anthropic"))
    }
}
