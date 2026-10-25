import XCTest

/// 언어 쌍으로 일반화한 번역 방향.
///
/// 왜 일반화했는가: 이 Mac에서 재 보니 Apple 번역은 한국어와 20개가 넘는 언어 사이를
/// 지원하고 그 쌍이 전부 설치돼 있었다 — ko↔en 제한은 마디 자신의 것이었다.
final class TranslationDirectionPairTests: XCTestCase {

    // MARK: 짐작

    /// 원문이 한국어가 아니면 **대상은 늘 한국어다** — 한국어 사용자의 문서 도구이므로
    /// "가져오기"가 기본이다.
    func testNonKoreanSourcesComeIntoKorean() {
        for (text, expected) in [("これは日本語の文です", "ja"),
                                 ("Это русское предложение", "ru"),
                                 ("هذه جملة عربية", "ar"),
                                 ("นี่คือประโยคภาษาไทย", "th"),
                                 ("यह हिंदी वाक्य है", "hi")] {
            let direction = TranslationDirection.resolve(text)
            XCTAssertEqual(direction.source, expected, "원문 판정: \(text)")
            XCTAssertEqual(direction.target, "ko", "대상은 한국어여야 한다: \(text)")
        }
    }

    /// 일본어 문장에는 보통 가나가 섞인다. 한자만 세면 중국어로 보이므로 가나를
    /// 먼저 센다 — 가나가 있으면 일본어가 이긴다.
    func testKanaWinsOverHanForJapanese() {
        XCTAssertEqual(TranslationDirection.resolve("日本語の文書です").source, "ja")
    }

    /// 한자만 있으면 중국어로 본다. 일본어와 가를 수 없는 경우이고, **사용자가 메뉴에서
    /// 바꿀 수 있으므로** 틀려도 막히지 않는다 — 그것이 문자 기반 짐작을 받아들일 수
    /// 있는 이유다.
    func testHanOnlyIsReadAsChinese() {
        XCTAssertEqual(TranslationDirection.resolve("这是中文句子").source, "zh")
    }

    /// 한국어 원문의 대상은 기억해 둔 언어를 따른다.
    func testKoreanSourceUsesThePreferredTarget() {
        XCTAssertEqual(TranslationDirection.resolve("한국어 문서입니다", preferredTarget: "ja"),
                       TranslationDirection(source: "ko", target: "ja"))
    }

    /// 기억해 둔 값이 한국어로 꼬여 있으면 영어로 둔다 — 한국어→한국어는 번역이 아니다.
    func testKoreanToKoreanIsAvoided() {
        let direction = TranslationDirection.resolve("한국어 문서입니다", preferredTarget: "ko")
        XCTAssertEqual(direction, .koreanToEnglish)
        XCTAssertFalse(direction.isTrivial)
    }

    /// 낱말 단위로 센다는 규칙을 못박는다. 글자로 세면 한글이 늘 진다 —
    /// `한글 English`가 2 대 7이 되어 한국어 우선 규칙이 무력해진다(실제로 그렇게
    /// 고쳤다가 기존 테스트가 잡았다).
    func testCountingIsByWordNotByCharacter() {
        XCTAssertEqual(TranslationDirection.resolve("한글 English"), .koreanToEnglish)
        XCTAssertEqual(TranslationDirection.resolve("한 Internationalization"), .koreanToEnglish)
    }

    /// 조사가 붙은 라틴 낱말(`Swift를`)은 한국어 낱말이다.
    func testLatinWordWithKoreanParticleCountsAsKorean() {
        XCTAssertEqual(TranslationDirection.resolve("Swift를 씁니다").source, "ko")
    }

    // MARK: 값

    func testReversedSwapsBothSides() {
        XCTAssertEqual(TranslationDirection(source: "ko", target: "ja").reversed,
                       TranslationDirection(source: "ja", target: "ko"))
    }

    func testTrivialDirectionIsDetected() {
        XCTAssertTrue(TranslationDirection(source: "ko", target: "ko").isTrivial)
        XCTAssertFalse(TranslationDirection.koreanToEnglish.isTrivial)
    }

    /// 이름은 한국어로 고정한다 — UI가 한국어뿐이라 `Locale.current`를 쓰면 영어
    /// 시스템에서 "Korean"이 나와 한 화면에 두 언어가 섞인다.
    func testNamesAreKoreanRegardlessOfSystemLocale() {
        XCTAssertEqual(TranslationDirection.name(of: "ja"), "일본어")
        XCTAssertEqual(TranslationDirection.name(of: "ru"), "러시아어")
        XCTAssertEqual(TranslationDirection.name(of: "ko"), "한국어")
    }

    /// 모르는 코드는 코드를 그대로 보인다 — 빈 칸보다 낫다.
    func testUnknownCodeFallsBackToTheCodeItself() {
        XCTAssertEqual(TranslationDirection.name(of: "zzz"), "zzz")
    }

    func testLabelReadsAsADirection() {
        XCTAssertEqual(TranslationDirection(source: "ko", target: "ja").label, "한국어 → 일본어")
    }

    // MARK: 언어 목록

    func testLanguageIsInstalledWhenEitherDirectionIs() {
        let outboundOnly = TranslationDirection.Language(
            code: "ja", name: "일본어", outboundInstalled: true, inboundInstalled: false)
        let neither = TranslationDirection.Language(
            code: "ja", name: "일본어", outboundInstalled: false, inboundInstalled: false)
        XCTAssertTrue(outboundOnly.isInstalled)
        XCTAssertFalse(neither.isInstalled)
    }
}

/// 번역본의 파일 이름.
///
/// 전에는 늘 '무제'로 열려 사용자가 다른 이름으로 저장에서 직접 적어야 했다.
final class TranslatedFileNameTests: XCTestCase {

    private func name(_ path: String?, _ target: String) -> String? {
        TranslationDirection(source: "ko", target: target)
            .translatedFileName(for: path.map { URL(fileURLWithPath: $0) })
    }

    func testAppendsTheTargetLanguageBeforeTheExtension() {
        XCTAssertEqual(name("/tmp/foo.md", "en"), "foo.en.md")
        XCTAssertEqual(name("/tmp/글.md", "ja"), "글.ja.md")
    }

    /// 저장되지 않은 원본은 제안할 이름이 없다 — 그때는 '무제'로 둔다.
    func testUnsavedDocumentHasNoSuggestion() {
        XCTAssertNil(name(nil, "en"))
    }

    /// 확장자가 없으면 붙이지 않는다 — 원본에 없던 것을 더하지 않는다.
    func testFileWithoutExtensionKeepsHavingNone() {
        XCTAssertEqual(name("/tmp/README", "en"), "README.en")
    }

    /// 이미 번역본인 파일을 또 번역하면 겹쳐 쌓인다. 그것이 맞다 —
    /// `foo.en.md`를 한국어로 가져오면 `foo.en.ko.md`이고, 어디서 왔는지 이름이 말한다.
    func testTranslatingATranslationStacksTheTags() {
        XCTAssertEqual(
            TranslationDirection(source: "en", target: "ko")
                .translatedFileName(for: URL(fileURLWithPath: "/tmp/foo.en.md")),
            "foo.en.ko.md")
    }

    /// 점으로 시작하는 파일에서 이름이 사라지지 않아야 한다.
    func testDotFileKeepsItsName() {
        XCTAssertEqual(name("/tmp/.hidden.md", "en"), ".hidden.en.md")
    }
}
