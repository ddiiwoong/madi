import AppKit
import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

/// 기울임 구분자 규칙. `*`와 `_`는 CommonMark에서 규칙이 다르고, 그 차이가
/// 한국어에서 특히 크게 드러난다.
final class EmphasisRuleTests: XCTestCase {

    private func emphasised(_ line: String) -> [String] {
        let text = line as NSString
        let whole = NSRange(location: 0, length: text.length)
        return MarkdownSyntax().scanInline(in: text, range: whole)
            .filter { $0.kind == .emphasis }
            .map { text.substring(with: $0.contentRange) }
    }

    // MARK: 한국어 — 조사가 바로 붙는다

    func testKoreanParticleRightAfterTheClosingStar() {
        // 실측된 결함: `은`이 낱말 글자라 강조가 아예 인식되지 않았다. 한국어에서
        // 조사는 공백 없이 붙으므로 이것이 막히면 기울임을 거의 쓸 수 없다.
        XCTAssertEqual(emphasised("*기울임*은 서로 달라야 합니다."), ["기울임"])
        XCTAssertEqual(emphasised("보통 글과 *기울인 한글*을 나란히 둡니다."), ["기울인 한글"])
        XCTAssertEqual(emphasised("*강조*와 *다른 강조*가 모두 됩니다."), ["강조", "다른 강조"])
    }

    func testStarEmphasisStillWorksWithSurroundingSpaces() {
        XCTAssertEqual(emphasised("보통 글과 *italic latin* 도 봅니다."), ["italic latin"])
        XCTAssertEqual(emphasised("*斜体* 와 *かたむき* 도"), ["斜体", "かたむき"])
    }

    // MARK: 밑줄은 낱말 안에서 강조하지 않는다

    func testUnderscoreInsideAWordIsNotEmphasis() {
        // `snake_case_name`이 기울어지면 코드 이름이 망가져 보인다. CommonMark도 금지한다.
        XCTAssertTrue(emphasised("snake_case_name 입니다").isEmpty)
        XCTAssertTrue(emphasised("a_b_c").isEmpty)
    }

    func testUnderscoreEmphasisWorksAtWordBoundaries() {
        XCTAssertEqual(emphasised("보통 _기울임_ 보통"), ["기울임"])
    }

    // MARK: 굵게와 섞이지 않는다

    func testStrongIsNotReadAsEmphasis() {
        XCTAssertTrue(emphasised("**굵게**와 보통").isEmpty,
                      "굵게가 기울임으로 읽혔다")
    }

    func testStrongAndEmphasisTogether() {
        let line = "**굵게**와 *기울임*은 다르다"
        XCTAssertEqual(emphasised(line), ["기울임"])
        let text = line as NSString
        let strong = MarkdownSyntax()
            .scanInline(in: text, range: NSRange(location: 0, length: text.length))
            .filter { $0.kind == .strong }
            .map { text.substring(with: $0.contentRange) }
        XCTAssertEqual(strong, ["굵게"])
    }

    // MARK: 내용 안의 다른 구분자

    func testStarEmphasisMayContainUnderscores() {
        XCTAssertEqual(emphasised("*파일 이름은 a_b 입니다*"), ["파일 이름은 a_b 입니다"])
    }

    func testCodeSpanWinsOverEmphasis() {
        // 코드 안의 별표는 강조가 아니다.
        XCTAssertTrue(emphasised("`*코드 속 별표*`").isEmpty)
    }

    func testEmptyEmphasisIsNotMatched() {
        XCTAssertTrue(emphasised("** 와 __ 는 내용이 없다").isEmpty)
    }

    // MARK: 강조·링크 안의 인라인 코드

    private func kinds(_ line: String) -> [InlineKind] {
        let ns = line as NSString
        return MarkdownSyntax().scanInline(in: ns, range: NSRange(location: 0, length: ns.length)).map(\.kind)
    }

    func testStrongMayContainInlineCode() {
        XCTAssertEqual(kinds("**문서 레벨 `NSUndoManager` 하나**에"), [.strong, .code],
                       "코드가 먼저 자리를 차지해도 강조는 그 바깥에서 산다")
        XCTAssertEqual(kinds("*기울임 `x` 안*"), [.emphasis, .code])
        XCTAssertEqual(kinds("~~취소 `x`~~"), [.strikethrough, .code])
    }

    func testLinkTextMayContainInlineCode() {
        XCTAssertEqual(kinds("[`설정` 열기](https://example.com)"), [.link(url: "https://example.com"), .code])
    }

    func testEmphasisMarkersInsideCodeStillDoNotCount() {
        XCTAssertEqual(kinds("`a **b` c**"), [.code], "표시가 코드 안에 있으면 강조가 아니다")
    }

    // MARK: 겹친 강조 — CommonMark의 짝 찾기 (Notion 내보내기에서 처음 봄)

    /// 보이는 글(표시를 뺀 것)과, 그 글자마다 굵게 · 기울임인지.
    private func rendered(_ line: String) -> (text: String, strong: String, emphasis: String) {
        let ns = line as NSString
        let tokens = MarkdownSyntax().scanInline(in: ns, range: NSRange(location: 0, length: ns.length))
        var hidden = IndexSet()
        var strong = IndexSet()
        var emphasis = IndexSet()
        for token in tokens {
            token.markerRanges.forEach { hidden.insert(integersIn: $0.location ..< NSMaxRange($0)) }
            let content = token.contentRange.location ..< NSMaxRange(token.contentRange)
            if token.kind == .strong { strong.insert(integersIn: content) }
            if token.kind == .emphasis { emphasis.insert(integersIn: content) }
        }
        func pick(_ keep: (Int) -> Bool) -> String {
            (0 ..< ns.length).filter { !hidden.contains($0) && keep($0) }
                .map { ns.substring(with: NSRange(location: $0, length: 1)) }.joined()
        }
        return (pick { _ in true }, pick { strong.contains($0) }, pick { emphasis.contains($0) })
    }

