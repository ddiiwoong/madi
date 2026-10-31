import AppKit

@MainActor
protocol BlockViewOwner: AnyObject {
    /// 이 블록의 글이 바뀌었다.
    func blockView(_ view: ParagraphBlockView, didChangeSource source: String)
    /// 이 블록 안에서 선택이 바뀌었다.
    func blockView(_ view: ParagraphBlockView, didChangeSelection range: NSRange)
    /// 캐럿이 이 블록의 위/아래 경계를 넘으려 한다.
    func blockView(_ view: ParagraphBlockView, didMoveCaretBeyond direction: BlockCaretNavigation.Direction)
    /// 조합(IME) 상태가 바뀌었다.
    func blockViewDidChangeCompositionState(_ view: ParagraphBlockView)
    /// 이 블록이 first responder가 됐다.
    func blockViewDidBecomeFocused(_ view: ParagraphBlockView)
    /// 링크를 눌렀다.
    func blockView(_ view: ParagraphBlockView, didClickLink url: String)
}

/// 블록 하나를 그리는 뷰 — `docs/block-editor-design.md` §4의 `ParagraphBlockView`.
///
/// 단계 1에서는 **모든** 종류의 블록이 이 뷰로 그려진다. 표도 아직 글이다(설계 §7의
/// 단계 1: "표는 아직 텍스트"). 그래서 화면은 지금의 편집기와 같아야 하고, 달라지는
/// 것은 그 아래의 구조뿐이다.
///
/// 블록마다 TextKit 1 스택을 하나씩 갖는다. 비싸기 때문에 컨테이너가 **보이는 블록만**
/// 뷰를 주고 나머지는 높이만 기억한다(§4).
///
/// ## 되돌리기를 끈 이유
///
/// `allowsUndo = false`다. 블록마다 undo 스택을 두면 ⌘Z가 방금 고친 블록이 아니라
/// first responder가 마지막으로 머문 블록을 되돌린다(§5.2). 되돌리기는 문서 하나의
/// `NSUndoManager`가 `BlockEdit` 단위로 맡는다.
@MainActor
final class ParagraphBlockView: NSView {

    weak var owner: BlockViewOwner?

    /// 지금 이 뷰가 들고 있는 블록. 재사용될 때 바뀐다.
    private(set) var blockID: Block.ID?
    private(set) var blockIndex: Int = 0

    /// 편집 **직전**의 캐럿(이 블록 안의 UTF-16 오프셋). `shouldChangeTextIn`이 채우고
    /// `textDidChange`가 쓰고 버린다. 되돌릴 때 캐럿이 갈 자리이고, 길이 차이로
    /// 어림하면 앞으로 지우기에서 한 칸 밀린다 — 아래 대리자 주석에 실측을 적었다.
    private(set) var caretBeforeEdit: Int?

    let textView: BlockTextView
    private let storage = NSTextStorage()
    private let textLayout = NSLayoutManager()
    private let container: NSTextContainer
    private var markerDelegate: MarkerHidingLayoutDelegate!
    /// 스타일러는 컨테이너가 하나만 들고 모든 블록이 나눠 쓴다 — 테마·그림 캐시·문서
    /// 위치가 블록마다 갈라지면 한 문서 안에서 글자 크기가 달라진다.
    private weak var styler: MarkdownStyler?

    private var isApplyingModel = false

    init(styler: MarkdownStyler) {
        container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        textLayout.addTextContainer(container)
        storage.addLayoutManager(textLayout)
        textView = BlockTextView(frame: .zero, textContainer: container)
        self.styler = styler
        super.init(frame: .zero)
        markerDelegate = MarkerHidingLayoutDelegate(storage: storage)
        textLayout.delegate = markerDelegate
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func configure() {
        textView.isEditable = true
        textView.isRichText = false
        // 문서 레벨 되돌리기 — 위 주석 참고.
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [:]
        textView.delegate = self
        textView.blockOwner = self
        addSubview(textView)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        textView.frame = bounds
        container.size = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
    }

    // MARK: 모델 싣기

    /// 블록을 싣는다. 재사용되는 뷰도 이 길로 들어온다.
    func show(block: Block, index: Int, width: Double, isFocusedBlock: Bool) {
        blockID = block.id
        blockIndex = index
        isApplyingModel = true
        if storage.string != block.sourceSlice {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                      with: block.sourceSlice)
        }
        isApplyingModel = false
        restyle(width: width, isFocusedBlock: isFocusedBlock)
    }

