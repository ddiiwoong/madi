import AppKit

@MainActor
public protocol BlockContainerDelegate: AnyObject {
    func blockContainerDidChangeText(_ container: BlockContainerView)
    func blockContainer(_ container: BlockContainerView, didClickLink url: String)
}

/// 블록 편집기의 컨테이너 — `docs/block-editor-design.md` §4.
///
/// 문서를 블록의 배열로 들고, **보이는 블록만** 뷰를 만들어 수직으로 쌓는다.
/// `NSStackView`를 쓰지 않는 이유는 설계가 적은 그대로다: 내재 크기를 가진 자식을
/// 늘려 주지 않고, 수백 블록의 레이아웃을 전부 들고 있는 비용이 크다.
///
/// ## 설계와 다르게 한 것 — `SelectionCoordinator`를 별도 객체로 두지 않았다
///
/// 설계 §5.1은 코디네이터 객체를 적었다. 실제로 짜 보니 그 객체가 들 **상태**는 이미
/// 순수 모델에 있고(`BlockSelection` · `BlockInputGuard` · `BlockEdit`), 남는 일은
/// "그 상태를 블록 뷰에 전하고 first responder를 옮기는 것"뿐이다. 그 일은 뷰를
/// 들고 있는 컨테이너만 할 수 있어서, 객체를 하나 더 두면 양방향 배선만 늘어난다.
/// 테스트가 필요한 판단은 전부 Core의 순수 타입에 있고 `make core-only`가 지킨다.
@MainActor
public final class BlockContainerView: NSView {

    public weak var containerDelegate: BlockContainerDelegate?

    private let scrollView = NSScrollView()
    private let canvas = BlockCanvasView()

    private let parser = BlockParser()
    private let serializer = BlockSerializer()
    private let factory = BlockEditFactory()
    private let styler = MarkdownStyler()
    private let imageStore = InlineImageStore()

    private var theme = MarkdownTheme() {
        didSet { styler.theme = theme }
    }

    private var document = BlockDocument(frontMatter: nil, blocks: [])
    /// 블록 사이 간격은 0이다 — 마크다운의 빈 줄이 이미 간격을 만들고, 거기에
    /// 더하면 기존 편집기보다 문서가 성겨진다(끝 조건은 "지금과 동작이 같다").
    private var geometry = BlockViewportLayout(spacing: 0, overscan: 320)
    private var placements: [BlockViewportLayout.Placement] = []
    /// 잰 높이. 아직 뷰를 가져 보지 않은 블록은 어림값으로 쌓는다.
    private var measured: [Block.ID: Double] = [:]
    private var activeViews: [Block.ID: ParagraphBlockView] = [:]
    private var pool: [ParagraphBlockView] = []

    private var selection = BlockSelection(caretAt: BlockPosition(blockIndex: 0, offset: 0))
    private var inputGuard = BlockInputGuard()
    private var focusedBlockID: Block.ID?
    private var isRebuilding = false
    /// `syncViews`가 자기를 다시 부르는 깊이. 잰 높이로 자리를 고치면 새로 보이는
    /// 블록이 생길 수 있어 한 번 더 돌지만, 끝없이 돌지는 않게 가둔다.
    private var syncDepth = 0
    /// 뷰에 선택을 싣는 중인가. 그 동안 뷰가 돌려주는 선택 변경 신호를 무시해야
    /// 블록을 넘는 선택이 한 블록으로 줄어들지 않는다.
    private var isApplyingSelection = false
    /// 한글 조합 중에 미뤄 둔 편집(설계 §5.4). 조합이 끝나면 반드시 실린다 —
    /// 떨어뜨리면 사용자가 친 글자가 모델에 없는 채 화면에만 남는다.
    private var pendingSource: (index: Int, source: String, caret: Int)?

    /// 문서 레벨 되돌리기 — 설계 §5.2. 블록 뷰들의 undo는 모두 꺼져 있고 ⌘Z는
    /// 이 스택만 본다.
    public let documentUndoManager = UndoManager()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        styler.theme = theme
        styler.imageStore = imageStore
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func configure() {
        canvas.container = self
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 굴릴 때마다 보이는 범위를 다시 세어 뷰를 붙이고 뗀다.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportMoved),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    @objc private func viewportMoved() {
        syncViews()
    }

