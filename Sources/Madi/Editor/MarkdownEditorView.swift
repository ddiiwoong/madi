import AppKit

@MainActor
public protocol MarkdownEditorDelegate: AnyObject {
    func markdownEditorDidChangeText(_ editor: MarkdownEditorView)
    func markdownEditor(_ editor: MarkdownEditorView, didClickLink url: String)
}

/// The editor. One `NSTextStorage` holds markdown source; the styler draws it
/// as a formatted document and the layout manager drops the glyphs of syntax
/// markers that are not on the caret's line. So the rendered view IS the
/// editable view — there is no separate preview to switch to.
@MainActor
public final class MarkdownEditorView: NSView {

    public weak var editorDelegate: MarkdownEditorDelegate?

    public let textView: MarkdownTextView
    private let scrollView = NSScrollView()
    /// 속성을 미루지 않고 고치는 저장소(`EagerTextStorage` — 큰 문서 앞쪽의 타이핑 비용).
    private let storage = EagerTextStorage()
    private let layout = NSLayoutManager()
    private let container: NSTextContainer
    private let styler = MarkdownStyler()
    private let imageStore = InlineImageStore()
    /// 편집기와 스타일러가 **같은 테마를 봐야 한다.** 둘은 각자 인스턴스를 들고
    /// 있어서 기본값이 같을 때는 들키지 않지만, 한쪽만 바꾸면 글자 크기가 반쪽만
    /// 적용된다. 그래서 여기서 바뀔 때마다 스타일러에도 넘긴다.
    private var theme = MarkdownTheme() {
        didSet { styler.theme = theme }
    }

    private var searchState = MarkdownStyler.SearchState()
    private var currentQuery = ""
    private var lastCaretLine: Int?
    private var isStyling = false
    private var pendingRestyle = false

