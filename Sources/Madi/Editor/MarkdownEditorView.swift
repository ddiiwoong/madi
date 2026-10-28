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

    public let textView: DecoratedTextView
    private let scrollView = NSScrollView()
    private let storage = NSTextStorage()
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
        textView = DecoratedTextView(frame: frameRect, textContainer: container)
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func configure() {
        layout.delegate = self
        styler.theme = theme
        styler.imageStore = imageStore
        // 원격 그림은 나중에 도착한다. 도착하면 자리를 잡아야 하므로 다시 칠한다.
        imageStore.onRemoteImageLoaded = { [weak self] in self?.restyleAll() }

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
            invalidateBlocks()
            restyleAll()
            let clamped = min(selected.location, storage.length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
        }
    }

    public var outline: [OutlineEntry] {
        Outline.entries(in: storage.string as NSString)
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

    private func caretLine() -> Int? {
        let selection = textView.selectedRange()
        guard selection.location <= storage.length else { return nil }
        let text = storage.string as NSString
        var line = 1
        var index = 0
        while index < selection.location, index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            if NSMaxRange(lineRange) > selection.location { break }
            index = NSMaxRange(lineRange)
            line += 1
        }
        return line
    }

    /// 설정을 싣는다. 설정 화면의 각 항목이 여기서 실제 코드 경로로 이어진다.
    public func apply(_ preferences: EditorPreferences) {
        theme.bodyPointSize = preferences.bodyPointSize      // didSet이 스타일러에 넘긴다
        theme.lineSpacingScale = preferences.lineSpacing.scale
        theme.documentWidthMultiple = preferences.documentWidth.multipleOfBodySize
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
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let before = textView.textContainerInset
        updateTextInsets(viewWidth: newSize.width)
        if textView.textContainerInset != before { restyleAll() }
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

    private func restyleAll() {
        guard !isStyling else { return }
        isStyling = true
        lastCaretLine = caretLine()
        styler.contentWidth = max(120, Double(container.size.width) - 24)
        styler.style(storage, caretLine: lastCaretLine, search: searchState)
        syncCodeBlockBackgrounds()
        isStyling = false
    }

    private func restyle(dirty range: NSRange) {
        guard !isStyling else { return }
        isStyling = true
        styler.style(storage, caretLine: caretLine(), search: searchState, dirtyRange: range)
        syncCodeBlockBackgrounds()
        isStyling = false
    }

    /// Re-style only the two lines whose marker visibility can have flipped.
    private func restyleCaretTransition(from old: Int?, to new: Int?) {
        guard old != new else { return }
        let text = storage.string as NSString
        var ranges: [NSRange] = []
        for line in [old, new].compactMap({ $0 }) {
            if let range = rangeOfLine(line, in: text) { ranges.append(range) }
        }
        guard !ranges.isEmpty else { return }
        isStyling = true
        for range in ranges {
            styler.style(storage, caretLine: new, search: searchState, dirtyRange: range)
            syncCodeBlockBackgrounds()
        }
        isStyling = false
    }

    private func rangeOfLine(_ line: Int, in text: NSString) -> NSRange? {
        guard line > 0 else { return nil }
        var current = 1
        var index = 0
        while index <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
            if current == line { return lineRange }
            if NSMaxRange(lineRange) <= index { return nil }
            index = NSMaxRange(lineRange)
            current += 1
        }
        return nil
    }
}

// MARK: - Text view delegate

extension MarkdownEditorView: NSTextViewDelegate {

    public func textDidChange(_ notification: Notification) {
        invalidateBlocks()
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
