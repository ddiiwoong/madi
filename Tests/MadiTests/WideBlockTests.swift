import AppKit
import XCTest

/// 넓은 코드 블록과 넓은 표 — 줄을 바꾸지 않고 가로로 굴린다(사용자 — "코드랑 표 둘 다 추천안으로": 읽을 때는 가로로
/// 굴리고 고칠 때는 줄을 바꾼 원문, 표는 열이 너무 좁아지지 않게).
@MainActor
final class WideCodeStylerTests: XCTestCase {

    private func styler(column: Double = 300) -> MarkdownStyler {
        let styler = MarkdownStyler()
        styler.scrollsWideBlocks = true
        styler.drawsTables = true
        styler.textColumnWidth = column
        styler.contentWidth = column - 14
        return styler
    }

    private let longLine = "NAME STATUS ROLES AGE VERSION INTERNAL-IP EXTERNAL-IP OS-IMAGE KERNEL-VERSION CONTAINER-RUNTIME"

    private func source(_ body: String) -> String { "앞 문단\n\n```bash\n\(body)\n```\n\n뒤 문단\n" }

    private func caretLine(of fragment: String, in text: String) -> Int {
        let ns = text as NSString
        let location = ns.range(of: fragment).location
        return ns.substring(to: location).filter { $0 == "\n" }.count + 1
    }