    public override init(frame frameRect: NSRect) {
        // An explicit TextKit 1 stack: glyph-level hiding is only reachable
        // through NSLayoutManager, and a plain NSTextView would come up on
        // TextKit 2 where this delegate callback does not exist.
        container = NSTextContainer(size: NSSize(width: frameRect.width,
                                                 height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        textView = MarkdownTextView(frame: frameRect, textContainer: container)
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func configure() {
        layout.delegate = self
        storage.delegate = self
        // 고친 자리 근처만 다시 놓는다.
        //
        // 왜(실측, 22만 자 문서, 문서 처음에서 한 글자): 이어 놓기(기본값)에서는 한 글자가
        // 그 **뒤의 레이아웃 전부**를 무효로 만들었다(첫 미배치 글자 227,846 → 71). 텍스트
        // 뷰의 높이가 그 자리까지로 줄어 보이는 화면 전체를 다시 그렸고(16.9ms), 뒤 레이아웃이
        // 문서 끝까지 다시 돌았다. 끊어 놓기에서는 고친 줄만 다시 그린다(0.6ms).
        //
        // 대가: 아직 놓지 않은 구간의 높이는 어림이라 굴리는 동안 스크롤 막대가 조금씩 변할
        // 수 있다. 블록 좌표(나란히 보기)는 `ensureLayout`으로 끝까지 놓은 뒤에 재므로
        // 영향이 없다.
        layout.allowsNonContiguousLayout = true
        styler.theme = theme
        styler.imageStore = imageStore
        // 원격 그림은 나중에 도착한다. 도착하면 자리를 잡아야 하므로 다시 칠한다.
        imageStore.onRemoteImageLoaded = { [weak self] in self?.restyleAll() }
        useDiagramRenderer(DiagramRenderer.shared)

        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = false
        textView.importsGraphics = false
        textView.textContainerInset = theme.textInsets
        textView.insertionPointColor = theme.insertionPoint
        textView.backgroundColor = .textBackgroundColor
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.linkTextAttributes = [:]
        textView.clickHandler = { [weak self] index, modifiers in
            self?.handleClick(at: index, modifiers: modifiers) ?? false
        }
        textView.imageInsertHandler = { [weak self] pasteboard, range in
            self?.insertImages(from: pasteboard, replacing: range) ?? false
        }
        textView.updateDragTypeRegistration()

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Content

    public var markdown: String {
        get { storage.string }
        set {
            guard newValue != storage.string else { return }
            let selected = textView.selectedRange()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newValue)
            restyleAll()
            let clamped = min(selected.location, storage.length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
        }
    }

    public var outline: [OutlineEntry] {
        Outline.entries(lines: currentLines(), in: storage.string as NSString)
    }

    // MARK: Batching

    private var batchDepth = 0
    private var restyleAfterBatch = false

    /// 안에서 일어나는 전체 다시 칠하기를 **끝에서 한 번으로** 모은다.
    ///
    /// 왜(실측, 22만 자 문서): 문서를 열 때 글 넣기 · 문서 위치 · 설정 싣기가 각자 문서
    /// 전체를 칠해 0.3초짜리 패스가 세 번 돌았다. 셋은 서로의 결과를 쓰지 않는다 — 마지막
    /// 패스만 화면에 남는다.
    public func batchUpdates(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        if batchDepth == 0, restyleAfterBatch {
            restyleAfterBatch = false
            restyleAll()
        }
    }

    /// 전체 다시 칠하기가 몇 번 돌았는지. 테스트가 모으기를 확인하는 데 쓴다.
    private(set) var fullRestyleCount = 0

    // MARK: Lines

    /// 글의 줄 판정. **글이 바뀔 때까지 다시 훑지 않는다.**
    ///
    /// 왜(실측, 22만 자 문서): 줄 스캔 한 번이 12~30ms인데 글자 하나를 칠 때마다 세 번
    /// 돌았다 — 스타일 패스, 표 넓히기, 목차. 캐럿 줄은 그때마다 문서 처음부터 줄을 셌다.
    /// 이제 한 번 훑고 나머지는 이것을 나눠 쓴다.
    ///
    /// 열쇠는 `blockRevision`이고, 그것은 **저장소가** 글자가 바뀔 때마다 올린다
    /// (`textStorage(_:didProcessEditing:...)`). 텍스트 뷰의 `textDidChange`에서 올리면
    /// 저장소가 바뀐 뒤 그 알림이 오기 전까지 낡은 표를 읽는 구간이 생긴다 — 그 사이에
    /// 불리는 선택 변경 콜백이 낡은 표로 캐럿 줄을 찾으면 범위가 문서를 넘을 수 있다.
    /// 저장소에서 올리면 그런 구간이 없다.
    ///
    /// 글자 편집 하나가 오면 **고친 자리부터만** 다시 훑는다(`MarkdownSyntax.rescan`) — 옛
    /// 결과가 바로 앞 글의 것일 때. 아니면(처음, 여러 편집이 겹침) 다음에 읽을 때 전체를 훑는다.
    private var scanCache: (revision: Int, scan: MarkdownSyntax.LineScan)?

    func currentLines() -> [LineToken] {
        if let cache = scanCache, cache.revision == blockRevision { return cache.scan.lines }
        fullScanCount += 1
        let scan = MarkdownSyntax().scan(storage.string as NSString)
        scanCache = (blockRevision, scan)
        return scan.lines
    }

    /// 문서 전체를 훑은 횟수. 테스트가 "편집은 전체를 훑지 않는다"를 확인하는 데 쓴다.
    private(set) var fullScanCount = 0

    /// 글자 편집 하나를 받는다. 저장소 대리자가 그 자리에서 부른다.
    private func textDidEdit(range editedRange: NSRange, changeInLength delta: Int) {
        let previous = scanCache.flatMap { $0.revision == blockRevision ? $0.scan : nil }
        invalidateBlocks()
        guard let previous,
              let next = MarkdownSyntax().rescan(storage.string as NSString, after: previous,
                                                 editedRange: editedRange, changeInLength: delta)
        else { return }
        scanCache = (blockRevision, next)
    }

    /// 코드 보기 (⌘E) — toggles between the formatted document and the raw
    /// markdown. Same storage, different drawing.
    public var isCodeView: Bool {
        get { styler.codeView }
        set {
            guard styler.codeView != newValue else { return }
            styler.codeView = newValue
            restyleAll()
        }
    }

    /// The view to hand to `NSPrintOperation`. Printing the text view prints
    /// what is on screen, markers hidden and all, which is what "export this
    /// document" should produce.
    public var printableView: NSView { textView }

    // MARK: Search

    @discardableResult
    public func applySearch(query: String) -> [NSRange] {
        currentQuery = query
        let text = storage.string as NSString
        searchState.ranges = DocumentSearch.matches(in: text, query: query)
        searchState.currentIndex = searchState.ranges.isEmpty ? nil : 0
        restyleAll()
        return searchState.ranges
    }

    public func clearSearch() {
        currentQuery = ""
        guard !searchState.ranges.isEmpty || searchState.currentIndex != nil else { return }
        searchState = MarkdownStyler.SearchState()
        restyleAll()
    }

    public var searchMatchCount: Int { searchState.ranges.count }
    public var currentSearchMatch: Int? { searchState.currentIndex }

    /// Step to the next or previous match and scroll it into view.
    public func stepSearch(forward: Bool) {
        guard !searchState.ranges.isEmpty else { return }
        let count = searchState.ranges.count
        let current = searchState.currentIndex ?? 0
        let next = ((current + (forward ? 1 : -1)) % count + count) % count
        searchState.currentIndex = next
        restyleAll()
        reveal(searchState.ranges[next])
    }

    public func reveal(_ range: NSRange) {
        guard NSMaxRange(range) <= storage.length else { return }
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    public func moveCaret(to range: NSRange) {
        guard NSMaxRange(range) <= storage.length else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
    }

    // MARK: Block coordinates (나란히 보기)

    /// 스크롤이 일어나는 클립 뷰. 나란히 보기가 이것의 경계 변경을 듣는다.
    public var clipView: NSClipView { scrollView.contentView }

    /// 글이 바뀔 때마다 늘어난다. 블록 나누기와 짝짓기를 다시 해야 하는지 이것으로 안다.
    public private(set) var blockRevision = 0
    private var blockCache: (revision: Int, blocks: [Block], starts: [Int])?

    private func invalidateBlocks() {
        blockRevision &+= 1
        blockCache = nil
    }

    /// 이 편집기 글의 블록. `BlockParser`로 나눈 것이고 글이 바뀔 때까지 다시 나누지 않는다.
    public var blocks: [Block] { blockGeometry().blocks }

    /// 블록 나누기와 함께 **레이아웃을 끝까지** 돌린다.
    ///
    /// 왜(실측): TextKit 1은 레이아웃을 뒤에서 이어 가고, 그동안 텍스트 뷰의 높이는 아직
    /// 자라는 중이다. 막 연 창에서 높이를 읽으면 같은 문서가 잴 때마다 다른 높이로 나와
    /// 스크롤 맞추기가 어긋났다. 이미 끝났으면 `ensureLayout`은 아무 일도 하지 않는다.
    private func blockGeometry() -> (blocks: [Block], starts: [Int]) {
        layout.ensureLayout(for: container)
        if let cache = blockCache, cache.revision == blockRevision {
            return (cache.blocks, cache.starts)
        }
        let blocks = BlockParser().parseBlocks(storage.string)
        var starts: [Int] = []
        starts.reserveCapacity(blocks.count)
        var offset = 0
        for block in blocks {
            starts.append(offset)
            offset += (block.sourceSlice as NSString).length
        }
        blockCache = (blockRevision, blocks, starts)
        return (blocks, starts)
    }

    /// 블록 `index`의 위쪽 끝(텍스트 뷰 좌표). 첫 블록은 0, 끝(`index == count`)은 글 높이다 —
    /// 위아래 여백을 첫 블록과 마지막 블록에 넣어야 문서 처음과 끝이 서로 맞는다.
    private func blockTop(_ index: Int, starts: [Int]) -> CGFloat {
        if index <= 0 { return 0 }
        if index >= starts.count { return textView.frame.height }
        let character = starts[index]
        guard character < storage.length else { return textView.frame.height }
        let glyph = layout.glyphIndexForCharacter(at: character)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.minY + textView.textContainerOrigin.y
    }

    /// 지금 보고 있는 자리를 블록 좌표로. `3.4`는 네 번째 블록의 40% 지점이다.
    ///
    /// 기준 줄은 **스크롤한 만큼 화면 아래로 내려간다** — 맨 위에서는 화면 위쪽 끝, 맨
    /// 아래에서는 화면 아래쪽 끝이다. 화면 위쪽 끝만 쓰면 한쪽이 바닥에 닿아도 다른 쪽은
    /// 바닥에 닿지 못한다(두 글의 높이가 다르므로). 이렇게 하면 처음은 처음끼리, 끝은
    /// 끝끼리 맞고 그 사이는 끊김 없이 이어진다.
    public func scrollReferencePosition() -> Double {
        let geometry = blockGeometry()
        let count = geometry.starts.count
        guard count > 0 else { return 0 }
        let documentHeight = textView.frame.height
        let visible = clipView.bounds.height
        let maxOrigin = max(0, documentHeight - visible)
        guard maxOrigin > 0, documentHeight > 0 else { return 0 }
        let origin = min(max(clipView.bounds.origin.y, 0), maxOrigin)
        let reference = origin * documentHeight / maxOrigin

        // reference 이하에서 시작하는 마지막 블록을 이분 탐색으로 찾는다 — 블록마다
        // 레이아웃을 묻지 않는다(큰 문서에서 블록이 수천 개다).
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if blockTop(mid, starts: geometry.starts) <= reference { lo = mid } else { hi = mid - 1 }
        }
        let top = blockTop(lo, starts: geometry.starts)
        let bottom = blockTop(lo + 1, starts: geometry.starts)
        let fraction = bottom > top ? Double((reference - top) / (bottom - top)) : 0
        return Double(lo) + min(max(fraction, 0), 1)
    }

    /// 블록 좌표로 스크롤한다. 실제로 놓인 원점(클립 뷰의 y)을 돌려준다.
    @discardableResult
    public func scroll(toReferencePosition position: Double) -> CGFloat {
        let origin = originForReferencePosition(position)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: origin))
        scrollView.reflectScrolledClipView(clipView)
        return clipView.bounds.origin.y
    }

    /// `scroll(toReferencePosition:)`이 놓을 원점. 옮기지 않고 재기만 한다.
    public func originForReferencePosition(_ position: Double) -> CGFloat {
        let geometry = blockGeometry()
        let count = geometry.starts.count
        let documentHeight = textView.frame.height
        let visible = clipView.bounds.height
        let maxOrigin = max(0, documentHeight - visible)
        guard count > 0, maxOrigin > 0, documentHeight > 0 else { return 0 }
        let clamped = min(max(position.isFinite ? position : 0, 0), Double(count))
        let index = min(Int(clamped), count - 1)
        let fraction = CGFloat(clamped - Double(index))
        let top = blockTop(index, starts: geometry.starts)
        let bottom = blockTop(index + 1, starts: geometry.starts)
        let reference = top + fraction * (bottom - top)
        // `scrollReferencePosition`의 역: reference = origin × 높이 / maxOrigin.
        return min(max(reference * maxOrigin / documentHeight, 0), maxOrigin)
    }

    // MARK: Styling

    /// 캐럿이 있는 줄(1부터). 줄 표에서 이분 탐색으로 찾는다 — 전에는 문서 처음부터 줄을
    /// 셌고, 캐럿을 한 칸 옮길 때마다 그 앞의 줄을 전부 다시 셌다.
    ///
    /// 끝에 줄바꿈이 없는 문서에서 캐럿이 맨 끝에 있으면 **마지막 줄**이다. 전에 세던
    /// 방식은 여기서 없는 줄(마지막 + 1)을 돌려줘, 그 줄의 마커가 캐럿이 있는데도 숨었다.
    func caretLine() -> Int? {
        let selection = textView.selectedRange()
        guard selection.location <= storage.length else { return nil }
        return Self.lineNumber(at: selection.location, in: currentLines())
    }

    /// `location`이 든 줄의 번호. 시작이 `location` 이하인 마지막 줄이다.
    static func lineNumber(at location: Int, in lines: [LineToken]) -> Int {
        guard !lines.isEmpty else { return 1 }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].range.location <= location { lo = mid } else { hi = mid - 1 }
        }
        return lines[lo].lineNumber
    }

