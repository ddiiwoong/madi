import AppKit
import XCTest

/// 읽기 화면의 세 가지 — 표를 격자로, 인용을 막대로, 문서 메타데이터 카드를 글과 함께 굴리기.
///
/// 셋 다 실제 문서(세 열 한국어 표, 네 줄 인용, 항목 열두 개인 front matter)를 앱으로 열어 보고
/// 고쳤다. 여기서는 그때 본 것을 수치로 지킨다.
@MainActor
final class TableGridTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func editor(_ markdown: String, width: CGFloat = 720) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: width, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        window.contentView = editor
        window.orderBack(nil)
        windows.append(window)
        editor.markdown = markdown
        return editor
    }

    private func caret(_ editor: MarkdownEditorView, at location: Int) {
        editor.textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    private let table = """
    앞 문단

    | 기능 | 단축키 | 상태 |
    |:---|:---:|---:|
    | 원본 보기 | ⌘E | 있음 |
    | **번역** | `⌘⇧T` | [링크](https://example.com) |

    끝 문단

    """

    // MARK: 열 너비

    func testColumnsKeepTheirNaturalWidthWhenTheyFit() {
        XCTAssertEqual(TableGrid.columnWidths(natural: [50, 80, 120], available: 600, minimum: 40), [50, 80, 120])
    }

    /// 짧은 열은 제 폭으로 남고 긴 열들이 나머지를 나눈다 — 이름 열까지 꺾이지 않는다.
    func testNarrowColumnsKeepTheirWidthAndWideOnesShareTheRest() {
        let widths = TableGrid.columnWidths(natural: [120, 400, 300], available: 600, minimum: 40)
        XCTAssertEqual(widths[0], 120)
        XCTAssertLessThanOrEqual(widths.reduce(0, +), 600)
        XCTAssertGreaterThan(widths[1], widths[2], "더 긴 열이 더 넓다")
        XCTAssertGreaterThan(widths[2], 200, "남은 폭을 나눈 몫보다 좁아지지 않는다")
    }

    func testColumnsDoNotShrinkBelowTheMinimum() {
        XCTAssertEqual(TableGrid.columnWidths(natural: [500, 500, 500, 500], available: 200, minimum: 60),
                       [60, 60, 60, 60])
    }

    /// 긴 칸은 표를 넓히지 않고 **칸 안에서** 줄을 바꾼다.
    func testLongCellsWrapInsideTheirColumn() {
        let font = NSFont.systemFont(ofSize: 15)
        func cell(_ text: String) -> NSAttributedString { NSAttributedString(string: text, attributes: [.font: font]) }
        let long = String(repeating: "실행 ID, 파라미터, 지표, 입력 데이터의 메타데이터 ", count: 4)
        let grid = TableGrid(rows: [TableGrid.Row(cells: [cell("이름"), cell("설명")], isHeader: true),
                                    TableGrid.Row(cells: [cell("MLflow"), cell(long)], isHeader: false)],
                             columnCount: 2, lineHeight: 18, maxWidth: 400, minimumColumnWidth: 60)
        XCTAssertLessThanOrEqual(grid.size.width, 400)
        XCTAssertEqual(grid.rowHeights[0], 18 + TableGrid.padding.top + TableGrid.padding.bottom)
        XCTAssertGreaterThan(grid.rowHeights[1], grid.rowHeights[0] * 2, "긴 칸이 여러 줄이 됐다")
        XCTAssertEqual(grid.cellFrames()[1][1].minX, grid.columnWidths[0])
    }

    // MARK: 칸의 글

    /// 구분 행은 빠지고, 칸의 마커는 사라지고, 머리 행은 굵다. `\|`는 막대 글자다.
    func testCellsDropMarkersAndTheDelimiterRow() throws {
        let text = "| 이름 | 값 |\n| --- | --- |\n| **굵게** | a \\| b |\n" as NSString
        let lines = MarkdownSyntax().scanLines(in: text)
        let parsed = try XCTUnwrap(MarkdownTable.blocks(in: text, lines: lines).first)
        let grid = MarkdownStyler().tableGrid(for: parsed, text: text)
        XCTAssertEqual(grid.rows.map { $0.cells.map(\.string) }, [["이름", "값"], ["굵게", "a | b"]])
        XCTAssertEqual(grid.rows.map(\.isHeader), [true, false])
        let header = try XCTUnwrap(grid.rows[0].cells[0].attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: header).contains(.boldFontMask))
        let bold = try XCTUnwrap(grid.rows[1].cells[0].attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    }

    // MARK: 편집기

    /// 캐럿이 표 밖이면 격자다 — 원문 글자는 모두 숨고, 머리 행이 격자 높이를 갖고, 나머지 행은 접힌다.
    func testTableOutsideTheCaretIsDrawnAsAGrid() throws {
        let editor = editor(table)
        caret(editor, at: 0)
        XCTAssertEqual(editor.drawnTableCount, 1)

        let storage = try XCTUnwrap(editor.textView.textStorage)
        let text = storage.string as NSString
        let header = text.range(of: "| 기능 | 단축키 | 상태 |")
        let lastRow = text.range(of: "| **번역** | `⌘⇧T` | [링크](https://example.com) |")
        for location in header.location ..< NSMaxRange(lastRow) where text.character(at: location) != 0x0A {
            XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: location, effectiveRange: nil), "\(location)이 보인다")
        }
        let placement = try XCTUnwrap(editor.textView.imagePlacements.first { $0.lineRange == header })
        let headerStyle = try XCTUnwrap(storage.attribute(.paragraphStyle, at: header.location,
                                                          effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(headerStyle.minimumLineHeight, placement.size.height + 2, accuracy: 0.01)
        let rowStyle = try XCTUnwrap(storage.attribute(.paragraphStyle, at: lastRow.location,
                                                       effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertLessThan(rowStyle.maximumLineHeight, 1, "머리 행 아래는 접힌다")
        // 접힌 행에는 밑줄·바탕이 남지 않는다(실측: 링크 밑줄이 표 아래에 파란 점으로 남았다).
        for location in lastRow.location ..< NSMaxRange(lastRow) {
            XCTAssertNil(storage.attribute(.underlineStyle, at: location, effectiveRange: nil))
            XCTAssertNil(storage.attribute(.backgroundColor, at: location, effectiveRange: nil))
        }
        // 문서는 그대로다.
        XCTAssertEqual(editor.markdown, table)
    }

    /// 캐럿이 표에 들어오면 원문을 보이고, 나가면 다시 격자다.
    func testCaretInsideTheTableShowsTheSource() throws {
        let editor = editor(table)
        let text = editor.markdown as NSString
        let row = text.range(of: "| 원본 보기 |")
        caret(editor, at: row.location + 3)
        XCTAssertEqual(editor.drawnTableCount, 0)
        let storage = try XCTUnwrap(editor.textView.textStorage)
        XCTAssertNil(storage.attribute(.mdHiddenMarker, at: row.location, effectiveRange: nil), "막대가 보인다")
        XCTAssertFalse(editor.textView.imagePlacements.contains { $0.lineRange.location == text.range(of: "| 기능").location })

        caret(editor, at: text.length)
        XCTAssertEqual(editor.drawnTableCount, 1)
        XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: row.location, effectiveRange: nil))
    }

    /// 찾은 곳이 표 안이면 표를 펼친다 — 접힌 표에서는 찾은 글자가 보이지 않는다.
    func testSearchMatchInsideTheTableShowsTheSource() {
        let editor = editor(table)
        caret(editor, at: 0)
        XCTAssertEqual(editor.drawnTableCount, 1)
        XCTAssertEqual(editor.applySearch(query: "단축키").count, 1)
        XCTAssertEqual(editor.drawnTableCount, 0)
        editor.clearSearch()
        XCTAssertEqual(editor.drawnTableCount, 1)
    }

    /// 원본 보기와 프린트. 원본 보기는 날 글자, 프린트·PDF는 캐럿이 없으니 모든 표가 격자다.
    func testCodeViewShowsSourceAndOutputDrawsGrids() {
        let editor = editor(table)
        caret(editor, at: (editor.markdown as NSString).range(of: "| 원본").location)
        XCTAssertEqual(editor.drawnTableCount, 0)
        editor.isRenderingForOutput = true
        XCTAssertEqual(editor.drawnTableCount, 1, "내보내기에는 캐럿이 없다")
        editor.isRenderingForOutput = false
        editor.isCodeView = true
        XCTAssertEqual(editor.drawnTableCount, 0)
    }

    // MARK: 칸의 링크

    private final class LinkSpy: MarkdownEditorDelegate {
        var opened: [String] = []
        func markdownEditorDidChangeText(_ editor: MarkdownEditorView) {}
        func markdownEditor(_ editor: MarkdownEditorView, didClickLink url: String) { opened.append(url) }
    }

    /// 칸 안 글자의 링크만 찾는다 — 칸의 빈 자리나 링크가 아닌 글자는 nil이다.
    func testGridFindsTheLinkUnderAPoint() throws {
        let font = NSFont.systemFont(ofSize: 15)
        let link = NSMutableAttributedString(string: "열기 ", attributes: [.font: font])
        link.append(NSAttributedString(string: "링크", attributes: [.font: font, .mdLinkTarget: "https://example.com"]))
        let grid = TableGrid(rows: [TableGrid.Row(cells: [NSAttributedString(string: "이름", attributes: [.font: font]),
                                                          // 머리가 넓어 아래 칸의 글 뒤에 빈 자리가 남는다.
                                                          NSAttributedString(string: "주소와 그 설명을 적는 넓은 칸",
                                                                             attributes: [.font: font])],
                                                  isHeader: true),
                                    TableGrid.Row(cells: [NSAttributedString(string: "예", attributes: [.font: font]), link],
                                                  isHeader: false)],
                             columnCount: 2, lineHeight: 18, maxWidth: 600, minimumColumnWidth: 60)
        let cell = TableGrid.textFrame(in: grid.cellFrames()[1][1])
        let plain = NSAttributedString(string: "열기 ", attributes: [.font: font]).size().width
        let onLink = NSPoint(x: cell.minX + plain + 4, y: cell.midY)
        XCTAssertEqual(grid.link(at: onLink), "https://example.com")
        XCTAssertNil(grid.link(at: NSPoint(x: cell.minX + 3, y: cell.midY)), "링크가 아닌 글자")
        XCTAssertNil(grid.link(at: NSPoint(x: cell.maxX - 1, y: cell.midY)), "글자 뒤의 빈 자리")
        XCTAssertNil(grid.link(at: NSPoint(x: 5, y: 5)), "머리 칸")
    }

    /// 편집기에서: 격자 위의 ⌘클릭이 칸의 링크를 연다. 보조 키 없는 클릭은 받지 않는다(캐럿이 표로 간다).
    func testCommandClickOnAGridLinkOpensIt() throws {
        let editor = editor(table)
        let spy = LinkSpy()
        editor.editorDelegate = spy
        caret(editor, at: 0)
        let table = try XCTUnwrap(editor.textView.imagePlacements.first { $0.lineRange.length > 0 && $0.size.width > 100 })
        let frame = try XCTUnwrap(editor.textView.frame(of: table))
        // 링크는 셋째 열의 둘째 본문 행(머리 행 다음 다음)이다. 오른쪽 맞춤 열이라 칸의 오른쪽 끝에 있다.
        let grid = try XCTUnwrap(editor.drawnTableGrid(headerLine: table.lineRange))
        let cell = TableGrid.textFrame(in: grid.cellFrames()[2][2])
        let point = NSPoint(x: frame.minX + cell.maxX - 6, y: frame.minY + cell.midY)

        XCTAssertFalse(editor.handleDrawingClick(at: point, modifiers: []), "그냥 클릭은 텍스트 뷰에 맡긴다")
        XCTAssertTrue(spy.opened.isEmpty)
        XCTAssertTrue(editor.handleDrawingClick(at: point, modifiers: .command))
        XCTAssertEqual(spy.opened, ["https://example.com"])
        // 실제 누르기의 길(`mouseDown`)로도. 먹은 클릭이라 캐럿이 표로 가지 않고 표는 격자로 남는다.
        let textView = editor.textView
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: textView.convert(point, to: nil),
                                                     modifierFlags: .command, timestamp: 100,
                                                     windowNumber: textView.window?.windowNumber ?? 0, context: nil,
                                                     eventNumber: 41, clickCount: 1, pressure: 1))
        textView.mouseDown(with: press)
        XCTAssertEqual(spy.opened, ["https://example.com", "https://example.com"])
        XCTAssertEqual(editor.drawnTableCount, 1)
        // 링크가 없는 칸의 ⌘클릭은 먹지 않는다.
        let plain = TableGrid.textFrame(in: grid.cellFrames()[1][0])
        XCTAssertFalse(editor.handleDrawingClick(at: NSPoint(x: frame.minX + plain.minX + 4,
                                                             y: frame.minY + plain.midY), modifiers: .command))
    }

    /// 표 맞추기 설정을 꺼도 격자는 그린다 — 그 설정은 표를 고치는 동안의 원문에 닿는다.
    func testGridDoesNotDependOnTheAlignmentSetting() {
        let editor = editor(table)
        var preferences = EditorPreferences.standard
        preferences.alignTables = false
        editor.apply(preferences)
        caret(editor, at: 0)
        XCTAssertEqual(editor.drawnTableCount, 1)
    }
}

