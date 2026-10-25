import Foundation

/// 번역 방향 — 원문 언어와 대상 언어의 쌍.
///
/// 처음에는 `koreanToEnglish` · `englishToKorean` 두 케이스 열거형이었다. 그런데
/// 이 Mac에서 재 보니 Apple 번역은 한국어와 **20개가 넘는 언어** 사이를 지원하고
/// (`LanguageAvailability.supportedLanguages`가 47개를 돌려주고, 한국어를 한쪽에 둔
/// 쌍이 전부 `installed`였다) ko↔en 제한은 마디 자신의 것이었다. 그래서 쌍으로 바꿨다.
///
/// 이름은 그대로 `TranslationDirection`이다 — 부르는 쪽 25곳이 `direction.label`·
/// `sourceIdentifier` 같은 것만 쓰므로, 타입 이름을 바꾸면 얻는 것 없이 전부 고쳐야 한다.
///
/// **Foundation만 쓴다.** 언어를 알아내는 정석은 `NLLanguageRecognizer`지만 그것은
/// NaturalLanguage 프레임워크이고, Core에 들이면 `make core-only`가 깨진다 — Core를
/// 다른 플랫폼으로 옮길 수 있다는 전제가 그 import 하나로 무너진다. 그래서 판정은
/// **문자 범위**로 한다. 문자는 언어가 아니지만(한자는 중국어와 일본어 둘 다다) 기본값을
/// 고르는 데는 충분하고, **사용자가 메뉴에서 바꿀 수 있으므로** 틀려도 막히지 않는다.
public struct TranslationDirection: Equatable, Hashable, Sendable {

    /// BCP-47의 기본 언어 코드(`ko`, `en`, `zh`…). 지역 변종(`en-GB`)은 쓰지 않는다 —
    /// 번역 품질이 지역으로 갈리지 않고, 목록이 세 배로 길어진다.
    public let source: String
    public let target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    public var sourceIdentifier: String { source }
    public var targetIdentifier: String { target }

    public var sourceLanguageName: String { Self.name(of: source) }
    public var targetLanguageName: String { Self.name(of: target) }

    public var label: String { "\(sourceLanguageName) → \(targetLanguageName)" }

    /// 원문과 대상이 같으면 번역할 것이 없다.
    public var isTrivial: Bool { source == target }

    public var reversed: TranslationDirection {
        TranslationDirection(source: target, target: source)
    }

    public static let koreanToEnglish = TranslationDirection(source: "ko", target: "en")
    public static let englishToKorean = TranslationDirection(source: "en", target: "ko")

    /// 한국어와 오갈 수 있는 언어 하나. 목록은 시스템이 주고(Services) 화면이 읽는다.
    ///
    /// **Core에 둔다.** Translation 프레임워크에 기대지 않는 평범한 값이고, Core에
    /// 있으면 화면과 테스트가 `@available(macOS 26)` 없이 쓸 수 있다 — 고르개를
    /// 만드는 코드가 번역 엔진을 알아야 할 이유가 없다.
    public struct Language: Equatable, Hashable, Sendable {
        public let code: String
        public let name: String
        /// 한국어 → 이 언어가 바로 되는가.
        public let outboundInstalled: Bool
        /// 이 언어 → 한국어가 바로 되는가.
        public let inboundInstalled: Bool

        public init(code: String, name: String,
                    outboundInstalled: Bool, inboundInstalled: Bool) {
            self.code = code
            self.name = name
            self.outboundInstalled = outboundInstalled
            self.inboundInstalled = inboundInstalled
        }

        public var isInstalled: Bool { outboundInstalled || inboundInstalled }
    }

    // MARK: 번역본의 파일 이름

    /// 원본 이름에서 번역본의 이름을 만든다 — `foo.md` → `foo.en.md`.
    ///
    /// 전에는 번역본이 늘 '무제'로 열려 사용자가 다른 이름으로 저장에서 직접 적어야
    /// 했다. 저장되지 않은 원본은 제안할 이름이 없으므로 nil이고, 그때는 '무제'로 둔다.
    /// 확장자가 없으면 붙이지 않는다 — 원본에 없던 것을 더하지 않는다.
    public func translatedFileName(for url: URL?) -> String? {
        guard let url else { return nil }
        let name = url.lastPathComponent
        let extensionPart = url.pathExtension
        let base = extensionPart.isEmpty ? name : (name as NSString).deletingPathExtension
        guard !base.isEmpty else { return nil }
        let tagged = "\(base).\(target)"
        return extensionPart.isEmpty ? tagged : "\(tagged).\(extensionPart)"
    }

    // MARK: 이름