    func testBoldItalicTogether() {
        let result = rendered("앞 ***굵고 기울임*** 뒤")
        XCTAssertEqual(result.text, "앞 굵고 기울임 뒤", "전에는 `*굵고 기울임*`이 남았다")
        XCTAssertEqual(result.strong, "굵고 기울임")
        XCTAssertEqual(result.emphasis, "굵고 기울임")
    }

    func testEmphasisNestsBothWays() {
        let outer = rendered("*바깥 **안** 바깥*")
        XCTAssertEqual(outer.text, "바깥 안 바깥")
        XCTAssertEqual(outer.emphasis, "바깥 안 바깥", "전에는 기울임이 아예 없었다")
        XCTAssertEqual(outer.strong, "안")
        let inner = rendered("**바깥 *안* 바깥**")
        XCTAssertEqual(inner.strong, "바깥 안 바깥")
        XCTAssertEqual(inner.emphasis, "안")
        XCTAssertEqual(rendered("*foo**bar**baz*").strong, "bar", "셋의 규칙")
    }

    /// 닫는 `**` 앞이 문장 부호이고 뒤에 조사가 붙어도 닫는다 — CommonMark 그대로면 `**"값"**은`이 굵어지지 않는다.
    func testClosingAfterPunctuationBeforeAKoreanParticle() {
        XCTAssertEqual(rendered("**metric_id=\"DatasetDriftMetric\"**은 정한다").strong, "metric_id=\"DatasetDriftMetric\"")
        XCTAssertEqual(rendered("**MLOps 관련 내용(혹은 도전과제)**을 정리").strong, "MLOps 관련 내용(혹은 도전과제)")
        XCTAssertEqual(rendered("a**\"b\"**c").text, "a**\"b\"**c", "라틴 글자 사이는 CommonMark 그대로")
    }

    /// Notion은 굵은 조각 둘을 잇대어 `****`로 내보낸다. 셋의 규칙 때문에 짝이 안 되던 별표 넷을 닫고 다시 연다.
    func testNotionJoinedStrongRuns() {
        let joined = rendered("**프로필 네임스페이스 (****`kubeflow-user-example-com`**)")
        XCTAssertEqual(joined.text, "프로필 네임스페이스 (kubeflow-user-example-com)", "전에도 지금도 CommonMark는 `****`가 남는다")
        XCTAssertEqual(joined.strong, "프로필 네임스페이스 (kubeflow-user-example-com")
        let tail = rendered("***왜 마이크로배치인가****: 비교합니다.*")
        XCTAssertEqual(tail.text, "왜 마이크로배치인가: 비교합니다.")
        XCTAssertEqual(tail.strong, "왜 마이크로배치인가")
        XCTAssertEqual(tail.emphasis, "왜 마이크로배치인가: 비교합니다.")
        XCTAssertEqual(rendered("**a****b**").text, "ab")
    }

    func testEmphasisInsideLinkTextButNotAcrossIt() {
        let ns = "[*Link*](https://x.y)" as NSString
        let kinds = MarkdownSyntax().scanInline(in: ns, range: NSRange(location: 0, length: ns.length)).map(\.kind)
        XCTAssertEqual(kinds, [.link(url: "https://x.y"), .emphasis], "전에는 `*Link*`가 그대로 보였다")
        XCTAssertEqual(rendered("*[a*](https://x.y)").emphasis, "", "링크 안팎의 구분자는 짝이 아니다")
        XCTAssertEqual(rendered("**[굵은 링크](https://x.y)**").strong, "굵은 링크", "링크를 감싼 굵게")
    }

    func testEscapedAndUnmatchedDelimitersStayText() {
        XCTAssertEqual(rendered("\\*글자\\*").emphasis, "")
        XCTAssertEqual(rendered("**6.1.1 벤토 빌드하기*** Building").text, "6.1.1 벤토 빌드하기* Building",
                       "남는 별표 하나는 글자(CommonMark와 같다)")
        XCTAssertEqual(rendered("~~취소~~와 ~하나~").text, "취소와 ~하나~")
    }

    @MainActor
    func testBoldItalicIsDrawnBothWays() throws {
        let storage = NSTextStorage(string: "***굵고 기울임***\n")
        MarkdownStyler().style(storage, caretLine: nil, search: MarkdownStyler.SearchState())
        let font = try XCTUnwrap(storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertNotNil(storage.attribute(.obliqueness, at: 4, effectiveRange: nil), "한글은 강제로 기울인다")
        XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: 0, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: 2, effectiveRange: nil))
    }

    @MainActor
    func testStrongAroundCodeIsDrawnBold() throws {
        let storage = NSTextStorage(string: "**문서 `x` 하나**\n")
        MarkdownStyler().style(storage, caretLine: nil, search: MarkdownStyler.SearchState())
        let font = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "전에는 굵게 그려지지 않았다")
    }
}
