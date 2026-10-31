import AppKit
import XCTest

/// 다이어그램·수식 블록 찾기(`RenderedBlock`, Core).
final class RenderedBlockTests: XCTestCase {

    private func blocks(_ markdown: String) -> [RenderedBlock] {
        let text = markdown as NSString
        return RenderedBlock.blocks(in: text, lines: MarkdownSyntax().scanLines(in: text))
    }

    func testMermaidFenceIsFoundWithItsBody() {
        let found = blocks("앞\n\n```mermaid\ngraph TD\n  A --> B\n```\n\n뒤\n")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, .mermaid)
        XCTAssertEqual(found.first?.delimiter, .fence)
        XCTAssertEqual(found.first?.source, "graph TD\n  A --> B")
        XCTAssertEqual(found.first?.firstLine, 3)
        XCTAssertEqual(found.first?.lastLine, 6)
    }

    /// 범위는 여는 줄의 처음부터 닫는 줄의 끝까지다(마지막 줄바꿈은 뺀다).
    func testRangeSpansFenceToFence() {
        let markdown = "x\n```math\na^2\n```\ny"
        let found = blocks(markdown)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual((markdown as NSString).substring(with: found[0].range), "```math\na^2\n```")
    }

    func testInfoStringIsReadByItsFirstWord() {
        XCTAssertEqual(RenderedBlock.kind(forFenceInfo: "Mermaid"), .mermaid)
        XCTAssertEqual(RenderedBlock.kind(forFenceInfo: "mermaid title=흐름"), .mermaid)
        XCTAssertEqual(RenderedBlock.kind(forFenceInfo: "math"), .math)
        XCTAssertEqual(RenderedBlock.kind(forFenceInfo: "katex"), .math)
        // `latex`는 대개 LaTeX **문서**의 코드다 — 수식으로 그리지 않는다.
        XCTAssertNil(RenderedBlock.kind(forFenceInfo: "latex"))
        XCTAssertNil(RenderedBlock.kind(forFenceInfo: "swift"))
        XCTAssertNil(RenderedBlock.kind(forFenceInfo: nil))
    }

    /// 치는 중인 블록 — 닫는 펜스가 없으면 아래 글 전체가 그 블록이다. 그림으로 바꾸면 문서가
    /// 통째로 사라져 보인다.
    func testUnclosedFenceIsNotRendered() {
        XCTAssertTrue(blocks("```mermaid\ngraph TD\n  A --> B\n\n이어지는 글\n").isEmpty)
    }

    func testOtherCodeBlocksAreLeftAlone() {
        XCTAssertTrue(blocks("```swift\nlet x = 1\n```\n").isEmpty)
        // 다른 코드 블록 **안의** `$$`는 코드다.
        XCTAssertTrue(blocks("```\n$$\nx\n$$\n```\n").isEmpty)
    }

    func testDollarBlockOnItsOwnLines() {
        let found = blocks("앞\n\n$$\n\\int_0^1 x\\,dx\n= \\frac12\n$$\n\n뒤\n")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].kind, .math)
        XCTAssertEqual(found[0].delimiter, .dollars)
        XCTAssertEqual(found[0].source, "\\int_0^1 x\\,dx\n= \\frac12")
        XCTAssertEqual(found[0].firstLine, 3)
        XCTAssertEqual(found[0].lastLine, 6)
    }

    func testOneLineDollarBlock() {
        let found = blocks("  $$ E = mc^2 $$\n")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].source, "E = mc^2")
        XCTAssertEqual(found[0].firstLine, found[0].lastLine)
        XCTAssertTrue(blocks("$$$$\n").isEmpty, "빈 수식")
        XCTAssertTrue(blocks("$$ 닫히지 않음\n").isEmpty)
    }

    /// 짝 없는 `$$` 하나가 문서 끝까지를 삼키지 않는다 — 빈 줄에서 문단이 끝난다.
    func testUnpairedDollarsStopAtABlankLine() {
        XCTAssertTrue(blocks("$$\nx + y\n\n뒤의 글\n\n$$\n").isEmpty)
    }

    /// 글 안의 `$`(값, 인라인 수식)는 블록이 아니다.
    func testInlineDollarsAreNotBlocks() {
        XCTAssertTrue(blocks("값은 $5$이고 $$가 글 중간에 있다.\n").isEmpty)
    }

    func testBlocksComeInDocumentOrder() {
        let found = blocks("```mermaid\npie\n```\n\n$$ x $$\n\n```math\ny\n```\n")
        XCTAssertEqual(found.map(\.kind), [.mermaid, .math, .math])
        XCTAssertEqual(found.map(\.firstLine), [1, 5, 7])
    }
}