    /// 설정을 싣는다. 설정 화면의 각 항목이 여기서 실제 코드 경로로 이어진다.
    public func apply(_ preferences: EditorPreferences) {
        theme.bodyPointSize = preferences.bodyPointSize      // didSet이 스타일러에 넘긴다
        theme.lineSpacingScale = preferences.lineSpacing.scale
        theme.documentWidthMultiple = preferences.documentWidth.multipleOfBodySize
        theme.bodyFontFamily = preferences.bodyFontFamily
        theme.codeFontFamily = preferences.codeFontFamily
        styler.highlightsCode = preferences.highlightCode
        styler.alignsTables = preferences.alignTables
        styler.appliesSyntheticSlant = preferences.syntheticSlant
        imageStore.loadsRemote = preferences.loadsRemoteImages
        updateTextInsets()
        textView.insertionPointColor = theme.insertionPoint
        restyleAll()
    }

    /// 글을 가운데 두는 가로 여백을 다시 잰다. 창 크기가 바뀔 때도 불려야 한다.
    private func updateTextInsets(viewWidth: CGFloat? = nil) {
        let width = viewWidth ?? bounds.width
        let insets = theme.textInsets(forViewWidth: width)
        guard textView.textContainerInset != insets else { return }
        textView.textContainerInset = insets
    }

