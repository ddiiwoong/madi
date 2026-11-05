import AppKit
import XCTest

/// 각주 — 참조 `[^1]`과 정의 `[^1]: 글` (GFM).
///
/// 참조 링크와 같은 약속을 지킨다: **정의가 없는 참조는 각주가 아니다.** 그리고 정의 줄은
/// 링크 정의 꼴(`[^1]: https://…`)과 겹쳐도 각주로 읽는다.
final class FootnoteTests: XCTestCase {

    private let syntax = MarkdownSyntax()

    private func lines(_ source: String) -> [LineToken] {
        syntax.scanLines(in: source as NSString)
    }

    private func inline(_ source: String, line wanted: Int = 1) -> [InlineToken] {
        let text = source as NSString
        let scanned = syntax.scanLines(in: text)
        let definitions = LinkDefinitions(scanning: text, lines: scanned)
        guard let line = scanned.first(where: { $0.lineNumber == wanted }) else { return [] }
        return syntax.scanInline(in: text, range: line.contentRange, definitions: definitions)
    }

    // MARK: 정의 줄

    func testDefinitionLineIsAFootnoteNotALinkDefinition() {
        let source = "본문\n\n[^1]: 각주 글\n[^web]: https://example.com\n"
        let scanned = lines(source)
        XCTAssertEqual(scanned[2].kind, .footnoteDefinition)
        XCTAssertEqual(scanned[3].kind, .footnoteDefinition, "주소 하나뿐이어도 GFM에서는 각주다")

        let definitions = LinkDefinitions(scanning: source as NSString, lines: scanned)
        XCTAssertTrue(definitions.hasFootnote("1"))
        XCTAssertTrue(definitions.hasFootnote("WEB"), "라벨은 대소문자를 가리지 않는다")
        XCTAssertNil(definitions.url(for: "^web"), "링크 정의 표에 섞이지 않는다")
    }

    func testDefinitionMarkersAreTheBracketsAndTheColon() {
        let source = "[^note]: 각주 글" as NSString
        let line = syntax.scanLines(in: source)[0]
        XCTAssertEqual(line.markerRanges.map { source.substring(with: $0) }, ["[^", "]: "])
        XCTAssertEqual(source.substring(with: line.contentRange), "각주 글")
        XCTAssertEqual(MarkdownSyntax.footnoteLabel(ofDefinition: line, in: source), "note")
    }

    func testALabelWithSpacesIsNotAFootnote() {
        XCTAssertNotEqual(lines("[^두 낱말]: 글")[0].kind, .footnoteDefinition)
    }

    // MARK: 참조

    func testReferenceWithADefinitionIsAFootnote() throws {
        let source = "본문[^1]입니다.\n\n[^1]: 각주 글\n"
        let tokens = inline(source)
        let token = try XCTUnwrap(tokens.first)
        XCTAssertEqual(token.kind, .footnoteReference(label: "1"))
        let text = source as NSString
        XCTAssertEqual(text.substring(with: token.contentRange), "1")
        XCTAssertEqual(token.markerRanges.map { text.substring(with: $0) }, ["[^", "]"])
    }

    func testReferenceWithoutADefinitionIsPlainText() {
        XCTAssertTrue(inline("본문[^없음] 입니다.").isEmpty, "정의가 없으면 평범한 대괄호 글이다")
    }

    func testReferenceIsNotTakenByAShortcutReferenceLink() {
        // `[^1]`은 참조 링크 축약 꼴에도 맞는다. 링크 정의 `[^1]: x`가 있어도 — 각주 정의 줄이
        // 먼저 판정되므로 그런 링크 정의는 생기지 않는다.
        let tokens = inline("본문[^1]\n\n[^1]: https://example.com\n")
        XCTAssertEqual(tokens.map(\.kind), [.footnoteReference(label: "1")])
    }

    // MARK: 번역

