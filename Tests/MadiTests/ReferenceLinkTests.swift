import XCTest

/// 참조 링크 — `[글][참조]` + `[참조]: url`.
///
/// 이 묶음이 지키는 것 가운데 가장 중요한 하나: **정의가 없는 참조는 링크가 아니다.**
/// 그 규칙이 없으면 `[보류]`처럼 링크가 아닌 대괄호 글이 전부 밑줄 친 링크로 보인다.
final class ReferenceLinkTests: XCTestCase {

    private let syntax = MarkdownSyntax()

    private func definitions(_ source: String) -> LinkDefinitions {
        let text = source as NSString
        return LinkDefinitions(scanning: text, lines: syntax.scanLines(in: text))
    }

    /// 한 줄 문서의 인라인 토큰. 정의는 문서 전체에서 모은다.
    private func inlineTokens(_ source: String, line wanted: Int = 1) -> [InlineToken] {
        let text = source as NSString
        let lines = syntax.scanLines(in: text)
        let definitions = LinkDefinitions(scanning: text, lines: lines)
        guard let line = lines.first(where: { $0.lineNumber == wanted }) else { return [] }
        return syntax.scanInline(in: text, range: line.contentRange, definitions: definitions)
    }

    private func urls(_ tokens: [InlineToken]) -> [String] {
        tokens.compactMap {
            switch $0.kind {
            case let .link(url), let .image(url), let .autolink(url): return url
            default: return nil
            }
        }
    }

    // MARK: 정의 줄

    func testDefinitionLineIsItsOwnKind() {
        let source = "본문\n\n[참조]: https://example.com\n"
        let kinds = syntax.scanLines(in: source as NSString).map(\.kind)
        XCTAssertEqual(kinds[2], .linkDefinition)
    }

    func testDefinitionCollectsLabelAndURL() {
        let table = definitions("[참조]: https://example.com\n")
        XCTAssertEqual(table.url(for: "참조"), "https://example.com")
        XCTAssertEqual(table.count, 1)
    }

    /// 라벨은 대소문자와 가운데 공백을 무시한다(CommonMark).
    func testLabelNormalisationIgnoresCaseAndInnerWhitespace() {
        let table = definitions("[Foo   Bar]: https://example.com\n")
        XCTAssertEqual(table.url(for: "foo bar"), "https://example.com")
        XCTAssertEqual(table.url(for: "  FOO  BAR  "), "https://example.com")
    }

    func testDefinitionAcceptsTitleAndAngleBracketedURL() {
        let table = definitions("""
        [a]: https://example.com "제목"
        [b]: <https://example.com/x y> '다른 제목'
        """)
        XCTAssertEqual(table.url(for: "a"), "https://example.com")
        XCTAssertEqual(table.url(for: "b"), "<https://example.com/x y>")
    }

    /// 같은 라벨이 두 번이면 먼저 나온 것이 이긴다.
    func testFirstDefinitionWins() {
        let table = definitions("[a]: https://first.example\n[a]: https://second.example\n")
        XCTAssertEqual(table.url(for: "a"), "https://first.example")
    }

    /// 코드 블록 안의 정의 꼴은 **코드다.** 세면, 문서에 쓴 예제가 실제 링크를 바꾼다.
    func testDefinitionInsideCodeBlockIsNotCollected() {
        let table = definitions("""
        ```
        [a]: https://example.com
        ```
        """)
        XCTAssertTrue(table.isEmpty)
    }

    /// 정의 줄에서 숨는 것은 라벨과 콜론까지다. **주소는 남는다** — 어디로 가는
    /// 링크인지가 그 줄의 내용이고, 줄을 통째로 숨기면 빈 줄이 남는다.
    func testDefinitionLineKeepsURLVisible() {
        let source = "[참조]: https://example.com\n"
        let line = syntax.scanLines(in: source as NSString)[0]
        XCTAssertEqual((source as NSString).substring(with: line.contentRange),
                       "https://example.com")
        XCTAssertEqual(line.markerRanges.count, 1)
        XCTAssertEqual((source as NSString).substring(with: line.markerRanges[0]), "[참조]: ")
    }

    // MARK: 세 가지 참조 꼴

    func testFullReferenceResolvesThroughDefinition() {
        let tokens = inlineTokens("""
        [마디 소개][madi]를 보라.

        [madi]: https://example.com/madi
        """)
        XCTAssertEqual(urls(tokens), ["https://example.com/madi"])
        XCTAssertEqual(tokens.count, 1)
    }

