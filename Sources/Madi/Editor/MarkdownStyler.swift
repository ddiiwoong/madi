import AppKit

/// Custom attribute marking syntax punctuation the layout manager should not
/// draw. Hiding happens at glyph generation, so the characters stay in the
/// document and editing still sees them — they merely take no space.
extension NSAttributedString.Key {
    static let mdHiddenMarker = NSAttributedString.Key("mdHiddenMarker")
    static let mdLinkTarget = NSAttributedString.Key("mdLinkTarget")
    /// 체크박스 `[ ]`의 세 글자. 값은 여는 대괄호의 위치(`Int`)다 — 누르면 편집기가 그 칸을
    /// 뒤집는다(`MarkdownEditorView.handleClick`).
    static let mdTaskBox = NSAttributedString.Key("mdTaskBox")
    /// 각주의 오갈 곳. `definition:<라벨>`(참조 → 정의) 또는 `reference:<라벨>`(정의 → 첫 참조).
    /// ⌘클릭하면 편집기가 그리로 캐럿을 옮긴다.
    static let mdFootnoteJump = NSAttributedString.Key("mdFootnoteJump")
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
        /// 글 넓이의 가운데에 놓는가. 수식 블록이 그렇다(TeX·KaTeX의 표시 수식 관례). 그림과
        /// 다이어그램은 글처럼 왼쪽에 붙는다.
        public var centered = false