    /// 다시 칠한다.
    ///
    /// `caretLine`은 **이 블록 안의** 줄 번호다. 캐럿이 다른 블록에 있으면 `nil`을
    /// 넘겨 마커를 모두 숨긴다 — 그래야 지금 고치고 있는 블록만 마커가 보인다.
    func restyle(width: Double, isFocusedBlock: Bool) {
        guard let styler else { return }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        styler.contentWidth = max(120, width - 8)
        styler.style(storage, caretLine: isFocusedBlock ? caretLine() : nil,
                     search: MarkdownStyler.SearchState())
        textView.codeBlockColor = styler.theme.codeBackground
        textView.codeBlockRanges = styler.codeBlockRanges
        textView.imagePlacements = styler.imagePlacements
    }

    /// 글이 차지하는 높이. 컨테이너가 쌓는 데 쓴다.
    ///
    /// `usedRect`를 그대로 쓰면 **블록마다 빈 줄 하나가 덧붙는다.** 블록의 조각은
    /// 줄바꿈으로 끝나고, TextKit은 그 줄바꿈 뒤에 캐럿이 설 자리로 여분의 줄
    /// 조각(`extraLineFragmentRect`)을 하나 더 만든다. 편집기 하나에 문서 전체가
    /// 들어 있을 때는 문서 끝에 한 번만 생기지만, 블록마다 저장소가 따로이면
    /// 블록마다 생긴다 — 실측으로 한 줄 블록이 32pt 대신 46.5pt였고, 문서의
    /// 수직 리듬이 기존 편집기와 달라졌다.
    func fittingHeight(width: Double) -> Double {
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textLayout.ensureLayout(for: container)
        var height = Double(textLayout.usedRect(for: container).height)
        let extra = textLayout.extraLineFragmentRect
        if extra.height > 0 { height -= Double(extra.height) }
        // 빈 블록도 한 줄 높이는 차지해야 캐럿을 놓을 수 있다.
        return max(height, Double(styler?.theme.bodyPointSize ?? 15) * 1.2)
    }

    var source: String { storage.string }

    /// 블록의 번호만 바뀌었다(앞에서 블록이 생기거나 사라졌다). 글은 그대로이므로
    /// 다시 칠하지 않는다 — 번호만 고친다.
    func blockIndexDidMove(to index: Int) {
        blockIndex = index
    }

    /// 이 블록 안의 캐럿 줄 번호(1부터). 마커 숨김이 이 값을 본다.
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

    // MARK: 선택 몫 그리기

    /// 이 블록이 받은 선택 몫을 그린다(설계 §5.1).
    ///
    /// 따로 그리지 않는다 — `NSTextView`는 first responder가 아닐 때 선택을 흐린
    /// 회색으로 그려 주고, 그것이 "걸쳐 있는 선택의 가운데 블록"에 정확히 맞는 모습이다.
    /// 선택 범위를 넣는 것만으로 되고, first responder를 훔치지 않는다.
    func apply(coverage: BlockSelection.Coverage) {
        let length = storage.length
        switch coverage {
        case .outside:
            if textView.selectedRange().length > 0 {
                textView.setSelectedRange(NSRange(location: textView.selectedRange().location,
                                                  length: 0))
            }
        case .whole:
            textView.setSelectedRange(NSRange(location: 0, length: length))
        case .partial(let range):
            let location = min(max(0, range.location), length)
            let span = range.length == NSNotFound
                ? length - location
                : min(range.length, length - location)
            textView.setSelectedRange(NSRange(location: location, length: max(0, span)))
        }
    }

    /// 캐럿을 놓는다. 경계를 넘어 들어올 때 쓴다.
    ///
    /// `preferredX`를 주면 그 **가로 위치에 가장 가까운 글자**에 놓는다. 설계 §5.3이
    /// 약속한 "수평 위치를 보존해 캐럿을 놓는다"가 이것이다 — 없으면 ↓를 누를 때마다
    /// 캐럿이 줄 맨 앞으로 떨어져, 긴 문단 사이를 오르내릴 수 없다.
    /// MarkText(Muya)도 표 칸 사이에서 **열 번호를 보존**한다.
    func placeCaret(at edge: BlockCaretNavigation.Edge, preferredX: CGFloat? = nil) {
        guard let preferredX else {
            let location = edge == .top ? 0 : storage.length
            textView.setSelectedRange(NSRange(location: location, length: 0))
            return
        }
        textLayout.ensureLayout(for: container)
        let used = textLayout.usedRect(for: container)
        // 들어온 쪽의 끝 줄에서 그 x에 가장 가까운 글자를 찾는다.
        let y = edge == .top ? used.minY + 1 : max(used.minY, used.maxY - 2)
        let localX = textView.convert(NSPoint(x: preferredX, y: 0), from: nil).x
        let point = NSPoint(x: localX - textView.textContainerOrigin.x,
                            y: y)
        let index = textLayout.characterIndex(for: point, in: container,
                                              fractionOfDistanceBetweenInsertionPoints: nil)
        textView.setSelectedRange(NSRange(location: min(index, storage.length), length: 0))
    }