@MainActor
final class QuoteBarTests: XCTestCase {

    private func bars(_ markdown: String) -> [MarkdownStyler.QuoteBar] {
        let text = markdown as NSString
        let lines = MarkdownSyntax().scanLines(in: text)
        return MarkdownStyler.quoteBars(in: lines, alerts: GithubAlert.map(lines: lines, in: text))
    }

    private func lineRange(_ needle: String, in markdown: String) -> NSRange {
        let text = markdown as NSString
        let line = text.lineRange(for: text.range(of: needle))
        let end = text.substring(with: line).hasSuffix("\n") ? 1 : 0
        return NSRange(location: line.location, length: line.length - end)
    }

    /// 이어진 인용 줄에 막대 하나. 빈 인용 줄(`>`)은 덩이를 끊지 않고, 빈 줄은 끊는다.
    func testOneBarPerQuoteRun() {
        let markdown = "> 하나\n>\n> 둘\n\n> 셋\n"
        let first = lineRange("> 하나", in: markdown)
        let second = lineRange("> 둘", in: markdown)
        let third = lineRange("> 셋", in: markdown)
        XCTAssertEqual(bars(markdown), [
            .init(range: NSRange(location: first.location, length: NSMaxRange(second) - first.location), level: 1, alert: nil),
            .init(range: third, level: 1, alert: nil),
        ])
    }