    public override func layout() {
        super.layout()
        relayout(remeasureAll: true)
    }

    // MARK: 내용

    /// 본문 마크다운. front matter는 창이 이미 갈라 두었으므로 여기는 본문만 받는다.
    public var markdown: String {
        get { serializer.serialize(document) }
        set {
            guard newValue != serializer.serialize(document) else { return }
            document = BlockDocument(frontMatter: nil, blocks: parser.parseBlocks(newValue))
            measured.removeAll()
            selection = BlockSelection(caretAt: BlockPosition(blockIndex: 0, offset: 0))
            documentUndoManager.removeAllActions()
            detachAllViews()
            relayout(remeasureAll: true)
        }
    }

    public var blockCount: Int { document.blocks.count }

    public var documentURL: URL? {
        get { styler.documentURL }
        set {
            guard styler.documentURL != newValue else { return }
            styler.documentURL = newValue
            imageStore.forget()
            relayout(remeasureAll: true)
        }
    }

    public func apply(_ preferences: EditorPreferences) {
        theme.bodyPointSize = preferences.bodyPointSize
        styler.highlightsCode = preferences.highlightCode
        styler.alignsTables = preferences.alignTables
        styler.appliesSyntheticSlant = preferences.syntheticSlant
        measured.removeAll()
        relayout(remeasureAll: true)
    }

    /// 블록 종류별 개수 — 진단과 측정에 쓴다.
    public var blockKindSummary: [String: Int] {
        var out: [String: Int] = [:]
        for block in document.blocks {
            let key: String
            switch block.kind {
            case .paragraph: key = "paragraph"
            case .heading: key = "heading"
            case .quote: key = "quote"
            case .list: key = "list"
            case .codeBlock: key = "codeBlock"
            case .table: key = "table"
            case .thematicBreak: key = "thematicBreak"
            case .blankLines: key = "blankLines"
            }
            out[key, default: 0] += 1
        }
        return out
    }

    /// 지금 뷰를 가진 블록 수. 가시 범위 재사용이 실제로 동작하는지 재는 값이다.
    public var liveViewCount: Int { activeViews.count }

    // MARK: 레이아웃

    private var contentWidth: Double {
        Double(max(200, scrollView.contentSize.width)) - Double(theme.textInsets.width) * 2
    }

