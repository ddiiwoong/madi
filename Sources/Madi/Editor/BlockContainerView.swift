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

    /// 이어지는 타이핑 한 줄기. ⌘Z 한 번이 런 전체를 되돌리게 한다.
    ///
    /// 왜 `NSUndoManager`의 묶음(`beginUndoGrouping`)을 쓰지 않는가: 묶음이 열려 있는
    /// 동안은 `canUndo`가 거짓이라 **타이핑 중에 ⌘Z가 비활성**이 된다. 그래서 런이
    /// 시작할 때 되돌리기를 **한 번만** 등록하고, 그 되돌리기가 실행될 때 현재 상태에서
    /// 역산해 런의 시작으로 돌려놓는다 — 런이 길어져도 등록은 하나다.
    ///
    /// 참조 타입이어야 한다. 등록한 클로저가 이 객체를 잡고 있고, 그 뒤의 타이핑이
    /// `endCaret`을 고쳐도 같은 객체를 봐야 한다.
    private final class TypingRun {
        let blockIndex: Int
        /// 런이 시작할 때 그 자리에 있던 블록. 되돌리기가 이것으로 돌려놓는다.
        let startBlocks: [Block]
        /// 런이 시작하기 전의 캐럿.
        let caretOnUndo: BlockPosition
        /// 런의 마지막 캐럿. 다음 편집이 이어지는지 가린다.
        var endCaret: Int
        let name: String

        init(blockIndex: Int, startBlocks: [Block], caretOnUndo: BlockPosition,
             endCaret: Int, name: String) {
            self.blockIndex = blockIndex
            self.startBlocks = startBlocks
            self.caretOnUndo = caretOnUndo
            self.endCaret = endCaret
            self.name = name
        }
    }

    private var typingRun: TypingRun?


    /// 런을 닫는다. 다음 타이핑은 새 되돌리기 단위가 된다.
    ///
    /// 닫아야 하는 자리: 구조를 바꾸는 편집, 되돌리기·다시 하기, 문서를 새로 싣기.
    ///
    /// **선택 변경으로는 닫지 않는다.** 처음에 그렇게 했다가 실패했다: 런을 세운 직후
    /// `show()`가 저장소를 다시 쓰면 선택이 0으로 갔다 돌아오고, 그 알림이 **나중에**
    /// 도착해 런을 끊는다. 플래그로 그 사이를 막아도 알림 전달 시점이 동기적이지
    /// 않아 새어 나갔다(다섯 글자에 ⌘Z 다섯 번이 그대로였다). 그래서 이어짐 판정을
    /// 전달 시점에 기대지 않는 **편집 시점**으로 옮겼다 — `caretBefore`가 런의 끝과
    /// 맞는지만 본다. 캐럿을 다른 곳으로 옮기고 치면 그 값이 어긋나 저절로 새 런이 된다.
    private func breakTypingRun() {
        typingRun = nil
    }

    /// 타이핑 런 하나를 되돌린다 — **현재 상태에서 역산**해 런의 시작으로 돌려놓는다.
    private func undoTypingRun(_ run: TypingRun) {
        guard document.blocks.indices.contains(run.blockIndex) else { return }
        let current = [document.blocks[run.blockIndex]]
        let edit = BlockEdit(range: run.blockIndex ..< (run.blockIndex + 1),
                             old: current, new: run.startBlocks, name: run.name)
        breakTypingRun()
        // `performUndo`를 지나므로 다시 하기(⌘⇧Z)도 한 번에 런 전체를 되살린다.
        performUndo(edit, placingCaretAt: run.caretOnUndo)
    }

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
            breakTypingRun()
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
    ///
    /// `restoring`은 **되돌릴 때 캐럿을 놓을 자리**다. MarkText(Muya)는 선택까지
    /// undo 스택에 함께 쌓아 경로로 되살린다(`src/history/index.ts`) — 그렇게 하지
    /// 않으면 긴 문단 가운데를 고치고 ⌘Z를 눌렀을 때 캐럿이 문단 처음으로 튄다.
    private func perform(_ edit: BlockEdit, caretOffsetWithinNew: Int?,
                         restoring caretOnUndo: BlockPosition? = nil) {
        guard !edit.isNoop else { return }
        let inverse = edit.inverted()
        var caretBefore = selection.start
        // 구조가 바뀌는 편집은 타이핑 런을 끊는다. 끊지 않으면 Enter 앞뒤의 타이핑이
        // 한 ⌘Z에 함께 되돌아간다.
        breakTypingRun()
        // 되돌릴 때 돌아갈 자리: 지금 캐럿이 있던 곳.
        let undoCaret = caretOnUndo ?? selection.start

        guard edit.apply(to: &document) else { return }

        documentUndoManager.setActionName(edit.name)
        documentUndoManager.registerUndo(withTarget: self) { [caretAfterUndo = undoCaret] target in
            // 되돌리기도 같은 길을 지난다 — 그래서 다시 하기(⌘⇧Z)가 공짜로 생긴다.
            // 되돌린 뒤의 캐럿은 **편집하던 자리**이고, 다시 하기로 돌아갈 자리는
            // 그때의 캐럿이다.
            target.performUndo(inverse, placingCaretAt: caretAfterUndo)
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

    /// 되돌리기 — 캐럿을 **편집하던 자리**에 놓는다.
    ///
    /// `perform`과 갈라 둔 이유: 되돌릴 때 캐럿이 갈 곳은 "새 블록 안의 오프셋"이
    /// 아니라 편집 전에 캐럿이 있던 자리다. 그 둘을 한 함수에 섞으면 어느 쪽
    /// 좌표계인지 호출하는 쪽이 매번 생각해야 한다.
    private func performUndo(_ edit: BlockEdit, placingCaretAt caret: BlockPosition) {
        guard !edit.isNoop else { return }
        let inverse = edit.inverted()
        let caretForRedo = caret
        // 되돌린 **뒤에** 치는 글자는 새 런이다. 되돌리기 자신이 런을 끊는다.
        breakTypingRun()
        guard edit.apply(to: &document) else { return }

        documentUndoManager.setActionName(edit.name)
        documentUndoManager.registerUndo(withTarget: self) { target in
            target.performUndo(inverse, placingCaretAt: caretForRedo)
        }

        let clampedBlock = min(max(0, caret.blockIndex), max(0, document.blocks.count - 1))
        let position = BlockPosition(blockIndex: clampedBlock, offset: caret.offset)
        selection = BlockSelection(caretAt: position)
        rebuildAfterStructureChange(focus: position)
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
        replaceSelectionAcrossBlocks(with: "", name: String(localized: "삭제"))
    }

    /// 블록을 넘는 선택을 글자로 바꾼다 — 치기·붙이기가 지나는 길이다.
    ///
    /// 블록마다 텍스트 뷰가 따로이므로 `insertText`에 맡기면 **자기 블록의 몫만**
    /// 지워지고 나머지 블록의 선택된 글이 남는다. 그래서 치기도 하나의 편집으로
    /// 여기서 처리한다(되돌리기도 한 번에 돌아간다).
    public func replaceSelectionAcrossBlocks(with text: String, name: String = String(localized: "입력")) {
        guard selectionSpansBlocks,
              let edit = factory.replacement(in: document, selection: selection,
                                             with: text, name: name) else { return }
        let caret = selection.start.offset + (text as NSString).length
        perform(edit, caretOffsetWithinNew: caret)
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
        guard let edit = factory.deletion(in: document, selection: span, name: String(localized: "합치기")),
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

    // MARK: 마우스로 블록을 넘는 선택

    /// 창 좌표의 점이 가리키는 문서 위치.
    ///
    /// 문서 위의 여백이면 문서 처음, 아래 여백이면 문서 끝이다 — 끌어서 창 끝까지
    /// 내리면 마지막 블록의 끝까지 잡혀야 한다.
    func position(atWindowPoint point: NSPoint) -> BlockPosition? {
        guard let last = document.blocks.indices.last else { return nil }
        let y = Double(canvas.convert(point, from: nil).y) - Double(theme.textInsets.height)
        guard let index = geometry.blockIndex(at: y, placements: placements),
              document.blocks.indices.contains(index) else { return nil }
        let block = document.blocks[index]
        if let view = activeViews[block.id] {
            return BlockPosition(blockIndex: index, offset: view.offset(atWindowPoint: point))
        }
        // 뷰가 없는 블록(보이는 범위 밖). 자리의 위쪽 절반이면 처음, 아래면 끝.
        let length = (block.sourceSlice as NSString).length
        guard placements.indices.contains(index) else {
            return BlockPosition(blockIndex: last, offset: length)
        }
        let placement = placements[index]
        return BlockPosition(blockIndex: index,
                             offset: y < placement.y + placement.height / 2 ? 0 : length)
    }

    /// 끌기 한 걸음 — 선택의 머리를 그 점으로 옮긴다. 닻은 그대로다.
    func extendDragSelection(toWindowPoint point: NSPoint) {
        guard let head = position(atWindowPoint: point) else { return }
        selection = BlockSelection(anchor: selection.anchor, head: head)
        applySelectionToViews()
    }

    /// 끌기를 시작한다 — 닻을 누른 자리에 놓는다.
    func beginDragSelection(in view: ParagraphBlockView, atWindowPoint point: NSPoint) {
        // first responder를 먼저 옮긴다. 캐럿이 들어온 블록은 마커가 드러나 글자
        // 자리가 바뀌므로, 닻은 **그 다음에** 잰다 — 순서를 바꾸면 닻이 누른
        // 글자에서 마커 길이만큼 밀린다.
        if window?.firstResponder !== view.textView {
            window?.makeFirstResponder(view.textView)
        }
        guard let index = index(of: view) else { return }
        let anchor = BlockPosition(blockIndex: index, offset: view.offset(atWindowPoint: point))
        selection = BlockSelection(caretAt: anchor)
        applySelectionToViews()
    }

    /// 마우스를 놓을 때까지 끌기를 따라간다. `BlockTextView.mouseDown`이 끌기로
    /// 판정한 뒤에 부른다.
    ///
    /// 창 밖으로 끌고 멈춰 있어도 계속 굴러야 하므로 주기 이벤트를 받는다 —
    /// 끌기 이벤트는 마우스가 움직일 때만 온다.
    func trackDragSelection(from textView: BlockTextView, mouseDown: NSEvent,
                            firstDrag: NSEvent) {
        guard let view = textView.blockOwner, let window else { return }
        beginDragSelection(in: view, atWindowPoint: mouseDown.locationInWindow)

        var lastDrag = firstDrag
        let step = { [unowned self] (event: NSEvent) in
            // 굴리기가 먼저다. 굴리면 보이는 블록이 바뀌어(뷰가 붙는다) 그 다음에
            // 재야 새로 들어온 블록 안의 자리가 잡힌다.
            canvas.autoscroll(with: event)
            extendDragSelection(toWindowPoint: event.locationInWindow)
        }
        step(firstDrag)

        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic],
                                           until: .distantFuture, inMode: .eventTracking,
                                           dequeue: true) {
            switch event.type {
            case .leftMouseDragged:
                lastDrag = event
                step(event)
            case .periodic:
                step(lastDrag)
            default:
                extendDragSelection(toWindowPoint: event.locationInWindow)
                return
            }
        }
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
    ///
    /// **이어지는 타이핑은 되돌리기 하나로 묶는다**(아래 `TypingRun`). 묶지 않으면
    /// 다섯 글자를 치고 ⌘Z를 다섯 번 눌러야 하는데, 기본 편집기(`NSTextView`)는
    /// 한 번이다 — 실측으로 5 대 1이었고, 그것이 "⌘Z가 이상하다"로 신고된 것이다.
    private func applyWithoutRebuild(_ edit: BlockEdit, blockIndex: Int,
                                     view: ParagraphBlockView) {
        // 되돌릴 때 돌아갈 자리 — **편집 전** 캐럿. 뷰가 `shouldChangeTextIn`에서
        // 잡아 둔 값이 가장 정확하다. 조합(IME) 갱신처럼 그 길을 지나지 않은 편집은
        // 길이 차이로 어림한다(편집이 캐럿 앞에서 일어났다고 보는 근사다).
        let caretNow = view.textView.selectedRange().location
        let caretBefore: Int
        if let exact = view.caretBeforeEdit {
            caretBefore = exact
        } else {
            let oldLength = (edit.old.first?.sourceSlice as NSString?)?.length ?? 0
            let newLength = (edit.new.first?.sourceSlice as NSString?)?.length ?? 0
            caretBefore = max(0, caretNow - newLength + oldLength)
        }

        // 이 편집이 열려 있는 타이핑 런을 이어 가는가 — 같은 블록이고 캐럿이
        // 런의 끝에서 이어질 때만이다. 캐럿이 뛰었으면 새 런이다.
        //
        // **줄바꿈은 런을 가른다.** Enter 한 번은 구조를 바꾸지 않는다(마크다운에서
        // `a\n첫 문단`은 여전히 한 문단이라 블록이 쪼개지지 않는다). 그래서 이 조건이
        // 없으면 "abc" + Enter + "def"가 ⌘Z 하나가 되어, 줄바꿈만 되돌리려던 사용자가
        // 앞 문장까지 잃는다. 실측으로 드러난 경우다.
        let oldNewlines = (edit.old.first?.sourceSlice ?? "").count { $0 == "\n" }
        let newNewlines = (edit.new.first?.sourceSlice ?? "").count { $0 == "\n" }
        let crossesLine = oldNewlines != newNewlines
        let continues = !crossesLine
            && typingRun?.blockIndex == blockIndex
            && typingRun?.endCaret == caretBefore

        guard edit.apply(to: &document) else { return }

        if let run = typingRun, continues {
            // 등록하지 않는다. 이미 걸어 둔 되돌리기가 **런의 시작 상태**로 돌려놓으므로
            // (되돌릴 때 현재 상태에서 역산한다) ⌘Z 한 번이 런 전체를 되돌린다.
            run.endCaret = caretNow
        } else {
            let run = TypingRun(blockIndex: blockIndex,
                                startBlocks: edit.old,
                                caretOnUndo: BlockPosition(blockIndex: blockIndex,
                                                           offset: caretBefore),
                                endCaret: caretNow,
                                name: edit.name)
            typingRun = run
            documentUndoManager.setActionName(edit.name)
            documentUndoManager.registerUndo(withTarget: self) { target in
                target.undoTypingRun(run)
            }
            // 줄바꿈은 자기 한 칸으로 끝난다 — 뒤에 치는 글자는 또 새 런이다.
            if crossesLine { breakTypingRun() }
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
        let spannedBlocks = selectionSpansBlocks
        selection = BlockSelection(anchor: BlockPosition(blockIndex: index, offset: range.location),
                                   head: BlockPosition(blockIndex: index,
                                                       offset: range.location + range.length))
        // 블록을 넘던 선택이 한 블록으로 줄었다(끈 뒤에 클릭했다). 다른 블록들에 남은
        // 회색 선택 몫을 지운다 — 지우지 않으면 화면에는 선택이 남아 있는데 ⌘C는
        // 이 블록만 복사한다.
        if spannedBlocks { applySelectionToViews() }
        // 캐럿이 움직이면 마커 보임이 달라진다 — 그 블록만 다시 칠한다.
        view.restyle(width: contentWidth, isFocusedBlock: true)
    }

    func blockView(_ view: ParagraphBlockView,
                   didMoveCaretBeyond direction: BlockCaretNavigation.Direction) {
        guard inputGuard.allowsBoundaryMove, let index = index(of: view),
              let target = BlockCaretNavigation.target(from: index, direction: direction,
                                                       blockCount: document.blocks.count)
        else { return }
        // ↑↓는 가로 위치를 지켜야 한다. ←→는 글자 하나를 넘는 것이니 끝에 붙인다.
        let keepsColumn = direction == .up || direction == .down
        focus(blockIndex: target.blockIndex, edge: target.edge,
              preferredX: keepsColumn ? view.caretXInWindow : nil)
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
    func focus(blockIndex: Int, edge: BlockCaretNavigation.Edge,
               preferredX: CGFloat? = nil) {
        guard document.blocks.indices.contains(blockIndex),
              placements.indices.contains(blockIndex) else { return }
        let placement = placements[blockIndex]
        scrollView.contentView.scrollToVisible(
            NSRect(x: 0, y: placement.y, width: 1, height: max(placement.height, 1)))
        syncViews()
        let id = document.blocks[blockIndex].id
        guard let view = activeViews[id] else { return }
        focusedBlockID = id
        view.placeCaret(at: edge, preferredX: preferredX)
        window?.makeFirstResponder(view.textView)
        // 실제로 놓인 자리를 쓴다 — `preferredX`로 줄 가운데에 놓였을 수 있다.
        selection = BlockSelection(caretAt: BlockPosition(
            blockIndex: blockIndex, offset: view.textView.selectedRange().location))
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
