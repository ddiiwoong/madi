import XCTest

/// 번역 실패 안내.
///
/// 왜 문구를 테스트하는가: 사용자가 요청한 것이 "언어 팩이 없을 때 안내를 잘 해 달라"는
/// 것이었고, 안내는 **쓸모가 문구에 있다.** 길을 두루뭉술하게 적으면(“시스템 설정에서
/// 받으세요”) 어디를 눌러야 하는지 알 수 없고, 언어를 `ko`로 적으면 설정 화면의 목록에서
/// 찾을 수 없다. 그래서 세 가지를 지킨다: 길의 각 단계가 들어 있는지, 언어가 사람이 읽는
/// 이름인지, 다음에 무엇을 하라고 말하는지.
@available(macOS 26.0, *)
final class TranslationGuidanceTests: XCTestCase {

    private func missing(_ direction: TranslationDirection) -> AppleTranslator.Failure {
        .languagePackMissing(direction: direction)
    }

    // MARK: 언어 팩이 없을 때

    func testMissingPackNamesTheDirectionInItsCause() {
        let text = missing(.koreanToEnglish).errorDescription ?? ""
        XCTAssertTrue(text.contains("한국어 → 영어"), "어느 방향인지 말해야 한다 — 실제 \(text)")
        XCTAssertFalse(text.contains("ko"), "언어 코드가 아니라 사람이 읽는 이름이어야 한다")
    }

    /// 길을 **각 단계까지** 적는다. 전에는 "시스템 설정 → 일반 → 언어 및 지역 →
    /// 번역 언어"를 원인 문장에 한 덩이로 붙여 두어 할 일이 원인에 묻혔다.
    func testMissingPackSpellsOutEveryStepOfThePath() {
        let text = missing(.koreanToEnglish).recoverySuggestion ?? ""
        for step in ["시스템 설정", "일반", "언어 및 지역", "번역 언어"] {
            XCTAssertTrue(text.contains(step), "길에 ‘\(step)’이 없다 — 실제 \(text)")
        }
    }

    func testMissingPackNamesBothLanguagesToDownload() {
        let text = missing(.koreanToEnglish).recoverySuggestion ?? ""
        XCTAssertTrue(text.contains("한국어"), "받을 언어를 이름으로 말해야 한다")
        XCTAssertTrue(text.contains("영어"), "받을 언어를 이름으로 말해야 한다")
    }

    /// 받은 **뒤에 무엇을 할지**까지 말해야 한다. 받아 놓고 다시 시도할 줄 몰라
    /// 같은 경고를 다시 보는 것이 가장 흔한 막힘이다.
    func testMissingPackTellsTheUserToTryAgain() {
        let text = missing(.koreanToEnglish).recoverySuggestion ?? ""
        XCTAssertTrue(text.contains("⌘⇧T"), "다시 시도하는 방법(단축키)을 말해야 한다")
        XCTAssertTrue(text.contains("다시"), "다시 누르라고 말해야 한다")
    }

    /// 받을 때 네트워크가 필요하고 그 뒤로는 필요 없다는 사실. 온디바이스라는 것이
    /// 이 기능을 쓸지 판단하는 근거이므로 안내에 있어야 한다.
    func testMissingPackExplainsTheNetworkOnlyOnce() {
        let text = missing(.koreanToEnglish).recoverySuggestion ?? ""
        XCTAssertTrue(text.contains("네트워크"), "받을 때 네트워크가 필요함을 말해야 한다")
        XCTAssertTrue(text.contains("기기 안") || text.contains("인터넷 없이"),
                      "받은 뒤에는 기기 안에서 된다는 것을 말해야 한다")
    }

    func testBothDirectionsProduceGuidance() {
        for direction in [TranslationDirection.koreanToEnglish, .englishToKorean] {
            let failure = missing(direction)
            XCTAssertFalse((failure.errorDescription ?? "").isEmpty, "\(direction.label)")
            XCTAssertFalse((failure.recoverySuggestion ?? "").isEmpty, "\(direction.label)")
        }
    }

    // MARK: 지원되지 않을 때

    /// 지원되지 않는 방향도 **무엇을 할 수 있는지** 말해야 한다. 전에는
    /// "지원하지 않습니다"로 끝나서 사용자가 할 수 있는 일이 없었다.
    func testUnsupportedStillOffersSomewhereToLook() {
        let failure = AppleTranslator.Failure.unsupported(direction: .koreanToEnglish)
        let text = failure.recoverySuggestion ?? ""
        XCTAssertTrue(text.contains("번역 언어"), "어디서 볼 수 있는지 말해야 한다 — 실제 \(text)")
        XCTAssertTrue(failure.suggestsLanguageSettings,
                      "설정을 열어 주는 것이 쓸모 있는 경우다")
    }

