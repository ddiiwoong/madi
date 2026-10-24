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

    public let textView: CodeBlockBackgroundTextView
    private let scrollView = NSScrollView()
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container: NSTextContainer
    private let styler = MarkdownStyler()
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
        textView = CodeBlockBackgroundTextView(frame: frameRect, textContainer: container)
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func configure() {
        layout.delegate = self
        styler.theme = theme

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
        styler.highlightsCode = preferences.highlightCode
        styler.alignsTables = preferences.alignTables
        styler.appliesSyntheticSlant = preferences.syntheticSlant
        textView.textContainerInset = theme.textInsets
        textView.insertionPointColor = theme.insertionPoint
        restyleAll()
    }

    /// 스타일러가 센 코드 블록 범위를 그리는 쪽에 넘긴다. 배경은 글자의 성질이
    /// 아니라 블록의 성질이라 속성으로는 고르게 칠할 수 없다.
    private func syncCodeBlockBackgrounds() {
        textView.codeBlockColor = theme.codeBackground
        textView.codeBlockRanges = styler.codeBlockRanges
    }

    private func restyleAll() {
        guard !isStyling else { return }
        isStyling = true
        lastCaretLine = caretLine()
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