    /// 창 크기가 바뀌면 여백을 다시 재고 다시 칠한다.
    ///
    /// `layout()`을 쓸 수 없다 — 이 타입에는 `layout`이라는 `NSLayoutManager`
    /// 프로퍼티가 이미 있어 이름이 충돌한다(컴파일러가 거절한다).
    ///
    /// 다시 칠해야 하는 이유: 그림 폭 맞춤과 표 열 맞추기가 **컨테이너 폭을 읽는다.**
    /// 여백만 바꾸고 칠하지 않으면 넓은 창에서 줄인 그림이 좁아진 글 폭을 넘는다.
    ///
    /// 창을 **끌어서** 바꾸는 동안에는 칠하지 않고 놓을 때 한 번 칠한다. 22만 자 문서에서
    /// 한 번 칠하는 데 0.16초라 끄는 동안 매 단계 칠하면 창이 초당 여섯 번밖에 못 움직였다
    /// (실측). 그동안 그림은 끌기 전의 폭으로 그려진다 — 놓으면 맞춰진다.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let before = textView.textContainerInset
        updateTextInsets(viewWidth: newSize.width)
        guard textView.textContainerInset != before else { return }
        if isLiveResizing {
            restyleAfterLiveResize = true
        } else {
            restyleAll()
        }
    }

    private var isLiveResizing = false
    private var restyleAfterLiveResize = false

    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isLiveResizing = true
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isLiveResizing = false
        if restyleAfterLiveResize {
            restyleAfterLiveResize = false
            restyleAll()
        }
    }

    /// 스타일러가 센 코드 블록 범위를 그리는 쪽에 넘긴다. 배경은 글자의 성질이
    /// 아니라 블록의 성질이라 속성으로는 고르게 칠할 수 없다.
    private func syncCodeBlockBackgrounds() {
        textView.codeBlockColor = theme.codeBackground
        textView.codeBlockRanges = styler.codeBlockRanges
        textView.imagePlacements = styler.imagePlacements
    }

    /// 문서 위치를 알려 준다. 그림의 상대 경로를 푸는 기준이다.
    public var documentURL: URL? {
        get { styler.documentURL }
        set {
            guard styler.documentURL != newValue else { return }
            styler.documentURL = newValue
            imageStore.forget()
            restyleAll()
        }
    }

    // MARK: 다이어그램·수식

    /// `deinit`에서 지워야 해서 격리 밖에 둔다. 쓰는 곳은 메인 스레드뿐이다.
    nonisolated(unsafe) private var diagramObserver: NSObjectProtocol?

    deinit {
        if let diagramObserver { NotificationCenter.default.removeObserver(diagramObserver) }
    }

    /// 다이어그램·수식을 그릴 곳을 바꾼다. 앱은 `DiagramRenderer.shared`를 쓰고, 테스트가
    /// 저장소의 자원으로 만든 렌더러나 대역을 넣는다. nil이면 원문으로 둔다.
    func useDiagramRenderer(_ renderer: RenderedBlockImages?) {
        if let diagramObserver { NotificationCenter.default.removeObserver(diagramObserver) }
        diagramObserver = nil
        styler.renderedBlockImages = renderer
        if let renderer {
            // 그림은 나중에 도착한다. 이 문서에 블록이 있을 때만 다시 칠한다 — 다른 창의
            // 그림이 도착할 때마다 큰 문서를 칠하면 타이핑이 멈춘다.
            diagramObserver = NotificationCenter.default.addObserver(
                // 큐 없이 받는다 — 렌더러는 메인 액터에서 알리므로 그 자리에서 바로 칠한다.
                forName: DiagramRenderer.didRender, object: renderer, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.styler.renderedBlocks.isEmpty else { return }
                    self.restyleAll()
                }
            }
        }
        restyleAll()
    }

    /// 화면이 다크·라이트로 바뀌면 그림을 그 외관으로 다시 받는다(Mermaid 테마, 수식 색).
    /// 다른 색은 시스템 의미색이라 저절로 바뀐다.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard !styler.renderedBlocks.isEmpty else { return }
        restyleAll()
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 지금 그림으로 그려진 블록의 수. 테스트가 쓴다.
    var renderedImageCount: Int { styler.imagePlacements.count }

    private func restyleAll() {
        guard !isStyling else { return }
        if batchDepth > 0 {
            restyleAfterBatch = true
            return
        }
        isStyling = true
        fullRestyleCount += 1
        lastCaretLine = caretLine()
        styler.isDarkAppearance = isDarkAppearance
        styler.contentWidth = max(120, Double(container.size.width) - 24)
        styler.style(storage, caretLine: lastCaretLine, search: searchState, lines: currentLines())
        syncCodeBlockBackgrounds()
        isStyling = false
    }

    private func restyle(dirty range: NSRange) {
        guard !isStyling else { return }
        isStyling = true
        styler.isDarkAppearance = isDarkAppearance
        styler.style(storage, caretLine: caretLine(), search: searchState, dirtyRange: range,
                     lines: currentLines())
        syncCodeBlockBackgrounds()
        isStyling = false
    }

    /// Re-style only the two lines whose marker visibility can have flipped.
    private func restyleCaretTransition(from old: Int?, to new: Int?) {
        guard old != new else { return }
        let text = storage.string as NSString
        let lines = currentLines()
        var ranges: [NSRange] = []
        for line in [old, new].compactMap({ $0 }) {
            if let range = Self.rangeOfLine(line, in: lines, text: text) { ranges.append(range) }
        }
        guard !ranges.isEmpty else { return }
        isStyling = true
        for range in ranges {
            styler.style(storage, caretLine: new, search: searchState, dirtyRange: range,
                         lines: lines)
            syncCodeBlockBackgrounds()
        }
        isStyling = false
    }

    /// 줄 번호의 범위(줄바꿈 포함). 없는 줄이면 nil.
    static func rangeOfLine(_ line: Int, in lines: [LineToken], text: NSString) -> NSRange? {
        guard line > 0, line <= lines.count, lines[line - 1].lineNumber == line else { return nil }
        return text.lineRange(for: NSRange(location: lines[line - 1].range.location, length: 0))
    }
}