    /// 겹친 인용은 겹마다 막대가 하나 더 있다.
    func testNestedQuotesGetABarPerLevel() {
        let markdown = "> 바깥\n>> 안쪽 하나\n>> 안쪽 둘\n> 다시 바깥\n"
        let outer = NSRange(location: 0, length: (markdown as NSString).length - 1)
        let inner1 = lineRange(">> 안쪽 하나", in: markdown)
        let inner2 = lineRange(">> 안쪽 둘", in: markdown)
        XCTAssertEqual(bars(markdown), [
            .init(range: outer, level: 1, alert: nil),
            .init(range: NSRange(location: inner1.location, length: NSMaxRange(inner2) - inner1.location),
                  level: 2, alert: nil),
        ])
    }

    /// 알림 상자의 바깥 막대는 그 종류를 안다 — 막대를 그 색으로 칠한다.
    func testAlertBarKnowsItsKind() {
        XCTAssertEqual(bars("> [!WARNING]\n> 조심\n").map(\.alert), [.warning])
        // 외관마다 갈리는 색은 매번 새로 만들어져 객체로는 같지 않다 — 푼 값을 비교한다.
        let theme = MarkdownTheme()
        func resolved(_ color: NSColor) -> NSColor? {
            var value: NSColor?
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { value = color.usingColorSpace(.sRGB) }
            return value
        }
        XCTAssertEqual(resolved(theme.quoteBarColor(for: .warning)), resolved(theme.alertColor(for: .warning)))
        XCTAssertEqual(resolved(theme.quoteBarColor(for: nil)), resolved(theme.quoteBar))
    }

