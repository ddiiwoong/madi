import AppKit

/// Custom attribute marking syntax punctuation the layout manager should not
/// draw. Hiding happens at glyph generation, so the characters stay in the
/// document and editing still sees them — they merely take no space.
extension NSAttributedString.Key {
    static let mdHiddenMarker = NSAttributedString.Key("mdHiddenMarker")
    static let mdLinkTarget = NSAttributedString.Key("mdLinkTarget")
}

/// Applies rendered-looking attributes to the markdown source in place.
///
/// This is what makes "the viewer is editable" true: there is one text storage
/// holding markdown, and it is drawn as a formatted document. Syntax markers on
/// the line the caret sits on stay visible so the structure can be edited; on
/// every other line they are hidden.
@MainActor
public final class MarkdownStyler {

    public var theme = MarkdownTheme()
    /// 코드 보기 — render the raw markdown instead of the formatted document:
    /// monospace throughout, every marker visible. The text storage is the same
    /// either way, so this is purely how it is drawn.
    public var codeView = false
    private let syntax = MarkdownSyntax()

    public init() {}

    public struct SearchState {
        public var ranges: [NSRange] = []
        public var currentIndex: Int?
        public init() {}
    }

    /// - Parameters:
    ///   - caretLine: 1-based line the insertion point is on, or nil when the
    ///     view has no selection. Markers on that line are left visible.
    ///   - dirtyRange: restrict attribute writes to the lines intersecting this
    ///     range. Lines are still SCANNED from the top — whether a line sits
    ///     inside a fenced code block depends on every line before it, so a
    ///     window-only scan would mis-classify code as prose. Scanning is cheap;
    ///     writing attributes and invalidating layout is what costs.
    public func style(_ storage: NSTextStorage, caretLine: Int?, search: SearchState,
                      dirtyRange: NSRange? = nil) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        var writeRange = dirtyRange.map { text.lineRange(for: NSIntersectionRange($0, full)) } ?? full

        // 편집이 표에 닿으면 **표 전체**를 다시 칠한다. 한 칸을 넓히면 그 열의 너비가
        // 바뀌므로 다른 행의 글자 간격이 낡는다. 그 줄만 칠하면 표가 어긋난 채 남는다.
        if writeRange.length != full.length {
            writeRange = extendedOverTables(writeRange, in: text, limit: full)
        }

        storage.beginEditing()
        defer { storage.endEditing() }

        if codeView {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = theme.lineSpacing * 0.5
            storage.setAttributes([
                .font: theme.monoFont,
                .foregroundColor: theme.text,
                .paragraphStyle: style,
            ], range: writeRange)
            // `setAttributes` above already replaced every attribute in the
            // range, hiding included; this makes that reliance explicit so a
            // later switch to `addAttributes` cannot leave markers invisible.
            storage.removeAttribute(.mdHiddenMarker, range: writeRange)
            for line in syntax.scanLines(in: text) {
                guard NSIntersectionRange(line.range, writeRange).length > 0 else { continue }
                for marker in line.markerRanges where marker.length > 0 {
                    storage.addAttribute(.foregroundColor, value: theme.dim, range: marker)
                }
            }
            for (index, range) in search.ranges.enumerated()
            where NSMaxRange(range) <= text.length && NSIntersectionRange(range, writeRange).length > 0 {
                storage.addAttribute(.backgroundColor,
                                     value: index == search.currentIndex
                                        ? theme.currentSearchHighlight : theme.searchHighlight,
                                     range: range)
            }
            return
        }

        storage.setAttributes([
            .font: theme.bodyFont,
            .foregroundColor: theme.text,
            .paragraphStyle: paragraphStyle(for: .paragraph),
        ], range: writeRange)

        let lines = syntax.scanLines(in: text)
        for line in lines {
            guard line.range.length == 0 || NSIntersectionRange(line.range, writeRange).length > 0
                    || NSLocationInRange(line.range.location, writeRange) else { continue }
            apply(line, in: storage, text: text, caretLine: caretLine)
        }

        highlightCode(lines: lines, in: storage, text: text, writeRange: writeRange)
        // 표 맞추기는 **마커 숨김이 끝난 뒤**여야 한다. 보이는 너비를 재려면
        // 어느 글자가 숨었는지 이미 정해져 있어야 하기 때문이다.
        alignTables(lines, in: storage, text: text, writeRange: writeRange)