// MARK: - Editing commands

extension MarkdownEditorView {

    /// 편집 규칙이 계산한 편집을 적용한다. **모든 규칙 편집이 이 길을 지난다** — 그래야
    /// 실행 취소에 하나씩 실리고, 문서가 바뀐 것을 창(저장 표시·목차)이 안다.
    ///
    /// `shouldChangeText` → 바꾸기 → `didChangeText`는 `NSTextView`가 타이핑에 쓰는 순서와
    /// 같다. 앞의 것이 실행 취소를 등록하고, 뒤의 것이 `textDidChange`를 불러 편집기 대리자에게
    /// 알린다. 그 알림은 선택 근처만 다시 칠하므로, 편집이 여러 줄에 걸치면 그 범위를 더 칠한다.
    @discardableResult
    func perform(_ edit: TextEdit, actionName: String? = nil) -> Bool {
        guard NSMaxRange(edit.range) <= storage.length,
              textView.shouldChangeText(in: edit.range, replacementString: edit.replacement)
        else { return false }
        if actionName != nil { textView.breakUndoCoalescing() }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        let length = storage.length
        let selection = NSRange(location: min(edit.selection.location, length),
                                length: min(edit.selection.length, length - min(edit.selection.location, length)))
        textView.setSelectedRange(selection)
        textView.didChangeText()
        let start = min(edit.range.location, length)
        restyle(dirty: NSRange(location: start,
                               length: min((edit.replacement as NSString).length, length - start)))
        if let actionName {
            textView.undoManager?.setActionName(actionName)
            textView.breakUndoCoalescing()
        }
        textView.scrollRangeToVisible(selection)
        return true
    }