    /// 캐럿의 가로 위치(창 좌표). 블록을 넘어갈 때 그 값을 넘겨 자리를 보존한다.
    var caretXInWindow: CGFloat? {
        textLayout.ensureLayout(for: container)
        let caret = textView.selectedRange()
        guard caret.location <= storage.length else { return nil }
        let glyphRange = textLayout.glyphRange(
            forCharacterRange: NSRange(location: caret.location, length: 0),
            actualCharacterRange: nil)
        var box = textLayout.boundingRect(forGlyphRange: glyphRange, in: container)
        if box.isEmpty, storage.length > 0, caret.location > 0 {
            // 줄 끝에서는 빈 사각형이 나온다. 앞 글자의 오른쪽 끝을 쓴다.
            let previous = textLayout.glyphRange(
                forCharacterRange: NSRange(location: caret.location - 1, length: 1),
                actualCharacterRange: nil)
            box = textLayout.boundingRect(forGlyphRange: previous, in: container)
            box.origin.x = box.maxX
        }
        let local = NSPoint(x: box.origin.x + textView.textContainerOrigin.x, y: 0)
        return textView.convert(local, to: nil).x
    }

    /// 창 좌표의 점에 가장 가까운 **캐럿 자리**(이 블록 안의 UTF-16 오프셋).
    ///
    /// 마우스로 블록을 넘겨 끌 때 쓴다. 점이 이 블록보다 위면 0, 아래면 끝이다 —
    /// `characterIndexForInsertion`에 맡기면 위아래로 벗어난 점도 가장 가까운 줄로
    /// 끌어와, 블록 아래 틈을 가리킨 선택이 마지막 줄 가운데에서 멈춘다.
    func offset(atWindowPoint point: NSPoint) -> Int {
        let local = textView.convert(point, from: nil)
        if local.y < textView.bounds.minY { return 0 }
        if local.y >= textView.bounds.maxY { return storage.length }
        let index = textView.characterIndexForInsertion(at: local)
        return min(max(0, index), storage.length)
    }

    func placeCaret(atOffset offset: Int) {
        let location = min(max(0, offset), storage.length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    var isComposing: Bool { textView.hasMarkedText() }

    /// 캐럿이 첫 줄에 있는가 / 마지막 줄에 있는가. 경계를 넘을지 가린다.
    var caretIsOnFirstLine: Bool {
        let text = storage.string as NSString
        guard text.length > 0 else { return true }
        let caret = min(textView.selectedRange().location, text.length)
        return text.lineRange(for: NSRange(location: caret, length: 0)).location == 0
    }

    var caretIsOnLastLine: Bool {
        let text = storage.string as NSString
        guard text.length > 0 else { return true }
        let caret = min(textView.selectedRange().location, text.length)
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        return NSMaxRange(line) >= text.length
    }
}

// MARK: - 텍스트 뷰 대리자

extension ParagraphBlockView: NSTextViewDelegate {

    /// 편집 **직전**의 캐럿을 잡아 둔다.
    ///
    /// 왜 필요한가(실측): 되돌릴 때 캐럿이 갈 자리를 옛/새 조각의 **길이 차이로**
    /// 어림하면 앞으로 지우기(fn+Delete)에서 한 칸 밀린다 — 오프셋 2에서 앞으로
    /// 지우고 ⌘Z를 누르면 캐럿이 3에 섰다. 길이 차이 보정은 "편집이 캐럿 앞에서
    /// 일어났다"를 가정하는데, 앞으로 지우기는 캐럿 **뒤**를 고치고 캐럿은 그대로다.
    /// (old, new, 지금 캐럿) 셋만으로는 지우기 두 방향을 가를 수 없다 — Backspace도
    /// 앞으로 지우기도 편집 뒤 캐럿이 바뀐 자리와 같아진다. 그래서 편집 전 값을 잡는다.
    ///
    /// 치기·Backspace·앞으로 지우기 모두 이 값이 곧 "되돌리면 캐럿이 있어야 할 자리"다.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        caretBeforeEdit = textView.selectedRange().location
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingModel else { return }
        owner?.blockView(self, didChangeSource: storage.string)
        // 한 번 쓰고 버린다. 조합(IME) 갱신은 `shouldChangeTextIn`을 지나지 않는
        // 경우가 있어, 남겨 두면 다음 편집이 낡은 값을 쓴다.
        caretBeforeEdit = nil
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplyingModel else { return }
        owner?.blockView(self, didChangeSelection: textView.selectedRange())
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? String {
            owner?.blockView(self, didClickLink: url)
            return true
        }
        return false
    }
}

// MARK: - 블록 경계를 아는 텍스트 뷰

/// `NSTextView`는 자기 글의 끝에서 ↓를 누르면 아무 일도 하지 않는다. 블록 편집기에서는
/// 그것이 "다음 블록으로"여야 하므로, 경계에서만 주인에게 넘긴다.
///
/// 조합(IME) 중에는 넘기지 않는다 — 주인이 `BlockInputGuard`로 막지만, 여기서도
/// `hasMarkedText()`를 보고 `super`에 맡겨 조합 중의 방향키가 입력기의 것으로 남게 한다.
@MainActor
final class BlockTextView: DecoratedTextView {

