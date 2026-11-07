import Foundation
import XCTest

/// 서식 메뉴의 규칙(`MarkdownFormatting`) — 원문을 어떻게 고치고 캐럿 · 선택이 어디로 가는지.
///
/// 글은 `«고른 글»`과 `‸`(캐럿)로 적는다. 앞이 편집 전, 뒤가 편집 뒤다.
final class MarkdownFormattingTests: XCTestCase {

    /// `«…»` · `‸`를 읽어 규칙을 적용하고, 결과를 같은 꼴로 돌려준다. 규칙이 nil이면 nil.
    private func run(_ marked: String, _ rule: (NSString, NSRange) -> TextEdit?,
                     file: StaticString = #filePath, line: UInt = #line) -> String? {
        var text = marked as NSString
        var selection: NSRange
        if text.range(of: "‸").location != NSNotFound {
            selection = NSRange(location: text.range(of: "‸").location, length: 0)
            text = text.replacingOccurrences(of: "‸", with: "") as NSString
        } else {
            let open = text.range(of: "«").location
            XCTAssertNotEqual(open, NSNotFound, "시험의 전제 — 캐럿이나 선택이 있다", file: file, line: line)
            text = text.replacingOccurrences(of: "«", with: "") as NSString
            let close = text.range(of: "»").location
            text = text.replacingOccurrences(of: "»", with: "") as NSString
            selection = NSRange(location: open, length: close - open)
        }
        guard let edit = rule(text, selection) else { return nil }
        let result = edit.applied(to: text as String) as NSString
        selection = edit.selection
        if selection.length == 0 { return result.replacingCharacters(in: selection, with: "‸") }
        let closed = result.replacingCharacters(in: NSRange(location: NSMaxRange(selection), length: 0), with: "»")
        return (closed as NSString).replacingCharacters(in: NSRange(location: selection.location, length: 0), with: "«")
    }

    private func bold(_ s: NSString, _ r: NSRange) -> TextEdit? { MarkdownFormatting.toggle(.bold, in: s, selection: r) }
    private func italic(_ s: NSString, _ r: NSRange) -> TextEdit? { MarkdownFormatting.toggle(.italic, in: s, selection: r) }
    private func heading(_ level: Int) -> (NSString, NSRange) -> TextEdit? {
        { MarkdownFormatting.heading(level, in: $0, selection: $1) }
    }
    private func block(_ kind: MarkdownFormatting.Block) -> (NSString, NSRange) -> TextEdit? {
        { MarkdownFormatting.toggle(kind, in: $0, selection: $1) }
    }

    // MARK: 글자 꾸밈

    func testBoldWrapsAndUnwrapsTheSelection() {
        XCTAssertEqual(run("앞 «글» 뒤", bold), "앞 **«글»** 뒤")
        XCTAssertEqual(run("앞 **«글»** 뒤", bold), "앞 «글» 뒤", "표식이 고른 글 바로 밖에 있으면 푼다")
        XCTAssertEqual(run("앞 «**글**» 뒤", bold), "앞 «글» 뒤", "고른 글의 양 끝이 표식이어도 푼다")
    }

    func testEmptySelectionInsertsAPairAndRemovesAnEmptyPair() {
        XCTAssertEqual(run("앞 ‸뒤", bold), "앞 **‸**뒤")
        XCTAssertEqual(run("앞 **‸**뒤", bold), "앞 ‸뒤")
        XCTAssertEqual(run("앞 **‸**뒤", italic), "앞 ***‸***뒤", "굵게의 빈 쌍은 기울임의 빈 쌍이 아니다")
    }

    /// `*` 하나는 기울임, 둘은 굵게, 셋은 둘 다. 서로 헷갈리지 않는다.
    func testItalicAndBoldShareTheAsteriskWithoutConfusion() {
        XCTAssertEqual(run("«**글**»", italic), "*«**글**»*", "굵은 글을 기울이면 ***")
        XCTAssertEqual(run("***«글»***", italic), "**«글»**", "*** 에서 기울임만 뺀다")
        XCTAssertEqual(run("***«글»***", bold), "*«글»*", "*** 에서 굵게만 뺀다")
        XCTAssertEqual(run("*«글»*", bold), "***«글»***")
    }

