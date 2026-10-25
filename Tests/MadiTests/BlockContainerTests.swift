import AppKit
import XCTest

/// 블록 컨테이너를 **실제 `NSTextView`와 응답자 연쇄를 지나** 확인하는 테스트.
///
/// 순수 모델 테스트(`BlockEditorPhase1Tests`)는 판단이 맞는지 보고, 이쪽은 그 판단이
/// 뷰까지 **배선되어 있는지** 본다. 둘이 다 필요하다는 것을 실측으로 배웠다: ⌘A가
/// 모델에는 올바르게 실리는데도, 선택을 뷰에 싣는 순간 그 뷰가 돌려주는
/// `textViewDidChangeSelection`이 모델을 한 블록으로 되돌려 복사가 18바이트만
/// 나왔다. 모델 테스트는 초록이었다.
///
/// 창은 화면 밖(x = -20000)에 만들고 `orderBack`으로 띄운다 — 테스트가 사용자의
/// 화면을 가로채면 안 된다.
@MainActor
final class BlockContainerTests: XCTestCase {

    private var window: NSWindow!
    private var container: BlockContainerView!

    private let body = "# 제목\n\n첫 문단이다.\n\n둘째 문단이다.\n"

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 700, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        container = BlockContainerView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        window.contentView = container
        container.frame = window.contentView!.bounds
        window.orderBack(nil)
        container.markdown = body
        settle()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
        container = nil
    }

    /// 지연 레이아웃이 끝나게 한다. 블록 뷰의 높이는 TextKit이 레이아웃을 돌린
    /// 뒤에야 참이다.
    private func settle() {
        container.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private var blocks: [NSTextView] {
        guard let scroll = container.subviews.compactMap({ $0 as? NSScrollView }).first,
              let canvas = scroll.documentView else { return [] }
        return canvas.subviews
            .compactMap { $0 as? ParagraphBlockView }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(\.textView)
    }

    // MARK: 구조

    func testDocumentBecomesOneViewPerBlock() {
        XCTAssertEqual(container.blockCount, 5, "제목·빈 줄·문단·빈 줄·문단")
        XCTAssertEqual(blocks.count, 5, "작은 문서에서는 모든 블록이 보이므로 뷰도 다섯")
        XCTAssertEqual(blocks.first?.string, "# 제목\n")
    }

    func testBlocksDoNotOverlapVertically() {
        let views = container.subviews
            .compactMap { $0 as? NSScrollView }.first?
            .documentView?.subviews
            .compactMap { $0 as? ParagraphBlockView }
            .sorted { $0.frame.minY < $1.frame.minY } ?? []
        XCTAssertFalse(views.isEmpty)
        for (upper, lower) in zip(views, views.dropFirst()) {
            XCTAssertLessThanOrEqual(upper.frame.maxY, lower.frame.minY + 0.5,
                                     "블록이 겹치면 글이 서로를 덮는다")
        }
    }

    func testRoundTripIsByteIdenticalWithoutEditing() {
        XCTAssertEqual(container.markdown, body,
                       "열기만 하고 돌려준 글이 달라지면 저장이 diff를 만든다")
    }

    /// 두 줄 블록은 한 줄 블록의 **정확히 두 배**여야 한다.
    ///
    /// 이것이 깨지는 방식이 하나 있고 실제로 겪었다: 블록의 조각은 줄바꿈으로
    /// 끝나고 TextKit이 그 뒤에 캐럿이 설 자리로 줄 조각을 하나 더 만든다. 그것을
    /// 빼지 않으면 모든 블록이 빈 줄 하나씩을 더 갖고(한 줄 블록 32.5pt → 46.5pt),
    /// 문서가 기존 편집기보다 성겨진다. 높이가 다 같이 늘어나므로 "블록 높이가
    /// 모두 같은가"로는 잡히지 않는다 — 배수로 재야 잡힌다.
    func testATwoLineBlockIsExactlyTwiceAOneLineBlock() {
        container.markdown = "한 줄.\n\n첫 줄.\n둘째 줄.\n"
        settle()
        let views = container.subviews
            .compactMap { $0 as? NSScrollView }.first?
            .documentView?.subviews
            .compactMap { $0 as? ParagraphBlockView }
            .sorted { $0.frame.minY < $1.frame.minY } ?? []
        XCTAssertEqual(views.count, 3, "전제: 한 줄 문단 · 빈 줄 · 두 줄 문단")

        let oneLine = Double(views[0].frame.height)
        let twoLine = Double(views[2].frame.height)
        XCTAssertEqual(twoLine, oneLine * 2, accuracy: 1.0,
                       "블록마다 여분의 줄 조각이 붙으면 2배가 아니라 1.5배가 된다")
    }

    // MARK: 블록을 넘는 선택 — 응답자 연쇄까지

    func testSelectAllThroughTheResponderChainSpansEveryBlock() {
        guard let first = blocks.first else { return XCTFail("블록 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(first))

        // 메뉴의 `모두 선택`이 응답자 연쇄로 닿는 지점을 직접 부른다.
        // `NSApp.sendAction(to: nil)`은 쓸 수 없다 — 테스트 번들에는 key window가
        // 없어서 연쇄 탐색이 시작되지 않는다(실측: false를 돌려준다). 키 → 메뉴 →
        // first responder 구간은 AppKit의 몫이고, 여기서 지켜야 하는 것은 그 다음,
        // 즉 블록 뷰가 컨테이너에 넘기는 배선이다.
        first.selectAll(nil)

        XCTAssertTrue(container.selectionSpansBlocks,
                      "⌘A는 블록 하나가 아니라 문서 전체를 선택해야 한다")
        XCTAssertEqual(container.selectedMarkdown, body,
                       "선택된 글이 문서와 바이트가 같아야 한다")
    }

    func testApplyingTheSelectionToViewsDoesNotShrinkItBackToOneBlock() {
        guard let first = blocks.first else { return XCTFail("블록 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(first))
        container.selectAll()
        // 뷰에 싣는 동안 돌아오는 선택 변경 신호가 모델을 덮어쓰면 여기서 깨진다.
        settle()
        XCTAssertTrue(container.selectionSpansBlocks)
        XCTAssertEqual(container.selectedMarkdown, body)
    }

    func testCopyOfACrossBlockSelectionPutsTheWholeRangeOnThePasteboard() {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        guard let first = blocks.first else { return XCTFail("블록 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(first))
        container.selectAll()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("SENTINEL", forType: .string)

        first.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), body,
                       "블록을 넘는 복사는 블록 뷰 하나가 아니라 컨테이너가 조립해야 한다")
    }

    // MARK: 마우스로 블록을 넘는 선택 — 실제 이벤트 경로

    /// 블록 뷰 안의 글자 자리 → 창 좌표. 그 글자의 **왼쪽 끝 바로 안**을 가리켜
    /// `characterIndexForInsertion`이 그 글자 앞(= `offset`)을 돌려주게 한다.
    private func windowPoint(in textView: NSTextView, offset: Int) -> NSPoint {
        guard let layout = textView.layoutManager, let box = textView.textContainer else {
            return .zero
        }
        layout.ensureLayout(for: box)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: offset, length: 1),
                                       actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: box)
        let local = NSPoint(x: rect.minX + 1 + textView.textContainerOrigin.x,
                            y: rect.midY + textView.textContainerOrigin.y)
        return textView.convert(local, to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// 누른다. 실제 앱에서 누른 뷰를 first responder로 만드는 것은 `NSWindow.sendEvent`이고
    /// 그 다음에 뷰의 `mouseDown`이 불린다 — 그 순서를 그대로 밟는다. `sendEvent`로
    /// 보내지 않는 이유: 화면 밖의 key가 아닌 창은 첫 클릭을 창 활성화로 먹는다(실측:
    /// 다섯 테스트가 아무 선택도 없이 끝났다).
    private func press(_ textView: NSTextView, at point: NSPoint) {
        window.makeFirstResponder(textView)
        textView.mouseDown(with: mouse(.leftMouseDown, at: point))
    }

    /// 누르고, `path`를 따라 끌고, 마지막 점에서 놓는다 — `mouseDown`이 도는 추적
    /// 고리가 꺼내 가도록 끌기·놓기를 **먼저** 큐에 넣는다.
    private func drag(on textView: NSTextView, from start: NSPoint, through path: [NSPoint]) {
        for point in path { window.postEvent(mouse(.leftMouseDragged, at: point), atStart: false) }
        window.postEvent(mouse(.leftMouseUp, at: path.last ?? start), atStart: false)
        press(textView, at: start)
        settle()
    }

    /// 마커가 없는 문단 둘 — 캐럿이 들어와 마커가 드러나도 글자 자리가 바뀌지 않는다.
    private func paragraphs() -> (first: NSTextView, second: NSTextView)? {
        let views = blocks
        guard views.count == 5 else { return nil }
        XCTAssertEqual(views[2].string, "첫 문단이다.\n", "전제: 셋째 블록이 첫 문단")
        XCTAssertEqual(views[4].string, "둘째 문단이다.\n", "전제: 다섯째 블록이 둘째 문단")
        return (views[2], views[4])
    }

    func testMouseDragAcrossBlocksSelectsEverythingInBetween() {
        guard let (first, second) = paragraphs() else { return XCTFail("블록이 부족하다") }
        let start = windowPoint(in: first, offset: 2)    // "첫 " 뒤
        let end = windowPoint(in: second, offset: 3)     // "둘째 " 뒤
        drag(on: first, from: start, through: [end])

        XCTAssertTrue(container.selectionSpansBlocks,
                      "끌기가 누른 블록 끝에서 멈추면 블록을 넘을 수 없다")
        XCTAssertEqual(container.selectedMarkdown, "문단이다.\n\n둘째 ")
    }

    func testMouseDragUpwardsSelectsTheSameRange() {
        guard let (first, second) = paragraphs() else { return XCTFail("블록이 부족하다") }
        let start = windowPoint(in: second, offset: 3)
        let end = windowPoint(in: first, offset: 2)
        drag(on: second, from: start, through: [end])

        XCTAssertEqual(container.selectedMarkdown, "문단이다.\n\n둘째 ",
                       "위로 끌어도 같은 범위여야 한다")
    }

    func testMouseDragBelowTheLastBlockSelectsToTheEndOfTheDocument() {
        guard let (first, second) = paragraphs() else { return XCTFail("블록이 부족하다") }
        let start = windowPoint(in: first, offset: 2)
        let bottom = second.convert(NSPoint(x: 10, y: second.bounds.maxY + 40), to: nil)
        drag(on: first, from: start, through: [bottom])

        XCTAssertEqual(container.selectedMarkdown, "문단이다.\n\n둘째 문단이다.\n",
                       "문서 아래 빈 곳까지 끌면 마지막 블록의 끝까지 잡혀야 한다 — "
                       + "마지막 줄 가운데에서 멈추면 안 된다")
    }

    /// 끌기를 가로챘어도 **클릭은 `NSTextView`의 것**으로 남아야 한다 — 링크 열기·
    /// 캐럿 놓기가 모두 이 길이다.
    func testAPlainClickStillPlacesTheCaretInThatBlock() {
        guard let (_, second) = paragraphs() else { return XCTFail("블록이 부족하다") }
        let point = windowPoint(in: second, offset: 3)
        window.postEvent(mouse(.leftMouseUp, at: point), atStart: false)
        press(second, at: point)
        settle()

        XCTAssertTrue(window.firstResponder === second, "클릭한 블록이 first responder여야 한다")
        XCTAssertEqual(second.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertFalse(container.selectionSpansBlocks)
    }

    func testClickingAfterADragClearsTheSelectionInOtherBlocks() {
        guard let (first, second) = paragraphs() else { return XCTFail("블록이 부족하다") }
        drag(on: first, from: windowPoint(in: first, offset: 2),
             through: [windowPoint(in: second, offset: 3)])
        XCTAssertTrue(container.selectionSpansBlocks, "전제: 블록을 넘는 선택")

        let point = windowPoint(in: first, offset: 1)
        window.postEvent(mouse(.leftMouseUp, at: point), atStart: false)
        press(first, at: point)
        settle()

        XCTAssertFalse(container.selectionSpansBlocks)
        XCTAssertEqual(second.selectedRange().length, 0,
                       "다른 블록에 회색 선택이 남으면 화면과 ⌘C가 어긋난다")
    }

    // MARK: 문서 레벨 되돌리기

    func testTypingRegistersOnTheDocumentUndoManagerNotTheTextView() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertFalse(paragraph.allowsUndo,
                       "블록마다 undo를 두면 ⌘Z가 엉뚱한 블록을 되돌린다")
        XCTAssertTrue(window.makeFirstResponder(paragraph))

        paragraph.setSelectedRange(NSRange(location: 0, length: 0))
        paragraph.insertText("추가 ", replacementRange: NSRange(location: 0, length: 0))
        settle()

        XCTAssertTrue(container.markdown.contains("추가 첫 문단이다."),
                      "입력이 모델에 실려야 한다")
        XCTAssertTrue(container.documentUndoManager.canUndo,
                      "문서 undo 스택에 등록되어야 한다")

        container.documentUndoManager.undo()
        settle()
        XCTAssertEqual(container.markdown, body, "되돌리면 바이트가 같아야 한다")
    }

    func testUndoThenRedoReturnsTheEdit() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(paragraph))
        paragraph.setSelectedRange(NSRange(location: 0, length: 0))
        paragraph.insertText("가", replacementRange: NSRange(location: 0, length: 0))
        settle()
        let edited = container.markdown

        container.documentUndoManager.undo()
        settle()
        XCTAssertEqual(container.markdown, body)

        container.documentUndoManager.redo()
        settle()
        XCTAssertEqual(container.markdown, edited,
                       "되돌리기와 같은 길을 지나므로 다시 하기도 되어야 한다")
    }

    // MARK: 블록이 갈리고 합쳐지는 것

    func testTypingABlankLineSplitsTheBlockAndKeepsTheText() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(paragraph))
        let before = container.blockCount

        // "첫 " 뒤에 빈 줄을 넣는다.
        paragraph.setSelectedRange(NSRange(location: 2, length: 0))
        paragraph.insertText("\n\n", replacementRange: NSRange(location: 2, length: 0))
        settle()

        XCTAssertGreaterThan(container.blockCount, before, "블록이 갈려야 한다")
        XCTAssertEqual(container.markdown, "# 제목\n\n첫 \n\n문단이다.\n\n둘째 문단이다.\n",
                       "갈려도 글자는 하나도 잃지 않아야 한다")
    }

    func testBackspaceAtTheStartOfABlockMergesItWithThePrevious() {
        guard let second = blocks.dropFirst(4).first else { return XCTFail("둘째 문단 뷰가 없다") }
        XCTAssertEqual(second.string, "둘째 문단이다.\n", "전제: 마지막 블록")
        XCTAssertTrue(window.makeFirstResponder(second))
        second.setSelectedRange(NSRange(location: 0, length: 0))

        second.deleteBackward(nil)
        settle()

        XCTAssertEqual(container.markdown, "# 제목\n\n첫 문단이다.\n둘째 문단이다.\n",
                       "블록 처음에서 Backspace는 앞 블록과 합치는 것이다")
    }

    // MARK: 한글 조합 보호 (§5.4)

    func testCaretDoesNotCrossBlocksWhileComposing() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(paragraph))
        paragraph.setSelectedRange(NSRange(location: paragraph.string.utf16.count, length: 0))

        // 조합을 시작한다 — `ㄱ`을 치고 아직 확정하지 않은 상태.
        paragraph.setMarkedText("ㄱ", selectedRange: NSRange(location: 0, length: 1),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(paragraph.hasMarkedText(), "전제: 조합 중")

        paragraph.moveDown(nil)
        XCTAssertTrue(window.firstResponder === paragraph,
                      "조합 중에 블록을 넘어가면 치던 글자가 사라진다")

        paragraph.unmarkText()
        paragraph.setSelectedRange(NSRange(location: paragraph.string.utf16.count, length: 0))
        paragraph.moveDown(nil)
        XCTAssertFalse(window.firstResponder === paragraph,
                       "조합이 끝나면 경계를 넘어야 한다")
    }

    /// 블록을 넘는 선택 위에 글자를 치면 **선택된 전부**가 대체되어야 한다.
    ///
    /// MarkText의 `crossBlockFormat.spec.ts`를 읽다 확인할 생각이 났다. 블록마다
    /// 텍스트 뷰가 따로이므로 `insertText`는 **자기 블록의 몫만** 지운다 — 나머지
    /// 블록의 선택된 글은 그대로 남아, 사용자가 보기에는 "선택했는데 일부만 바뀐다".
    func testTypingOverACrossBlockSelectionReplacesAllOfIt() {
        guard let first = blocks.first else { return XCTFail("블록 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(first))
        container.selectAll()
        XCTAssertTrue(container.selectionSpansBlocks, "전제: 블록을 넘는 선택")

        first.insertText("가", replacementRange: first.selectedRange())
        settle()

        // 전체 선택은 문서 끝의 줄바꿈까지 포함하므로, 대체 결과에 줄바꿈이 없는 것이
        // 맞다(일반 편집기도 그렇다).
        XCTAssertEqual(container.markdown, "가",
                       "선택한 전부가 대체되어야 한다 — 다른 블록의 글이 남으면 안 된다")
        XCTAssertEqual(container.blockCount, 1)
    }

    /// 되돌리면 캐럿이 **고치던 자리**로 돌아온다.
    ///
    /// MarkText(Muya)는 선택까지 undo 스택에 함께 쌓는다(`src/history/index.ts`).
    /// 그렇게 하지 않으면 긴 문단 가운데를 고치고 ⌘Z를 눌렀을 때 캐럿이 문단
    /// 처음으로 튀어, 고친 자리를 눈으로 다시 찾아야 한다.
    func testUndoPutsTheCaretBackWhereTheEditHappened() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(paragraph))
        // "첫 문단이다.\n"의 가운데(offset 4)에서 고친다.
        paragraph.setSelectedRange(NSRange(location: 4, length: 0))
        paragraph.insertText("X", replacementRange: NSRange(location: 4, length: 0))
        settle()
        XCTAssertTrue(container.markdown.contains("첫 문단X이다."), "전제: 가운데를 고쳤다")

        container.documentUndoManager.undo()
        settle()

        XCTAssertEqual(container.markdown, body)
        let caret = (window.firstResponder as? NSTextView)?.selectedRange().location
        XCTAssertEqual(caret, 4,
                       "되돌린 뒤 캐럿이 고치던 자리(4)가 아니라 \(caret ?? -1)에 있다")
    }

    // MARK: 되돌리기 묶기 — 이어지는 타이핑은 ⌘Z 한 번

    /// 한 글자마다 되돌리기를 쌓으면 다섯 글자를 치고 ⌘Z를 다섯 번 눌러야 한다.
    /// 기본 편집기(`NSTextView`)는 한 번이고, 그 차이가 "⌘Z가 이상하다"로 신고됐다
    /// (실측 5 대 1).
    private func undoStepsBackTo(_ target: String, limit: Int = 30) -> Int {
        var steps = 0
        while container.documentUndoManager.canUndo, steps < limit {
            container.documentUndoManager.undo()
            settle()
            steps += 1
            if container.markdown == target { break }
        }
        return steps
    }

    func testContiguousTypingIsOneUndoStep() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(paragraph))
        paragraph.setSelectedRange(NSRange(location: 0, length: 0))
        for ch in ["a", "b", "c", "d", "e"] {
            paragraph.insertText(ch, replacementRange: paragraph.selectedRange())
            settle()
        }
        XCTAssertTrue(container.markdown.contains("abcde첫 문단이다."), "전제: 다섯 글자가 들어갔다")
        // 전제: 모의 키 입력 하나하나가 **자기 되돌리기 묶음**에 들어간다. 이것이
        // 거짓이면(이벤트 묶기가 다섯을 한 묶음으로 넣으면) 아래 단정은 공허해진다 —
        // `NSUndoManager`가 묶은 것을 내 묶기가 한 일로 읽게 된다. 실측 결과 0이다.
        XCTAssertEqual(container.documentUndoManager.groupingLevel, 0,
                       "열린 묶음이 남아 있으면 이 테스트는 내 묶기를 재는 것이 아니다")

        XCTAssertEqual(undoStepsBackTo(body), 1,
                       "이어지는 타이핑은 ⌘Z 한 번에 되돌아가야 한다")
        XCTAssertEqual(container.markdown, body, "되돌리면 바이트가 같아야 한다")
    }

    /// 묶기가 **끊겨야 할 때 끊기는지.** 안 끊으면 서로 떨어진 두 편집이 한 ⌘Z에
    /// 함께 되돌아가, 사용자가 고치지 않은 자리까지 사라진다.
    func testMovingTheCaretStartsANewUndoStep() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(paragraph))

        paragraph.setSelectedRange(NSRange(location: 0, length: 0))
        paragraph.insertText("ab", replacementRange: paragraph.selectedRange())
        settle()
        // 캐럿을 **다른 곳으로** 옮기고 또 친다.
        paragraph.setSelectedRange(NSRange(location: paragraph.string.utf16.count - 1, length: 0))
        settle()
        paragraph.insertText("Z", replacementRange: paragraph.selectedRange())
        settle()

        container.documentUndoManager.undo()
        settle()
        XCTAssertFalse(container.markdown.contains("Z"), "뒤의 편집만 되돌아가야 한다")
        XCTAssertTrue(container.markdown.contains("ab첫 문단이다."),
                      "앞의 타이핑은 남아 있어야 한다 — 함께 되돌아가면 고치지 않은 자리가 사라진다")
    }

    func testTypingInAnotherBlockStartsANewUndoStep() {
        let views = blocks
        guard views.count > 4 else { return XCTFail("블록이 모자라다") }
        XCTAssertTrue(window.makeFirstResponder(views[2]))
        views[2].setSelectedRange(NSRange(location: 0, length: 0))
        views[2].insertText("a", replacementRange: views[2].selectedRange())
        settle()

        XCTAssertTrue(window.makeFirstResponder(views[4]))
        views[4].setSelectedRange(NSRange(location: 0, length: 0))
        views[4].insertText("b", replacementRange: views[4].selectedRange())
        settle()

        container.documentUndoManager.undo()
        settle()
        XCTAssertTrue(container.markdown.contains("a첫 문단이다."),
                      "다른 블록의 편집이 함께 되돌아갔다")
        XCTAssertFalse(container.markdown.contains("b둘째"), "뒤의 편집은 되돌아가야 한다")
    }

    /// 묶인 런도 다시 하기(⌘⇧Z) 한 번에 되살아나야 한다.
    func testRedoRestoresACoalescedRunInOneStep() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(paragraph))
        paragraph.setSelectedRange(NSRange(location: 0, length: 0))
        for ch in ["a", "b", "c"] {
            paragraph.insertText(ch, replacementRange: paragraph.selectedRange())
            settle()
        }
        let typed = container.markdown

        container.documentUndoManager.undo()
        settle()
        XCTAssertEqual(container.markdown, body)

        var redos = 0
        while container.documentUndoManager.canRedo, redos < 10 {
            container.documentUndoManager.redo(); settle(); redos += 1
        }
        XCTAssertEqual(redos, 1, "묶인 런은 다시 하기도 한 번이어야 한다")
        XCTAssertEqual(container.markdown, typed)
    }

    /// 줄바꿈은 런을 가른다.
    ///
    /// Enter 한 번은 **구조를 바꾸지 않는다** — 마크다운에서 `a\n첫 문단`은 여전히
    /// 한 문단이라 블록이 쪼개지지 않고, 그래서 이 편집도 타이핑과 같은 경로를 지난다.
    /// 가르지 않으면 "ab" + Enter + "cd"가 ⌘Z 하나가 되어, 줄바꿈만 되돌리려던
    /// 사용자가 앞 문장까지 잃는다(실측으로 드러났다 — 처음엔 이 경우를 구조 변경으로
    /// 잘못 알고 테스트를 썼다).
    func testLineBreakIsItsOwnUndoStep() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(paragraph))
        paragraph.setSelectedRange(NSRange(location: 0, length: 0))
        paragraph.insertText("ab", replacementRange: paragraph.selectedRange())
        settle()
        paragraph.insertNewline(nil)
        settle()
        paragraph.insertText("cd", replacementRange: paragraph.selectedRange())
        settle()
        XCTAssertTrue(container.markdown.contains("ab\ncd첫 문단이다."),
                      "전제: 줄바꿈 앞뒤로 쳤다 — 실제 \(container.markdown.debugDescription)")

        container.documentUndoManager.undo()      // "cd"만
        settle()
        XCTAssertTrue(container.markdown.contains("ab\n첫 문단이다."),
                      "뒤의 타이핑만 되돌아가야 한다 — 실제 \(container.markdown.debugDescription)")

        container.documentUndoManager.undo()      // 줄바꿈만
        settle()
        XCTAssertTrue(container.markdown.contains("ab첫 문단이다."),
                      "줄바꿈만 되돌아가야 한다 — 실제 \(container.markdown.debugDescription)")

        container.documentUndoManager.undo()      // "ab"
        settle()
        XCTAssertEqual(container.markdown, body)
    }

    /// 구조가 바뀌는 편집(빈 줄로 문단을 둘로 쪼개기)은 런을 끊는다.
    ///
    /// Enter **두 번**이어야 블록이 쪼개진다 — 한 번은 위의 소프트 줄바꿈이다.
    func testStructuralEditBreaksTheRun() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(paragraph))
        paragraph.setSelectedRange(NSRange(location: 0, length: 0))
        paragraph.insertText("a", replacementRange: paragraph.selectedRange())
        settle()
        paragraph.insertNewline(nil)
        settle()
        paragraph.insertNewline(nil)
        settle()
        let afterSplit = container.markdown
        XCTAssertTrue(afterSplit.contains("a\n\n첫 문단이다."),
                      "전제: 쪼개졌다 — 실제 \(afterSplit.debugDescription)")

        container.documentUndoManager.undo()
        settle()
        XCTAssertTrue(container.markdown.contains("a"),
                      "쪼개기를 되돌렸을 때 그 앞의 타이핑까지 사라지면 안 된다 — "
                      + "실제 \(container.markdown.debugDescription)")
    }

    /// 앞으로 지우기(fn+Delete) 뒤의 되돌리기 캐럿.
    ///
    /// 길이 차이로 어림하면 한 칸 밀린다(실측: 기대 2, 실제 3). Backspace는 캐럿 앞을,
    /// 앞으로 지우기는 캐럿 뒤를 고치는데 **편집 뒤의 캐럿은 두 경우가 같은 자리**라
    /// (old, new, 지금 캐럿)만으로는 가를 수 없다. 그래서 편집 전 캐럿을 잡아 쓴다.
    func testUndoAfterForwardDeleteKeepsTheCaretWhereItWas() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(paragraph))
        paragraph.setSelectedRange(NSRange(location: 2, length: 0))
        paragraph.deleteForward(nil)
        settle()
        XCTAssertTrue(container.markdown.contains("첫 단이다."), "전제: 캐럿 뒤 글자가 지워졌다")

        container.documentUndoManager.undo()
        settle()
        XCTAssertEqual(container.markdown, body)
        let caret = (window.firstResponder as? NSTextView)?.selectedRange().location
        XCTAssertEqual(caret, 2,
                       "앞으로 지우기는 캐럿을 옮기지 않으므로 되돌린 뒤에도 2여야 한다")
    }

    /// Backspace 쪽도 함께 못박는다 — 두 방향이 같은 코드를 지나므로, 한쪽만 맞는
    /// 보정은 다른 쪽을 깨뜨린다.
    func testUndoAfterBackspaceKeepsTheCaretWhereItWas() {
        guard let paragraph = blocks.dropFirst(2).first else { return XCTFail("문단 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(paragraph))
        paragraph.setSelectedRange(NSRange(location: 3, length: 0))
        paragraph.deleteBackward(nil)
        settle()

        container.documentUndoManager.undo()
        settle()
        XCTAssertEqual(container.markdown, body)
        let caret = (window.firstResponder as? NSTextView)?.selectedRange().location
        XCTAssertEqual(caret, 3, "Backspace는 캐럿 앞을 지우므로 되돌린 뒤 3이어야 한다")
    }

    /// 블록을 넘어갈 때 **가로 위치**를 지킨다 — 설계 §5.3의 약속.
    func testCaretKeepsItsHorizontalPositionAcrossBlocks() {
        // 빈 줄을 두지 않는다 — 빈 줄 블록은 캐럿 자리가 0뿐이라 가로 위치를
        // 지켰는지 알 수 없다(처음 쓴 테스트가 그래서 0을 보고 실패했다).
        container.markdown = "# 제목은 꽤 길게 쓴 제목입니다\n둘째 줄도 비슷하게 길게 씁니다\n"
        settle()
        guard let first = blocks.first, blocks.count >= 2 else { return XCTFail("블록이 부족하다") }
        XCTAssertTrue(window.makeFirstResponder(first))

        // 첫 블록의 글 가운데에 캐럿을 두고 ↓.
        first.setSelectedRange(NSRange(location: 8, length: 0))
        first.moveDown(nil)
        settle()

        guard let landed = window.firstResponder as? NSTextView else {
            return XCTFail("캐럿이 어느 블록에도 없다")
        }
        XCTAssertFalse(landed === first, "다음 블록으로 가야 한다")
        XCTAssertGreaterThan(landed.selectedRange().location, 0,
                             "가로 위치를 버리면 줄 맨 앞(0)으로 떨어진다 — "
                             + "긴 문단 사이를 오르내릴 수 없다")
    }

    func testCaretCrossesBlocksOnArrowAtTheBoundary() {
        guard let first = blocks.first, blocks.count > 1 else { return XCTFail("블록이 부족하다") }
        XCTAssertTrue(window.makeFirstResponder(first))
        first.setSelectedRange(NSRange(location: first.string.utf16.count, length: 0))
        first.moveDown(nil)
        XCTAssertFalse(window.firstResponder === first,
                       "마지막 줄에서 ↓는 다음 블록으로 가야 한다")
    }

    /// 조합 중에는 **문서가 바뀌지 않는다.**
    ///
    /// 한글은 조합 중에 Backspace로 자모를 하나씩 되돌린다(`각` → `가` → `ㄱ`).
    /// 그 사이에 편집기가 블록을 허물고 다시 세우면 치던 글자가 사라진다.
    /// MarkText(Muya)는 같은 규칙을 키마다 테스트로 고정해 두었다
    /// (`imeBackspaceComposition.spec.ts` · `imeTabComposition.spec.ts`).
    ///
    /// **이 테스트가 증명하지 않는 것:** `deleteBackward`에 넣은
    /// `!hasMarkedText()` 가드가 걸린다는 것. 변이로 확인해 보니 그 가드를 없애도
    /// 이 테스트는 초록이다 — 조합이 캐럿을 (0,0)에 두지 않아 합치기 조건 자체가
    /// 거짓이고, 블록을 넘는 삭제는 조합이 선택을 줄여서 닿지 않는다. 가드는 그
    /// 두 경로가 바뀌었을 때를 위한 방어로 남겼고, 여기 있는 것은 **동작**에 대한
    /// 약속이다.
    func testBackspaceDuringCompositionDoesNotChangeTheDocument() {
        guard let second = blocks.dropFirst(4).first else { return XCTFail("둘째 문단 뷰가 없다") }
        XCTAssertEqual(second.string, "둘째 문단이다.\n", "전제: 마지막 블록")
        XCTAssertTrue(window.makeFirstResponder(second))
        second.setSelectedRange(NSRange(location: 0, length: 0))
        let before = container.markdown
        let blocksBefore = container.blockCount

        second.setMarkedText("ㄱ", selectedRange: NSRange(location: 0, length: 1),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(second.hasMarkedText(), "전제: 조합 중")
        second.deleteBackward(nil)
        settle()

        XCTAssertEqual(container.blockCount, blocksBefore,
                       "조합 중의 Backspace가 블록을 합쳤다 — 입력기에 넘겨야 한다")
        XCTAssertEqual(container.markdown, before, "조합 중의 Backspace로 문서가 바뀌었다")
        second.unmarkText()
    }

    /// 조합 중의 ⌘A는 문서 전체를 잡지 않는다.
    ///
    /// 위와 같이 **동작에 대한 약속**이다. 오늘은 조합이 시작될 때 선택이 그 블록
    /// 안으로 줄어들어서 저절로 성립하고, `selectAll`의 조합 가드를 없애도 이
    /// 테스트는 초록이다.
    func testSelectAllDuringCompositionDoesNotSpanBlocks() {
        guard let first = blocks.first else { return XCTFail("블록 뷰가 없다") }
        XCTAssertTrue(window.makeFirstResponder(first))
        first.setSelectedRange(NSRange(location: 0, length: 0))
        first.setMarkedText("ㄱ", selectedRange: NSRange(location: 0, length: 1),
                            replacementRange: NSRange(location: NSNotFound, length: 0))

        first.selectAll(nil)
        XCTAssertFalse(container.selectionSpansBlocks,
                       "조합 중의 ⌘A가 문서 전체를 잡으면 조합 중인 범위가 밀린다")
        first.unmarkText()
    }
}