    func testCollapsedReferenceUsesVisibleTextAsLabel() {
        let tokens = inlineTokens("""
        [마디][]를 보라.

        [마디]: https://example.com/madi
        """)
        XCTAssertEqual(urls(tokens), ["https://example.com/madi"])
    }

    func testShortcutReferenceUsesVisibleTextAsLabel() {
        let tokens = inlineTokens("""
        [마디]를 보라.

        [마디]: https://example.com/madi
        """)
        XCTAssertEqual(urls(tokens), ["https://example.com/madi"])
    }

    func testReferenceImageResolvesToAnImageToken() {
        let tokens = inlineTokens("""
        ![그림][logo]

        [logo]: logo.png
        """)
        XCTAssertEqual(tokens.count, 1)
        guard case let .image(url) = tokens.first?.kind else {
            return XCTFail("그림 토큰이 아니다: \(String(describing: tokens.first?.kind))")
        }
        XCTAssertEqual(url, "logo.png")
    }

    // MARK: 해결되지 않는 것은 평범한 글자다

    func testUnresolvedReferenceIsPlainText() {
        XCTAssertTrue(inlineTokens("[보류] 상태입니다.\n").isEmpty)
        XCTAssertTrue(inlineTokens("[글][없는참조]를 보라.\n").isEmpty)
    }

    /// 체크 목록의 `[x]`는 참조가 아니다. 블록 마커로 이미 떼어져 인라인 범위에
    /// 들어오지도 않지만, 들어왔더라도 `x`라는 정의가 없으니 글자로 남는다.
    func testTaskListCheckboxIsNotAReference() {
        XCTAssertTrue(inlineTokens("- [x] 끝난 일\n").isEmpty)
    }

    /// 알림 표식도 참조로 보이지 않는다.
    func testAlertMarkerIsNotAReference() {
        XCTAssertTrue(inlineTokens("> [!NOTE] 알립니다\n").isEmpty)
    }

    // MARK: 인라인 꼴이 참조 꼴보다 먼저다

    func testInlineLinkWinsOverShortcutPattern() {
        let tokens = inlineTokens("""
        [글](https://inline.example)을 보라.

        [글]: https://reference.example
        """)
        XCTAssertEqual(urls(tokens), ["https://inline.example"])
        XCTAssertEqual(tokens.count, 1, "인라인 링크 하나여야 한다 — 축약 참조가 앞부분을 또 집으면 안 된다")
    }

    func testInlineImageWinsOverReferenceImagePattern() {
        let tokens = inlineTokens("""
        ![그림](real.png)

        [그림]: other.png
        """)
        XCTAssertEqual(urls(tokens), ["real.png"])
        XCTAssertEqual(tokens.count, 1)
    }

    /// 인라인 코드 안의 참조 꼴은 코드다.
    func testReferenceInsideInlineCodeIsNotResolved() {
        let tokens = inlineTokens("""
        `[마디]`를 보라.

        [마디]: https://example.com
        """)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.kind, .code)
    }

    // MARK: 마커 범위

    /// 캐럿이 없는 줄에서 접히는 것은 대괄호와 라벨이고, **보이는 글자는 남는다.**
    func testFullReferenceHidesOnlyBracketsAndLabel() {
        let source = """
        [마디 소개][madi]

        [madi]: https://example.com
        """
        let tokens = inlineTokens(source)
        guard let token = tokens.first else { return XCTFail("토큰이 없다") }
        let ns = source as NSString
        XCTAssertEqual(ns.substring(with: token.contentRange), "마디 소개")
        XCTAssertEqual(token.markerRanges.map { ns.substring(with: $0) }, ["[", "][madi]"])
    }

    // MARK: 정의 표가 없으면 참조는 글자다

    /// `scanInline`을 정의 없이 부르면(기존 호출 지점) 참조는 평범한 글자다.
    /// 기본값이 그렇게 동작해야, 표를 넘기지 않은 곳에서 주소 없는 링크가 생기지 않는다.
    func testWithoutDefinitionsReferencesStayPlain() {
        let source = "[마디]를 보라.\n"
        let text = source as NSString
        let line = syntax.scanLines(in: text)[0]
        XCTAssertTrue(syntax.scanInline(in: text, range: line.contentRange).isEmpty)
    }
}