    /// 글 칸보다 긴 줄이 있는 블록은 캐럿이 밖에 있으면 그림이 된다 — 블록의 글자는 숨고, 그림은 글 칸보다 넓다.
    func testLongLineBlockBecomesAWideImageWhenTheCaretIsOutside() throws {
        let text = source("kubectl get node -owide\n\(longLine)")
        let storage = NSTextStorage(string: text)
        let styler = styler()
        styler.style(storage, caretLine: 1, search: MarkdownStyler.SearchState())
        let fenceLine = (text as NSString).lineRange(for: (text as NSString).range(of: "```bash"))
        let placement = try XCTUnwrap(styler.imagePlacements.first { $0.lineRange.location == fenceLine.location })
        XCTAssertGreaterThan(Double(placement.size.width), 300, "줄을 바꾸지 않아 글 칸보다 넓다")
        let rendering = try XCTUnwrap(styler.codeRenderings[placement.lineRange])
        XCTAssertEqual(rendering.lineCount, 4, "여는 펜스 · 두 줄 · 닫는 펜스 — 줄이 바뀌지 않는다")
        let body = (text as NSString).range(of: "kubectl")
        XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: body.location, effectiveRange: nil), "원문 글자는 숨는다")
        XCTAssertEqual(styler.codeBlockRanges.count, 1, "회색 상자는 그대로")
    }

    /// 캐럿이 블록에 들어오면 원문(줄을 바꾼 글)이다 — 고치려면 원문이 보여야 한다. 지금 찾은 곳이 블록에 있어도 그렇다.
    func testCaretOrCurrentMatchInsideKeepsTheSource() {
        let text = source("kubectl get node -owide\n\(longLine)")
        let storage = NSTextStorage(string: text)
        let styler = styler()
        styler.style(storage, caretLine: caretLine(of: "kubectl", in: text), search: MarkdownStyler.SearchState())
        XCTAssertTrue(styler.imagePlacements.isEmpty)
        XCTAssertNil(storage.attribute(.mdHiddenMarker, at: (text as NSString).range(of: "kubectl").location,
                                       effectiveRange: nil))

        var search = MarkdownStyler.SearchState()
        search.ranges = [(text as NSString).range(of: "EXTERNAL-IP")]
        search.currentIndex = 0
        styler.style(storage, caretLine: 1, search: search)
        XCTAssertTrue(styler.imagePlacements.isEmpty, "찾은 글자를 보이려고 원문")
    }

    /// 긴 줄이 없는 블록, 내보내기, 원본 보기, 끈 편집기는 전과 같다(글 그대로).
    func testShortBlocksOutputAndCodeViewStayText() {
        let short = source("ls -la")
        let storage = NSTextStorage(string: short)
        let styler = styler()
        styler.style(storage, caretLine: 1, search: MarkdownStyler.SearchState())
        XCTAssertTrue(styler.imagePlacements.isEmpty, "긴 줄이 없으면 글")

        let long = NSTextStorage(string: source(longLine))
        styler.theme.isForOutput = true
        styler.style(long, caretLine: 1, search: MarkdownStyler.SearchState())
        XCTAssertTrue(styler.imagePlacements.isEmpty, "PDF · 프린트는 줄을 바꾼다 — 종이는 굴릴 수 없다")
        styler.theme.isForOutput = false

        styler.codeView = true
        styler.style(long, caretLine: 1, search: MarkdownStyler.SearchState())
        XCTAssertTrue(styler.imagePlacements.isEmpty)
        styler.codeView = false

        let off = MarkdownStyler()
        off.textColumnWidth = 300
        off.style(long, caretLine: 1, search: MarkdownStyler.SearchState())
        XCTAssertTrue(off.imagePlacements.isEmpty, "기본은 꺼져 있다")
    }

    /// 붙은 두 블록은 따로 판정한다 — 긴 줄이 있는 쪽만 그림이 된다.
    func testAdjacentBlocksAreJudgedSeparately() {
        let text = "```\nshort\n```\n```bash\n\(longLine)\n```\n"
        let storage = NSTextStorage(string: text)
        let styler = styler()
        styler.style(storage, caretLine: nil, search: MarkdownStyler.SearchState())
        XCTAssertEqual(styler.imagePlacements.count, 1)
        XCTAssertNil(storage.attribute(.mdHiddenMarker, at: (text as NSString).range(of: "short").location,
                                       effectiveRange: nil))
    }

    /// 누른 자리의 글자 — 그림의 둘째 줄을 누르면 그 줄의 그 글자.
    func testRenderingMapsAPointBackToTheDocument() throws {
        let text = source("kubectl get node\n\(longLine)")
        let storage = NSTextStorage(string: text)
        let styler = styler()
        styler.style(storage, caretLine: 1, search: MarkdownStyler.SearchState())
        let rendering = try XCTUnwrap(styler.codeRenderings.values.first)
        let lineHeight = rendering.size.height / CGFloat(rendering.lineCount)
        let advance = ("M" as NSString).size(withAttributes: [.font: styler.theme.monoFont]).width
        // 셋째 줄(긴 줄)의 다섯째 글자 가운데.
        let point = NSPoint(x: MarkdownStyler.codeIndent + advance * 4.3, y: lineHeight * 2.5)
        let index = rendering.documentIndex(at: point)
        XCTAssertEqual(index, (text as NSString).range(of: longLine).location + 4)
        XCTAssertEqual(rendering.documentIndex(at: NSPoint(x: 0, y: lineHeight * 1.5)),
                       (text as NSString).range(of: "kubectl").location, "줄의 처음")
    }

    private func paragraphStyle(at location: Int, in storage: NSTextStorage) -> NSParagraphStyle? {
        storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
    }

    /// 넓힌 자리(오른쪽 빈자리까지)에도 다 들지 않는 코드 그림만 막대의 자리를 갖는다 — 그만큼 여는 펜스 줄이 높다.
    func testWideCodeReservesBarSpaceOnlyWhenItOverflowsTheWideArea() throws {
        let text = source(longLine)
        let fence = (text as NSString).range(of: "```bash").location
        let narrow = NSTextStorage(string: text)
        let styler = styler()
        styler.style(narrow, caretLine: 1, search: MarkdownStyler.SearchState())
        let clipped = try XCTUnwrap(styler.imagePlacements.first)
        XCTAssertEqual(clipped.scrollBarSpace, MarkdownStyler.wideScrollBarSpace)
        XCTAssertEqual(paragraphStyle(at: fence, in: narrow)?.minimumLineHeight ?? 0,
                       clipped.size.height + MarkdownStyler.wideScrollBarSpace, accuracy: 0.01)

        let roomy = NSTextStorage(string: text)
        styler.wideAreaWidth = Double(clipped.size.width) + 40
        styler.style(roomy, caretLine: 1, search: MarkdownStyler.SearchState())
        let fits = try XCTUnwrap(styler.imagePlacements.first)
        XCTAssertEqual(fits.scrollBarSpace, 0, "넓힌 자리에 다 든다 — 굴릴 것이 없다")
        XCTAssertEqual(paragraphStyle(at: fence, in: roomy)?.minimumLineHeight ?? 0, fits.size.height, accuracy: 0.01)
    }

    private func wideTable(columns: Int, cell: (Int) -> String) -> String {
        let header = "| " + (1 ... columns).map { "열 \($0)" }.joined(separator: " | ") + " |"
        let rule = "|" + String(repeating: " --- |", count: columns)
        let row = "| " + (1 ... columns).map(cell).joined(separator: " | ") + " |"
        return "앞\n\n\(header)\n\(rule)\n\(row)\n\n뒤\n"
    }

    /// 글 칸에 들지 않는 표는 오른쪽 빈자리까지 열을 편다. 거기에 다 들면 막대가 없고, 그래도 넘치면 막대의 자리를 비운다.
    func testWideTableSpreadsIntoTheWideAreaAndReservesABarOnlyWhenItStillOverflows() throws {
        let text = wideTable(columns: 8) { "칸 \($0)의 조금 긴 설명입니다" }
        let header = (text as NSString).range(of: "| 열 1").location

        let clippedStorage = NSTextStorage(string: text)
        let styler = styler()
        styler.style(clippedStorage, caretLine: 1, search: MarkdownStyler.SearchState())
        let clipped = try XCTUnwrap(styler.imagePlacements.first)
        XCTAssertGreaterThan(Double(clipped.size.width), 300)
        XCTAssertEqual(clipped.scrollBarSpace, MarkdownStyler.wideScrollBarSpace)
        XCTAssertEqual(paragraphStyle(at: header, in: clippedStorage)?.minimumLineHeight ?? 0,
                       clipped.size.height + 2 + MarkdownStyler.wideScrollBarSpace, accuracy: 0.01)

        let roomyStorage = NSTextStorage(string: text)
        styler.wideAreaWidth = 3000
        styler.style(roomyStorage, caretLine: 1, search: MarkdownStyler.SearchState())
        let roomy = try XCTUnwrap(styler.imagePlacements.first)
        XCTAssertGreaterThan(roomy.size.width, clipped.size.width, "열을 덜 좁힌다 — 칸 안에서 줄을 덜 바꾼다")
        XCTAssertLessThanOrEqual(roomy.size.height, clipped.size.height)
        XCTAssertEqual(roomy.scrollBarSpace, 0)
        XCTAssertEqual(paragraphStyle(at: header, in: roomyStorage)?.minimumLineHeight ?? 0,
                       roomy.size.height + 2, accuracy: 0.01)
    }

    /// 글 칸 안에 드는 표(칸 안에서 줄을 바꿔)는 빈자리가 있어도 전과 같다. 내보내기도 전처럼 글 넓이에 맞춘다.
    func testTablesThatFitTheColumnAndOutputIgnoreTheWideArea() throws {
        let text = wideTable(columns: 2) { "칸 \($0)에는 글 칸 안에서 줄이 바뀌는 아주 긴 설명이 들어 있습니다" }
        let styler = styler()
        styler.style(NSTextStorage(string: text), caretLine: 1, search: MarkdownStyler.SearchState())
        let before = try XCTUnwrap(styler.imagePlacements.first).size
        XCTAssertLessThanOrEqual(Double(before.width), 300, "글 칸에 든다")
        styler.wideAreaWidth = 3000
        styler.style(NSTextStorage(string: text), caretLine: 1, search: MarkdownStyler.SearchState())
        XCTAssertEqual(try XCTUnwrap(styler.imagePlacements.first).size, before, "빈자리를 쓰지 않는다")

        let many = wideTable(columns: 8) { "칸 \($0)의 조금 긴 설명입니다" }
        styler.theme.isForOutput = true
        styler.style(NSTextStorage(string: many), caretLine: 1, search: MarkdownStyler.SearchState())
        let output = try XCTUnwrap(styler.imagePlacements.first)
        XCTAssertLessThanOrEqual(Double(output.size.width), styler.contentWidth + 8, "PDF · 프린트는 글 넓이에 맞춘다")
        XCTAssertEqual(output.scrollBarSpace, 0)
    }
}