        public init(lineRange: NSRange, size: CGSize, image: NSImage, centered: Bool = false) {
            self.lineRange = lineRange
            self.size = size
            self.image = image
            self.centered = centered
        }
    }

    public private(set) var imagePlacements: [ImagePlacement] = []

    /// 그림을 읽어 주는 곳. 편집기가 넣어 준다. 없으면 그림을 그리지 않는다.
    var imageStore: InlineImageStore?

    /// Mermaid·수식 블록을 그려 주는 곳(`DiagramRenderer`). 없으면 원문으로 둔다 —
    /// 블록 편집기와 대부분의 테스트가 그렇다.
    var renderedBlockImages: RenderedBlockImages?
    /// 지금 화면이 다크인가. Mermaid 테마와 수식 글자 색을 고른다. 편집기가 칠하기 전에 넣는다.
    public var isDarkAppearance = false
    /// 이번 패스에서 찾은 다이어그램·수식 블록. 편집기가 "그림이 도착하면 다시 칠할 것이
    /// 있는가"를 이것으로 안다.
    public private(set) var renderedBlocks: [RenderedBlock] = []
    /// 상대 경로의 기준이 되는 문서 위치. 저장하지 않은 문서는 nil이다.
    public var documentURL: URL?

    /// 상자로 그릴 체크박스 하나 — 캐럿이 없는 줄의 `[ ]` · `[x]`.
    public struct TaskBox: Equatable {
        /// `[ ]` 세 글자.
        public let range: NSRange
        public let checked: Bool
    }

    /// 체크박스를 **상자로 그릴지.** 켜면 캐럿이 없는 줄의 `[ ]` 세 글자를 투명하게 하고 그 자리를
    /// `taskBoxes`로 알린다 — 텍스트 뷰가 거기에 상자를 그린다(`DecoratedTextView`). 글자는 문서에
    /// 그대로 있어 폭도 클릭도 같다. 기본 편집기만 켠다: 블록 편집기는 상자를 그리는 쪽을 잇지
    /// 않았으므로, 켜면 글자만 사라진다.
    public var drawsTaskBoxes = false
    /// 이번 패스에서 상자로 그릴 체크박스(위치 순).
    public private(set) var taskBoxes: [TaskBox] = []

    /// 캐럿이 없는 표를 **격자로 그릴지**(`TableGrid`). 기본 편집기만 켠다 — 블록 편집기는 그림을
    /// 그리는 쪽을 잇지 않았고, 표를 따로 다룬다.
    public var drawsTables = false
    /// 이번 패스에서 격자로 그린 표 — 머리 행(격자 그림이 놓인 줄)과 그 격자. 편집기가 ⌘클릭을 받을 때
    /// 점 아래의 링크를 이것으로 찾는다.
    public struct DrawnTable {
        public let headerLine: NSRange
        let grid: TableGrid
    }

    public private(set) var drawnTables: [DrawnTable] = []
    /// 이번 패스에서 격자로 그린 표의 수. 테스트가 쓴다.
    public var drawnTableCount: Int { drawnTables.count }
    /// 격자로 그려 원문을 접은 표들. 찾기 표시를 거기에 칠하지 않는다 — 숨긴 글자의 바탕은 격자 밖에
    /// 엉뚱하게 남는다. 지금 찾은 곳이 든 표는 원문으로 펼쳐지므로 보인다.
    private var foldedTableRanges: [NSRange] = []
    /// 지은 격자. 표의 원문과 글 넓이·글꼴이 같으면 다시 재지 않는다 — 글자 하나를 칠 때마다 문서의
    /// 모든 표를 다시 재면 표가 많은 문서에서 타이핑이 느려진다.
    private var tableGridCache: [String: (grid: TableGrid, image: NSImage)] = [:]

    /// 인용 막대 하나 — 이어진 인용 줄들의 왼쪽에 세로로 긋는다.
    ///
    /// 전에는 줄마다 `>`가 흐린 글자로 남아 막대 노릇을 했다. 줄마다 따로 찍힌 `>`는 이어진 선으로
    /// 읽히지 않고, 빈 인용 줄에는 `>` 하나만 덩그러니 남았다. 이제 `>`는 다른 마커처럼 캐럿이 없는
    /// 줄에서 숨고, 그 자리에 덩이 하나에 막대 하나를 그린다(`DecoratedTextView`).
    public struct QuoteBar: Equatable {
        /// 걸친 줄들 — 첫 줄의 처음부터 끝 줄의 끝까지(줄바꿈 제외).
        public let range: NSRange
        /// 몇 겹째인가. 1이 가장 바깥이다(`>>`의 안쪽 막대는 2).
        public let level: Int
        /// 알림 상자(`> [!NOTE]`)면 그 종류. 바깥 막대만 갖는다.
        public let alert: GithubAlert?
    }

    /// 이번 패스의 인용 막대(위치 순, 같은 자리에서는 바깥 막대가 먼저).
    public private(set) var quoteBars: [QuoteBar] = []

    /// 인용 한 겹의 들여쓰기, 막대가 글 칸 왼쪽에서 들어간 자리, 막대 굵기.
    static let quoteIndentStep: CGFloat = 16
    static let quoteBarInset: CGFloat = 2
    static let quoteBarWidth: CGFloat = 3

    /// `depth`겹 인용 줄의 글이 시작하는 자리. 한 겹이면 18pt(전과 같다).
    static func quoteIndent(depth: Int) -> CGFloat {
        quoteIndentStep * CGFloat(max(1, depth)) + quoteBarInset
    }
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
        // 격자로 그리는 표도 그렇다 — 캐럿이 표의 한 행으로 들어와도 바뀌는 것은 표 전체다.
        if alignsTables || drawsTables, writeRange.length != full.length {
            writeRange = extendedOverTables(writeRange, in: text, limit: full, lines: lines)
        }
        // 다이어그램·수식 블록도 **통째로** 칠한다. 블록은 캐럿이 안에 있으면 원문, 밖에 있으면
        // 그림인데, 캐럿이 블록의 가운데 줄로 들어와도 바뀌는 것은 블록 전체다 — 그 줄만 칠하면
        // 나머지 줄은 접힌 채 남는다.
        renderedBlocks = (renderedBlockImages != nil && !codeView)
            ? RenderedBlock.blocks(in: text, lines: lines) : []
        if writeRange.length != full.length, !renderedBlocks.isEmpty {
            writeRange = Self.extended(writeRange, over: renderedBlocks.map(\.range), in: text, limit: full)
        }

        storage.beginEditing()
        defer { storage.endEditing() }

        if codeView {
            // 코드 보기에서는 문서 전체가 날 글자다 — 블록도 그림도 그릴 근거가 없다.
            codeBlockRanges = []
            imagePlacements = []
            taskBoxes = []
            quoteBars = []
            drawnTables = []
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
        taskBoxes = drawsTaskBoxes ? Self.taskBoxes(in: lines, caretLine: caretLine) : []
        definitions = LinkDefinitions(scanning: text, lines: lines)
        // `> [!NOTE]`로 시작하는 인용 덩이는 색이 있는 안내 상자다. 줄 하나만 보고는
        // 알 수 없어서(덩이의 첫 줄이 종류를 말한다) 미리 한 번 훑는다.
        let alerts = GithubAlert.map(lines: lines, in: text)
        quoteBars = Self.quoteBars(in: lines, alerts: alerts)
        for (index, line) in lines.enumerated() {
            guard line.range.length == 0 || NSIntersectionRange(line.range, writeRange).length > 0
                    || NSLocationInRange(line.range.location, writeRange) else { continue }
            let quoteContinues: Bool
            if case .quote = line.kind, index + 1 < lines.count, case .quote = lines[index + 1].kind {
                quoteContinues = true
            } else {
                quoteContinues = false
            }
            apply(line, in: storage, text: text, caretLine: caretLine, alert: alerts[index],
                  quoteContinues: quoteContinues)
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
        // 맞춘 뒤에 격자로 바꾼다 — 캐럿이 든 표는 위에서 맞춘 원문으로 남는다.
        if drawsTables {
            placeTables(lines, in: storage, text: text, caretLine: caretLine, search: search,
                        writeRange: writeRange)
        } else {
            drawnTables = []
            foldedTableRanges = []
        }
        // 마지막이다 — 블록의 줄에 앞의 패스가 준 속성을 통째로 덮어쓴다.
        if !renderedBlocks.isEmpty {
            placeRenderedBlocks(lines, in: storage, text: text, caretLine: caretLine,
                                writeRange: writeRange)
        }

        for (index, range) in search.ranges.enumerated()
        where NSMaxRange(range) <= text.length && NSIntersectionRange(range, writeRange).length > 0
            && !foldedTableRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
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
        // 그림을 읽을 곳이 없어도 목록은 비운다 — 뒤의 패스(표 격자)가 이 목록에 더한다.
        guard let imageStore else {
            imagePlacements = []
            return
        }
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

    // MARK: 다이어그램·수식

    /// `range`가 닿는 블록을 통째로 감싸도록 넓힌다(`extendedOverTables`와 같은 이유).
    static func extended(_ range: NSRange, over blocks: [NSRange], in text: NSString,
                         limit: NSRange) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        for block in blocks where NSIntersectionRange(block, range).length > 0
            || NSLocationInRange(range.location, block) || NSLocationInRange(block.location, range) {
            start = min(start, block.location)
            end = max(end, NSMaxRange(block))
        }
        let grown = NSRange(location: start, length: max(0, end - start))
        return NSIntersectionRange(text.lineRange(for: NSIntersectionRange(grown, limit)), limit)
    }

    /// 블록을 그림으로 바꾼다 — **문서를 고치지 않고**(`placeImages`와 같은 길).
    ///
    /// 여는 줄이 그림의 높이를 갖고 나머지 줄은 높이 0으로 접힌다. 글자는 모두 숨는다.
    /// 캐럿이 블록 안에 있으면 원문을 보인다 — 고치려면 원문이 보여야 하고, 캐럿이 있는 줄의
    /// 마커를 보이는 이 편집기의 성질을 블록 단위로 넓힌 것이다. 그림이 아직 없거나(그리는 중)
    /// 그리지 못했으면 원문 그대로 둔다 — 틀린 Mermaid를 고칠 수 있어야 한다.
    ///
    /// 자리 목록은 `placeImages`처럼 **문서 전체**로 만들고, 속성 쓰기만 `writeRange`로 좁힌다.
    private func placeRenderedBlocks(_ lines: [LineToken], in storage: NSTextStorage,
                                     text: NSString, caretLine: Int?, writeRange: NSRange) {
        guard let renderer = renderedBlockImages else { return }
        let textColor = resolvedTextColorHex()
        let family = theme.bodyFontFamily.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\", " } ?? ""
        let fontFamily = family + "-apple-system, sans-serif"

        var placements = imagePlacements
        var shownAsImage: [NSRange] = []
        var dollarSources: [NSRange] = []

        for block in renderedBlocks {
            let writes = NSIntersectionRange(block.range, writeRange).length > 0
                || NSLocationInRange(block.range.location, writeRange)
            let blockLines = lines[(block.firstLine - 1) ... (block.lastLine - 1)]

            var image: NSImage?
            if caretLine.map(block.contains(line:)) != true {
                let request = RenderRequest(kind: block.kind, source: block.source,
                                            isDark: isDarkAppearance,
                                            fontSize: Double(theme.bodyPointSize),
                                            textColor: textColor, fontFamily: fontFamily)
                if case let .ready(ready) = renderer.image(for: request) { image = ready }
            }

            guard let image else {
                // 원문으로 둔다. `$$` 블록의 줄은 문단으로 칠해졌으므로 코드처럼 다시 칠한다 —
                // `x_1 + y_1`의 `_`가 기울임 표시로 읽혀 숨으면 고칠 수식이 망가져 보인다.
                if block.delimiter == .dollars {
                    dollarSources.append(block.range)
                    if writes { showAsCode(blockLines, in: storage, text: text) }
                }
                continue
            }

            let pixels = ImageReference.Size(width: Double(image.size.width),
                                             height: Double(image.size.height))
            let display = ImageReference.displaySize(for: pixels, maxWidth: contentWidth)
            let size = CGSize(width: display.width, height: display.height)
            guard size.height > 0, let first = blockLines.first else { continue }
            placements.append(ImagePlacement(lineRange: first.range, size: size, image: image,
                                             centered: block.kind == .math))
            shownAsImage.append(block.range)
            guard writes else { continue }

            for line in blockLines {
                if line.range.length > 0 { hide(line.range, in: storage) }
                // 줄바꿈까지 덮는다 — 문단 스타일은 줄바꿈 글자까지가 한 문단이다.
                // **줄바꿈은 숨기지 않는다**: 숨긴 글자는 폭 0의 제어 문자가 되고, 줄바꿈이
                // 그렇게 되면 줄이 끊기지 않아 블록 뒤의 글이 그림 줄에 붙는다.
                let paragraph = text.lineRange(for: NSRange(location: line.range.location, length: 0))
                let style = NSMutableParagraphStyle()
                if line.lineNumber == block.firstLine {
                    style.paragraphSpacing = theme.paragraphSpacing
                    style.minimumLineHeight = size.height + 8
                    style.maximumLineHeight = size.height + 8
                } else {
                    // 접는다. 0은 "제한 없음"이라 아주 작은 값을 준다.
                    style.minimumLineHeight = 0
                    style.maximumLineHeight = 0.001
                }
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            }
        }

        // 그림이 된 펜스 블록은 회색 상자를 그리지 않는다. 원문으로 보이는 `$$` 블록은 코드처럼
        // 상자를 그린다. 그리는 쪽이 이분 탐색하므로 **위치 순**이어야 한다.
        codeBlockRanges = (codeBlockRanges.filter { range in
            !shownAsImage.contains { NSIntersectionRange($0, range).length > 0 }
        } + dollarSources).sorted { $0.location < $1.location }
        imagePlacements = placements.sorted { $0.lineRange.location < $1.lineRange.location }
    }

    /// `$$` 블록의 원문을 코드처럼 칠한다 — 고정폭, 코드 색, 마커 숨김 없음.
    private func showAsCode(_ lines: ArraySlice<LineToken>, in storage: NSTextStorage, text: NSString) {
        let style = paragraphStyle(for: .codeBody)
        for line in lines where line.range.length > 0 {
            storage.setAttributes([
                .font: theme.monoFont,
                .foregroundColor: theme.codeText,
                .paragraphStyle: style,
            ], range: line.range)
        }
    }

    /// 본문 글자 색을 지금 외관에서 푼 `#rrggbb`. 수식 글자 색이다.
    private func resolvedTextColorHex() -> String {
        var hex = isDarkAppearance ? "#ffffff" : "#000000"
        let appearance = NSAppearance(named: isDarkAppearance ? .darkAqua : .aqua)
        appearance?.performAsCurrentDrawingAppearance {
            guard let color = theme.text.usingColorSpace(.sRGB) else { return }
            hex = String(format: "#%02x%02x%02x",
                         Int((color.redComponent * 255).rounded()),
                         Int((color.greenComponent * 255).rounded()),
                         Int((color.blueComponent * 255).rounded()))
        }
        return hex
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
            //    재는 것은 칸의 글이 아니라 **막대와 막대 사이 전체**다(`slot`). 칸 둘레의
            //    공백은 행마다 다르다 — 구분 행은 흔히 `|:---|`로 공백 없이 쓰고 본문 행은
            //    `| 기능 |`로 쓴다. 글만 재서 맞추면 공백만큼(고정폭 두 칸, 약 17pt) 막대가
            //    어긋났다(실측: 구분 행의 막대가 70.7 / 122.7 / 165.9, 다른 행은 88.1 / 157.3 / 217.9).
            var measured: [Int: [Int: CGFloat]] = [:]   // [줄번호: [열: 너비]]
            var widths = [CGFloat](repeating: 0, count: table.columnCount)
            for row in table.rows {
                var perColumn: [Int: CGFloat] = [:]
                for (column, cell) in row.cells.enumerated() where column < widths.count {
                    let value = visibleWidth(of: slot(of: cell, in: row), in: storage)
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

    /// 칸이 차지하는 자리 — 앞 막대 바로 뒤부터 뒤 막대 바로 앞까지, 칸 둘레의 공백을 넣어서.
    /// 막대가 없는 쪽은 줄의 처음이나 끝까지다.
    private func slot(of cell: NSRange, in row: MarkdownTable.Row) -> NSRange {
        let start = separator(before: cell, in: row).map(NSMaxRange) ?? row.range.location
        let end = row.separators.first { $0.location >= NSMaxRange(cell) }?.location
            ?? NSMaxRange(row.range)
        return NSRange(location: start, length: max(0, end - start))
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

    // MARK: 표를 격자로

    /// 캐럿이 없는 표를 격자 그림으로 바꾼다 — **문서를 고치지 않고**(`placeRenderedBlocks`와 같은 길).
    ///
    /// 머리 행이 격자의 높이를 갖고 나머지 행은 높이 0으로 접힌다. 글자는 모두 숨는다. 캐럿이 표 안에
    /// 있거나 지금 찾은 곳이 표 안이면 원문으로 둔다 — 고치려면, 찾은 글자를 보려면 원문이 보여야 한다.
    /// 자리 목록은 문서 전체로 만들고 속성 쓰기만 `writeRange`로 좁힌다(`placeImages`와 같은 이유).
    private func placeTables(_ lines: [LineToken], in storage: NSTextStorage, text: NSString,
                             caretLine: Int?, search: SearchState, writeRange: NSRange) {
        let currentMatch = search.currentIndex.flatMap { search.ranges.indices.contains($0) ? search.ranges[$0] : nil }
        var placements = imagePlacements
        var drawn: [DrawnTable] = []
        var used: Set<String> = []
        foldedTableRanges = []

        for table in MarkdownTable.blocks(in: text, lines: lines) {
            guard table.columnCount > 0, let first = table.rows.first else { continue }
            let block = tableRange(table)
            let isOpen = caretLine.map { line in table.rows.contains { $0.lineNumber == line } } == true
                || currentMatch.map { NSIntersectionRange($0, block).length > 0 || NSLocationInRange($0.location, block) } == true
            guard !isOpen else { continue }

            let key = tableCacheKey(text.substring(with: block))
            used.insert(key)
            let entry: (grid: TableGrid, image: NSImage)
            if let cached = tableGridCache[key] {
                entry = cached
            } else {
                let grid = tableGrid(for: table, text: text)
                entry = (grid, grid.image(line: theme.tableLine, headerBackground: theme.tableHeaderBackground))
                tableGridCache[key] = entry
            }
            guard entry.grid.size.height > 0 else { continue }
            drawn.append(DrawnTable(headerLine: first.range, grid: entry.grid))
            foldedTableRanges.append(block)
            placements.append(ImagePlacement(lineRange: first.range, size: entry.grid.size, image: entry.image))

            let writes = NSIntersectionRange(block, writeRange).length > 0 || NSLocationInRange(block.location, writeRange)
            guard writes else { continue }
            for row in table.rows {
                if row.range.length > 0 {
                    hide(row.range, in: storage)
                    // 맞추기가 준 간격도 걷는다 — 숨긴 글자에 남으면 접힌 줄이 그만큼 넓어질 수 있다.
                    // 밑줄·배경도 걷는다. 폭 0인 글자에도 밑줄은 그려진다(실측: 칸의 링크 밑줄이 표 아래에
                    // 파란 점으로 남았다).
                    for key in [NSAttributedString.Key.kern, .underlineStyle, .strikethroughStyle, .backgroundColor] {
                        storage.removeAttribute(key, range: row.range)
                    }
                }
                // 줄바꿈까지 덮는다. 줄바꿈은 숨기지 않는다 — 숨기면 줄이 끊기지 않아 다음 행이 붙는다.
                let paragraph = text.lineRange(for: NSRange(location: row.range.location, length: 0))
                let style = NSMutableParagraphStyle()
                if row.lineNumber == first.lineNumber {
                    style.paragraphSpacing = theme.paragraphSpacing
                    style.minimumLineHeight = entry.grid.size.height + 2
                    style.maximumLineHeight = entry.grid.size.height + 2
                } else {
                    // 접는다. 0은 "제한 없음"이라 아주 작은 값을 준다.
                    style.minimumLineHeight = 0
                    style.maximumLineHeight = 0.001
                }
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            }
        }
        // 지금 문서에 없는 표의 격자는 버린다 — 고칠 때마다 옛 꼴이 쌓인다.
        tableGridCache = tableGridCache.filter { used.contains($0.key) }
        drawnTables = drawn
        imagePlacements = placements.sorted { $0.lineRange.location < $1.lineRange.location }
    }

    /// 격자를 다시 쓸 수 있는지 가리는 열쇠 — 원문, 글 넓이, 글꼴, 줄 간격.
    private func tableCacheKey(_ source: String) -> String {
        "\(contentWidth)|\(theme.bodyPointSize)|\(theme.lineSpacingScale)|\(theme.bodyFontFamily ?? "")|"
            + "\(theme.codeFontFamily ?? "")|\(appliesSyntheticSlant)\n" + source
    }

    /// 표 하나의 격자. 구분 행은 빼고, 칸의 인라인 마크업은 본문처럼 그린다(마커는 뺀다).
    func tableGrid(for table: MarkdownTable, text: NSString) -> TableGrid {
        var rows: [TableGrid.Row] = []
        for row in table.rows where row.kind != .delimiter {
            let isHeader = row.kind == .header
            let cells = (0 ..< table.columnCount).map { column -> NSAttributedString in
                guard column < row.cells.count, row.cells[column].length > 0 else { return NSAttributedString() }
                return cellText(text.substring(with: row.cells[column]), header: isHeader,
                                alignment: table.alignment(forColumn: column))
            }
            rows.append(TableGrid.Row(cells: cells, isHeader: isHeader))
        }
        let font = theme.bodyFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return TableGrid(rows: rows, columnCount: table.columnCount, lineHeight: lineHeight,
                         maxWidth: CGFloat(contentWidth), minimumColumnWidth: theme.bodyPointSize * 4)
    }

    /// 칸 하나의 글. 칸 밖과 같은 인라인 칠하기(`styleInline`)를 거친 뒤 숨긴 마커를 뺀다.
    private func cellText(_ raw: String, header: Bool, alignment: MarkdownTable.Alignment) -> NSAttributedString {
        // `\|`는 칸을 나누지 않는 막대 글자다(`MarkdownTable.parseRow`) — 그려진 칸에는 막대로 보인다.
        let source = raw.replacingOccurrences(of: "\\|", with: "|") as NSString
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing * 0.5
        switch alignment {
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        case .left, .none: style.alignment = .natural
        }
        let cell = NSTextStorage(string: source as String, attributes: [
            .font: header ? theme.semiboldBodyFont : theme.bodyFont,
            .foregroundColor: theme.text,
            .paragraphStyle: style,
        ])
        styleInline(in: cell, text: source, content: NSRange(location: 0, length: source.length), onCaretLine: false)
        let visible = NSMutableAttributedString()
        cell.enumerateAttribute(.mdHiddenMarker, in: NSRange(location: 0, length: cell.length)) { value, range, _ in
            guard value == nil else { return }
            visible.append(cell.attributedSubstring(from: range))
        }
        return visible
    }

    // MARK: Blocks

    /// 이어진 인용 줄들에 겹마다 막대 하나. 줄 판정만 보므로 문서 전체를 훑어도 싸다.
    static func quoteBars(in lines: [LineToken], alerts: [Int: GithubAlert]) -> [QuoteBar] {
        var bars: [QuoteBar] = []
        // 겹 → (첫 줄 시작, 끝 줄 끝, 알림)
        var open: [Int: (start: Int, end: Int, alert: GithubAlert?)] = [:]

        func close(deeperThan depth: Int) {
            for level in open.keys.sorted() where level > depth {
                if let run = open.removeValue(forKey: level) {
                    bars.append(QuoteBar(range: NSRange(location: run.start, length: run.end - run.start),
                                         level: level, alert: run.alert))
                }
            }
        }

        for (index, line) in lines.enumerated() {
            guard case let .quote(depth) = line.kind, depth > 0 else {
                close(deeperThan: 0)
                continue
            }
            close(deeperThan: depth)
            for level in 1 ... depth {
                if var run = open[level] {
                    run.end = NSMaxRange(line.range)
                    open[level] = run
                } else {
                    open[level] = (line.range.location, NSMaxRange(line.range), level == 1 ? alerts[index] : nil)
                }
            }
        }
        close(deeperThan: 0)
        return bars.sorted { ($0.range.location, $0.level) < ($1.range.location, $1.level) }
    }

    private func apply(_ line: LineToken, in storage: NSTextStorage, text: NSString,
                       caretLine: Int?, alert: GithubAlert? = nil, quoteContinues: Bool = false) {
        guard line.range.length > 0 || line.kind == .blank else { return }
        let onCaretLine = caretLine == line.lineNumber
        var style = paragraphStyle(for: line.kind)
        if quoteContinues, let mutable = style.mutableCopy() as? NSMutableParagraphStyle {
            // 인용 덩이 안의 줄 사이는 줄 간격만 둔다 — 줄마다 문단 간격을 두면 이어진 인용이 낱줄로
            // 흩어져 보인다. 덩이 안의 문단은 빈 인용 줄(`>`)이 가른다.
            mutable.paragraphSpacing = 0
            style = mutable
        }
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
                        .font: theme.semiboldBodyFont,
                    ], range: line.contentRange)
                }
            } else {
                storage.addAttributes([.foregroundColor: theme.quote], range: line.range)
            }

            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)

        case let .listItem(_, checked):
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)
            // 체크박스는 표지의 두 번째 조각이다(`MarkdownSyntax`). 누를 수 있게 표시한다.
            if checked != nil, let box = Self.taskBoxRange(of: line), NSMaxRange(box) <= text.length {
                storage.addAttribute(.mdTaskBox, value: box.location, range: box)
            }

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

        case .footnoteDefinition:
            // `[^1]: 글` → 위첨자 `1`과 글. 괄호와 콜론은 마커로 접히고, 라벨 뒤에 글자 간격을
            // 조금 주어 글과 붙지 않게 한다(접힌 콜론 뒤 공백도 마커라 사라진다).
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)
            if let label = MarkdownSyntax.footnoteLabelRange(ofDefinition: line), NSMaxRange(label) <= text.length {
                var attributes = footnoteAttributes(at: label.location, in: storage)
                attributes[.mdFootnoteJump] = "reference:" + text.substring(with: label)
                storage.addAttributes(attributes, range: label)
                if !onCaretLine {
                    storage.addAttribute(.kern, value: theme.bodyPointSize * 0.4,
                                         range: NSRange(location: NSMaxRange(label) - 1, length: 1))
                }
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

            // 알림 상자의 `>`는 종류 색으로 칠한다(캐럿이 있는 줄에서 보인다) — 막대와 같은 색이다.
            storage.addAttribute(.foregroundColor,
                                 value: alert.map(theme.alertColor(for:)) ?? theme.dim,
                                 range: marker)
            // 목록의 글머리는 그려진 모양의 일부라 남긴다. 인용의 `>`는 숨기고 그 자리에 막대를
            // 그린다(`quoteBars`). 렌더러가 삼키는 마크업은 숨긴다.
            if !onCaretLine, shouldHideMarker(for: line.kind) {
                hide(marker, in: storage)
            }
        }

        // 상자로 그리는 체크박스는 글자를 투명하게 한다 — 숨기면(폭 0) 상자를 그릴 자리가 없다.
        if drawsTaskBoxes, !onCaretLine, let box = Self.taskBoxRange(of: line), NSMaxRange(box) <= text.length {
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: box)
        }
    }

    /// 체크박스 줄의 `[ ]` 범위. 줄 판정의 두 번째 마커다(`MarkdownSyntax`).
    static func taskBoxRange(of line: LineToken) -> NSRange? {
        guard case .listItem(_, .some) = line.kind, line.markerRanges.count > 1 else { return nil }
        let box = line.markerRanges[1]
        return box.length == 3 ? box : nil
    }

    /// 캐럿이 없는 줄의 체크박스들. 캐럿이 있는 줄은 원문(`[ ]`)으로 둔다 — 다른 마커와 같다.
    static func taskBoxes(in lines: [LineToken], caretLine: Int?) -> [TaskBox] {
        lines.compactMap { line in
            guard line.lineNumber != caretLine, let box = taskBoxRange(of: line),
                  case let .listItem(_, checked?) = line.kind else { return nil }
            return TaskBox(range: box, checked: checked)
        }
    }

    private func shouldHideMarker(for kind: BlockKind) -> Bool {
        switch kind {
        case .heading, .codeFence, .setextUnderline: return true
        // `>`는 막대로 그린다(`quoteBars`).
        case .quote: return true
        // 정의 줄의 라벨(`[참조]: `)은 렌더러가 삼키는 markup이라 접는다. 주소는
        // 마커가 아니므로 남는다 — 줄 전체가 사라지면 사용자가 친 글자가 없어진다.
        case .linkDefinition: return true
        // 각주 정의의 `[^`와 `]: `. 라벨과 글은 마커가 아니라 남는다.
        case .footnoteDefinition: return true
        case .listItem, .thematicBreak, .tableRow, .tableDelimiter,
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
                let slanted = italic(existing)
                storage.addAttribute(.font, value: slanted, range: token.contentRange)
                // 한글·일본어·중국어에는 기울임꼴이 없어 글꼴을 바꿔도 그림이 한 픽셀도
                // 달라지지 않는다(실측). 그 글자에만 강제 기울임을 더한다 — 모든 글자에
                // 주면 진짜 기울임꼴을 받는 영문이 두 번 기울어 지나치게 눕는다.
                // 글꼴 자체에 기울임꼴이 없으면(Pretendard) 영문도 강제로 기울인다.
                let hasItalic = NSFontManager.shared.traits(of: slanted).contains(.italicFontMask)
                for slantRange in SyntheticSlant.ranges(in: text, range: token.contentRange,
                                                        fontHasItalic: hasItalic,
                                                        cjk: appliesSyntheticSlant) {
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
            case let .footnoteReference(label):
                var attributes = footnoteAttributes(at: token.contentRange.location, in: storage)
                attributes[.mdFootnoteJump] = "definition:" + label
                storage.addAttributes(attributes, range: token.contentRange)
            }

            for marker in token.markerRanges where marker.length > 0 {
                storage.addAttribute(.foregroundColor, value: theme.dim, range: marker)
                if !onCaretLine { hide(marker, in: storage) }
            }
        }
    }

    /// 각주 라벨의 모양 — 그 자리 글꼴의 작은 위첨자, 링크 색. 제목 안의 각주는 제목 크기를 따른다.
    private func footnoteAttributes(at location: Int, in storage: NSTextStorage) -> [NSAttributedString.Key: Any] {
        let base = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? theme.bodyFont
        let size = base.pointSize * 0.72
        let font = NSFontManager.shared.convert(base, toSize: size)
        return [
            .font: font,
            .baselineOffset: base.pointSize * 0.36,
            .foregroundColor: theme.link,
        ]
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
        case let .quote(depth):
            // 겹마다 막대 하나만큼 들어간다(`quoteBars`).
            style.firstLineHeadIndent = Self.quoteIndent(depth: depth)
            style.headIndent = Self.quoteIndent(depth: depth)
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