    /// 체크박스(`[ ]` · `[x]`)를 뒤집는다. `box`는 여는 대괄호의 위치다.
    @discardableResult
    func toggleTask(atBox box: Int) -> Bool {
        guard let edit = ListEditing.toggleTask(in: storage.string as NSString, box: box,
                                                selection: textView.selectedRange()) else { return false }
        return perform(edit, actionName: String(localized: "할 일 표시"))
    }

    /// 글자 위의 클릭. 보조 키 없는 클릭이 체크박스 위면 뒤집고, ⌘클릭이 링크 위면 연다.
    /// 나머지는 텍스트 뷰에 맡긴다(캐럿 놓기).
    func handleClick(at index: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard index < storage.length, !styler.codeView else { return false }
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        if flags.isEmpty, let box = storage.attribute(.mdTaskBox, at: index, effectiveRange: nil) as? Int {
            return toggleTask(atBox: box)
        }
        guard flags == .command else { return false }
        if let jump = storage.attribute(.mdFootnoteJump, at: index, effectiveRange: nil) as? String {
            return followFootnote(jump)
        }
        if let url = storage.attribute(.mdLinkTarget, at: index, effectiveRange: nil) as? String {
            editorDelegate?.markdownEditor(self, didClickLink: url)
            return true
        }
        return false
    }

    // MARK: 그림 넣기