final class WideTableGridTests: XCTestCase {

    func testReadableMinimumsKeepColumnsFromCollapsing() {
        // 다 합쳐 넘치지만 최소들은 들어간다 — 넓은 열에서 덜어 내고 좁은 열은 제 폭.
        XCTAssertEqual(TableGrid.columnWidths(natural: [80, 600, 600], available: 800, minimums: [120, 120, 120]),
                       [80, 360, 360])
        // 최소들만으로도 넘치면 최소들 — 표가 넓어진다.
        XCTAssertEqual(TableGrid.columnWidths(natural: [300, 300, 300, 300], available: 400, minimums: [120, 120, 120, 120]),
                       [120, 120, 120, 120])
        // 들어가면 제 폭.
        XCTAssertEqual(TableGrid.columnWidths(natural: [100, 100], available: 400, minimums: [120, 120]), [100, 100])
    }

    func testLongestWordSetsTheMinimum() {
        let font = NSFont.systemFont(ofSize: 15)
        let cell = NSAttributedString(string: "이름 kubeflow-user-example-com 끝", attributes: [.font: font])
        let word = ("kubeflow-user-example-com" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(TableGrid.longestWordWidth(in: cell), ceil(word), accuracy: 1)
    }

    /// 열이 많은 표 — 읽을 만한 폭을 주면 글 넓이보다 넓어지고, 주지 않으면(내보내기) 전처럼 글 넓이에 맞춘다.
    func testManyColumnsMakeAWideGridOnlyWhenScrolling() {
        let font = NSFont.systemFont(ofSize: 15)
        let cells = (1 ... 8).map { NSAttributedString(string: "열 \($0)의 조금 긴 설명입니다", attributes: [.font: font]) }
        let rows = [TableGrid.Row(cells: cells, isHeader: true), TableGrid.Row(cells: cells, isHeader: false)]
        let scrolling = TableGrid(rows: rows, columnCount: 8, lineHeight: 20, maxWidth: 500, minimumColumnWidth: 60,
                                  readableWidth: 90)
        XCTAssertGreaterThan(scrolling.size.width, 500)
        XCTAssertTrue(scrolling.columnWidths.allSatisfy { $0 >= 90 + 20 - 0.5 }, "\(scrolling.columnWidths)")
        let fitted = TableGrid(rows: rows, columnCount: 8, lineHeight: 20, maxWidth: 500, minimumColumnWidth: 60)
        XCTAssertLessThanOrEqual(fitted.size.width, 500 + 8)
    }
}

/// 편집기 안에서 — 가로 보기가 놓이고, 굴리고, 누르면 원문이 된다.
@MainActor
final class WideBlockEditorTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func editor(_ markdown: String, width: CGFloat = 520, height: CGFloat = 420) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        editor.codePasteboard = NSPasteboard(name: NSPasteboard.Name("madi-test-\(UUID().uuidString)"))
        window.contentView = editor
        window.orderBack(nil)
        windows.append(window)
        editor.markdown = markdown
        settle(editor)
        return editor
    }

    private func settle(_ editor: MarkdownEditorView) {
        for _ in 0 ..< 3 {
            editor.layoutSubtreeIfNeeded()
            editor.textView.layoutManager?.ensureLayout(for: editor.textView.textContainer!)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            editor.textView.updateWideViews()
        }
    }

    private let longLine = "node-1          Ready    control-plane   4m40s   v1.36.5+k3s1   192.0.2.10        <none>   Ubuntu 26.04 LTS"

    private var source: String {
        "# 제목\n\n앞 문단입니다.\n\n```bash\nkubectl get node -owide\n\(longLine)\n```\n\n뒤 문단입니다.\n"
    }

    /// 블록 자리에 가로 보기 하나 — 좁은 창에서는 글 칸 안에 들고, 안의 그림은 그보다 넓다. 블록은 줄을 바꾸지 않아 낮다.
    /// 넘치므로 오른쪽이 흐리고, 그림 아래에 늘 보이는 막대가 있다.
    func testWideCodeBlockGetsAHorizontalScroller() throws {
        let view = editor(source)
        let wide = try XCTUnwrap(view.textView.wideViews.first)
        XCTAssertEqual(view.textView.wideViews.count, 1)
        let document = try XCTUnwrap(wide.documentView)
        XCTAssertGreaterThan(document.frame.width, wide.frame.width, "옆으로 더 있다")
        let columnRight = view.textView.textContainerOrigin.x + view.textView.textContainer!.lineFragmentPadding
            + view.textView.textColumnWidth
        XCTAssertLessThanOrEqual(wide.frame.maxX, columnRight + 1, "좁은 창에는 빈자리가 없다 — 글 칸 안")
        XCTAssertEqual(wide.frame.minX, columnRight - view.textView.textColumnWidth, accuracy: 1,
                       "글 칸의 왼쪽 끝 — 코드 글이 다른 코드 블록과 같은 자리에서 시작한다")
        XCTAssertEqual(wide.contentView.frame.height, document.frame.height, accuracy: 1)
        XCTAssertEqual(wide.frame.height, document.frame.height + MarkdownStyler.wideScrollBarSpace, accuracy: 1,
                       "그림 아래에 막대의 자리")
        XCTAssertFalse(wide.scrollBar.isHidden, "막대가 늘 보인다")
        XCTAssertEqual(wide.scrollBar.frame.minY, wide.contentView.frame.maxY, accuracy: 0.5, "그림을 가리지 않는다")
        XCTAssertTrue(wide.fadesTrailingEdge, "오른쪽에 더 있다")
        XCTAssertFalse(wide.fadesLeadingEdge)
        XCTAssertNotNil(wide.contentView.layer?.mask, "잘린 쪽이 흐리다")
        let rendering = try XCTUnwrap(view.codeRendering(at: wide.placement.lineRange))
        XCTAssertEqual(rendering.lineCount, 4, "네 줄 — 긴 줄이 꺾이지 않았다")
        let block = try XCTUnwrap(view.textView.codeBlockRanges.first)
        let background = try XCTUnwrap(view.textView.codeBlockFrame(block))
        XCTAssertGreaterThanOrEqual(background.maxY, wide.frame.maxY, "회색 상자가 막대까지 덮는다")
    }

    /// 가로로 굴리면 가로 보기가 굴리고, 세로로 굴리면 문서가 굴러간다.
    func testHorizontalWheelScrollsTheBlockAndVerticalWheelScrollsTheDocument() throws {
        let filler = (1 ... 60).map { "문단 \($0)" }.joined(separator: "\n\n")
        let view = editor(source + "\n" + filler)
        let wide = try XCTUnwrap(view.textView.wideViews.first)
        let horizontal = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                               wheel1: 0, wheel2: -60, wheel3: 0))
        let documentTop = view.clipView.bounds.origin.y
        wide.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: horizontal)))
        XCTAssertEqual(wide.horizontalOffset, 60, accuracy: 0.5, "옆으로 굴렀다")
        XCTAssertEqual(view.clipView.bounds.origin.y, documentTop, accuracy: 0.5, "문서는 그대로")
        XCTAssertEqual(wide.contentView.bounds.height, wide.documentView!.frame.height, accuracy: 1.5,
                       "칸 안에서 세로로 구르지 않는다 — 막대가 칸을 가져가지 않는다")
        wide.scrollHorizontally(to: 10_000)
        XCTAssertEqual(wide.horizontalOffset, wide.documentView!.frame.width - wide.contentView.bounds.width,
                       accuracy: 0.5, "끝에서 멈춘다")

        let vertical = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                             wheel1: -80, wheel2: 0, wheel3: 0))
        let offset = wide.horizontalOffset
        wide.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: vertical)))
        XCTAssertGreaterThan(view.clipView.bounds.origin.y, documentTop, "세로는 문서가 받는다")
        XCTAssertEqual(wide.horizontalOffset, offset, accuracy: 0.5)
    }

    /// 누르면 그 글자에 캐럿이 가고 블록이 원문이 된다 — 가로 보기가 걷히고 글자가 다시 보인다.
    func testClickingPutsTheCaretInTheBlockAndOpensTheSource() throws {
        let view = editor(source)
        let wide = try XCTUnwrap(view.textView.wideViews.first)
        let rendering = try XCTUnwrap(view.codeRendering(at: wide.placement.lineRange))
        let lineHeight = rendering.size.height / CGFloat(rendering.lineCount)
        XCTAssertTrue(view.handleWideClick(wide.placement, at: NSPoint(x: 12, y: lineHeight * 2.5), modifiers: []))
        settle(view)
        let line = (view.markdown as NSString).range(of: longLine)
        XCTAssertTrue(NSLocationInRange(view.textView.selectedRange().location, NSRange(location: line.location,
                                                                                        length: line.length + 1)))
        XCTAssertTrue(view.textView.wideViews.isEmpty, "원문이 됐다")
        XCTAssertNil(view.storageAttribute(.mdHiddenMarker, at: line.location))
    }

    /// 열이 많은 표도 넓으면 가로 보기에 든다. 내보내는 동안은 전처럼 글 넓이에 맞춘다(가로 보기 없음).
    func testWideTableScrollsAndOutputFits() throws {
        let header = "| " + (1 ... 8).map { "열 \($0)" }.joined(separator: " | ") + " |"
        let rule = "|" + String(repeating: " --- |", count: 8)
        let row = "| " + (1 ... 8).map { "칸 \($0)의 조금 긴 설명입니다" }.joined(separator: " | ") + " |"
        let view = editor("앞\n\n\(header)\n\(rule)\n\(row)\n\n뒤\n")
        XCTAssertEqual(view.textView.wideViews.count, 1, "넓은 표는 가로로")
        view.isRenderingForOutput = true
        settle(view)
        XCTAssertTrue(view.textView.wideViews.isEmpty, "PDF · 프린트는 글 넓이에 맞춘다")
        view.isRenderingForOutput = false
        settle(view)
        XCTAssertEqual(view.textView.wideViews.count, 1)
    }

    /// 복사 단추는 가로 보기 위에 뜬다 — 넓은 블록도 바로 베낄 수 있다.
    func testCopyButtonFloatsAboveTheWideView() throws {
        let view = editor(source)
        let wide = try XCTUnwrap(view.textView.wideViews.first)
        view.updateCodeCopyButton(at: NSPoint(x: wide.frame.midX, y: wide.frame.midY))
        let button = try XCTUnwrap(view.codeCopyButton)
        XCTAssertFalse(button.isHidden)
        let subviews = view.textView.subviews
        XCTAssertGreaterThan(try XCTUnwrap(subviews.firstIndex(of: button)), try XCTUnwrap(subviews.firstIndex(of: wide)),
                             "단추가 앞에")
        XCTAssertTrue(view.textView.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button)
        button.press()
        XCTAssertEqual(view.codePasteboard.string(forType: .string), "kubectl get node -owide\n\(longLine)")
    }

    /// 창을 좁히면(여백이 그대로인 폭) 다시 잰다 — 넓던 블록이 넓어지고, 넓히면 다시 글이 된다.
    func testNarrowingTheWindowRemeasures() throws {
        let medium = "kubectl get pods --all-namespaces -o wide --sort-by=.metadata.name"
        let view = editor("앞\n\n```bash\n\(medium)\n```\n", width: 1000)
        XCTAssertTrue(view.textView.wideViews.isEmpty, "넓은 창에서는 들어간다")
        view.window?.setContentSize(NSSize(width: 420, height: 420))
        view.setFrameSize(NSSize(width: 420, height: 420))
        settle(view)
        XCTAssertEqual(view.textView.wideViews.count, 1, "좁히면 넘친다")
    }

    private func table(columns: Int, cell: (Int) -> String) -> String {
        let header = "| " + (1 ... columns).map { "열 \($0)" }.joined(separator: " | ") + " |"
        let rule = "|" + String(repeating: " --- |", count: columns)
        let row = "| " + (1 ... columns).map(cell).joined(separator: " | ") + " |"
        return "앞\n\n\(header)\n\(rule)\n\(row)\n\n뒤 문단\n"
    }

    /// 넓은 창 — 글은 가운데 있고 양옆이 빈다. 글 칸보다 넓은 표는 오른쪽 빈자리까지 펴서 다 보인다(굴릴 것도, 막대도 없다).
    func testWideTableUsesTheRightGutterInAWideWindow() throws {
        let view = editor(table(columns: 8) { "칸 \($0) 조금 긴 글" }, width: 1400)
        let text = view.textView
        let columnLeft = text.textContainerOrigin.x + text.textContainer!.lineFragmentPadding
        XCTAssertGreaterThan(text.wideAreaWidth, text.textColumnWidth + 150, "넓은 창에는 오른쪽에 빈자리가 있다")
        let wide = try XCTUnwrap(text.wideViews.first, "글 칸보다 넓은 표")
        XCTAssertGreaterThan(wide.placement.size.width, text.textColumnWidth)
        XCTAssertLessThanOrEqual(wide.placement.size.width, text.wideAreaWidth)
        XCTAssertGreaterThan(wide.frame.maxX, columnLeft + text.textColumnWidth + 20, "글 칸 오른쪽으로 넓혔다")
        XCTAssertLessThanOrEqual(wide.frame.maxX, text.bounds.width - MarkdownTheme().textInsets.width,
                                 "창 오른쪽에 기본 여백은 남긴다")
        XCTAssertEqual(wide.frame.width, wide.placement.size.width, accuracy: 1, "다 보인다")
        XCTAssertEqual(wide.overflowWidth, 0)
        XCTAssertTrue(wide.scrollBar.isHidden)
        XCTAssertFalse(wide.fadesLeadingEdge || wide.fadesTrailingEdge)
        XCTAssertNil(wide.contentView.layer?.mask)
        XCTAssertEqual(wide.frame.height, wide.placement.size.height, accuracy: 1, "막대의 자리를 비우지 않는다")
    }

    /// 넓은 창의 긴 줄 코드 — 빈자리까지 펴서 다 보이고, 회색 상자도 그 폭까지 넓어진다(글이 상자 밖에 놓이지 않는다).
    func testWideCodeInAWideWindowFitsAndTheBackgroundFollows() throws {
        let line = String(repeating: "abcdefghij ", count: 9)
        let view = editor("앞\n\n```\n\(line)\n```\n", width: 1400)
        let text = view.textView
        let wide = try XCTUnwrap(text.wideViews.first, "글 칸보다 길다")
        XCTAssertLessThanOrEqual(wide.placement.size.width, text.wideAreaWidth, "빈자리에는 든다")
        XCTAssertEqual(wide.frame.width, wide.placement.size.width, accuracy: 1)
        XCTAssertTrue(wide.scrollBar.isHidden)
        let block = try XCTUnwrap(text.codeBlockRanges.first)
        let background = try XCTUnwrap(text.codeBlockFrame(block))
        XCTAssertGreaterThanOrEqual(background.maxX, wide.frame.maxX, "상자가 글을 덮는다")
        XCTAssertEqual(background.minX, wide.frame.minX - text.codeBlockPadding.left, accuracy: 1, "왼쪽은 그대로")
    }

    /// 넓은 창에서 다 보이던 블록은 창을 좁혀도 처음부터 보인다 — 굴린 적이 없으면 왼쪽 끝이다.
    func testShrinkingTheWindowKeepsTheBlockAtItsStart() throws {
        let line = String(repeating: "abcdefghij ", count: 9)
        let view = editor("앞\n\n```\n\(line)\n```\n", width: 1400)
        XCTAssertEqual(try XCTUnwrap(view.textView.wideViews.first).overflowWidth, 0)
        for width in stride(from: 1300, through: 800, by: -100) {
            view.window?.setContentSize(NSSize(width: CGFloat(width), height: 420))
            view.setFrameSize(NSSize(width: CGFloat(width), height: 420))
            settle(view)
        }
        let wide = try XCTUnwrap(view.textView.wideViews.first)
        XCTAssertGreaterThan(wide.overflowWidth, 0, "좁히니 넘친다")
        XCTAssertEqual(wide.horizontalOffset, 0, accuracy: 0.5, "처음부터 보인다")
        XCTAssertFalse(wide.fadesLeadingEdge)
    }

    /// 넓힌 자리에도 넘치는 표 — 잘린 쪽이 흐리고 늘 보이는 막대가 있다. 굴리면 흐린 쪽이 따라 바뀐다. 표 아래 글은 막대
    /// 밑에서 시작한다.
    func testOverflowingTableFadesTheClippedSidesAndKeepsABar() throws {
        let view = editor(table(columns: 8) { "칸 \($0)의 조금 긴 설명입니다" }, width: 825)
        let wide = try XCTUnwrap(view.textView.wideViews.first)
        XCTAssertGreaterThan(wide.overflowWidth, 100)
        XCTAssertFalse(wide.scrollBar.isHidden, "막대가 늘 보인다")
        XCTAssertEqual(wide.contentView.frame.height, wide.placement.size.height, accuracy: 1, "그림은 다 보인다")
        XCTAssertTrue(wide.fadesTrailingEdge)
        XCTAssertFalse(wide.fadesLeadingEdge)

        wide.scrollHorizontally(to: wide.overflowWidth / 2)
        XCTAssertTrue(wide.fadesLeadingEdge && wide.fadesTrailingEdge, "가운데 — 양쪽이 잘렸다")
        let mask = try XCTUnwrap(wide.contentView.layer?.mask)
        XCTAssertEqual(mask.frame, try XCTUnwrap(wide.contentView.layer?.bounds), "가림이 굴린 칸을 따라간다")
        wide.scrollHorizontally(to: wide.overflowWidth)
        XCTAssertTrue(wide.fadesLeadingEdge)
        XCTAssertFalse(wide.fadesTrailingEdge, "끝 — 오른쪽은 다 보인다")

        let after = (view.markdown as NSString).range(of: "뒤 문단")
        let layout = try XCTUnwrap(view.textView.layoutManager)
        let glyphs = layout.glyphRange(forCharacterRange: after, actualCharacterRange: nil)
        let line = layout.boundingRect(forGlyphRange: glyphs, in: view.textView.textContainer!)
            .offsetBy(dx: 0, dy: view.textView.textContainerOrigin.y)
        XCTAssertGreaterThanOrEqual(line.minY, wide.frame.maxY, "막대가 다음 글을 덮지 않는다")
    }

    /// 막대를 끌면 그만큼 굴리고, 길을 누르면 손잡이가 그 자리로 온다 — 마우스만으로도 옆을 본다.
    func testDraggingTheBarScrollsTheTable() throws {
        let view = editor(table(columns: 8) { "칸 \($0)의 조금 긴 설명입니다" }, width: 825)
        let wide = try XCTUnwrap(view.textView.wideViews.first)
        let bar = wide.scrollBar
        let window = try XCTUnwrap(view.window)
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            let point = bar.convert(NSPoint(x: x, y: bar.bounds.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        }
        XCTAssertTrue(view.textView.hitTest(view.textView.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY),
                                                                  from: bar)) === bar, "막대를 누를 수 있다")
        // 손잡이(맨 왼쪽)를 잡고 40pt 끈다.
        bar.mouseDown(with: try event(.leftMouseDown, x: 8))
        XCTAssertEqual(wide.horizontalOffset, 0, accuracy: 0.5, "손잡이를 잡기만 하면 그대로")
        bar.mouseDragged(with: try event(.leftMouseDragged, x: 48))
        bar.mouseUp(with: try event(.leftMouseUp, x: 48))
        let viewRatio = wide.contentView.bounds.width / wide.documentView!.frame.width
        let thumb = max(28, (bar.bounds.width * viewRatio).rounded())
        XCTAssertEqual(wide.horizontalOffset, 40 * wide.overflowWidth / (bar.bounds.width - thumb), accuracy: 1)
        XCTAssertTrue(wide.fadesLeadingEdge)

        // 길의 오른쪽 끝을 누르면 끝까지.
        bar.mouseDown(with: try event(.leftMouseDown, x: bar.bounds.maxX - 1))
        bar.mouseUp(with: try event(.leftMouseUp, x: bar.bounds.maxX - 1))
        XCTAssertEqual(wide.horizontalOffset, wide.overflowWidth, accuracy: 0.5)
    }
}

extension MarkdownEditorView {
    /// 시험용 — 저장소의 속성 하나.
    func storageAttribute(_ key: NSAttributedString.Key, at index: Int) -> Any? {
        textView.textStorage?.attribute(key, at: index, effectiveRange: nil)
    }
}
