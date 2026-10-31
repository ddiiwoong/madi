import Foundation

/// LLM 교정에 쓸 바깥 서비스 — 소곤(Sogon)이 부르는 서비스와 같은 다섯이다.
///
/// **지금은 키를 두고 확인하는 데까지다.** 문서를 바깥으로 보내는 교정은 아직 없다 — 보낼지는
/// 사람이 정할 일이고(TODO '결정이 필요한 것'), 정해지기 전까지 이 타입은 문서를 싣는 요청을
/// 만들지 않는다. 키 확인은 그 서비스에 **모델 목록만** 묻는다.
///
/// 소곤에서 가져온 것: 서비스마다 인증 헤더가 다르다는 것(Anthropic `x-api-key` + 필수
/// `anthropic-version`, Gemini `x-goog-api-key` — 질의 문자열 `?key=`로도 되지만 그러면 키가 주소에
/// 실려 로그에 남는다, 나머지는 `Bearer`), 권장 모델(소곤이 재 보고 정한 기본값).
/// 가져오지 않은 것: 소곤의 OpenAI는 Codex CLI의 로그인 토큰으로 ChatGPT 내부 주소를 부른다 —
/// 공개 API가 아니어서 마디는 OpenAI의 공개 API 키를 쓴다. 로컬 MLX는 Swift 꾸러미가 필요해
/// 넣지 않았다(마디는 Swift 의존성이 없다).
public enum LLMService: String, CaseIterable, Sendable {
    case anthropic
    case openai
    case gemini
    case groq
    case bedrock

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .bedrock: return "Amazon Bedrock"
        }
    }

    /// 키를 받는 곳. 화면에 그대로 적는다(링크로 열지 않는다 — 누르는 순간 브라우저가 열린다).
    public var keyConsole: String {
        switch self {
        case .anthropic: return "console.anthropic.com"
        case .openai: return "platform.openai.com/api-keys"
        case .gemini: return "aistudio.google.com/apikey"
        case .groq: return "console.groq.com/keys"
        case .bedrock: return "console.aws.amazon.com/bedrock"
        }
    }

    /// 소곤의 기본 모델. 키 확인이 "이 키로 그 모델을 쓸 수 있는가"를 함께 알려 준다.
    ///
    /// 목록 전체를 들고 있지 않는다 — 모델 목록은 몇 달이면 낡고(소곤이 겪었다), 지금 마디에는
    /// 모델을 고를 곳이 없다(교정이 없으므로). 목록은 키 확인이 서비스에게 묻는다.
    public var recommendedModel: String {
        switch self {
        case .anthropic: return "claude-haiku-5-5"
        case .openai: return "gpt-5.5"
        case .gemini: return "gemini-3.5-flash-lite"
        case .groq: return "openai/gpt-oss-120b"
        case .bedrock: return "amazon.nova-lite-v1:0"
        }
    }

    /// Bedrock만 리전을 받는다 — 주소가 리전마다 다르다.
    public var needsRegion: Bool { self == .bedrock }

    public static let defaultBedrockRegion = "us-east-1"

    /// 리전 이름으로 받을 수 있는 글자인가. 주소의 호스트에 들어가므로 아무 글자나 받지 않는다.
    public static func isValidRegion(_ region: String) -> Bool {
        !region.isEmpty && region.count <= 32
            && region.unicodeScalars.allSatisfy { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "-" }
    }

    // MARK: 키 확인

    /// 키 확인 요청 — **모델 목록**을 묻는 GET. 몸통이 없고, 문서의 글자는 하나도 싣지 않는다.
    /// 키가 비었거나 리전이 이상하면 nil.
    public func modelListRequest(key: String, region: String? = nil) -> URLRequest? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let url: URL?
        switch self {
        case .anthropic: url = URL(string: "https://api.anthropic.com/v1/models?limit=1000")
        case .openai: url = URL(string: "https://api.openai.com/v1/models")
        case .gemini: url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")
        case .groq: url = URL(string: "https://api.groq.com/openai/v1/models")
        case .bedrock:
            let name = region ?? Self.defaultBedrockRegion
            guard Self.isValidRegion(name) else { return nil }
            // 제어 평면의 ListFoundationModels. 실행 평면(bedrock-runtime)에는 목록이 없다.
            url = URL(string: "https://bedrock.\(name).amazonaws.com/foundation-models")
        }
        guard let url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch self {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")   // 없으면 400
        case .gemini:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .openai, .groq, .bedrock:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// 모델 목록 응답에서 모델 이름을 꺼낸다. 모양이 다르면 빈 목록.
    ///
    /// - Anthropic·OpenAI·Groq: `{"data": [{"id": …}]}`
    /// - Gemini: `{"models": [{"name": "models/gemini-…"}]}` — 앞의 `models/`를 뗀다
    /// - Bedrock: `{"modelSummaries": [{"modelId": …}]}`
    public func modelIDs(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        switch self {
        case .anthropic, .openai, .groq:
            return (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        case .gemini:
            return (object["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
        case .bedrock:
            return (object["modelSummaries"] as? [[String: Any]] ?? []).compactMap { $0["modelId"] as? String }
        }
    }

    /// 오류 응답에서 사람이 읽을 문장을 꺼낸다. 서비스마다 모양이 조금씩 다르다
    /// (`{"error": {"message": …}}`, `{"message": …}`). 없으면 nil.
    public static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = object["message"] as? String ?? object["Message"] as? String { return message }
        return nil
    }
}