    weak var blockOwner: ParagraphBlockView?

    override func moveDown(_ sender: Any?) {
        guard !hasMarkedText(), let blockOwner, blockOwner.caretIsOnLastLine else {
            return super.moveDown(sender)
        }
        blockOwner.owner?.blockView(blockOwner, didMoveCaretBeyond: .down)
    }

    override func moveUp(_ sender: Any?) {
        guard !hasMarkedText(), let blockOwner, blockOwner.caretIsOnFirstLine else {
            return super.moveUp(sender)
        }
        blockOwner.owner?.blockView(blockOwner, didMoveCaretBeyond: .up)
    }

    override func moveLeft(_ sender: Any?) {
        guard !hasMarkedText(), let blockOwner,
              selectedRange().location == 0, selectedRange().length == 0 else {
            return super.moveLeft(sender)
        }
        blockOwner.owner?.blockView(blockOwner, didMoveCaretBeyond: .up)
    }

    override func moveRight(_ sender: Any?) {
        guard !hasMarkedText(), let blockOwner,
              selectedRange().location == textStorage?.length,
              selectedRange().length == 0 else {
            return super.moveRight(sender)
        }
        blockOwner.owner?.blockView(blockOwner, didMoveCaretBeyond: .down)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let blockOwner {
            blockOwner.owner?.blockViewDidBecomeFocused(blockOwner)
        }
        return accepted
    }

    // MARK: 블록을 넘는 명령
    //
    // `NSTextView`의 ⌘A·⌘C·Delete는 **자기 글**만 본다. 블록 편집기에서 그것은
    // 문서의 일부일 뿐이라, 블록을 넘는 선택이 걸려 있으면 컨테이너에 넘긴다.

    override func selectAll(_ sender: Any?) {
        // 조합 중에는 선택을 건드리지 않는다 — 선택을 다시 싣는 순간 조합 중인
        // 블록의 범위가 바뀌어 치던 글자가 깨진다.
        guard !hasMarkedText(),
              let container = blockOwner?.owner as? BlockContainerView else {
            return super.selectAll(sender)
        }
        container.selectAll()
    }

    override func copy(_ sender: Any?) {
        guard let container = blockOwner?.owner as? BlockContainerView,
              container.selectionSpansBlocks else {
            return super.copy(sender)
        }
        container.copySelection()
    }