    /// 사람이 읽는 언어 이름.
    ///
    /// **한국어 이름으로 고정한다.** `Locale.current`를 쓰면 영어 시스템에서 "Korean"이
    /// 나오는데, 마디의 UI는 지금 한국어뿐이라 한 화면에 두 언어가 섞인다. 현지화를
    /// 하는 날 이 함수가 `Locale.current`를 보도록 바꾸면 된다(그때 이름을 단정하는
    /// 테스트도 함께 고쳐야 한다).
    static func name(of code: String) -> String {
        let korean = Locale(identifier: "ko")
        return korean.localizedString(forLanguageCode: code) ?? code
    }

    // MARK: 자동 판정

    /// 글에서 쓰인 문자로 원문 언어를 짐작한다.
    ///
    /// 대상은 **원문이 한국어면 `preferredTarget`, 아니면 한국어**다. 한국어 사용자의
    /// 문서이므로 "한국어로 가져오기"가 기본이고, 원문이 이미 한국어일 때만 내보낸다.
    public static func resolve(_ text: String,
                               preferredTarget: String = "en") -> TranslationDirection {
        let source = dominantLanguage(in: text)
        if source == "ko" {
            // 대상이 한국어로 들어오면(설정이 꼬였거나 기본값이 이상하면) 영어로 둔다 —
            // 한국어→한국어는 번역이 아니다.
            return TranslationDirection(source: "ko",
                                        target: preferredTarget == "ko" ? "en" : preferredTarget)
        }
        return TranslationDirection(source: source, target: "ko")
    }

    /// 가장 많이 쓰인 문자의 언어. 어느 것도 뚜렷하지 않으면 영어로 본다.
    ///
    /// **낱말 단위로 센다**(글자가 아니다). 글자로 세면 한글이 늘 진다 — 한글은 한 음절이
    /// 한 글자인데 영어 낱말은 여러 글자라, `한글 English`에서 2 대 7이 된다. 원래 규칙이
    /// 낱말 단위였고 그 규칙에는 근거가 있다(아래).
    ///
    /// 한글이 섞여 있으면 **라틴과 같은 수여도 한국어로 본다** — 한국어 문장에 영어
    /// 낱말이 섞이는 쪽이 그 반대보다 훨씬 흔하다.
    static func dominantLanguage(in text: String) -> String {
        var counts: [String: Int] = [:]
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            // 낱말의 언어는 **있으면 이기는 문자**로 먼저 정한다. 한글이 있으면
            // 한국어다(조사가 붙은 `Swift를`은 한국어 낱말이다). 가나가 있으면
            // 일본어다 — 가나는 일본어에만 나오고, 한자 수로 겨루면 `日本語の文書です`
            // 처럼 한자가 많은 일본어 문장이 중국어로 판정된다(실측).
            var inWord: [String: Int] = [:]
            for scalar in word.unicodeScalars {
                guard let code = language(for: scalar) else { continue }
                inWord[code, default: 0] += 1
            }
            guard !inWord.isEmpty else { continue }
            let code: String
            if inWord["ko"] != nil {
                code = "ko"
            } else if inWord["ja"] != nil {
                code = "ja"
            } else {
                code = inWord.max {
                    $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
                }?.key ?? "en"
            }
            counts[code, default: 0] += 1
        }
        guard !counts.isEmpty else { return "en" }
        let korean = counts["ko"] ?? 0
        let latin = counts["en"] ?? 0
        if korean > 0, korean >= latin { return "ko" }
        // 나머지는 많이 쓰인 쪽. 같으면 코드 순으로 정해 결과가 흔들리지 않게 한다.
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }?.key ?? "en"
    }

    /// 문자 하나가 가리키는 언어. 모르는 문자는 nil(공백·숫자·기호).
    ///
    /// 한자(`Han`)는 **중국어로 본다.** 일본어와 가를 수 없는데, 일본어 문장에는 보통
    /// 가나가 섞이므로 가나를 먼저 센다 — 가나가 하나라도 많으면 일본어가 이긴다.
    private static func language(for scalar: Unicode.Scalar) -> String? {
        let value = scalar.value
        switch value {
        case 0xAC00 ... 0xD7A3, 0x1100 ... 0x11FF, 0x3131 ... 0x318E:
            return "ko"                                  // 한글 음절·자모
        case 0x3040 ... 0x309F, 0x30A0 ... 0x30FF:
            return "ja"                                  // 히라가나·가타카나
        case 0x4E00 ... 0x9FFF, 0x3400 ... 0x4DBF:
            return "zh"                                  // 한자
        case 0x0400 ... 0x04FF:
            return "ru"                                  // 키릴
        case 0x0600 ... 0x06FF, 0x0750 ... 0x077F:
            return "ar"                                  // 아랍
        case 0x0E00 ... 0x0E7F:
            return "th"                                  // 타이
        case 0x0900 ... 0x097F:
            return "hi"                                  // 데바나가리
        case 0x05D0 ... 0x05EA:
            return "he"                                  // 히브리
        case 0x0041 ... 0x005A, 0x0061 ... 0x007A, 0x00C0 ... 0x024F:
            return "en"                                  // 라틴(확장 포함)
        default:
            return nil
        }
    }
}
