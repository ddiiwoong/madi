import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class TranslationDirectionTests: XCTestCase {

    func testKoreanGoesToEnglish() {
        XCTAssertEqual(TranslationDirection.resolve("한국어 문장입니다"), .koreanToEnglish)
    }

    func testEnglishGoesToKorean() {
        XCTAssertEqual(TranslationDirection.resolve("This is an English sentence"), .englishToKorean)
    }

    func testTieIsReadAsKorean() {
        XCTAssertEqual(TranslationDirection.resolve("한글 English"), .koreanToEnglish)
    }

    func testJamoOnlyCountsAsKorean() {
        XCTAssertEqual(TranslationDirection.resolve("ㅋㅋㅋ"), .koreanToEnglish)
    }

    func testNoLettersFallsBackToEnglishToKorean() {
        XCTAssertEqual(TranslationDirection.resolve("1234 !!! ---"), .englishToKorean)
    }
}

final class MarkdownTranslationPlanTests: XCTestCase {

    private let open = "\u{E000}"
    private let close = "\u{E001}"

    private func plan(_ text: String) -> MarkdownTranslationPlan {
        MarkdownTranslationPlan.make(text)
    }

    /// 이 타입의 전부인 불변식: 조각을 이으면 원문과 같고, 항등 번역이면 문서가 복원된다.
    private func assertRoundTrips(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let made = plan(text)
        XCTAssertEqual(made.source, text, "조각을 이은 결과가 원문과 다르다", file: file, line: line)
        let identity = try? made.assembled(with: made.translatableTexts)
        XCTAssertEqual(identity, text, "항등 조립이 원문과 다르다", file: file, line: line)
    }

    func testBaselineRoundTrip() {
        assertRoundTrips("그냥 한 문단입니다.\n")
    }

    func testRoundTripOnADocumentWithEverything() {
        assertRoundTrips("""
        # 제목

        **굵게**와 *기울임*, `인라인 코드`, [링크](https://example.com), <https://auto.link>,
        ![그림](./a.png) 그리고 ~~취소선~~.

        > 인용문

        - 목록
        - [x] 완료
        1. 번호

        ```swift
        let code = "번역되지 않는다"
        ```

        | 열 하나 | 열 둘 |
        | --- | ---: |
        | 값 하나 | 값 둘 |

        ---

        마지막 문단.
        """)
    }

    func testRoundTripPreservesCRLFAndTrailingNewlines() {
        assertRoundTrips("# 제목\r\n\r\n본문\r\n")
        assertRoundTrips("본문\n\n\n")
        assertRoundTrips("")
    }

    // MARK: 문맥 — 이 설계의 이유

    func testASentenceGoesToTheTranslatorAsONEUnit() {
        // 마커마다 쪼개 넘겼을 때 "The main text is**Boldly**Wow…"가 나왔다(실측).
        // 문장 하나는 반드시 단위 하나여야 한다.
        let made = plan("본문은 **굵게**와 `인라인 코드`, [문서 링크](https://example.com)를 포함합니다.\n")
        XCTAssertEqual(made.units.count, 1, "문장이 쪼개졌다: \(made.translatableTexts)")

        let unit = made.units[0]
        // 번역기가 보는 글: 보호 구간은 자리표, 나머지는 문장 그대로.
        XCTAssertEqual(unit.text,
                       "본문은 \(open)0\(close)굵게\(open)1\(close)와 \(open)2\(close), \(open)3\(close)문서 링크\(open)4\(close)를 포함합니다.")
        XCTAssertEqual(unit.protected.map(\.text),
                       ["**", "**", "`인라인 코드`", "[", "](https://example.com)"])
        XCTAssertEqual(unit.protected.map(\.role),
                       [.opening, .closing, .standalone, .opening, .closing])
    }

