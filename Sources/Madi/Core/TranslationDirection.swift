import Foundation

/// 번역 방향. 한국어·영어 두 방향만 다룬다.
///
/// 규칙은 Sogon과 같다 — 낱말 단위로 한글이 든 것과 라틴 문자가 든 것을 세고, 한글이
/// 하나라도 있고 라틴보다 적지 않으면 한국어→영어로 본다. 동률을 한국어로 보는 것은
/// 한국어 문장에 영어 낱말이 섞이는 쪽이 훨씬 흔하기 때문이다.
public enum TranslationDirection: Equatable, Sendable {
    case koreanToEnglish
    case englishToKorean

    public var sourceIdentifier: String { self == .koreanToEnglish ? "ko" : "en" }
    public var targetIdentifier: String { self == .koreanToEnglish ? "en" : "ko" }

    public var label: String {
        self == .koreanToEnglish ? "한국어 → 영어" : "영어 → 한국어"
    }

    /// 글 전체에서 **한 번** 정한다. 구간마다 다시 정하면 한 문서 안에서 방향이 갈린다.
    public static func resolve(_ text: String) -> TranslationDirection {
        var korean = 0
        var latin = 0
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let scalars = word.unicodeScalars
            if scalars.contains(where: isHangul) {
                korean += 1
            } else if scalars.contains(where: { ("a" ... "z").contains($0) || ("A" ... "Z").contains($0) }) {
                latin += 1
            }
        }
        return korean > 0 && korean >= latin ? .koreanToEnglish : .englishToKorean
    }

    /// 한글 음절과 자모. 자모만 쓴 `ㅋㅋ`도 한국어다.
    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00 ... 0xD7A3).contains(scalar.value) || (0x3131 ... 0x318E).contains(scalar.value)
    }
}