        for (index, range) in search.ranges.enumerated()
        where NSMaxRange(range) <= text.length && NSIntersectionRange(range, writeRange).length > 0 {
            let isCurrent = index == search.currentIndex
            storage.addAttribute(.backgroundColor,
                                 value: isCurrent ? theme.currentSearchHighlight : theme.searchHighlight,
                                 range: range)
        }
    }

    // MARK: 코드 구문 강조

    /// 코드 본문 줄들을 **블록 단위로 묶어** 한 번에 강조한다.
    ///
    /// 줄 하나씩 넘기면 안 된다 — `/* */`나 `"""`처럼 줄을 넘나드는 구문은 블록 전체를
    /// 봐야 어디서 끝나는지 알 수 있다. 그래서 더럽혀진 범위가 블록의 일부뿐이어도
    /// 블록은 통째로 훑고, **쓰는 것만** 그 범위로 좁힌다(비용은 쓰기와 레이아웃 무효화에
    /// 있고 훑기는 싸다 — 줄 스캔이 이미 같은 이유로 늘 전체를 본다).
    private func highlightCode(lines: [LineToken], in storage: NSTextStorage,
                               text: NSString, writeRange: NSRange) {
        var run: [LineToken] = []

        func flush() {
            defer { run = [] }
            guard let first = run.first, let last = run.last,
                  let language = CodeLanguage.named(first.language) else { return }
            let start = first.range.location
            let end = NSMaxRange(last.range)
            guard end > start, NSMaxRange(NSRange(location: start, length: end - start)) <= text.length
            else { return }
            let blockRange = NSRange(location: start, length: end - start)
            guard NSIntersectionRange(blockRange, writeRange).length > 0 else { return }

            for span in CodeHighlighter.spans(in: text.substring(with: blockRange), language: language) {
                let absolute = NSRange(location: blockRange.location + span.range.location,
                                       length: span.range.length)
                guard NSMaxRange(absolute) <= text.length,
                      NSIntersectionRange(absolute, writeRange).length > 0 else { continue }
                storage.addAttribute(.foregroundColor,
                                     value: theme.codeColor(for: span.role), range: absolute)
            }
        }

        for line in lines {
            if line.kind == .codeBody { run.append(line) } else { flush() }
        }
        flush()
    }

    /// `range`가 걸친 표들을 통째로 감싸도록 넓힌다.
    ///
    /// 표 하나가 통째로 들어와야 열 너비를 다시 잴 수 있다. 줄 스캔은 늘 전체를 하므로
    /// 여기서 드는 비용은 넓힌 만큼의 **쓰기**뿐이고, 표는 보통 몇 줄이다.
    private func extendedOverTables(_ range: NSRange, in text: NSString,
                                    limit: NSRange) -> NSRange {
        let tables = MarkdownTable.blocks(in: text, lines: syntax.scanLines(in: text))
        guard !tables.isEmpty else { return range }

        var start = range.location
        var end = NSMaxRange(range)
        for table in tables {
            guard let first = table.rows.first, let last = table.rows.last else { continue }
            let block = NSRange(location: first.range.location,
                                length: max(0, NSMaxRange(last.range) - first.range.location))
            guard NSIntersectionRange(block, range).length > 0
                    || NSLocationInRange(block.location, range) else { continue }
            start = min(start, block.location)
            end = max(end, NSMaxRange(block))
        }
        let grown = NSRange(location: start, length: max(0, end - start))
        return NSIntersectionRange(text.lineRange(for: NSIntersectionRange(grown, limit)), limit)
    }

    // MARK: 표 열 맞추기

    /// 표의 칸을 **글자 간격으로** 늘려 막대가 같은 자리에 오게 한다.
    ///
    /// 왜 이렇게 하는가: 흔한 방법은 칸에 공백을 끼워 넣는 것인데, 그러면 저장할 때
    /// **원문이 달라진다.** 이 앱은 편집기이고 문서를 바이트 그대로 지키는 것이 전제다.
    /// `.kern`은 글자의 나아감만 늘리므로 글자를 하나도 더하지 않고 같은 효과를 낸다.
    ///
    /// 한계를 알고 쓴다: 캐럿이 있는 줄은 마커가 보이므로 그 줄의 칸이 열 너비보다
    /// 넓어질 수 있다. 그때는 늘리지 않고(음수 간격은 글자를 겹치게 한다) 그 줄만
    /// 오른쪽으로 밀린 채 둔다. 편집 중인 줄이 원문 그대로 보이는 것은 이 편집기의
    /// 일관된 성질이다.
    private func alignTables(_ lines: [LineToken], in storage: NSTextStorage,
                             text: NSString, writeRange: NSRange) {
        for table in MarkdownTable.blocks(in: text, lines: lines) {
            guard table.columnCount > 0 else { continue }
            let blockRange = tableRange(table)
            guard NSIntersectionRange(blockRange, writeRange).length > 0 else { continue }

            // 1. 열 너비 — 각 열에서 가장 넓은 칸을 따른다.
            //    너비는 **먼저 전부 재고** 나중에 간격을 준다. 재면서 주면 앞 칸에
            //    준 간격이 뒤 칸의 측정에 섞여 들어간다.
            var measured: [Int: [Int: CGFloat]] = [:]   // [줄번호: [열: 너비]]
            var widths = [CGFloat](repeating: 0, count: table.columnCount)
            for row in table.rows {
                var perColumn: [Int: CGFloat] = [:]
                for (column, cell) in row.cells.enumerated() where column < widths.count {
                    let value = visibleWidth(of: cell, in: storage)
                    perColumn[column] = value
                    widths[column] = max(widths[column], value)
                }
                measured[row.lineNumber] = perColumn
            }

            // 2. 칸마다 부족한 만큼을 앞/뒤에 나눠 준다.
            for row in table.rows {
                for (column, cell) in row.cells.enumerated() where column < widths.count {
                    let own = measured[row.lineNumber]?[column] ?? 0
                    let pad = widths[column] - own
                    guard pad > 0.5 else { continue }

                    let (before, after): (CGFloat, CGFloat)
                    switch table.alignment(forColumn: column) {
                    case .right: (before, after) = (pad, 0)
                    case .center: (before, after) = (pad / 2, pad / 2)
                    case .left, .none: (before, after) = (0, pad)
                    }

                    // 뒤쪽 간격은 칸의 **마지막 글자**에 준다. 빈 칸은 줄 글자가
                    // 없으니 앞쪽 몫에 합쳐 앞의 막대가 떠안는다.
                    if after > 0, cell.length > 0 {
                        addKern(after, at: cell.location + cell.length - 1,
                                in: storage, text: text, writeRange: writeRange)
                    }
                    let leading = before + (cell.length == 0 ? after : 0)
                    if leading > 0, let separator = separator(before: cell, in: row) {
                        addKern(leading, at: separator.location,
                                in: storage, text: text, writeRange: writeRange)
                    }
                }
            }
        }
    }

    private func tableRange(_ table: MarkdownTable) -> NSRange {
        guard let first = table.rows.first, let last = table.rows.last else { return NSRange() }
        let start = first.range.location
        return NSRange(location: start, length: max(0, NSMaxRange(last.range) - start))
    }

    /// 칸 바로 앞의 막대. 없으면(맨 앞 막대가 없는 표) nil.
    private func separator(before cell: NSRange, in row: MarkdownTable.Row) -> NSRange? {
        row.separators.last { NSMaxRange($0) <= cell.location }
    }

    /// 화면에 **보이는** 너비.
    ///
    /// 글꼴을 가정하지 않는다. 전에는 본문 글꼴로 쟀는데 표는 고정폭으로 그려져서
    /// 측정과 그리기가 달랐고, 그래서 열이 어긋났다. 이제 저장소에 실제로 들어 있는
    /// 속성을 그대로 쓴 문자열을 만들어 잰다 — 고정폭이든 굵은꼴이든 맞는다.
    ///
    /// 숨긴 마커는 빼고 잰다. 자리를 차지하지 않으므로 넣으면 실제보다 넓게 나온다.
    /// 이미 준 글자 간격도 뺀다 — 넣으면 다시 칠할 때마다 간격이 쌓인다.
    private func visibleWidth(of cell: NSRange, in storage: NSTextStorage) -> CGFloat {
        guard cell.length > 0, NSMaxRange(cell) <= storage.length else { return 0 }
        let visible = NSMutableAttributedString()
        storage.enumerateAttributes(in: cell, options: []) { attributes, range, _ in
            guard attributes[.mdHiddenMarker] == nil else { return }
            let piece = NSMutableAttributedString(attributedString:
                storage.attributedSubstring(from: range))
            piece.removeAttribute(.kern, range: NSRange(location: 0, length: piece.length))
            visible.append(piece)
        }
        guard visible.length > 0 else { return 0 }
        return visible.size().width
    }

    private func addKern(_ amount: CGFloat, at location: Int, in storage: NSTextStorage,
                         text: NSString, writeRange: NSRange) {
        let range = NSRange(location: location, length: 1)
        guard NSMaxRange(range) <= text.length,
              NSIntersectionRange(range, writeRange).length > 0 else { return }
        storage.addAttribute(.kern, value: amount, range: range)
    }

    // MARK: Blocks

    private func apply(_ line: LineToken, in storage: NSTextStorage, text: NSString, caretLine: Int?) {
        guard line.range.length > 0 || line.kind == .blank else { return }
        let onCaretLine = caretLine == line.lineNumber
        let style = paragraphStyle(for: line.kind)
        if line.range.length > 0 {
            storage.addAttribute(.paragraphStyle, value: style, range: line.range)
        }

        switch line.kind {
        case let .heading(level):
            storage.addAttribute(.font, value: theme.headingFont(level: level), range: line.range)
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)

        case .quote:
            storage.addAttributes([.foregroundColor: theme.quote], range: line.range)
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)

        case .listItem:
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)

        case .codeFence, .codeBody:
            storage.addAttributes([
                .font: theme.monoFont,
                .foregroundColor: theme.codeText,
                .backgroundColor: theme.codeBackground,
            ], range: line.range)

        case .thematicBreak:
            storage.addAttributes([.foregroundColor: theme.rule], range: line.range)

        case .tableRow, .tableDelimiter:
            // 고정폭을 바탕으로 깐다. 열 맞추기가 글자 간격으로 이뤄지므로 글꼴이
            // 꼭 고정폭이어야 하는 것은 아니지만, 격자는 고정폭이 읽기 쉽다.
            storage.addAttribute(.font, value: theme.monoFont, range: line.range)
            // 칸 안의 인라인 마크업도 그린다. 전에는 이 줄만 건너뛰어서 표 안의
            // `**굵게**`와 `` `코드` ``가 마커째 날 글자로 보였다.
            styleInline(in: storage, text: text, content: line.contentRange,
                        onCaretLine: onCaretLine)

        case .paragraph:
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)

        case .blank:
            break
        }

        // Markers: dimmed on the caret's line, hidden everywhere else.
        for marker in line.markerRanges where marker.length > 0 && NSMaxRange(marker) <= text.length {
            if case .codeFence = line.kind {
                storage.addAttribute(.foregroundColor, value: theme.dim, range: marker)
                if !onCaretLine { hide(marker, in: storage) }
                continue
            }
            if case .thematicBreak = line.kind { continue }
            if case .tableDelimiter = line.kind { continue }

            storage.addAttribute(.foregroundColor, value: theme.dim, range: marker)
            // A list bullet and a quote bar are part of the rendered look, so
            // they stay; only the markup that a renderer would consume is hidden.
            if !onCaretLine, shouldHideMarker(for: line.kind) {
                hide(marker, in: storage)
            }
        }
    }

    private func shouldHideMarker(for kind: BlockKind) -> Bool {
        switch kind {
        case .heading, .codeFence: return true
        case .quote, .listItem, .thematicBreak, .tableRow, .tableDelimiter,
             .codeBody, .paragraph, .blank: return false
        }
    }

    // MARK: Inlines

    private func styleInline(in storage: NSTextStorage, text: NSString,
                             content: NSRange, onCaretLine: Bool) {
        guard content.location != NSNotFound, content.length > 0,
              NSMaxRange(content) <= text.length else { return }

        for token in syntax.scanInline(in: text, range: content) {
            let existing = storage.attribute(.font, at: token.range.location,
                                             effectiveRange: nil) as? NSFont ?? theme.bodyFont

            switch token.kind {
            case .strong:
                storage.addAttribute(.font, value: bold(existing), range: token.contentRange)
            case .emphasis:
                storage.addAttribute(.font, value: italic(existing), range: token.contentRange)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle,
                                     value: NSUnderlineStyle.single.rawValue, range: token.contentRange)
            case .code:
                storage.addAttributes([
                    .font: theme.monoFont,
                    .backgroundColor: theme.codeBackground,
                ], range: token.contentRange)
            case let .link(url), let .image(url), let .autolink(url):
                storage.addAttributes([
                    .foregroundColor: theme.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .mdLinkTarget: url,
                ], range: token.contentRange)
            }

            for marker in token.markerRanges where marker.length > 0 {
                storage.addAttribute(.foregroundColor, value: theme.dim, range: marker)
                if !onCaretLine { hide(marker, in: storage) }
            }
        }
    }

    private func hide(_ range: NSRange, in storage: NSTextStorage) {
        storage.addAttribute(.mdHiddenMarker, value: true, range: range)
    }

    private func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    // MARK: Paragraph styles

    private func paragraphStyle(for kind: BlockKind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        style.paragraphSpacing = theme.paragraphSpacing

        switch kind {
        case .heading:
            style.paragraphSpacingBefore = theme.bodyPointSize * 0.9
            style.paragraphSpacing = theme.bodyPointSize * 0.3
        case .quote:
            style.firstLineHeadIndent = 18
            style.headIndent = 18
        case .listItem:
            style.firstLineHeadIndent = 4
            style.headIndent = 22
            style.paragraphSpacing = theme.bodyPointSize * 0.18
        case .codeBody, .codeFence:
            style.lineSpacing = theme.lineSpacing * 0.5
            style.paragraphSpacing = 0
            style.firstLineHeadIndent = 10
            style.headIndent = 10
        default:
            break
        }
        return style
    }
}