    /// 아직 재 보지 않은 블록의 높이 어림값. 줄 수로 센다 — 문서를 열자마자 스크롤
    /// 길이가 대충이라도 맞아야 굴릴 수 있고, 보이는 블록은 곧 실제 높이로 바뀐다.
    private func estimatedHeight(_ block: Block) -> Double {
        let lines = max(1, block.sourceSlice.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        } - (block.sourceSlice.hasSuffix("\n") ? 1 : 0))
        let lineHeight = Double(theme.bodyPointSize) * 1.55
        switch block.kind {
        case .heading(let level):
            let scale = Double(MarkdownTheme.headingScale[max(1, min(6, level)) - 1])
            return lineHeight * scale + 8
        case .blankLines:
            return Double(lines) * lineHeight * 0.6
        default:
            return Double(lines) * lineHeight
        }
    }

    private func height(of block: Block) -> Double {
        measured[block.id] ?? estimatedHeight(block)
    }

    private func relayout(remeasureAll: Bool) {
        guard !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        if remeasureAll { measured.removeAll() }

        let heights = document.blocks.map(height(of:))
        placements = geometry.placements(heights: heights)
        let total = geometry.totalHeight(heights: heights)
        canvas.frame = NSRect(x: 0, y: 0,
                              width: max(scrollView.contentSize.width, 1),
                              height: max(total + Double(theme.textInsets.height) * 2, 1))
        syncViews()
    }

    /// 보이는 블록에 뷰를 붙이고 벗어난 것은 뗀다.
    private func syncViews() {
        guard !document.blocks.isEmpty else { return detachAllViews() }
        let visibleRect = scrollView.contentView.bounds
        let inset = Double(theme.textInsets.height)
        let visible = geometry.visible(placements: placements,
                                       visibleOrigin: Double(visibleRect.minY) - inset,
                                       visibleHeight: Double(visibleRect.height))

        var wanted = Set<Block.ID>()
        var heightChanged = false

        for placement in visible {
            guard document.blocks.indices.contains(placement.blockIndex) else { continue }
            let block = document.blocks[placement.blockIndex]
            wanted.insert(block.id)

            let view = activeViews[block.id] ?? takeFromPool()
            activeViews[block.id] = view
            if view.superview == nil { canvas.addSubview(view) }

            let width = contentWidth
            view.frame = NSRect(x: Double(theme.textInsets.width),
                                y: placement.y + inset,
                                width: width, height: placement.height)
            if view.blockID != block.id || view.source != block.sourceSlice {
                view.owner = self
                view.show(block: block, index: placement.blockIndex, width: width,
                          isFocusedBlock: block.id == focusedBlockID)
            } else {
                view.blockIndexDidMove(to: placement.blockIndex)
            }

            let real = view.fittingHeight(width: width)
            if abs(real - placement.height) > 0.5 {
                measured[block.id] = real
                heightChanged = true
            } else {
                measured[block.id] = real
            }
            view.frame.size.height = real
            isApplyingSelection = true
            view.apply(coverage: selection.coverage(ofBlockAt: placement.blockIndex))
            isApplyingSelection = false
        }

        for (id, view) in activeViews where !wanted.contains(id) {
            // first responder를 들고 있는 뷰는 떼지 않는다 — 떼는 순간 캐럿과
            // 조합 중인 글자가 사라진다.
            if id == focusedBlockID { continue }
            view.removeFromSuperview()
            view.owner = nil
            activeViews.removeValue(forKey: id)
            if pool.count < 24 { pool.append(view) }
        }

        // 잰 높이가 어림값과 달랐다. 자리를 다시 잡는다.
        //
        // `isRebuilding`으로 막지 않는다 — 이 패스는 `relayout`을 다시 부르지 않고
        // 좌표만 고치므로 재귀가 아니다. 막아 두었을 때, `relayout`에서 들어온
        // 호출(문서를 처음 실을 때)이 이 패스를 건너뛰어 **블록들이 서로 겹쳤다**:
        // 자리는 어림값으로 잡히고 높이는 잰 값으로 들어가 제목(y=56, 높이 76)
        // 아래로 다음 블록이 y=113에 앉았다.
        if heightChanged {
            let heights = document.blocks.map(height(of:))
            placements = geometry.placements(heights: heights)
            let total = geometry.totalHeight(heights: heights)
            canvas.frame.size.height = max(total + Double(theme.textInsets.height) * 2, 1)
            for placement in placements {
                guard document.blocks.indices.contains(placement.blockIndex),
                      let view = activeViews[document.blocks[placement.blockIndex].id] else { continue }
                view.frame.origin.y = placement.y + inset
            }
            // 높이가 늘어 새로 보이게 된 블록이 있을 수 있다. 한 번만 더 돈다 —
            // 두 번째에는 잰 값이 캐시에 있어 `heightChanged`가 거짓이다.
            if syncDepth < 2 {
                syncDepth += 1
                syncViews()
                syncDepth -= 1
            }
        }
    }

    private func takeFromPool() -> ParagraphBlockView {
        if let view = pool.popLast() { return view }
        let view = ParagraphBlockView(styler: styler)
        view.owner = self
        return view
    }

    private func detachAllViews() {
        for (_, view) in activeViews {
            view.removeFromSuperview()
            view.owner = nil
        }
        activeViews.removeAll()
        pool.removeAll()
    }

    // MARK: 편집

    /// 편집을 문서에 싣고 되돌리기에 등록한다. **모든** 편집이 이 길을 지난다.
    private func perform(_ edit: BlockEdit, caretOffsetWithinNew: Int?) {
        guard !edit.isNoop else { return }
        let inverse = edit.inverted()
        var caretBefore = selection.start

        guard edit.apply(to: &document) else { return }

        documentUndoManager.setActionName(edit.name)
        documentUndoManager.registerUndo(withTarget: self) { target in
            // 되돌리기도 같은 길을 지난다 — 그래서 다시 하기(⌘⇧Z)가 공짜로 생긴다.
            target.perform(inverse, caretOffsetWithinNew: 0)
        }

        if let offset = caretOffsetWithinNew {
            let position = BlockEdit.position(forOffset: offset, within: edit.new,
                                              firstBlockIndex: edit.range.lowerBound)
            caretBefore = position
        } else {
            let clamped = min(caretBefore.blockIndex, max(0, document.blocks.count - 1))
            caretBefore = BlockPosition(blockIndex: clamped, offset: caretBefore.offset)
        }
        selection = BlockSelection(caretAt: caretBefore)

        rebuildAfterStructureChange(focus: caretBefore)
        containerDelegate?.blockContainerDidChangeText(self)
    }

    /// 블록 개수나 종류가 바뀐 뒤 뷰를 다시 세우고 캐럿을 놓는다.
    private func rebuildAfterStructureChange(focus position: BlockPosition) {
        guard document.blocks.indices.contains(position.blockIndex) else {
            detachAllViews()
            relayout(remeasureAll: false)
            return
        }
        let targetID = document.blocks[position.blockIndex].id
        // 식별자가 사라진 뷰를 모두 뗀다(남겨 두면 없는 블록을 그린다).
        let liveIDs = Set(document.blocks.map(\.id))
        for (id, view) in activeViews where !liveIDs.contains(id) {
            view.removeFromSuperview()
            view.owner = nil
            activeViews.removeValue(forKey: id)
        }
        focusedBlockID = targetID
        relayout(remeasureAll: false)
        if let view = activeViews[targetID] {
            view.placeCaret(atOffset: position.offset)
            window?.makeFirstResponder(view.textView)
        }
    }

    // MARK: 선택 · 복사

    public func selectAll() {
        guard let last = document.blocks.indices.last else { return }
        let end = (document.blocks[last].sourceSlice as NSString).length
        selection = BlockSelection(anchor: BlockPosition(blockIndex: 0, offset: 0),
                                   head: BlockPosition(blockIndex: last, offset: end))
        applySelectionToViews()
    }

    public var selectedMarkdown: String { selection.markdown(in: document.blocks) }
    public var selectionSpansBlocks: Bool { !selection.isWithinOneBlock && !selection.isCollapsed }

    public func copySelection() {
        let text = selectedMarkdown
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 블록을 넘는 선택을 지운다. 걸친 블록들을 한 조각으로 합쳐 다시 읽는다.
    public func deleteSelectionAcrossBlocks() {
        guard selectionSpansBlocks,
              let edit = factory.deletion(in: document, selection: selection) else { return }
        let offset = selection.start.offset
        perform(edit, caretOffsetWithinNew: offset)
    }

    /// 블록 처음에서 Backspace — 앞 블록의 **마지막 글자 하나**를 지운다. 그 글자가
    /// 줄바꿈이라 두 블록이 합쳐진다.
    ///
    /// 한 글자 물러서는 것이 요점이다. 앞 블록의 끝과 이 블록의 0 사이에는 글자가
    /// 없어서, 그 둘을 선택하면 **아무것도 지우지 않는 편집**이 된다. 실측으로
    /// 잡았다: 빈 줄 뒤 문단의 처음에서 Backspace를 눌렀을 때 문서가 한 바이트도
    /// 바뀌지 않았고, 합치기가 참을 돌려줘 `NSTextView`의 기본 동작까지 막혔다.
    ///
    /// 뒤로 한 칸이 아니라 **한 글자**를 센다 — UTF-16 한 칸은 이모지나 결합 문자를
    /// 반 토막 낸다. 아무것도 바꾸지 않는 편집이면 거짓을 돌려줘 텍스트 뷰가
    /// 평소대로 처리하게 한다.
    @discardableResult
    func mergeWithPreviousBlock(from textView: BlockTextView) -> Bool {
        guard let view = textView.blockOwner, let index = index(of: view), index > 0 else {
            return false
        }
        let previous = document.blocks[index - 1].sourceSlice as NSString
        guard previous.length > 0 else { return false }
        let lastCharacter = previous.rangeOfComposedCharacterSequence(at: previous.length - 1)
        let span = BlockSelection(anchor: BlockPosition(blockIndex: index - 1,
                                                       offset: lastCharacter.location),
                                  head: BlockPosition(blockIndex: index, offset: 0))
        guard let edit = factory.deletion(in: document, selection: span, name: "합치기"),
              !edit.isNoop else { return false }
        perform(edit, caretOffsetWithinNew: lastCharacter.location)
        return true
    }

    /// Shift+방향키로 선택을 옆 블록까지 늘린다. 늘릴 블록이 없으면 거짓.
    @discardableResult
    func extendSelection(from view: ParagraphBlockView,
                         direction: BlockCaretNavigation.Direction) -> Bool {
        guard inputGuard.allowsBoundaryMove, let index = index(of: view),
              let target = BlockCaretNavigation.target(from: selection.head.blockIndex == index
                                                        ? index : selection.head.blockIndex,
                                                       direction: direction,
                                                       blockCount: document.blocks.count)
        else { return false }
        let length = (document.blocks[target.blockIndex].sourceSlice as NSString).length
        selection = BlockSelection(anchor: selection.anchor,
                                   head: BlockPosition(blockIndex: target.blockIndex,
                                                       offset: target.edge == .top ? length : 0))
        applySelectionToViews()
        return true
    }

    private func applySelectionToViews() {
        // 뷰에 선택을 싣는 동안 그 뷰가 돌려주는 선택 변경 신호를 무시한다.
        //
        // 이것을 막지 않으면 블록을 넘는 선택이 **싣는 순간 한 블록으로 줄어든다**:
        // `apply(coverage:)`가 `setSelectedRange`를 부르면 `NSTextView`가
        // `textViewDidChangeSelection`을 내고, 그 콜백이 모델 선택을 "이 블록 안의
        // 범위"로 다시 쓴다. 실측으로 잡았다 — ⌘A 뒤 ⌘C가 문서 전체가 아니라
        // 캐럿이 있던 블록 18바이트만 복사했다.
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        for placement in placements {
            guard document.blocks.indices.contains(placement.blockIndex),
                  let view = activeViews[document.blocks[placement.blockIndex].id] else { continue }
            view.apply(coverage: selection.coverage(ofBlockAt: placement.blockIndex))
        }
    }

    private func index(of view: ParagraphBlockView) -> Int? {
        guard let id = view.blockID else { return nil }
        return document.blocks.firstIndex { $0.id == id }
    }
}