    func testTranslatorInsertedSpaceAfterAnOpeningDelimiterIsRemoved() {
        // 실측된 결함: `[문서 링크]`가 `[ document links]`로 나왔다.
        let made = plan("자세한 것은 [문서 링크](https://example.com)를 보세요\n")
        let unit = made.units[0]
        let translated = unit.text.replacingOccurrences(of: "문서 링크", with: " document links")
        let out = unit.restored(from: translated)
        XCTAssertTrue(out.contains("[document links]"), "끼워 넣은 공백이 남았다: \(out)")
    }

    func testASpaceAFTERAClosingDelimiterIsKept() {
        // 두 번째로 실측된 결함: `**굵게**와`를 번역하면 영어는 `**bold** and`처럼 공백이
        // 있어야 하는데, "원문에 공백이 없었으니 지운다"는 규칙이 `**bold**and`를 만들었다.
        // 닫는 구분자는 **앞**의 공백만 본다.
        let made = plan("본문은 **굵게**와 함께\n")
        let unit = made.units[0]
        let translated = unit.text
            .replacingOccurrences(of: "굵게", with: "bold")
            .replacingOccurrences(of: "와 함께", with: " and together")
        let out = unit.restored(from: translated)
        XCTAssertTrue(out.contains("**bold** and"), "닫는 구분자 뒤 공백이 지워졌다: \(out)")
    }

    func testStandaloneSpansNeverHaveTheirSpacingTouched() {
        // 인라인 코드는 감싸는 구간이 아니다 — 주변 공백을 건드릴 근거가 없다.
        let made = plan("값은 `code` 입니다\n")
        let unit = made.units[0]
        XCTAssertEqual(unit.protected.map(\.role), [.standalone])
        let out = unit.restored(from: unit.text.replacingOccurrences(of: "값은", with: "The value is"))
        XCTAssertTrue(out.contains("`code` "), "표준 구간의 공백이 사라졌다: \(out)")
    }

    func testTranslatorNeverSeesCodeOrUrls() {
        let texts = plan("""
        값은 `let x = 1`이고 [문서](https://example.com/ko/guide)를 보세요.

        ```swift
        let secret = "코드"
        ```
        """).translatableTexts.joined()
        XCTAssertFalse(texts.contains("let x = 1"))
        XCTAssertFalse(texts.contains("example.com"))
        XCTAssertFalse(texts.contains("let secret"))
    }

    // MARK: 무엇이 단위 밖에 남는가

    func testCodeBlockIsNeverAUnit() {
        XCTAssertEqual(plan("앞 문단\n\n```swift\nlet a = 1\n```\n\n뒤 문단\n").translatableTexts,
                       ["앞 문단", "뒤 문단"])
    }

    func testLineMarkersStayOutsideTheUnit() {
        XCTAssertEqual(plan("## 검색 기능\n").translatableTexts, ["검색 기능"])
        XCTAssertEqual(plan("- 항목 하나\n").translatableTexts, ["항목 하나"])
        XCTAssertEqual(plan("- [x] 완료된 항목\n").translatableTexts, ["완료된 항목"])
        XCTAssertEqual(plan("> 인용문\n").translatableTexts, ["인용문"])
        XCTAssertEqual(plan("3. 세 번째\n").translatableTexts, ["세 번째"])
    }

    func testThematicBreakAndTableDelimiterAreLiteral() {
        XCTAssertTrue(plan("---\n").units.isEmpty)
        XCTAssertTrue(plan("| --- | ---: |\n").units.isEmpty)
    }

    func testATableRowIsOneUnitSoCellsHaveContext() {
        // 전에는 칸마다 독립 단위였다. 번역기에 `검색` 한 낱말만 넘어가니 문맥이 없어
        // `reference`가 나왔다. 행을 통째로 넘기면 같은 행의 다른 칸이 문맥이 된다.
        let made = plan("| 열 하나 | 열 둘 |\n")
        XCTAssertEqual(made.units.count, 1, "행이 여러 단위로 쪼개졌다")
        XCTAssertEqual(made.units[0].protected.count, 3, "막대 셋이 지켜지지 않았다")
        XCTAssertEqual(made.units[0].protected.map(\.text), ["|", "|", "|"])
        // 번역기에 넘어가는 글에는 두 칸의 내용이 함께 있다.
        let sent = made.translatableTexts[0]
        XCTAssertTrue(sent.contains("열 하나"), sent)
        XCTAssertTrue(sent.contains("열 둘"), sent)
    }