    /// 막대는 글 칸 안, 글이 시작하기 전에 있다 — 겹마다 한 칸씩.
    func testBarsSitLeftOfTheText() {
        let one = DecoratedTextView.quoteBarFrame(level: 1, top: 10, bottom: 50, textLeft: 100)
        let two = DecoratedTextView.quoteBarFrame(level: 2, top: 10, bottom: 50, textLeft: 100)
        XCTAssertEqual(one.minX, 100 + MarkdownStyler.quoteBarInset)
        XCTAssertEqual(two.minX - one.minX, MarkdownStyler.quoteIndentStep)
        XCTAssertLessThan(one.maxX, 100 + MarkdownStyler.quoteIndent(depth: 1))
        XCTAssertLessThan(two.maxX, 100 + MarkdownStyler.quoteIndent(depth: 2))
        XCTAssertEqual(one.height, 40)
    }

    /// 편집기에서: `>`는 캐럿이 없는 줄에서 숨고 캐럿 줄에서는 보인다. 덩이 안의 줄 사이에는 문단
    /// 간격이 없고 끝 줄에만 있다. 두 겹은 한 칸 더 들어간다.
    func testEditorHidesMarkersAndTightensSpacing() throws {
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let markdown = "> 하나\n> 둘\n\n>> 안쪽\n\n끝\n"
        editor.markdown = markdown
        let text = markdown as NSString
        editor.textView.setSelectedRange(NSRange(location: text.length, length: 0))
        let storage = try XCTUnwrap(editor.textView.textStorage)
        XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: 0, effectiveRange: nil), "`>`가 숨는다")
        XCTAssertEqual(editor.textView.quoteBars.count, 3, "한 겹 덩이 하나 + 두 겹 덩이의 막대 둘")

        func style(_ needle: String) -> NSParagraphStyle? {
            storage.attribute(.paragraphStyle, at: text.range(of: needle).location, effectiveRange: nil) as? NSParagraphStyle
        }
        XCTAssertEqual(style("하나")?.paragraphSpacing, 0)
        XCTAssertGreaterThan(style("둘")?.paragraphSpacing ?? 0, 0, "덩이의 끝 줄")
        XCTAssertEqual(style("하나")?.headIndent, MarkdownStyler.quoteIndent(depth: 1))
        XCTAssertEqual(style("안쪽")?.headIndent, MarkdownStyler.quoteIndent(depth: 2))

        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertNil(storage.attribute(.mdHiddenMarker, at: 0, effectiveRange: nil), "캐럿 줄의 `>`는 보인다")
    }
}

