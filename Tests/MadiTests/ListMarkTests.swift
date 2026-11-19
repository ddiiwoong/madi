import AppKit
import XCTest

/// 목록의 글머리와 구분선 — 캐럿이 없는 줄에서 `-` 대신 점을, `---` 대신 선을 그린다(사용자 — "목록, 구분선도 보여주는건
/// 어색"). 글자는 문서에 그대로 있고 투명하게만 칠한다.
@MainActor
final class ListMarkStylerTests: XCTestCase {

    private func styler(drawing: Bool = true) -> MarkdownStyler {
        let styler = MarkdownStyler()
        styler.drawsListMarks = drawing
        return styler
    }

    private func color(at location: Int, in storage: NSTextStorage) -> NSColor? {
        storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    private func line(of fragment: String, in text: String) -> Int {
        let ns = text as NSString
        return ns.substring(to: ns.range(of: fragment).location).filter { $0 == "\n" }.count + 1
    }

    private let nested = "- 하나\n- 둘\n  - 안쪽\n    - 더 안쪽\n  - 다시 안쪽\n1. 번호\n   - 번호 안\n\n문단\n\n  - 들여 쓴 새 목록\n"

    /// 겹은 들여쓰기로 센다 — 더 들어가면 한 겹 안, 나오면 그만큼 밖. 번호 목록도 겹을 세고, 문단이 목록을 끊는다.
    func testBulletsCarryTheirNestingDepth() {
        let storage = NSTextStorage(string: nested)
        let styler = styler()
        styler.style(storage, caretLine: nil, search: MarkdownStyler.SearchState())
        XCTAssertEqual(styler.listBullets.map(\.depth), [1, 1, 2, 3, 2, 2, 1],
                       "하나 · 둘 · 안쪽 · 더 안쪽 · 다시 안쪽 · 번호 안 · 문단 뒤 새 목록(들여 썼어도 첫 겹)")
        let ns = nested as NSString
        XCTAssertEqual(styler.listBullets.first?.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(styler.listBullets[2].range, NSRange(location: ns.range(of: "  - 안쪽").location + 2, length: 1))
        XCTAssertEqual(storage.string, nested, "문서는 그대로")
    }

    /// 캐럿이 없는 줄의 글머리 글자는 투명하고(자리는 지킨다), 캐럿이 있는 줄은 원문 그대로 흐린 `-`다.
    func testBulletCharactersAreTransparentOffTheCaretLine() throws {
        let storage = NSTextStorage(string: nested)
        let styler = styler()
        let caret = line(of: "- 둘", in: nested)
        styler.style(storage, caretLine: caret, search: MarkdownStyler.SearchState())
        let ns = nested as NSString
        XCTAssertEqual(color(at: 0, in: storage), .clear)
        XCTAssertNil(storage.attribute(.mdHiddenMarker, at: 0, effectiveRange: nil), "숨기면 폭이 0이라 점을 그릴 자리가 없다")
        let onCaret = ns.range(of: "- 둘").location
        XCTAssertEqual(color(at: onCaret, in: storage), styler.theme.dim, "캐럿 줄은 원문")
        XCTAssertFalse(styler.listBullets.contains { $0.range.location == onCaret })
    }

    /// 번호는 그려진 모양 그대로 둔다 — 흐리게 하지 않고 본문 색. 캐럿이 있는 줄에서는 다른 표시처럼 흐리다.
    func testOrderedNumbersUseTheTextColor() {
        let text = "1. 하나\n2. 둘\n"
        let storage = NSTextStorage(string: text)
        let styler = styler()
        styler.style(storage, caretLine: 2, search: MarkdownStyler.SearchState())
        XCTAssertEqual(color(at: 0, in: storage), styler.theme.text)
        XCTAssertEqual(color(at: 1, in: storage), styler.theme.text, "`.`까지")
        XCTAssertEqual(color(at: (text as NSString).range(of: "2.").location, in: storage), styler.theme.dim)
        XCTAssertTrue(styler.listBullets.isEmpty, "번호 목록에는 점이 없다")
    }

    /// 체크박스 줄에는 점이 없다 — 상자만(GitHub와 같다). `-`는 투명하다.
    func testTaskItemsGetNoBullet() {
        let text = "- [ ] 할 일\n- [x] 한 일\n"
        let storage = NSTextStorage(string: text)
        let styler = styler()
        styler.drawsTaskBoxes = true
        styler.style(storage, caretLine: nil, search: MarkdownStyler.SearchState())
        XCTAssertTrue(styler.listBullets.isEmpty)
        XCTAssertEqual(color(at: 0, in: storage), .clear)
        XCTAssertEqual(styler.taskBoxes.count, 2)
    }

    /// 구분선 줄은 선으로 — 글자는 투명하다. 캐럿이 있는 줄은 원문(`---`)이다. 제목 밑줄(`---`)은 구분선이 아니다.
    func testThematicBreaksBecomeLines() {
        let text = "앞\n\n---\n\n* * *\n\n제목\n---\n"
        let storage = NSTextStorage(string: text)
        let styler = styler()
        styler.style(storage, caretLine: nil, search: MarkdownStyler.SearchState())
        let ns = text as NSString
        XCTAssertEqual(styler.thematicBreaks, [ns.lineRange(for: ns.range(of: "---")).trimmingNewline(in: ns),
                                               ns.lineRange(for: ns.range(of: "* * *")).trimmingNewline(in: ns)])
        XCTAssertEqual(color(at: ns.range(of: "---").location, in: storage), .clear)

        styler.style(storage, caretLine: 3, search: MarkdownStyler.SearchState())
        XCTAssertEqual(styler.thematicBreaks.count, 1, "캐럿이 있는 구분선은 원문")
        XCTAssertEqual(color(at: ns.range(of: "---").location, in: storage), styler.theme.rule)
        XCTAssertEqual(storage.string, text)
    }

    /// 끄면(블록 편집기) 전과 같다 — `-`는 흐린 글자로 보이고 그릴 것이 없다.
    func testOffByDefault() {
        let storage = NSTextStorage(string: nested)
        let styler = MarkdownStyler()
        styler.style(storage, caretLine: nil, search: MarkdownStyler.SearchState())
        XCTAssertTrue(styler.listBullets.isEmpty)
        XCTAssertTrue(styler.thematicBreaks.isEmpty)
        XCTAssertEqual(color(at: 0, in: storage), styler.theme.dim)
    }
}

private extension NSRange {
    /// 줄 범위에서 끝의 줄바꿈을 뺀 것(`LineToken.range`와 같은 꼴).
    func trimmingNewline(in text: NSString) -> NSRange {
        guard length > 0, text.character(at: NSMaxRange(self) - 1) == 0x0A else { return self }
        return NSRange(location: location, length: length - 1)
    }
}

/// 편집기 안에서 — 점과 선이 실제로 그려지고, 캐럿의 입력 글꼴이 그 자리의 글꼴을 따른다.
@MainActor
final class ListMarkEditorTests: XCTestCase {

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
        editor.layoutSubtreeIfNeeded()
        editor.textView.layoutManager?.ensureLayout(for: editor.textView.textContainer!)
        return editor
    }

    /// 텍스트 뷰를 그려 본 그림. 점(뷰 좌표)의 밝기를 읽는다 — 0은 검정, 1은 흰색.
    private func render(_ view: NSView) throws -> (NSPoint) -> CGFloat {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return { point in
            let color = rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.deviceRGB)
            return color.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 } ?? 1
        }
    }

    /// 점은 투명한 `-`의 자리에, 선은 글 칸 폭으로 그려진다 — 그린 그림의 그 자리가 어둡고, 바로 옆은 밝다.
    func testBulletsAndRulesAreDrawn() throws {
        let view = editor("문단\n\n- 하나\n  - 안쪽\n\n---\n\n끝\n")
        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let text = view.textView
        XCTAssertEqual(text.listBullets.map(\.depth), [1, 2])
        guard text.listBullets.count == 2 else { return }
        let disc = try XCTUnwrap(text.bulletFrame(of: text.listBullets[0]))
        let rule = try XCTUnwrap(text.thematicBreakFrame(of: try XCTUnwrap(text.thematicBreaks.first)))
        XCTAssertEqual(rule.width, text.textColumnWidth, accuracy: 0.5, "글 칸 폭")
        XCTAssertEqual(rule.minX, text.textContainerOrigin.x + text.textContainer!.lineFragmentPadding, accuracy: 0.5)

        let brightness = try render(text)
        XCTAssertLessThan(brightness(NSPoint(x: disc.midX, y: disc.midY)), 0.5, "채운 원 — 가운데가 어둡다")
        XCTAssertGreaterThan(brightness(NSPoint(x: disc.maxX + 3, y: disc.midY)), 0.9, "옆은 바탕")
        let ring = try XCTUnwrap(text.bulletFrame(of: text.listBullets[1]))
        XCTAssertGreaterThan(brightness(NSPoint(x: ring.midX, y: ring.midY)), 0.8, "빈 원 — 가운데가 비었다")
        XCTAssertLessThan(brightness(NSPoint(x: rule.midX, y: rule.minY + 0.25)), 0.95, "선이 있다")
        XCTAssertGreaterThan(brightness(NSPoint(x: rule.midX, y: rule.midY - 6)), 0.98, "선 위는 바탕 — `-` 글자가 보이지 않는다")
    }

    /// 같은 줄 안에서 옮겨도 따라간다 — 줄을 다시 칠하지 않는 움직임이다. 인라인 코드(고정폭)에서 본문으로.
    func testTypingFontFollowsWithinALine() throws {
        let source = "본문 `코드` 끝\n"
        let view = editor(source)
        let text = view.textView
        let storage = try XCTUnwrap(text.textStorage)
        let ns = source as NSString
        let code = ns.range(of: "코드")
        text.setSelectedRange(NSRange(location: code.location + 1, length: 0))
        let mono = try XCTUnwrap(storage.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(text.typingAttributes[.font] as? NSFont, mono)
        let end = ns.range(of: "끝")
        text.setSelectedRange(NSRange(location: NSMaxRange(end), length: 0))
        let body = try XCTUnwrap(storage.attribute(.font, at: end.location, effectiveRange: nil) as? NSFont)
        XCTAssertNotEqual(mono, body)
        XCTAssertEqual(text.typingAttributes[.font] as? NSFont, body, "같은 줄의 본문 글자 뒤")
    }

    /// 캐럿의 입력 글꼴이 그 자리의 글꼴을 따른다 — 캐럿의 높이와 새로 친 글자가 이것을 쓴다. 전에는 늘 시스템 기본
    /// 12pt였다(일반 글 텍스트 뷰는 입력 속성을 글에서 읽지 않는다). 문서 끝의 빈 줄은 본문 글꼴이다.
    func testTypingFontFollowsTheCaret() throws {
        let source = "# 큰 제목\n\n본문\n"
        let view = editor(source)
        let text = view.textView
        let storage = try XCTUnwrap(text.textStorage)
        let ns = source as NSString
        func typing() -> CGFloat { (text.typingAttributes[.font] as? NSFont)?.pointSize ?? 0 }
        func font(at location: Int) -> CGFloat {
            (storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        }

        let heading = ns.range(of: "제목")
        text.setSelectedRange(NSRange(location: NSMaxRange(heading), length: 0))
        XCTAssertEqual(typing(), font(at: heading.location), "제목 줄 끝 — 제목 글꼴")
        XCTAssertGreaterThan(typing(), 20)

        let body = ns.range(of: "본문")
        text.setSelectedRange(NSRange(location: body.location + 1, length: 0))
        XCTAssertEqual(typing(), font(at: body.location))

        text.setSelectedRange(NSRange(location: ns.length, length: 0))
        XCTAssertEqual(typing(), font(at: body.location), "끝의 빈 줄 — 본문 글꼴(전에는 12pt)")

        // 줄이 제목이 되면 캐럿도 따라간다.
        let bodySize = font(at: body.location)
        text.setSelectedRange(NSRange(location: body.location, length: 0))
        text.insertText("## ", replacementRange: text.selectedRange())
        XCTAssertGreaterThan(typing(), bodySize + 3, "본문이 제목이 됐다 — 캐럿 앞(`## `)의 글꼴이 커졌다")
    }
}
