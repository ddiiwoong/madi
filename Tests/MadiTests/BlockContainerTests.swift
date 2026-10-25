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