/// 문서 메타데이터 카드가 글과 함께 굴러가는지(`MarkdownEditorView.headerView`).
@MainActor
final class EditorHeaderTests: XCTestCase {

    /// 높이가 정해진 머리.
    private final class FixedHeader: NSView {
        let height: CGFloat
        init(height: CGFloat) {
            self.height = height
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
    }

    private func editor() -> MarkdownEditorView {
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        editor.markdown = "# 제목\n\n본문\n"
        return editor
    }

    private func textHeight(_ editor: MarkdownEditorView) -> CGFloat {
        editor.textView.layoutManager?.ensureLayout(for: editor.textView.textContainer!)
        editor.textView.sizeToFit()
        return editor.textView.frame.height
    }

    /// 머리는 텍스트 뷰 안(글과 함께 굴러간다)에 있고, 글은 머리 높이 + 틈만큼 내려가며, 텍스트 뷰도
    /// 그만큼 길어진다 — 아래 여백은 그대로다.
    func testHeaderPushesTheTextDownInsideTheScrollingView() {
        let editor = editor()
        let baseOrigin = editor.textView.textContainerOrigin.y
        let baseHeight = textHeight(editor)

        let header = FixedHeader(height: 100)
        editor.headerView = header
        XCTAssertTrue(header.superview === editor.textView, "머리가 굴러가는 뷰 안에 있다")
        let space = 100 + MarkdownEditorView.headerGap
        XCTAssertEqual(editor.textView.textContainerOrigin.y, baseOrigin + space, accuracy: 0.5)
        XCTAssertEqual(textHeight(editor), baseHeight + space, accuracy: 0.5)
        XCTAssertEqual(header.frame.minY, editor.textView.baseInsets.height, accuracy: 0.5, "글이 시작하던 자리")
        XCTAssertLessThan(header.frame.maxY, editor.textView.textContainerOrigin.y, "머리와 글이 겹치지 않는다")
    }