    // MARK: 번역할 글이 없을 때

    /// 이것은 **잘못이 아니다.** 설정을 열어 줄 이유가 없고, 왜 비었는지와 선택해서
    /// 번역하는 방법을 말해야 한다.
    func testNothingToTranslateIsNotAnError() {
        let failure = AppleTranslator.Failure.nothingToTranslate
        XCTAssertFalse(failure.suggestsLanguageSettings,
                       "언어 설정과 아무 상관이 없다")
        XCTAssertFalse(failure.isLanguagePackMissing)
        let text = failure.recoverySuggestion ?? ""
        XCTAssertTrue(text.contains("코드 블록"), "왜 비었는지 말해야 한다 — 실제 \(text)")
        XCTAssertTrue(text.contains("선택"), "일부만 번역하는 방법을 말해야 한다")
    }

    /// `other`는 시스템이 준 문구를 그대로 쓴다 — 우리가 덧붙일 말이 없다.
    func testOtherFailureCarriesTheSystemMessage() {
        let failure = AppleTranslator.Failure.other("무언가 잘못됐습니다")
        XCTAssertEqual(failure.errorDescription, "무언가 잘못됐습니다")
        XCTAssertNil(failure.recoverySuggestion)
        XCTAssertFalse(failure.suggestsLanguageSettings)
    }
}

/// 안내가 기대는 **전제**를 따로 못박는다.
///
/// `nothingToTranslate` 안내는 "코드 블록·수평선·표 구분선·빈 줄은 번역하지 않는다"고
/// 말한다. 그 문장이 참이 아니면 안내가 거짓이 되므로, 계획이 정말 단위를 0개로 내는지
/// 여기서 확인한다. 전에는 이 경우에 방향을 꾸며 내 `.englishToKorean`을 돌려줘
/// 부르는 쪽이 "번역했습니다 (영어 → 한국어)"라고 **거짓 보고**했다.
final class NothingToTranslateTests: XCTestCase {

    private func units(_ source: String) -> Int {
        MarkdownTranslationPlan.make(source).units.count
    }

    func testCodeOnlyDocumentHasNothingToTranslate() {
        XCTAssertEqual(units("```swift\nlet x = 1\n```"), 0)
    }

    func testThematicBreakOnlyDocumentHasNothingToTranslate() {
        XCTAssertEqual(units("---\n\n---\n"), 0)
    }

    func testBlankDocumentHasNothingToTranslate() {
        XCTAssertEqual(units("\n\n\n"), 0)
    }

    func testTableDelimiterOnlyHasNothingToTranslate() {
        XCTAssertEqual(units("| --- | --- |\n"), 0)
    }

    /// 반대쪽도 못박는다 — 글이 있으면 단위가 생겨야 한다. 없으면 모든 문서가
    /// "번역할 글이 없습니다"가 되고 위 단정들은 공허해진다.
    func testADocumentWithProseHasUnits() {
        XCTAssertGreaterThan(units("본문입니다.\n"), 0)
        XCTAssertGreaterThan(units("# 제목\n\n본문\n"), 0)
    }

    /// 코드 블록만 있는 문서도 **바이트가 보존된다** — 번역하지 않는 것과 글을 잃는
    /// 것은 다르다.
    func testCodeOnlyDocumentIsStillPreservedByThePlan() {
        let source = "```swift\nlet 한글 = \"문자열\"\n```\n"
        XCTAssertEqual(MarkdownTranslationPlan.make(source).source, source)
    }
}

/// 안내문에 쓰는 언어 이름.
final class TranslationLanguageNameTests: XCTestCase {

    func testNamesAreHumanReadableNotCodes() {
        XCTAssertEqual(TranslationDirection.koreanToEnglish.sourceLanguageName, "한국어")
        XCTAssertEqual(TranslationDirection.koreanToEnglish.targetLanguageName, "영어")
        XCTAssertEqual(TranslationDirection.englishToKorean.sourceLanguageName, "영어")
        XCTAssertEqual(TranslationDirection.englishToKorean.targetLanguageName, "한국어")
    }

    /// 이름과 식별자가 짝이 맞아야 한다 — 안내는 이름으로 말하고 세션은 식별자로
    /// 만들므로, 둘이 어긋나면 사용자가 받은 언어와 번역이 쓰는 언어가 달라진다.
    func testNamesAndIdentifiersAgree() {
        for direction in [TranslationDirection.koreanToEnglish, .englishToKorean] {
            let koreanIsSource = direction.sourceLanguageName == "한국어"
            XCTAssertEqual(direction.sourceIdentifier, koreanIsSource ? "ko" : "en")
            XCTAssertEqual(direction.targetIdentifier, koreanIsSource ? "en" : "ko")
        }
    }
}