/// 스타일러가 블록을 그림으로 바꾸는지 — 웹뷰 없이, 대역 렌더러로.
@MainActor
final class RenderedBlockLayoutTests: XCTestCase {

    /// 요청을 기억하고 정해 둔 답을 준다.
    final class StubRenderer: RenderedBlockImages {
        var answer: (RenderRequest) -> RenderOutcome
        private(set) var requests: [RenderRequest] = []
        init(_ answer: @escaping (RenderRequest) -> RenderOutcome) { self.answer = answer }
        func image(for request: RenderRequest) -> RenderOutcome {
            requests.append(request)
            return answer(request)
        }
    }

    static func picture(_ width: CGFloat, _ height: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func editor(_ markdown: String, renderer: RenderedBlockImages?,
                        caretAt caret: Int? = nil) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 760, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        window.contentView = editor
        window.orderBack(nil)
        windows.append(window)
        editor.useDiagramRenderer(renderer)
        editor.markdown = markdown
        editor.textView.setSelectedRange(NSRange(location: caret ?? 0, length: 0))
        editor.textView.layoutManager!.ensureLayout(for: editor.textView.textContainer!)
        return editor
    }

    /// 줄 번호(1부터)의 줄 조각 높이.
    private func lineHeight(_ editor: MarkdownEditorView, line: Int) -> CGFloat {
        let text = editor.textView.string as NSString
        var start = 0
        for _ in 1 ..< line { start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0))) }
        let layout = editor.textView.layoutManager!
        let glyph = layout.glyphIndexForCharacter(at: start)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height
    }

    private let document = "첫 줄\n\n```mermaid\ngraph TD\n  A --> B\n```\n\n끝 줄\n"

    /// 여는 줄이 그림의 높이를 갖고, 나머지 줄은 접힌다. 블록 뒤의 글은 그대로 이어진다.
    func testReadyBlockBecomesOnePictureLine() {
        let stub = StubRenderer { _ in .ready(Self.picture(240, 120)) }
        let view = editor(document, renderer: stub)            // 캐럿은 첫 줄

        // 그림 120 + 위아래 여백 8 + 문단 뒤 간격(본문 15pt × 0.55). 줄 조각이 문단 간격을 품는다.
        XCTAssertEqual(lineHeight(view, line: 3), 120 + 8 + 15 * 0.55, accuracy: 1, "여는 줄 = 그림 + 여백")
        for line in 4 ... 6 {
            XCTAssertLessThan(lineHeight(view, line: line), 1, "접힌 줄 \(line)")
        }
        XCTAssertGreaterThan(lineHeight(view, line: 8), 10, "블록 뒤의 글은 접히지 않는다")
        XCTAssertEqual(view.textView.imagePlacements.count, 1)
        XCTAssertEqual(view.textView.imagePlacements.first?.size, CGSize(width: 240, height: 120))
        // 회색 코드 상자는 그리지 않는다.
        XCTAssertTrue(view.textView.codeBlockRanges.isEmpty)
        // 원문은 그대로다.
        XCTAssertEqual(view.markdown, document)
    }

    func testRequestCarriesSourceAndAppearance() {
        let stub = StubRenderer { _ in .pending }
        let view = editor(document, renderer: stub)
        var request = stub.requests.last
        XCTAssertEqual(request?.kind, .mermaid)
        XCTAssertEqual(request?.source, "graph TD\n  A --> B")
        XCTAssertEqual(request?.fontSize, 15)
        XCTAssertEqual(request?.textColor.count, 7, "#rrggbb")
        XCTAssertEqual(request?.fontFamily, "-apple-system, sans-serif", "시스템 글꼴")

        // 설정의 본문 글꼴과 크기를 따른다 — 그림의 라벨이 본문과 같은 글꼴이어야 한다.
        var preferences = EditorPreferences.standard
        preferences.bodyPointSize = 18
        view.apply(preferences)
        request = stub.requests.last
        XCTAssertEqual(request?.fontFamily, "\"Pretendard\", -apple-system, sans-serif")
        XCTAssertEqual(request?.fontSize, 18)
    }

    /// 캐럿이 블록 **가운데 줄**로 들어오면 블록 전체가 원문이 된다. 그 줄만 칠하면 나머지
    /// 줄은 접힌 채 남는다.
    func testCaretInsideShowsTheWholeSource() {
        let stub = StubRenderer { _ in .ready(Self.picture(240, 120)) }
        let view = editor(document, renderer: stub)
        XCTAssertEqual(view.textView.imagePlacements.count, 1, "전제: 그림으로 시작한다")

        let middle = (document as NSString).range(of: "A --> B").location
        view.textView.setSelectedRange(NSRange(location: middle, length: 0))
        view.textView.layoutManager!.ensureLayout(for: view.textView.textContainer!)

        XCTAssertTrue(view.textView.imagePlacements.isEmpty)
        for line in 3 ... 6 {
            XCTAssertGreaterThan(lineHeight(view, line: line), 10, "원문 줄 \(line)")
        }
        XCTAssertEqual(view.textView.codeBlockRanges.count, 1, "코드 상자로 돌아온다")

        // 나가면 다시 그림이다.
        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        view.textView.layoutManager!.ensureLayout(for: view.textView.textContainer!)
        XCTAssertEqual(view.textView.imagePlacements.count, 1)
        XCTAssertLessThan(lineHeight(view, line: 5), 1)
    }

    /// 그리는 중이거나 그리지 못했으면 원문이다 — 틀린 Mermaid를 고칠 수 있어야 한다.
    func testPendingAndFailedKeepTheSource() {
        for outcome in [RenderOutcome.pending, .failed("Parse error")] {
            let view = editor(document, renderer: StubRenderer { _ in outcome })
            XCTAssertTrue(view.textView.imagePlacements.isEmpty)
            XCTAssertGreaterThan(lineHeight(view, line: 5), 10)
        }
    }

    /// 렌더러가 없으면(블록 편집기, 코드 보기) 묻지도 않는다.
    func testCodeViewDoesNotRender() {
        let stub = StubRenderer { _ in .ready(Self.picture(240, 120)) }
        let view = editor(document, renderer: stub)
        view.isCodeView = true
        XCTAssertTrue(view.textView.imagePlacements.isEmpty)
        XCTAssertGreaterThan(lineHeight(view, line: 5), 10)
    }

    /// `$$` 블록의 원문은 코드처럼 보인다 — `x_1 + y_1`의 `_`가 기울임 표시로 숨으면 안 된다.
    func testDollarSourceIsShownAsCode() {
        let markdown = "$$\nx_1 + y_1\n$$\n\n뒤\n"
        let view = editor(markdown, renderer: StubRenderer { _ in .pending })
        let storage = view.textView.textStorage!
        let underscore = (markdown as NSString).range(of: "_").location
        XCTAssertNil(storage.attribute(.mdHiddenMarker, at: underscore, effectiveRange: nil))
        let font = storage.attribute(.font, at: underscore, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.isFixedPitch == true)
        XCTAssertEqual(view.textView.codeBlockRanges.count, 1)
    }

    /// 넓은 그림은 글 넓이에 맞춰 줄인다.
    func testWidePictureIsScaledToTheTextWidth() {
        let view = editor(document, renderer: StubRenderer { _ in .ready(Self.picture(3000, 600)) })
        let size = view.textView.imagePlacements.first?.size ?? .zero
        XCTAssertLessThan(size.width, 760)
        XCTAssertEqual(size.width / size.height, 5, accuracy: 0.05, "비율은 지킨다")
    }

    /// 그림이 도착하면 다시 칠한다 — 알림을 받은 편집기가 자리를 잡는다.
    func testArrivalNotificationRestyles() {
        var ready = false
        let image = Self.picture(200, 100)
        let stub = StubRenderer { _ in ready ? .ready(image) : .pending }
        let view = editor(document, renderer: stub)
        XCTAssertTrue(view.textView.imagePlacements.isEmpty)
        ready = true
        NotificationCenter.default.post(name: DiagramRenderer.didRender, object: stub)
        XCTAssertEqual(view.textView.imagePlacements.count, 1)
    }
}