    /// 앞뒤 공백과 줄 앞의 블록 표식은 감싸지 않는다 — `** 글 **`나 `**# 제목**`은 꾸밈이 아니다.
    func testSpacesAndBlockMarkersStayOutside() {
        XCTAssertEqual(run("앞« 글 »뒤", bold), "앞 **«글»** 뒤")
        XCTAssertEqual(run("«# 제목»", bold), "# **«제목»**")
        XCTAssertEqual(run("«- [ ] 할 일»", bold), "- [ ] **«할 일»**")
        XCTAssertNil(run("앞«   »뒤", bold), "공백만 고르면 할 것이 없다")
    }

    func testSeveralLinesAreStyledLineByLine() {
        XCTAssertEqual(run("«첫 줄\n둘째 줄»", bold), "**«첫 줄**\n**둘째 줄»**")
        XCTAssertEqual(run("**«첫 줄**\n**둘째 줄»**", bold), "«첫 줄\n둘째 줄»", "모든 줄이 굵으면 모두 푼다")
        XCTAssertEqual(run("«**첫 줄**\n둘째 줄»", bold), "**«첫 줄**\n**둘째 줄»**", "안 굵은 줄만 감싼다")
        XCTAssertEqual(run("«가\n\n나»", bold), "**«가**\n\n**나»**", "빈 줄은 건너뛴다")
    }

    func testStrikethroughAndInlineCode() {
        XCTAssertEqual(run("«글»", { MarkdownFormatting.toggle(.strikethrough, in: $0, selection: $1) }), "~~«글»~~")
        XCTAssertEqual(run("«let x»", { MarkdownFormatting.toggle(.code, in: $0, selection: $1) }), "`«let x»`")
        XCTAssertEqual(run("`«let x»`", { MarkdownFormatting.toggle(.code, in: $0, selection: $1) }), "«let x»")
    }

    // MARK: 제목

    func testHeadingSetsChangesAndTogglesBack() {
        XCTAssertEqual(run("‸제목", heading(2)), "## ‸제목")
        XCTAssertEqual(run("## ‸제목", heading(2)), "‸제목", "같은 단계를 다시 누르면 본문")
        XCTAssertEqual(run("### 제‸목", heading(1)), "# 제‸목")
        XCTAssertEqual(run("## 제목‸", heading(0)), "제목‸", "본문")
        XCTAssertEqual(run("##‸ 제목", heading(4)), "#### ‸제목", "지운 표식 안의 캐럿은 새 표식 뒤로")
        XCTAssertNil(run("제목‸", heading(0)), "이미 본문")
    }

    /// 빈 줄에서는 그 줄을 제목 · 목록 · 인용으로 **시작**한다 — 이어서 쓰면 된다(앱에서 빈 줄에 캐럿을 두고 제목 2를
    /// 눌렀더니 아무 일도 없어 고쳤다).
    func testBlankLineStartsAHeadingListOrQuote() {
        XCTAssertEqual(run("앞\n‸\n뒤", heading(2)), "앞\n## ‸\n뒤")
        XCTAssertNil(run("앞\n‸\n뒤", heading(0)), "본문은 할 것이 없다")
        XCTAssertEqual(run("‸", block(.bullet)), "- ‸")
        XCTAssertEqual(run("‸", block(.numbered)), "1. ‸")
        XCTAssertEqual(run("‸", block(.task)), "- [ ] ‸")
        XCTAssertEqual(run("앞\n‸", block(.quote)), "앞\n> ‸")
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(run("#해시‸", heading(1)), "# #해시‸")
    }

    func testHeadingAppliesToEveryLineButSkipsBlankOnes() {
        XCTAssertEqual(run("«가\n\n나»", heading(3)), "### «가\n\n### 나»")
        XCTAssertEqual(run("«# 가\n## 나»", heading(2)), "«## 가\n## 나»", "단계가 섞이면 모두 그 단계로")
    }

    // MARK: 목록 · 인용

    func testBulletListTogglesAndConvertsOtherLists() {
        XCTAssertEqual(run("«가\n나»", block(.bullet)), "- «가\n- 나»")
        XCTAssertEqual(run("- «가\n- 나»", block(.bullet)), "«가\n나»")
        XCTAssertEqual(run("«1. 가\n2. 나»", block(.bullet)), "«- 가\n- 나»", "번호 목록을 글머리로")
    }

