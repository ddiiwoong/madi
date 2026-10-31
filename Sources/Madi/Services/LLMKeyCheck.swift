import Foundation

/// 키 확인의 결과.
enum KeyCheckResult: Equatable {
    /// 키가 받아들여졌다. 모델 수와, 소곤의 권장 모델이 그 목록에 있는가.
    case accepted(models: Int, hasRecommended: Bool)
    /// 서비스가 키를 거절했다(401·403). 서비스가 준 문장을 함께 둔다.
    case rejected(status: Int, message: String)
    /// 키 말고 다른 이유로 실패했다(다른 상태 코드, 읽을 수 없는 응답).
    case failed(String)
    /// 서비스에 닿지 못했다(네트워크).
    case unreachable(String)

    /// 화면에 적을 한 줄.
    func line(for service: LLMService) -> String {
        switch self {
        case let .accepted(models, hasRecommended):
            return hasRecommended
                ? String(localized: "키가 맞습니다 — 모델 \(models)개, 권장 모델 \(service.recommendedModel) 있음")
                // 조사를 보간값 뒤에 붙이지 않는다 — 모델 이름의 끝소리를 알 수 없다. 콜론으로 붙인다.
                : String(localized: "키가 맞습니다 — 모델 \(models)개. 목록에 권장 모델이 없습니다: \(service.recommendedModel)")
        case let .rejected(status, message):
            return String(localized: "키가 거절됐습니다 (HTTP \(status)): \(message)")
        case let .failed(message):
            return String(localized: "확인하지 못했습니다: \(message)")
        case let .unreachable(message):
            return String(localized: "서비스에 닿지 못했습니다: \(message)")
        }
    }
}

/// 키를 확인하는 곳. 설정 화면이 부르고, 테스트가 대역을 넣는다.
@MainActor
protocol KeyChecking {
    func check(_ service: LLMService, key: String, region: String?) async -> KeyCheckResult
}

/// 서비스에 모델 목록을 묻는다(`LLMService.modelListRequest`). **문서는 보내지 않는다.**
///
/// 세션은 쿠키·캐시를 쓰지 않는다 — 키 확인이 남길 것은 결과 한 줄뿐이다.
struct LiveKeyChecker: KeyChecking {

    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    func check(_ service: LLMService, key: String, region: String?) async -> KeyCheckResult {
        guard let request = service.modelListRequest(key: key, region: region) else {
            return .failed(String(localized: "키나 리전이 비어 있거나 맞지 않습니다"))
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .failed(String(localized: "HTTP 응답이 아닙니다"))
        }
        let message = LLMService.errorMessage(from: data)
            ?? String(String(decoding: data.prefix(200), as: UTF8.self))
        switch http.statusCode {
        case 200 ..< 300:
            let models = service.modelIDs(from: data)
            guard !models.isEmpty else { return .failed(String(localized: "모델 목록을 읽지 못했습니다")) }
            return .accepted(models: models.count, hasRecommended: models.contains(service.recommendedModel))
        case 401, 403:
            return .rejected(status: http.statusCode, message: message)
        default:
            return .failed("HTTP \(http.statusCode): \(message)")
        }
    }
}