// MARK: - 블록 뷰에서 올라오는 신호

extension BlockContainerView: BlockViewOwner {

    func blockView(_ view: ParagraphBlockView, didChangeSource source: String) {
        guard let index = index(of: view) else { return }
        let caret = view.textView.selectedRange().location

        // 조합 중이면 구조를 건드리지 않는다(설계 §5.4). 글자는 이미 뷰에 들어가
        // 있고, 모델에 싣는 일만 조합이 끝날 때까지 미룬다.
        guard let edit = factory.textEdit(in: document, blockIndex: index, newSource: source)
        else { return }

        let isStructural = edit.new.count != 1
        if isStructural, !inputGuard.requestStructureChange() {
            pendingSource = (index, source, caret)
            return
        }
        if isStructural {
            perform(edit, caretOffsetWithinNew: caret)
        } else {
            // 블록 하나로 남는 편집은 뷰를 다시 세울 필요가 없다 — 글자는 이미
            // 뷰에 있고 모델만 따라간다. 그래서 조합 중에도 안전하다.
            applyWithoutRebuild(edit, blockIndex: index, view: view)
        }
    }

    /// 뷰를 그대로 두고 모델만 갱신한다. 한 글자 칠 때마다 뷰를 다시 세우면 캐럿과
    /// 조합이 날아가므로, 블록 하나로 남는 편집은 이 길을 쓴다.
    private func applyWithoutRebuild(_ edit: BlockEdit, blockIndex: Int,
                                     view: ParagraphBlockView) {
        let inverse = edit.inverted()
        guard edit.apply(to: &document) else { return }
        documentUndoManager.setActionName(edit.name)
        documentUndoManager.registerUndo(withTarget: self) { target in
            target.perform(inverse, caretOffsetWithinNew: 0)
        }
        // 종류가 바뀌었을 수 있다(`## `을 쳐서 제목이 됐다) — 다시 칠한다.
        view.show(block: document.blocks[blockIndex], index: blockIndex,
                  width: contentWidth, isFocusedBlock: true)
        view.placeCaret(atOffset: view.textView.selectedRange().location)
        syncViews()
        containerDelegate?.blockContainerDidChangeText(self)
    }

