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

    /// 코드 블록의 범위(여는 펜스부터 닫는 펜스까지).
    ///
    /// 배경을 **그리는 쪽**이 읽는다. 글자마다 배경색을 주면 글자가 있는 만큼만
    /// 칠해져 오른쪽이 들쭉날쭉해지므로, 블록 하나를 둥근 사각형 하나로 그리도록
    /// 범위만 넘긴다. 코드 보기에서는 비어 있다(그때는 문서 전체가 날 글자다).
    public private(set) var codeBlockRanges: [NSRange] = []

    /// 설정에서 오는 켜고 끄기. 설정 화면의 각 항목이 **실제로 여기에 닿는다** —
    /// 아무 일도 하지 않는 설정은 사용자가 자기 잘못을 찾느라 시간을 버리게 만든다.
    public var highlightsCode = true
    public var alignsTables = true
    public var appliesSyntheticSlant = true

    /// 그림 하나가 놓일 자리. 그리는 쪽이 읽는다.
    public struct ImagePlacement: Equatable {
        public let lineRange: NSRange
        public let size: CGSize
        public let image: NSImage
    }

    public private(set) var imagePlacements: [ImagePlacement] = []

    /// 그림을 읽어 주는 곳. 편집기가 넣어 준다. 없으면 그림을 그리지 않는다.
    var imageStore: InlineImageStore?
    /// 상대 경로의 기준이 되는 문서 위치. 저장하지 않은 문서는 nil이다.
    public var documentURL: URL?
    /// 그림을 줄일 때 쓰는 글 넓이.
    public var contentWidth: Double = 700

    private let syntax = MarkdownSyntax()

    /// 이번 패스에서 쓸 링크 정의 표. **패스마다 한 번** 모은다 — 참조 링크의 주소는
    /// 그 줄에 없으므로 인라인 스캔이 이것을 받아야 하고, 줄마다 다시 모으면 문서
    /// 전체를 줄 수만큼 훑는다.
    private var definitions = LinkDefinitions.empty

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
    ///   - lines: 이 글의 줄 판정(`MarkdownSyntax.scanLines`). 부르는 쪽이 이미 갖고 있으면
    ///     넘긴다 — **지금 글의 것이어야 한다.** nil이면 여기서 훑는다.
    public func style(_ storage: NSTextStorage, caretLine: Int?, search: SearchState,
                      dirtyRange: NSRange? = nil, lines scanned: [LineToken]? = nil) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        var writeRange = dirtyRange.map { text.lineRange(for: NSIntersectionRange($0, full)) } ?? full
        let lines = scanned ?? syntax.scanLines(in: text)

        // 편집이 표에 닿으면 **표 전체**를 다시 칠한다. 한 칸을 넓히면 그 열의 너비가
        // 바뀌므로 다른 행의 글자 간격이 낡는다. 그 줄만 칠하면 표가 어긋난 채 남는다.
        if alignsTables, writeRange.length != full.length {
            writeRange = extendedOverTables(writeRange, in: text, limit: full, lines: lines)
        }

        storage.beginEditing()
        defer { storage.endEditing() }

        if codeView {
            // 코드 보기에서는 문서 전체가 날 글자다 — 블록도 그림도 그릴 근거가 없다.
            codeBlockRanges = []
            imagePlacements = []
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
            for line in lines {
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

        codeBlockRanges = codeBlocks(in: lines)
        definitions = LinkDefinitions(scanning: text, lines: lines)
        // `> [!NOTE]`로 시작하는 인용 덩이는 색이 있는 안내 상자다. 줄 하나만 보고는
        // 알 수 없어서(덩이의 첫 줄이 종류를 말한다) 미리 한 번 훑는다.
        let alerts = GithubAlert.map(lines: lines, in: text)
        for (index, line) in lines.enumerated() {
            guard line.range.length == 0 || NSIntersectionRange(line.range, writeRange).length > 0
                    || NSLocationInRange(line.range.location, writeRange) else { continue }
            apply(line, in: storage, text: text, caretLine: caretLine, alert: alerts[index])
        }

        placeImages(lines, in: storage, text: text, caretLine: caretLine, writeRange: writeRange)

        if highlightsCode {
            highlightCode(lines: lines, in: storage, text: text, writeRange: writeRange)
        }
        // 표 맞추기는 **마커 숨김이 끝난 뒤**여야 한다. 보이는 너비를 재려면
        // 어느 글자가 숨었는지 이미 정해져 있어야 하기 때문이다.
        if alignsTables {
            alignTables(lines, in: storage, text: text, writeRange: writeRange)
        }

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
                                    limit: NSRange, lines: [LineToken]) -> NSRange {
        let tables = MarkdownTable.blocks(in: text, lines: lines)
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

    /// 자기 줄을 통째로 차지하는 그림을 **문서를 고치지 않고** 보여 준다.
    ///
    /// 왜 이렇게 하는가(실측): 보통 글자에 `.attachment` 속성만 주면 줄 높이가 18pt에서
    /// 꼼짝도 하지 않는다. 첨부는 `U+FFFC`가 문서에 실제로 있어야 동작하고(그 경우 80pt),
    /// 글자를 끼워 넣으면 원문이 달라진다. `minimumLineHeight`는 글자를 하나도 더하지
    /// 않고 같은 80pt를 확보한다. 그래서 자리는 여기서 비우고 그림은 뷰가 그린다.
    ///
    /// 한계: **자기 줄을 통째로 차지하는 그림만** 보여 준다. 글 사이에 끼인 그림은
    /// 가로 자리를 잡는 일이 전혀 다른 문제라 원문을 그대로 둔다.
    /// 캐럿이 있는 줄도 원문을 보인다 — 이 편집기의 일관된 성질이다.
    private func placeImages(_ lines: [LineToken], in storage: NSTextStorage,
                             text: NSString, caretLine: Int?, writeRange: NSRange) {
        guard let imageStore else { return }
        var placements: [ImagePlacement] = []

        // 자리 목록은 **문서 전체**로 다시 만든다. 쓰기(숨김·줄 높이)만 `writeRange`로 좁힌다.
        //
        // 전에는 목록도 `writeRange` 안의 그림으로만 만들어, 부분 칠하기(타이핑 한 번)마다
        // 다른 줄의 그림이 목록에서 빠졌다 — 줄 높이는 그림 크기로 남은 채 빈 자리만
        // 그려졌다. 목록을 지난 패스에서 이어 받을 수는 없다: 글이 밀리면 옛 자리는 낡는다.
        // 줄 전체가 그림인 줄만 `![`로 시작하므로 그 줄만 인라인 스캔한다 — 문서 전체를
        // 훑어도 싸다.
        for line in lines {
            guard line.kind == .paragraph, line.contentRange.length > 0,
                  line.lineNumber != caretLine,
                  startsWithImageMarker(line.contentRange, in: text) else { continue }
            let writes = NSIntersectionRange(line.range, writeRange).length > 0

            // 줄 전체가 그림 하나여야 한다.
            let tokens = syntax.scanInline(in: text, range: line.contentRange,
                                           definitions: definitions)
            guard tokens.count == 1, case let .image(raw) = tokens[0].kind else { continue }
            let token = tokens[0]
            let trimmed = trimmedRange(line.contentRange, in: text)
            guard NSEqualRanges(token.range, trimmed) else { continue }

            // 로컬이 먼저다. 못 풀면 원격을 묻는데, 저장소가 꺼져 있으면 nil을
            // 돌려주므로 **게이트는 한 곳**(InlineImageStore.loadsRemote)이다.
            // 원격은 아직 안 받았으면 nil이고, 도착하면 다시 칠하면서 자리가 생긴다.
            let resolved: NSImage?
            if let url = ImageReference.localURL(for: raw, relativeTo: documentURL) {
                resolved = imageStore.image(at: url)
            } else if let url = ImageReference.remoteURL(for: raw) {
                resolved = imageStore.remoteImage(at: url)
            } else {
                resolved = nil
            }
            guard let image = resolved else { continue }
            // AppKit의 CGSize를 Core의 Foundation 전용 타입으로 바꿔 넘긴다.
            let pixels = ImageReference.Size(width: Double(image.size.width),
                                             height: Double(image.size.height))
            let display = ImageReference.displaySize(for: pixels, maxWidth: contentWidth)
            let size = CGSize(width: display.width, height: display.height)
            guard size.height > 0 else { continue }

            placements.append(ImagePlacement(lineRange: line.range, size: size, image: image))
            guard writes else { continue }

            // 글자를 모두 숨긴다 — 마커만이 아니라 `alt`와 경로까지. 그림이 보이는
            // 자리에 원문이 함께 보일 이유가 없다.
            hide(token.range, in: storage)

            let style = NSMutableParagraphStyle()
            style.lineSpacing = theme.lineSpacing
            style.paragraphSpacing = theme.paragraphSpacing
            style.minimumLineHeight = size.height + 4
            style.maximumLineHeight = size.height + 4
            storage.addAttribute(.paragraphStyle, value: style, range: line.range)
        }
        imagePlacements = placements
    }

    /// 앞의 스페이스·탭 뒤가 `![`인가. 줄 전체가 그림이려면 다듬은 내용이 `![`로 시작해야 한다.
    private func startsWithImageMarker(_ range: NSRange, in text: NSString) -> Bool {
        var index = range.location
        let end = NSMaxRange(range)
        while index < end, text.character(at: index) == 0x20 || text.character(at: index) == 0x09 {
            index += 1
        }
        return index + 1 < end && text.character(at: index) == 0x21 && text.character(at: index + 1) == 0x5B
    }

    /// 앞뒤 공백을 뺀 범위.
    private func trimmedRange(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        func isSpace(_ index: Int) -> Bool {
            let scalar = text.character(at: index)
            return scalar == 32 || scalar == 9
        }
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// 이어진 코드 줄을 블록으로 묶는다. **펜스 줄까지 넣는다** — 펜스는 마커라
    /// 폭 0으로 접히지만 줄 높이는 차지하므로, 배경에 넣으면 위아래 여백이 된다.
    private func codeBlocks(in lines: [LineToken]) -> [NSRange] {
        var blocks: [NSRange] = []
        var start: Int?
        var end = 0
        for line in lines {
            if line.kind == .codeFence || line.kind == .codeBody {
                if start == nil { start = line.range.location }
                end = NSMaxRange(line.range)
            } else if let begin = start {
                blocks.append(NSRange(location: begin, length: max(0, end - begin)))
                start = nil
            }
        }
        if let begin = start {
            blocks.append(NSRange(location: begin, length: max(0, end - begin)))
        }
        return blocks
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

    private func apply(_ line: LineToken, in storage: NSTextStorage, text: NSString,
                       caretLine: Int?, alert: GithubAlert? = nil) {
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
            if let alert {
                // 알림 상자. 글은 본문 색으로 읽히게 두고 **막대와 표식만** 종류 색으로
                // 칠한다 — 글 전체를 색칠하면 읽기 어려워진다.
                storage.addAttributes([.foregroundColor: theme.text], range: line.range)
                if GithubAlert.marker(inQuoteContent: line.contentRange.length > 0
                                        ? text.substring(with: line.contentRange) : "") != nil {
                    storage.addAttributes([
                        .foregroundColor: theme.alertColor(for: alert),
                        .font: NSFont.systemFont(ofSize: theme.bodyPointSize, weight: .semibold),
                    ], range: line.contentRange)
                }
            } else {
                storage.addAttributes([.foregroundColor: theme.quote], range: line.range)
            }
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)

        case .listItem:
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)

        case .codeFence:
            // 펜스 줄에 남아 보이는 것은 **언어 이름**이다(백틱은 마커로 숨는다).
            // 코드 본문과 같은 색으로 두면 코드의 첫 줄처럼 보이므로 흐린 라벨로 둔다.
            storage.addAttributes([
                .font: theme.monoFont,
                .foregroundColor: theme.dim,
            ], range: line.range)

        case .codeBody:
            // 배경은 여기서 칠하지 않는다. 글자마다 칠하면 글자가 있는 만큼만
            // 칠해져 오른쪽이 들쭉날쭉해진다. 블록 하나를 둥근 사각형 하나로
            // 그리는 일은 텍스트 뷰가 `codeBlockRanges`를 읽어서 한다.
            storage.addAttributes([
                .font: theme.monoFont,
                .foregroundColor: theme.codeText,
            ], range: line.range)

        case .setextUnderline:
            // 제목의 밑줄. 제목 글꼴로 그리면 숨겨도 그 줄만큼 큰 빈 자리가 남으므로
            // 본문 크기의 흐린 표시로 둔다(마커라서 캐럿이 없는 줄에서는 숨는다).
            storage.addAttributes([
                .font: theme.bodyFont,
                .foregroundColor: theme.dim,
            ], range: line.range)

        case .linkDefinition:
            // 줄 전체를 흐리게 깐 뒤 주소에만 링크 색을 준다. 주소 뒤의 제목
            // (`"제목"`)도 렌더러가 삼키는 metadata이므로 본문 색으로 두면 그 줄에서
            // 유일하게 평범한 글처럼 튄다 — 그렇다고 숨기지는 않는다(친 글자다).
            storage.addAttributes([
                .font: theme.bodyFont,
                .foregroundColor: theme.dim,
            ], range: line.range)
            // 라벨은 마커로 접히고 주소만 남는다. 주소에 링크 색과 대상을 주어
            // ⌘클릭으로 열 수 있게 한다 — 정의 줄이 바로 그 주소를 위한 줄이다.
            if line.contentRange.length > 0, NSMaxRange(line.contentRange) <= text.length {
                storage.addAttributes([
                    .foregroundColor: theme.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .mdLinkTarget: text.substring(with: line.contentRange),
                ], range: line.contentRange)
            }

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

            // 알림 상자의 `>` 막대는 종류 색으로 칠한다 — 상자의 종류를 한눈에
            // 가리는 것이 그 색이다. 그래서 흐린 색으로 덮지 않는다.
            storage.addAttribute(.foregroundColor,
                                 value: alert.map(theme.alertColor(for:)) ?? theme.dim,
                                 range: marker)
            // A list bullet and a quote bar are part of the rendered look, so
            // they stay; only the markup that a renderer would consume is hidden.
            if !onCaretLine, shouldHideMarker(for: line.kind) {
                hide(marker, in: storage)
            }
        }
    }

    private func shouldHideMarker(for kind: BlockKind) -> Bool {
        switch kind {
        case .heading, .codeFence, .setextUnderline: return true
        // 정의 줄의 라벨(`[참조]: `)은 렌더러가 삼키는 markup이라 접는다. 주소는
        // 마커가 아니므로 남는다 — 줄 전체가 사라지면 사용자가 친 글자가 없어진다.
        case .linkDefinition: return true
        case .quote, .listItem, .thematicBreak, .tableRow, .tableDelimiter,
             .codeBody, .paragraph, .blank: return false
        }
    }

    // MARK: Inlines

    private func styleInline(in storage: NSTextStorage, text: NSString,
                             content: NSRange, onCaretLine: Bool) {
        guard content.location != NSNotFound, content.length > 0,
              NSMaxRange(content) <= text.length else { return }

        for token in syntax.scanInline(in: text, range: content, definitions: definitions) {
            let existing = storage.attribute(.font, at: token.range.location,
                                             effectiveRange: nil) as? NSFont ?? theme.bodyFont

            switch token.kind {
            case .strong:
                storage.addAttribute(.font, value: bold(existing), range: token.contentRange)
            case .emphasis:
                storage.addAttribute(.font, value: italic(existing), range: token.contentRange)
                // 한글·일본어·중국어에는 기울임꼴이 없어 글꼴을 바꿔도 그림이 한 픽셀도
                // 달라지지 않는다(실측). 그 글자에만 강제 기울임을 더한다 — 모든 글자에
                // 주면 진짜 기울임꼴을 받는 영문이 두 번 기울어 지나치게 눕는다.
                for slantRange in (appliesSyntheticSlant
                                   ? SyntheticSlant.ranges(in: text, range: token.contentRange)
                                   : []) {
                    storage.addAttribute(.obliqueness,
                                         value: SyntheticSlant.obliqueness,
                                         range: slantRange)
                }
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