    /// 대지의 그림을 문서에 넣는다 — 파일은 문서 옆 `<이름>.assets`로 복사하고(문서 폴더 안의
    /// 파일은 그 자리를 가리킨다), 그림 데이터는 PNG로 적는다. 그림마다 자기 줄 하나.
    ///
    /// 저장하지 않은 문서에는 넣지 않는다. 그림을 둘 폴더가 없고, 절대 경로로 적으면 문서를
    /// 옮기는 순간 깨진다. 그때는 먼저 저장하라고 알린다.
    ///
    /// - Returns: 대지에 그림이 없으면 false(평소의 붙여넣기·끌어놓기에 맡긴다).
    func insertImages(from pasteboard: NSPasteboard, replacing range: NSRange?, date: Date = Date()) -> Bool {
        let files = ImagePasteboard.imageFiles(in: pasteboard)
        let data = files.isEmpty ? ImagePasteboard.pngData(in: pasteboard) : nil
        guard !files.isEmpty || data != nil else { return false }
        guard let documentURL else {
            presentImageAlert(String(localized: "그림을 넣으려면 먼저 문서를 저장하세요"),
                              detail: String(localized: "그림은 문서 옆의 ‘문서 이름.assets’ 폴더에 복사됩니다."))
            return true
        }
        let importer = ImageImporter(documentURL: documentURL)
        var lines: [String] = []
        do {
            for file in files { lines.append(try importer.importFile(file)) }
            if let data { lines.append(try importer.importImage(png: data, date: date)) }
        } catch {
            AppLog.error(String(localized: "그림을 넣지 못했습니다"), detail: error.localizedDescription)
            presentImageAlert(String(localized: "그림을 넣지 못했습니다"), detail: error.localizedDescription)
            return true
        }
        let target = range ?? textView.selectedRange()
        let edit = ImageAttachment.insertion(lines, replacing: target, in: storage.string as NSString)
        perform(edit, actionName: String(localized: "그림 넣기"))
        AppLog.info(String(localized: "그림 \(lines.count)개를 넣었습니다"), detail: lines.joined(separator: "\n"))
        return true
    }

    private func presentImageAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: 각주

    /// 각주 참조 ⌘클릭 → 정의 줄의 글 앞, 정의의 라벨 ⌘클릭 → 그 각주의 첫 참조 뒤.
    /// 값은 스타일러가 단 `.mdFootnoteJump`다.
    @discardableResult
    func followFootnote(_ jump: String) -> Bool {
        let text = storage.string as NSString
        let lines = currentLines()
        let definitions = LinkDefinitions(scanning: text, lines: lines)
        let target: Int?
        if jump.hasPrefix("definition:") {
            let label = String(jump.dropFirst("definition:".count))
            target = definitions.footnoteDefinitionLocation(label).flatMap { location in
                lines.first { $0.range.location == location }?.contentRange.location
            }
        } else if jump.hasPrefix("reference:") {
            target = Self.firstFootnoteReference(String(jump.dropFirst("reference:".count)),
                                                 in: text, lines: lines, definitions: definitions)
        } else {
            target = nil
        }
        guard let target, target <= storage.length else { return false }
        let range = NSRange(location: target, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        return true
    }

    /// 각주 `label`을 가리키는 첫 참조의 끝. 문서 순서로 찾는다(코드 블록 안은 보지 않는다 —
    /// 줄 판정이 이미 가렸다).
    static func firstFootnoteReference(_ label: String, in text: NSString, lines: [LineToken],
                                       definitions: LinkDefinitions) -> Int? {
        let wanted = LinkDefinitions.normalize(label)
        let syntax = MarkdownSyntax()
        for line in lines where line.contentRange.length > 0 {
            switch line.kind {
            case .codeFence, .codeBody, .linkDefinition, .thematicBreak, .tableDelimiter,
                 .setextUnderline, .blank:
                continue
            default:
                break
            }
            for token in syntax.scanInline(in: text, range: line.contentRange, definitions: definitions) {
                if case let .footnoteReference(found) = token.kind, LinkDefinitions.normalize(found) == wanted {
                    return NSMaxRange(token.range)
                }
            }
        }
        return nil
    }

    // MARK: 줄 편집 (메뉴의 편집 ▸ 줄)

    @objc func moveLinesUpAction(_ sender: Any?) {
        runLineEdit(LineEditing.moveUp, name: String(localized: "줄 옮기기"))
    }

    @objc func moveLinesDownAction(_ sender: Any?) {
        runLineEdit(LineEditing.moveDown, name: String(localized: "줄 옮기기"))
    }

    @objc func duplicateLinesAction(_ sender: Any?) {
        runLineEdit(LineEditing.duplicate, name: String(localized: "줄 복제"))
    }

    @objc func deleteLinesAction(_ sender: Any?) {
        runLineEdit(LineEditing.delete, name: String(localized: "줄 지우기"))
    }

    private func runLineEdit(_ rule: (NSString, NSRange) -> TextEdit?, name: String) {
        guard !textView.hasMarkedText(),
              let edit = rule(storage.string as NSString, textView.selectedRange()) else {
            NSSound.beep()
            return
        }
        perform(edit, actionName: name)
    }
}

// MARK: - Text storage delegate

extension MarkdownEditorView: @preconcurrency NSTextStorageDelegate {