    func blockView(_ view: ParagraphBlockView, didChangeSelection range: NSRange) {
        guard !isApplyingSelection, let index = index(of: view) else { return }
        guard view.textView == window?.firstResponder else { return }
        selection = BlockSelection(anchor: BlockPosition(blockIndex: index, offset: range.location),
                                   head: BlockPosition(blockIndex: index,
                                                       offset: range.location + range.length))
        // 캐럿이 움직이면 마커 보임이 달라진다 — 그 블록만 다시 칠한다.
        view.restyle(width: contentWidth, isFocusedBlock: true)
    }

    func blockView(_ view: ParagraphBlockView,
                   didMoveCaretBeyond direction: BlockCaretNavigation.Direction) {
        guard inputGuard.allowsBoundaryMove, let index = index(of: view),
              let target = BlockCaretNavigation.target(from: index, direction: direction,
                                                       blockCount: document.blocks.count)
        else { return }
        focus(blockIndex: target.blockIndex, edge: target.edge)
    }

    func blockViewDidChangeCompositionState(_ view: ParagraphBlockView) {
        inputGuard.setComposing(view.isComposing)
        guard inputGuard.takePendingStructureChange(), let pending = pendingSource else { return }
        pendingSource = nil
        guard document.blocks.indices.contains(pending.index),
              let edit = factory.textEdit(in: document, blockIndex: pending.index,
                                          newSource: pending.source) else { return }
        perform(edit, caretOffsetWithinNew: pending.caret)
    }