    func testNumberedListCountsPerIndentLevel() {
        XCTAssertEqual(run("«가\n  나\n  다\n라»", block(.numbered)), "1. «가\n  1. 나\n  2. 다\n2. 라»")
        XCTAssertEqual(run("«- 가\n- 나»", block(.numbered)), "«1. 가\n2. 나»")
        XCTAssertEqual(run("«1. 가\n2. 나»", block(.numbered)), "«가\n나»")
    }

    func testTaskListKeepsCheckedItems() {
        XCTAssertEqual(run("‸할 일", block(.task)), "- [ ] ‸할 일")
        XCTAssertEqual(run("«- [x] 끝\n남음»", block(.task)), "«- [x] 끝\n- [ ] 남음»", "체크한 것은 그대로")
        XCTAssertEqual(run("- [x] 끝‸", block(.task)), "끝‸")
    }

    /// 인용은 사이의 빈 줄도 `>`로 이어 한 덩이로 둔다.
    func testQuoteJoinsBlankLinesInside() {
        XCTAssertEqual(run("«가\n\n나»", block(.quote)), "> «가\n>\n> 나»")
        XCTAssertEqual(run("> «가\n>\n> 나»", block(.quote)), "«가\n\n나»")
    }

    // MARK: 링크

    func testLinkPlacesTheCaretWhereTypingContinues() {
        let link: (NSString, NSRange) -> TextEdit? = { MarkdownFormatting.link(in: $0, selection: $1) }
        XCTAssertEqual(run("‸", link), "[‸]()")
        XCTAssertEqual(run("«마디»", link), "[마디](‸)", "글을 고르면 주소를 쓸 자리로")
        XCTAssertEqual(run("«https://example.com»", link), "[‸](https://example.com)", "주소를 고르면 글을 쓸 자리로")
        XCTAssertNil(run("«가\n나»", link), "여러 줄은 링크가 될 수 없다")
    }

    // MARK: 코드 블록 · 표 · 구분선

    func testCodeBlockWrapsUnwrapsAndOpensAnEmptyOne() {
        let code: (NSString, NSRange) -> TextEdit? = { MarkdownFormatting.codeBlock(in: $0, selection: $1) }
        XCTAssertEqual(run("‸", code), "```\n‸\n```")
        XCTAssertEqual(run("«let x = 1»", code), "```‸\nlet x = 1\n```", "캐럿은 언어 이름을 쓸 자리")
        XCTAssertEqual(run("«```\nlet x = 1\n```»", code), "«let x = 1»")
        XCTAssertEqual(run("앞\n«a\nb»\n뒤", code), "앞\n```‸\na\nb\n```\n뒤")
    }

    func testTableAndRuleKeepABlankLineFromNeighbouringText() {
        let table: (NSString, NSRange) -> TextEdit? = { MarkdownFormatting.table(in: $0, selection: $1) }
        let rule: (NSString, NSRange) -> TextEdit? = { MarkdownFormatting.rule(in: $0, selection: $1) }
        XCTAssertEqual(run("‸", table), "| «열 1» | 열 2 |\n| --- | --- |\n|  |  |")
        XCTAssertEqual(run("글‸", table), "글\n\n| «열 1» | 열 2 |\n| --- | --- |\n|  |  |")
        // 글 바로 아래의 `---`는 제목 2가 된다 — 빈 줄을 둔다.
        XCTAssertEqual(run("글‸\n다음", rule), "글\n\n---‸\n\n다음")
        XCTAssertEqual(run("글\n‸\n다음", rule), "글\n\n---‸\n\n다음")
        XCTAssertEqual(run("글\n\n‸\n\n다음", rule), "글\n\n---‸\n\n다음")
    }

    /// 편집은 고친 범위만 바꾼다 — 앞뒤의 글은 그대로다(실행 취소가 그 범위만 되돌린다).
    func testEditsTouchOnlyTheLinesTheyChange() throws {
        let text = "머리\n\n가\n나\n\n꼬리" as NSString
        let selection = text.range(of: "가\n나")
        let edit = try XCTUnwrap(MarkdownFormatting.toggle(.bullet, in: text, selection: selection))
        XCTAssertEqual(edit.range, text.range(of: "가\n"), "첫 줄 앞부터 마지막 고친 자리까지")
        XCTAssertEqual(edit.applied(to: text as String), "머리\n\n- 가\n- 나\n\n꼬리")
    }
}