    /// 숨긴 머리는 자리를 차지하지 않는다.
    func testHiddenHeaderTakesNoSpace() {
        let editor = editor()
        let baseOrigin = editor.textView.textContainerOrigin.y
        let header = FixedHeader(height: 80)
        editor.headerView = header
        header.isHidden = true
        editor.headerDidChange()
        XCTAssertEqual(editor.textView.textContainerOrigin.y, baseOrigin, accuracy: 0.5)
        header.isHidden = false
        editor.headerDidChange()
        XCTAssertEqual(editor.textView.textContainerOrigin.y, baseOrigin + 80 + MarkdownEditorView.headerGap,
                       accuracy: 0.5)
    }

    /// 프린트·PDF에는 머리를 넣지 않는다(전과 같다). 끝나면 돌아온다.
    func testOutputLeavesTheHeaderOut() {
        let editor = editor()
        let baseOrigin = editor.textView.textContainerOrigin.y
        let header = FixedHeader(height: 60)
        editor.headerView = header
        editor.isRenderingForOutput = true
        XCTAssertTrue(header.isHidden)
        XCTAssertEqual(editor.textView.textContainerOrigin.y, baseOrigin, accuracy: 0.5)
        editor.isRenderingForOutput = false
        XCTAssertFalse(header.isHidden)
        XCTAssertGreaterThan(editor.textView.textContainerOrigin.y, baseOrigin + 60)
    }

    /// 머리는 글 칸을 따라 가운데에 선다 — 창이 넓어 글을 가운데 두면 머리도 함께 옮긴다.
    func testHeaderFollowsTheTextColumn() {
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 1600, height: 400))
        editor.apply(.standard)
        let header = FixedHeader(height: 40)
        editor.headerView = header
        editor.setFrameSize(NSSize(width: 1600, height: 400))
        editor.textView.layoutSubtreeIfNeeded()
        let inset = editor.textView.textContainerInset.width
        XCTAssertGreaterThan(inset, 100, "전제: 글을 가운데 둔다")
        XCTAssertEqual(header.frame.minX, inset + editor.textView.textContainer!.lineFragmentPadding
                       - editor.textView.codeBlockPadding.left, accuracy: 0.5)
        XCTAssertEqual(header.frame.maxX, editor.textView.frame.width - header.frame.minX, accuracy: 0.5)
    }
}
