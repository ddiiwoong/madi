import Foundation

/// 마디 화면의 언어 — 시스템을 따르거나, 한국어나 영어로 고정한다.
///
/// macOS의 앱별 언어(시스템 설정 ▸ 일반 ▸ 언어 및 지역 ▸ 응용 프로그램)와 **같은 값**을
/// 쓴다: 앱 자신의 도메인에 적은 `AppleLanguages`. 그래서 어느 쪽에서 바꿔도 다른 쪽에
/// 그대로 보이고, 마디가 따로 기억하는 것이 없다.
///
/// 번들이 어느 언어를 쓸지는 **프로세스가 뜰 때** 정해진다. 바꾼 언어는 다음 실행부터
/// 보이고, 설정 창이 그 사실을 적는다.
public enum InterfaceLanguage: String, CaseIterable, Sendable {
    case system
    case korean = "ko"
    case english = "en"

    public static let defaultsKey = "AppleLanguages"

    /// 앱 도메인에 적힌 값으로 지금 고른 것을 읽는다.
    ///
    /// **앱 도메인만** 본다. `UserDefaults.array(forKey:)`는 전역 도메인의 시스템 언어
    /// 목록까지 돌려주므로, 그것으로는 '시스템을 따른다'와 '고정했다'를 가를 수 없다.
    /// 지역이 붙은 값(`ko-KR`)도 그 언어로 읽는다. 마디에 없는 언어가 적혀 있으면
    /// 번들이 그 언어를 쓰지 못하므로 '시스템'으로 본다.
    public static func current(in domain: [String: Any]?) -> InterfaceLanguage {
        guard let first = (domain?[defaultsKey] as? [String])?.first else { return .system }
        let base = first.split(separator: "-").first.map(String.init) ?? first
        switch base {
        case "ko": return .korean
        case "en": return .english
        default: return .system
        }
    }

    /// 고른 언어를 적는다. 시스템을 고르면 앱 도메인의 값을 **지운다** — 빈 목록을 적으면
    /// 시스템 언어를 가린다.
    public func apply(to defaults: UserDefaults) {
        switch self {
        case .system: defaults.removeObject(forKey: Self.defaultsKey)
        case .korean, .english: defaults.set([rawValue], forKey: Self.defaultsKey)
        }
    }

    /// 고르개에 보이는 이름. 언어 이름은 **그 언어로** 적는다 — 읽지 못하는 화면에서
    /// 자기 언어를 찾아야 하는 사람에게는 그것만 읽힌다.
    public var label: String {
        switch self {
        case .system: return String(localized: "시스템 언어")
        case .korean: return "한국어"
        case .english: return "English"
        }
    }
}