    func testTableCellBoundariesSurviveATranslatorThatReordersText() {
        // 칸 경계가 섞이면 표가 망가진다. 자리표가 그것을 막는다.
        let made = plan("| 가 | 나 | 다 |\n")
        let unit = made.units[0]
        // 번역기가 칸 내용을 바꿔 돌려준 것처럼 꾸민다(자리표는 그대로 둔다).
        let translated = unit.text
            .replacingOccurrences(of: "가", with: "one")
            .replacingOccurrences(of: "나", with: "two")
            .replacingOccurrences(of: "다", with: "three")
        let restored = unit.restored(from: translated)
        XCTAssertEqual(restored.filter { $0 == "|" }.count, 4, "막대 수가 달라졌다: \(restored)")
        XCTAssertTrue(restored.contains("| one |"), restored)
        XCTAssertTrue(restored.contains("| three |"), restored)
    }

    func testAPipeInsideInlineCodeIsNotTreatedAsACellBoundary() {
        // `a|b`의 막대는 칸을 나누지 않는다. 지켜야 할 것은 인라인 코드 전체다.
        let made = plan("| `a|b` | 다 |\n")
        let unit = made.units[0]
        XCTAssertTrue(unit.protected.map(\.text).contains("`a|b`"),
                      "인라인 코드가 지켜지지 않았다: \(unit.protected.map(\.text))")
    }

    func testTableRowStillAssemblesBackToTheSource() {
        // 항등 조립 불변식. 행을 한 단위로 바꿨어도 깨지면 안 된다.
        assertRoundTrips("| 열 하나 | 열 둘 |\n| --- | --- |\n| 가 | 나 |\n")
        assertRoundTrips("| **굵게** | `코드` | [링크](https://a.b) |\n| --- | --- | --- |\n")
    }

    func testTableRoundTripKeepsAlignmentSpacing() {
        assertRoundTrips("| a   | b     |\n| --- | ----- |\n| 1   | 2     |\n")
    }

    func testAutolinkOnlyLineIsNotTranslated() {
        // 자리표와 공백뿐인 줄은 번역기를 부르지 않는다.
        XCTAssertTrue(plan("<https://example.com/path>\n").units.isEmpty)
    }

    func testWhitespaceOnlyGapsAreNotUnits() {
        XCTAssertTrue(plan("\n\n   \n\n").units.isEmpty)
    }

    // MARK: 조립

    func testAssemblyRestoresPlaceholders() throws {
        let made = plan("본문은 **굵게**를 포함합니다.\n")
        let translated = "The body contains \(open)0\(close)bold\(open)1\(close)."
        XCTAssertEqual(try made.assembled(with: [translated]),
                       "The body contains **bold**.\n")
    }

    func testAPlaceholderLostByTheTranslatorIsAppendedNotDropped() throws {
        // 자리표를 잃으면 자리를 알 수 없다. 그래도 지우지는 않는다 — 코드나 링크가
        // 조용히 사라지는 것이 더 나쁘다.
        let made = plan("값은 `code`입니다\n")
        XCTAssertEqual(made.units.count, 1)
        let out = try made.assembled(with: ["The value is"])
        XCTAssertTrue(out.contains("`code`"), "잃은 보호 구간이 사라졌다: \(out)")
    }

    func testAssemblyRefusesAWrongCount() {
        let made = plan("## 제목\n")
        XCTAssertThrowsError(try made.assembled(with: ["a", "b"])) { error in
            XCTAssertEqual(error as? MarkdownTranslationPlan.AssemblyError,
                           .countMismatch(expected: 1, got: 2))
        }
    }
}