    override func deleteBackward(_ sender: Any?) {
        // 조합 중의 Backspace는 **입력기의 것**이다. 한글은 조합 중에 Backspace로
        // 자모를 하나씩 되돌리고(`각` → `가` → `ㄱ`), 그 사이에 편집기가 블록을
        // 허물면 치던 글자가 사라진다. MarkText(Muya)도 같은 규칙을 테스트로
        // 고정해 두었다(`imeBackspaceComposition.spec.ts`).
        guard !hasMarkedText(),
              let container = blockOwner?.owner as? BlockContainerView else {
            return super.deleteBackward(sender)
        }
        if container.selectionSpansBlocks {
            return container.deleteSelectionAcrossBlocks()
        }
        // 블록 처음에서 Backspace는 앞 블록과 합치는 것이다.
        if selectedRange() == NSRange(location: 0, length: 0),
           container.mergeWithPreviousBlock(from: self) {
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        guard !hasMarkedText(),
              let container = blockOwner?.owner as? BlockContainerView,
              container.selectionSpansBlocks else {
            return super.deleteForward(sender)
        }
        container.deleteSelectionAcrossBlocks()
    }

    /// Shift+↓ / Shift+↑로 선택을 블록 밖까지 늘린다.
    override func moveDownAndModifySelection(_ sender: Any?) {
        guard !hasMarkedText(), let blockOwner, blockOwner.caretIsOnLastLine,
              let container = blockOwner.owner as? BlockContainerView,
              container.extendSelection(from: blockOwner, direction: .down) else {
            return super.moveDownAndModifySelection(sender)
        }
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        guard !hasMarkedText(), let blockOwner, blockOwner.caretIsOnFirstLine,
              let container = blockOwner.owner as? BlockContainerView,
              container.extendSelection(from: blockOwner, direction: .up) else {
            return super.moveUpAndModifySelection(sender)
        }
    }

    // MARK: 마우스로 블록을 넘는 선택
    //
    // `NSTextView.mouseDown`은 마우스를 놓을 때까지 **자기 안에서** 끌기를 처리하고,
    // 자기 글 밖으로 끌면 자기 처음이나 끝에서 선택을 멈춘다. 그래서 블록을 넘어
    // 끌 수가 없었다. 끌기만 컨테이너가 맡고, 클릭은 그대로 `super`에 둔다 —
    // 링크 열기, 두 번·세 번 클릭의 낱말·문단 선택, 선택한 글을 끌어 옮기기가
    // 모두 `NSTextView`의 것이라 다시 짜면 그만큼 잃는다.

    /// 끌기로 볼 최소 거리(pt). 클릭하다 손이 조금 떨린 것을 끌기로 보지 않는다.
    static let dragThreshold: CGFloat = 3

    override func mouseDown(with event: NSEvent) {
        guard shouldTrackDragItself(event),
              let blockOwner,
              let container = blockOwner.owner as? BlockContainerView,
              let window else {
            return super.mouseDown(with: event)
        }

        // 끌기인지 클릭인지는 다음 이벤트를 봐야 안다.
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantFuture, inMode: .eventTracking,
                                          dequeue: true) {
            if next.type == .leftMouseUp {
                // 클릭이었다. 놓기를 되돌려 넣고 평소대로 처리한다 — `super`의
                // 추적 고리가 그 놓기를 바로 꺼내 클릭 하나로 끝낸다.
                window.postEvent(next, atStart: true)
                return super.mouseDown(with: event)
            }
            let moved = hypot(next.locationInWindow.x - start.x,
                              next.locationInWindow.y - start.y)
            guard moved >= Self.dragThreshold else { continue }
            container.trackDragSelection(from: self, mouseDown: event, firstDrag: next)
            return
        }
    }

    /// 이 누르기를 컨테이너의 끌기로 볼 수 있는가.
    ///
    /// 한 번 클릭·보조 키 없음·조합 중 아님·선택한 글 바깥일 때만이다. 선택한 글
    /// 위에서 누르면 `NSTextView`가 그 글을 끌어 옮기는 동작이고, 두 번 클릭은 낱말
    /// 선택이며, Shift·⌥ 클릭은 선택 늘리기와 사각 선택이다 — 모두 `super`의 일이다.
    private func shouldTrackDragItself(_ event: NSEvent) -> Bool {
        guard event.clickCount == 1, !hasMarkedText() else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.shift, .option, .command, .control]) else { return false }
        let selected = selectedRange()
        if selected.length > 0 {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if index > selected.location, index < NSMaxRange(selected) { return false }
        }
        return true
    }

    /// 조합의 시작과 끝. 주인이 이 신호로 `BlockInputGuard`를 세운다.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if let blockOwner { blockOwner.owner?.blockViewDidChangeCompositionState(blockOwner) }
    }

    override func unmarkText() {
        super.unmarkText()
        if let blockOwner { blockOwner.owner?.blockViewDidChangeCompositionState(blockOwner) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // 블록을 넘는 선택 위에 치면 **선택한 전부**가 바뀌어야 한다. 이 뷰에 맡기면
        // 자기 블록의 몫만 지워지고 나머지 블록의 글이 남는다.
        if !hasMarkedText(),
           let container = blockOwner?.owner as? BlockContainerView,
           container.selectionSpansBlocks {
            container.replaceSelectionAcrossBlocks(with: (string as? String)
                ?? (string as? NSAttributedString)?.string ?? "")
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        if let blockOwner { blockOwner.owner?.blockViewDidChangeCompositionState(blockOwner) }
    }

    override func paste(_ sender: Any?) {
        guard let container = blockOwner?.owner as? BlockContainerView,
              container.selectionSpansBlocks,
              let text = NSPasteboard.general.string(forType: .string) else {
            return super.paste(sender)
        }
        container.replaceSelectionAcrossBlocks(with: text, name: String(localized: "붙여넣기"))
    }
}
