import AppKit
import XCTest

/// 보기 모드의 체크박스 — 캐럿이 없는 줄의 `[ ]` · `[x]`를 상자로 그린다.
///
/// 글자는 문서에 그대로 있고 투명하게만 칠한다. 그래서 폭이 바뀌지 않고(캐럿이 들어와 원문이
/// 보여도 줄이 밀리지 않는다), 누르기는 그 글자를 그대로 맞힌다.
@MainActor
final class TaskBoxTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func editor(_ markdown: String) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = editor
        window.orderBack(nil)
        windows.append(window)
        editor.markdown = markdown
        return editor
    }

    private let source = "제목\n\n- [ ] 할 일\n- [x] 끝난 일\n- 그냥 항목\n"

    private func range(of fragment: String, in text: String) -> NSRange {
        (text as NSString).range(of: fragment)
    }

    func testBoxesAreListedForLinesWithoutTheCaret() {
        let view = editor(source)
        view.textView.setSelectedRange(NSRange(location: 0, length: 0))     // 제목 줄
        XCTAssertEqual(view.textView.taskBoxes, [
            MarkdownStyler.TaskBox(range: range(of: "[ ]", in: source), checked: false),
            MarkdownStyler.TaskBox(range: range(of: "[x]", in: source), checked: true),
        ])
    }

    func testTheBoxCharactersAreTransparentButStillThere() throws {
        let view = editor(source)
        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let storage = try XCTUnwrap(view.textView.textStorage)
        let box = range(of: "[ ]", in: source)
        for index in box.location ..< NSMaxRange(box) {
            XCTAssertEqual(storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor, .clear)
            XCTAssertNil(storage.attribute(.mdHiddenMarker, at: index, effectiveRange: nil),
                         "숨기면 폭이 0이라 상자를 그릴 자리가 없다")
        }
        XCTAssertEqual(view.markdown, source, "문서는 그대로")
    }

    func testTheCaretLineShowsTheSourceInstead() throws {
        let view = editor(source)
        let box = range(of: "[ ]", in: source)
        view.textView.setSelectedRange(NSRange(location: NSMaxRange(box) + 2, length: 0))   // 그 줄
        XCTAssertEqual(view.textView.taskBoxes.map(\.range), [range(of: "[x]", in: source)],
                       "캐럿이 있는 줄은 원문 — 다른 마커와 같다")
        let color = try XCTUnwrap(view.textView.textStorage?.attribute(.foregroundColor, at: box.location,
                                                                       effectiveRange: nil) as? NSColor)
        XCTAssertNotEqual(color, .clear, "원문은 보여야 한다")

        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(view.textView.taskBoxes.count, 2, "나가면 다시 상자")
    }

    func testCodeViewShowsNoBoxes() {
        let view = editor(source)
        view.isCodeView = true
        XCTAssertTrue(view.textView.taskBoxes.isEmpty)
    }

    func testTheBlockEditorStylerLeavesBoxesAsText() {
        // 블록 편집기는 상자를 그리는 쪽을 잇지 않았다 — 거기서 글자를 투명하게 하면 사라진다.
        let storage = NSTextStorage(string: source)
        let styler = MarkdownStyler()
        styler.style(storage, caretLine: nil, search: MarkdownStyler.SearchState())
        XCTAssertTrue(styler.taskBoxes.isEmpty)
        let box = range(of: "[ ]", in: source)
        XCTAssertNotEqual(storage.attribute(.foregroundColor, at: box.location, effectiveRange: nil) as? NSColor,
                          .clear)
    }

    func testBoxFrameSitsOnTheTextAndWithinItsCharacters() {
        let glyphs = NSRect(x: 100, y: 40, width: 12.6, height: 30)
        let frame = DecoratedTextView.taskBoxFrame(glyphs: glyphs, baseline: 60, capHeight: 11)
        XCTAssertEqual(frame.width, frame.height, "정사각형")
        XCTAssertLessThanOrEqual(frame.width, glyphs.width, "세 글자의 폭을 넘지 않는다 — 뒤 글에 붙지 않게")
        XCTAssertEqual(frame.midX, glyphs.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, 60 - 11 / 2, accuracy: 1, "대문자 높이의 가운데 — 줄 조각의 가운데가 아니다")
    }

    /// 실제로 그려지는지 — 그린 그림의 화소를 본다. 한 일은 채워지고, 빈 칸은 테두리만.
    func testBoxesAreDrawn() throws {
        let view = editor(source)
        let tv = view.textView
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.window?.displayIfNeeded()
        let layout = try XCTUnwrap(tv.layoutManager)
        let container = try XCTUnwrap(tv.textContainer)
        func frame(of box: NSRange) throws -> NSRect {
            let glyphs = layout.glyphRange(forCharacterRange: box, actualCharacterRange: nil)
            var bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
            bounds.origin.x += tv.textContainerOrigin.x
            bounds.origin.y += tv.textContainerOrigin.y
            let fragment = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let baseline = fragment.minY + layout.location(forGlyphAt: glyphs.location).y + tv.textContainerOrigin.y
            let font = try XCTUnwrap(tv.textStorage?.attribute(.font, at: box.location, effectiveRange: nil) as? NSFont)
            return DecoratedTextView.taskBoxFrame(glyphs: bounds, baseline: baseline, capHeight: font.capHeight)
        }
        let open = try frame(of: range(of: "[ ]", in: source))
        let done = try frame(of: range(of: "[x]", in: source))

        let rep = try XCTUnwrap(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
        tv.cacheDisplay(in: tv.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / tv.bounds.width
        func brightness(_ point: NSPoint) -> CGFloat {
            // 텍스트 뷰는 뒤집힌 좌표다 — 비트맵의 행도 위에서부터 센다.
            let color = rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?
                .usingColorSpace(.deviceRGB)
            return color.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 } ?? 1
        }
        let background = brightness(NSPoint(x: tv.bounds.maxX - 4, y: open.midY))
        XCTAssertGreaterThan(background, 0.9, "전제: 밝은 바탕")
        XCTAssertLessThan(brightness(NSPoint(x: done.minX + done.width * 0.15, y: done.midY)), 0.85,
                          "한 일은 채워진다")
        XCTAssertGreaterThan(brightness(NSPoint(x: open.midX, y: open.midY)), 0.9, "빈 칸의 가운데는 비었다")
        XCTAssertLessThan(brightness(NSPoint(x: open.minX + 0.8, y: open.midY)), 0.85, "테두리는 보인다")
    }
}