    func testTranslationKeepsTheReferenceAndTheDefinitionHead() throws {
        let plan = MarkdownTranslationPlan.make("본문[^1]입니다.\n\n[^1]: 각주 글\n")
        XCTAssertTrue(plan.units.contains { $0.protected.contains { $0.text == "[^1]" } },
                      "참조는 번역기에 글로 넘어가지 않는다")
        XCTAssertTrue(plan.translatableTexts.contains("각주 글"), "각주의 글은 번역한다")
        XCTAssertFalse(plan.translatableTexts.contains { $0.contains("[^1]:") }, "정의의 머리는 남는다")
        let echoed = try plan.assembled(with: plan.translatableTexts)
        XCTAssertEqual(echoed, plan.source, "그대로 돌려주면 원문 그대로")
    }

    func testTranslationKeepsReferenceLinkLabels() {
        // 정의를 알게 되자 참조 링크도 링크로 받는다 — 라벨이 번역되면 정의 줄(번역하지 않음)과
        // 끊어진다.
        let plan = MarkdownTranslationPlan.make("[마디][home]를 보세요.\n\n[home]: https://example.com\n")
        XCTAssertTrue(plan.units.contains { $0.protected.contains { $0.text.contains("[home]") } })
    }
}

/// 각주가 **편집기에서** 어떻게 보이고 ⌘클릭으로 오가는지.
@MainActor
final class FootnoteEditorTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func editor(_ markdown: String) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = editor
        window.orderBack(nil)
        windows.append(window)
        editor.markdown = markdown
        return editor
    }

    private let source = "첫 문단[^1]이다.\n\n둘째 문단\n\n[^1]: 각주 글\n"

    func testReferenceIsASmallRaisedLabelAndItsBracketsFold() throws {
        let view = editor(source)
        let tv = view.textView
        tv.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))   // 다른 줄
        let storage = try XCTUnwrap(tv.textStorage)
        let ns = source as NSString
        let label = ns.range(of: "[^1]").location + 2
        XCTAssertEqual(storage.attribute(.mdFootnoteJump, at: label, effectiveRange: nil) as? String, "definition:1")
        let offset = try XCTUnwrap(storage.attribute(.baselineOffset, at: label, effectiveRange: nil) as? CGFloat)
        XCTAssertGreaterThan(offset, 0, "위첨자")
        XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: label - 2, effectiveRange: nil), "`[^`는 접힌다")
        XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: label + 1, effectiveRange: nil), "`]`도")
        XCTAssertNil(storage.attribute(.mdHiddenMarker, at: label, effectiveRange: nil), "라벨은 남는다")
    }

    func testDefinitionHeadFoldsAndItsLabelLeadsBack() throws {
        let view = editor(source)
        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let storage = try XCTUnwrap(view.textView.textStorage)
        let head = (source as NSString).range(of: "[^1]:").location
        XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: head, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(.mdFootnoteJump, at: head + 2, effectiveRange: nil) as? String, "reference:1")
        XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: head + 3, effectiveRange: nil), "`]: `는 접힌다")
    }

    func testCommandClickGoesToTheDefinitionAndBack() {
        let view = editor(source)
        let ns = source as NSString
        let label = ns.range(of: "[^1]").location + 2
        XCTAssertTrue(view.handleClick(at: label, modifiers: .command))
        XCTAssertEqual(view.textView.selectedRange().location, ns.range(of: "각주 글").location,
                       "정의의 글 앞으로")

        let head = ns.range(of: "[^1]:").location + 2
        XCTAssertTrue(view.handleClick(at: head, modifiers: .command))
        XCTAssertEqual(view.textView.selectedRange().location, NSMaxRange(ns.range(of: "[^1]")),
                       "첫 참조 뒤로")
    }

    func testPlainClickOnAReferencePlacesTheCaret() {
        let view = editor(source)
        let label = (source as NSString).range(of: "[^1]").location + 2
        XCTAssertFalse(view.handleClick(at: label, modifiers: []), "그냥 클릭은 고치러 들어가는 것이다")
    }
}