    /// 글자가 바뀌면 줄 표와 블록 표를 낡은 것으로 표시한다. 저장소가 바뀌는 **그 자리에서**
    /// 불리므로 어느 알림보다 먼저다. 스타일러가 속성만 바꾸는 편집은 건드리지 않는다.
    public func textStorage(_ textStorage: NSTextStorage,
                            didProcessEditing editedMask: NSTextStorageEditActions,
                            range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) {
            textDidEdit(range: editedRange, changeInLength: delta)
        }
    }
}

// MARK: - Text view delegate

extension MarkdownEditorView: NSTextViewDelegate {

    public func textDidChange(_ notification: Notification) {
        let edited = textView.selectedRange()
        // Widen by one character each way so a marker completed by this
        // keystroke (`**bold**`) is inside the restyled window.
        let dirty = NSRange(location: max(0, edited.location - 1),
                            length: min(storage.length - max(0, edited.location - 1), edited.length + 2))
        restyle(dirty: dirty)
        if searchState.ranges.isEmpty == false {
            // Matches moved; recompute rather than leave stale highlights.
            scheduleSearchRefresh()
        }
        editorDelegate?.markdownEditorDidChangeText(self)
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        let new = caretLine()
        restyleCaretTransition(from: lastCaretLine, to: new)
        lastCaretLine = new
    }

    /// Enter · Tab · ⇧Tab을 목록 규칙에 먼저 묻는다(`ListEditing`). 한글을 조합하는 중에는
    /// 묻지 않는다 — 그 Enter는 조합을 끝내는 키다.
    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let text = storage.string as NSString
        let selection = textView.selectedRange()
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            guard let edit = ListEditing.newline(in: text, selection: selection, lines: currentLines())
            else { return false }
            return perform(edit)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            let outdent = commandSelector == #selector(NSResponder.insertBacktab(_:))
            let result = ListEditing.indentation(in: text, selection: selection, lines: currentLines(),
                                                 outdent: outdent)
            guard result.handled else { return false }
            if let edit = result.edit {
                perform(edit, actionName: outdent ? String(localized: "내어쓰기") : String(localized: "들여쓰기"))
            }
            return true
        default:
            return false
        }
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? String {
            editorDelegate?.markdownEditor(self, didClickLink: url)
            return true
        }
        return false
    }

    private func scheduleSearchRefresh() {
        guard !pendingRestyle else { return }
        pendingRestyle = true
        let delay = DocumentSearch.debounce(forDocumentLength: storage.length)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pendingRestyle = false
            let text = self.storage.string as NSString
            self.searchState.ranges = DocumentSearch.matches(in: text, query: self.currentQuery)
            if let index = self.searchState.currentIndex, index >= self.searchState.ranges.count {
                self.searchState.currentIndex = self.searchState.ranges.isEmpty ? nil : 0
            }
            self.restyleAll()
        }
    }
}

// MARK: - Glyph hiding

extension MarkdownEditorView: @preconcurrency NSLayoutManagerDelegate {

    /// Where "the markers disappear" happens.
    ///
    /// A character carrying `.mdHiddenMarker` is reported as a CONTROL
    /// character, and the companion callback below gives control characters
    /// zero advancement — so the marker occupies no width while staying in the
    /// document. The obvious-looking alternative, handing back the `.null`
    /// glyph property, measurably corrupts the character-to-glyph mapping for
    /// the rest of the run: with `.null` on the `# ` of a heading, the text
    /// after the first word stopped being drawn at all.
    public func layoutManager(_ layoutManager: NSLayoutManager,
                              shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                              properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                              characterIndexes charIndexes: UnsafePointer<Int>,
                              font aFont: NSFont,
                              forGlyphRange glyphRange: NSRange) -> Int {
        let count = glyphRange.length
        var adjusted = [NSLayoutManager.GlyphProperty](repeating: [], count: count)
        var changed = false

        for i in 0 ..< count {
            adjusted[i] = props[i]
            let charIndex = charIndexes[i]
            guard charIndex < storage.length else { continue }
            if storage.attribute(.mdHiddenMarker, at: charIndex, effectiveRange: nil) != nil {
                adjusted[i].insert(.controlCharacter)
                changed = true
            }
        }

        guard changed else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: &adjusted, characterIndexes: charIndexes,
                                font: aFont, forGlyphRange: glyphRange)
        return count
    }

    public func layoutManager(_ layoutManager: NSLayoutManager,
                              shouldUse action: NSLayoutManager.ControlCharacterAction,
                              forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if charIndex < storage.length,
           storage.attribute(.mdHiddenMarker, at: charIndex, effectiveRange: nil) != nil {
            return .zeroAdvancement
        }
        return action
    }
}