    func blockViewDidBecomeFocused(_ view: ParagraphBlockView) {
        guard let id = view.blockID, focusedBlockID != id else { return }
        let previous = focusedBlockID
        focusedBlockID = id
        if let previous, let old = activeViews[previous] {
            // 캐럿이 떠난 블록은 마커를 다시 숨긴다.
            old.restyle(width: contentWidth, isFocusedBlock: false)
        }
        view.restyle(width: contentWidth, isFocusedBlock: true)
    }

    func blockView(_ view: ParagraphBlockView, didClickLink url: String) {
        containerDelegate?.blockContainer(self, didClickLink: url)
    }

    /// 블록에 캐럿을 놓는다. 보이지 않는 블록이면 먼저 보이게 굴린다.
    func focus(blockIndex: Int, edge: BlockCaretNavigation.Edge) {
        guard document.blocks.indices.contains(blockIndex),
              placements.indices.contains(blockIndex) else { return }
        let placement = placements[blockIndex]
        scrollView.contentView.scrollToVisible(
            NSRect(x: 0, y: placement.y, width: 1, height: max(placement.height, 1)))
        syncViews()
        let id = document.blocks[blockIndex].id
        guard let view = activeViews[id] else { return }
        focusedBlockID = id
        view.placeCaret(at: edge)
        window?.makeFirstResponder(view.textView)
        selection = BlockSelection(caretAt: BlockPosition(
            blockIndex: blockIndex,
            offset: edge == .top ? 0 : (document.blocks[blockIndex].sourceSlice as NSString).length))
    }
}

/// 블록 뷰들이 앉는 바탕. 위에서부터 쌓으므로 뒤집힌 좌표를 쓴다.
@MainActor
final class BlockCanvasView: NSView {
    weak var container: BlockContainerView?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
