import XCTest
// Core 소스는 이 번들에 직접 컴파일된다 — import가 필요 없다.

/// 블록 편집기 단계 1의 **판단**을 지키는 테스트 — `docs/block-editor-design.md` §5.
///
/// 여기 있는 것은 그리기가 아니라 규칙이다. 특히 한글 조합 보호는 설계가 "한국어
/// 사용자에게 가장 먼저 티가 나는 결함"이라고 적은 것이라 손으로 눌러 보는 것에
/// 맡길 수 없다.
final class BlockEditorPhase1Tests: XCTestCase {

    private let parser = BlockParser()
    private let serializer = BlockSerializer()
    private let factory = BlockEditFactory()

    // MARK: 블록을 넘는 선택 (§5.1)

    func testCoverageSplitsIntoStartMiddleEnd() {
        let selection = BlockSelection(anchor: BlockPosition(blockIndex: 1, offset: 3),
                                       head: BlockPosition(blockIndex: 4, offset: 2))
        XCTAssertEqual(selection.coverage(ofBlockAt: 0), .outside)
        XCTAssertEqual(selection.coverage(ofBlockAt: 1),
                       .partial(NSRange(location: 3, length: NSNotFound)),
                       "시작 블록은 길이를 모르는 채 '오프셋부터 끝까지'여야 한다")
        XCTAssertEqual(selection.coverage(ofBlockAt: 2), .whole)
        XCTAssertEqual(selection.coverage(ofBlockAt: 3), .whole)
        XCTAssertEqual(selection.coverage(ofBlockAt: 4), .partial(NSRange(location: 0, length: 2)))
        XCTAssertEqual(selection.coverage(ofBlockAt: 5), .outside)
    }

    func testCoverageIsDirectionIndependent() {
        let forward = BlockSelection(anchor: BlockPosition(blockIndex: 0, offset: 1),
                                     head: BlockPosition(blockIndex: 2, offset: 4))
        let backward = BlockSelection(anchor: BlockPosition(blockIndex: 2, offset: 4),
                                      head: BlockPosition(blockIndex: 0, offset: 1))
        for index in 0 ... 3 {
            XCTAssertEqual(forward.coverage(ofBlockAt: index), backward.coverage(ofBlockAt: index),
                           "뒤로 끈 선택도 같은 몫이어야 한다 (블록 \(index))")
        }
    }

    func testSelectionAssemblesMarkdownAcrossBlocks() {
        let body = "첫 문단이다.\n\n## 가운데 제목\n\n마지막 문단이다.\n"
        let blocks = parser.parseBlocks(body)
        XCTAssertEqual(blocks.count, 5, "전제: 문단·빈 줄·제목·빈 줄·문단 다섯 블록")

        // 전제를 재서 못박는다 — 오프셋은 UTF-16이고 눈으로 세면 틀린다.
        XCTAssertEqual(blocks[0].sourceSlice, "첫 문단이다.\n")
        XCTAssertEqual(blocks[4].sourceSlice, "마지막 문단이다.\n")

        // 첫 문단의 `첫 ` 뒤부터 마지막 문단의 `마지막`까지.
        let selection = BlockSelection(anchor: BlockPosition(blockIndex: 0, offset: 2),
                                       head: BlockPosition(blockIndex: 4, offset: 3))
        let copied = selection.markdown(in: blocks)

        XCTAssertTrue(copied.hasPrefix("문단이다."), "시작 블록은 오프셋부터 끝까지여야 한다")
        XCTAssertTrue(copied.contains("## 가운데 제목"), "가운데 블록은 통째로 들어가야 한다")
        XCTAssertTrue(copied.hasSuffix("마지막"), "끝 블록은 오프셋까지만이어야 한다")
        XCTAssertFalse(copied.contains("첫 "), "선택 밖의 글자가 들어가면 안 된다")
    }

    func testFullSelectionCopiesTheWholeDocumentByteForByte() {
        let body = "# 제목\n\n본문 **굵게**.\n\n| 가 | 나 |\n| --- | --- |\n| 1 | 2 |\n"
        let blocks = parser.parseBlocks(body)
        let last = blocks.count - 1
        let selection = BlockSelection(
            anchor: BlockPosition(blockIndex: 0, offset: 0),
            head: BlockPosition(blockIndex: last,
                                offset: (blocks[last].sourceSlice as NSString).length))
        XCTAssertEqual(selection.markdown(in: blocks), body,
                       "전체 선택을 복사하면 원문과 바이트가 같아야 한다")
    }

    func testCollapsedSelectionCopiesNothing() {
        let blocks = parser.parseBlocks("한 줄.\n")
        let caret = BlockSelection(caretAt: BlockPosition(blockIndex: 0, offset: 2))
        XCTAssertEqual(caret.markdown(in: blocks), "")
    }

    // MARK: 문서 레벨 되돌리기 (§5.2)

    func testEditAndItsInverseRestoreTheDocumentByteForByte() {
        let body = "첫 문단.\n\n둘째 문단.\n"
        var document = BlockDocument(frontMatter: nil, blocks: parser.parseBlocks(body))
        let before = serializer.serialize(document)

        let edit = factory.textEdit(in: document, blockIndex: 0, newSource: "# 제목이 됐다\n")
        XCTAssertNotNil(edit)
        XCTAssertTrue(edit!.apply(to: &document))
        XCTAssertNotEqual(serializer.serialize(document), before, "편집이 실제로 글을 바꿔야 한다")

        XCTAssertTrue(edit!.inverted().apply(to: &document))
        XCTAssertEqual(serializer.serialize(document), before,
                       "되돌리면 바이트가 같아야 한다")
        XCTAssertEqual(document.blocks, parser.parseBlocks(body),
                       "되돌린 모델이 처음과 같아야 한다")
    }

    func testTextEditRetypesTheBlockKindThroughTheParser() {
        let body = "그냥 문단이다.\n"
        var document = BlockDocument(frontMatter: nil, blocks: parser.parseBlocks(body))
        XCTAssertEqual(document.blocks[0].kind, .paragraph, "전제: 처음엔 문단")

        let edit = factory.textEdit(in: document, blockIndex: 0, newSource: "## 제목이다\n")
        XCTAssertNotNil(edit)
        edit!.apply(to: &document)

        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].kind, .heading(level: 2),
                       "`## `을 치면 블록 종류가 제목으로 바뀌어야 한다")
    }

    func testTextEditThatAddsABlankLineSplitsTheBlock() {
        var document = BlockDocument(frontMatter: nil, blocks: parser.parseBlocks("앞뒤 한 문단.\n"))
        XCTAssertEqual(document.blocks.count, 1, "전제: 한 블록")

        let edit = factory.textEdit(in: document, blockIndex: 0, newSource: "앞.\n\n뒤.\n")
        XCTAssertNotNil(edit)
        edit!.apply(to: &document)

        XCTAssertEqual(document.blocks.count, 3,
                       "빈 줄이 들어오면 문단·빈 줄·문단 세 블록이어야 한다")
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph, .blankLines, .paragraph])
        XCTAssertEqual(serializer.serialize(document), "앞.\n\n뒤.\n")
    }

    func testSingleBlockTextEditKeepsTheBlockIdentity() {
        let document = BlockDocument(frontMatter: nil, blocks: parser.parseBlocks("문단.\n"))
        let originalID = document.blocks[0].id

        let edit = factory.textEdit(in: document, blockIndex: 0, newSource: "문단이 길어졌다.\n")
        XCTAssertEqual(edit?.new.count, 1)
        XCTAssertEqual(edit?.new.first?.id, originalID,
                       "한 글자 칠 때마다 식별자가 바뀌면 뷰가 새로 만들어져 조합 중인 한글이 날아간다")
    }

    func testEmptyingABlockRemovesIt() {
        var document = BlockDocument(frontMatter: nil, blocks: parser.parseBlocks("지울 문단.\n"))
        let edit = factory.textEdit(in: document, blockIndex: 0, newSource: "")
        XCTAssertNotNil(edit)
        edit!.apply(to: &document)
        XCTAssertTrue(document.blocks.isEmpty)
        XCTAssertEqual(serializer.serialize(document), "")
    }

    func testTextEditWithNoChangeProducesNoUndoEntry() {
        let document = BlockDocument(frontMatter: nil, blocks: parser.parseBlocks("그대로.\n"))
        XCTAssertNil(factory.textEdit(in: document, blockIndex: 0, newSource: "그대로.\n"),
                     "바뀌지 않은 편집이 undo 스택에 들어가면 ⌘Z가 아무 일도 안 하는 것처럼 보인다")
    }

    func testDeletionAcrossBlocksMergesTheSurvivingEnds() {
        let body = "앞 문단이다.\n\n뒤 문단이다.\n"
        var document = BlockDocument(frontMatter: nil, blocks: parser.parseBlocks(body))
        XCTAssertEqual(document.blocks.count, 3, "전제: 문단·빈 줄·문단")

        // "앞 " 뒤부터 마지막 블록의 "뒤 " 뒤까지 지운다.
        let selection = BlockSelection(anchor: BlockPosition(blockIndex: 0, offset: 2),
                                       head: BlockPosition(blockIndex: 2, offset: 2))
        let edit = factory.deletion(in: document, selection: selection)
        XCTAssertNotNil(edit)
        edit!.apply(to: &document)

        XCTAssertEqual(serializer.serialize(document), "앞 문단이다.\n",
                       "걸친 블록은 한 조각으로 합쳐 다시 읽어야 한다")
        XCTAssertEqual(document.blocks.count, 1)
    }

    func testDeletionIsInvertible() {
        let body = "하나.\n\n둘.\n\n셋.\n"
        var document = BlockDocument(frontMatter: nil, blocks: parser.parseBlocks(body))
        let before = serializer.serialize(document)

        let selection = BlockSelection(anchor: BlockPosition(blockIndex: 0, offset: 1),
                                       head: BlockPosition(blockIndex: 4, offset: 1))
        let edit = factory.deletion(in: document, selection: selection)
        XCTAssertNotNil(edit)
        edit!.apply(to: &document)
        XCTAssertNotEqual(serializer.serialize(document), before)

        edit!.inverted().apply(to: &document)
        XCTAssertEqual(serializer.serialize(document), before,
                       "블록 개수가 바뀌는 편집도 뒤집을 수 있어야 한다")
    }

    func testTableEditMarksOnlyThatBlockModified() {
        let body = "앞 글.\n\n| 가 | 나 |\n| --- | --- |\n| 1 | 2 |\n"
        var document = BlockDocument(frontMatter: nil, blocks: parser.parseBlocks(body))
        guard let tableIndex = document.blocks.firstIndex(where: {
            if case .table = $0.kind { return true } else { return false }
        }) else { return XCTFail("전제: 표 블록이 있어야 한다") }

        let edit = factory.tableEdit(in: document, blockIndex: tableIndex) { model in
            model.setCell(row: 1, column: 0, plainText: "고침")
        }
        XCTAssertNotNil(edit)
        edit!.apply(to: &document)

        XCTAssertTrue(document.blocks[tableIndex].isModified)
        XCTAssertFalse(document.blocks[0].isModified, "고치지 않은 블록은 그대로여야 한다")
        XCTAssertTrue(serializer.serialize(document).hasPrefix("앞 글.\n\n"),
                      "고치지 않은 블록은 원문 조각이 그대로 나와야 한다")
        XCTAssertTrue(serializer.serialize(document).contains("고침"))
    }

    // MARK: 블록이 갈린 뒤의 캐럿

    func testCaretLandsInTheBlockThatHoldsTheOffsetAfterASplit() {
        // `앞.\n\n뒤.\n` → 문단(3) · 빈 줄(1) · 문단(3)
        let blocks = parser.parseBlocks("앞.\n\n뒤.\n")
        XCTAssertEqual(blocks.map { ($0.sourceSlice as NSString).length }, [3, 1, 3],
                       "전제: 조각 길이 3·1·3 (UTF-16)")

        // 갈리기 전 캐럿이 4였다면 셋째 블록의 처음이다(3 + 1 = 4).
        let position = BlockEdit.position(forOffset: 4, within: blocks, firstBlockIndex: 0)
        XCTAssertEqual(position, BlockPosition(blockIndex: 2, offset: 0),
                       "Enter를 쳐서 갈린 뒤 캐럿은 새로 생긴 아래 문단에 있어야 한다")
    }

    func testCaretOffsetIsRelativeToTheBlockItLandsIn() {
        let blocks = parser.parseBlocks("앞.\n\n뒤쪽 글.\n")
        let position = BlockEdit.position(forOffset: 6, within: blocks, firstBlockIndex: 0)
        XCTAssertEqual(position.blockIndex, 2)
        XCTAssertEqual(position.offset, 2, "3 + 1을 지나고 남은 2가 블록 안의 오프셋이다")
    }

    func testCaretRemapIsOffsetByTheFirstBlockIndex() {
        let blocks = parser.parseBlocks("앞.\n\n뒤.\n")
        let position = BlockEdit.position(forOffset: 0, within: blocks, firstBlockIndex: 7)
        XCTAssertEqual(position, BlockPosition(blockIndex: 7, offset: 0),
                       "갈린 블록이 문서 가운데 있으면 그 번호부터 세야 한다")
    }

    func testCaretBeyondTheEndClampsToTheLastBlock() {
        let blocks = parser.parseBlocks("앞.\n\n뒤.\n")
        let position = BlockEdit.position(forOffset: 9_999, within: blocks, firstBlockIndex: 0)
        XCTAssertEqual(position.blockIndex, 2)
        XCTAssertEqual(position.offset, 3, "마지막 블록의 끝을 넘어가지 않아야 한다")
    }

    func testCaretRemapOnAnEmptyReplacementStaysPut() {
        let position = BlockEdit.position(forOffset: 5, within: [], firstBlockIndex: 3)
        XCTAssertEqual(position, BlockPosition(blockIndex: 3, offset: 0),
                       "블록이 모두 사라진 자리에서도 쓸 수 있는 자리를 내놔야 한다")
    }

    // MARK: 캐럿 경계 이동 (§5.3)

    func testCaretTargetAtDocumentEdgesIsNil() {
        XCTAssertNil(BlockCaretNavigation.target(from: 0, direction: .up, blockCount: 3),
                     "첫 블록에서 ↑는 갈 곳이 없다")
        XCTAssertNil(BlockCaretNavigation.target(from: 2, direction: .down, blockCount: 3),
                     "마지막 블록에서 ↓는 갈 곳이 없다")
        XCTAssertNil(BlockCaretNavigation.target(from: 0, direction: .down, blockCount: 0))
    }

    func testCaretEntersTheNeighbourFromTheSideItCameFrom() {
        XCTAssertEqual(BlockCaretNavigation.target(from: 1, direction: .down, blockCount: 3),
                       .init(blockIndex: 2, edge: .top))
        XCTAssertEqual(BlockCaretNavigation.target(from: 1, direction: .up, blockCount: 3),
                       .init(blockIndex: 0, edge: .bottom))
    }

    // MARK: 입력기 보호 (§5.4)

    func testBoundaryMoveIsBlockedWhileComposingHangul() {
        var guardState = BlockInputGuard()
        XCTAssertTrue(guardState.allowsBoundaryMove, "조합 전에는 자유롭게 움직인다")

        guardState.setComposing(true)   // `ㄱ` — 조합 시작
        XCTAssertFalse(guardState.allowsBoundaryMove,
                       "조합 중에 블록을 넘어가면 치던 글자가 사라진다")

        guardState.setComposing(false)  // `각` — 확정
        XCTAssertTrue(guardState.allowsBoundaryMove)
    }

    func testStructureChangeIsDeferredNotDroppedWhileComposing() {
        var guardState = BlockInputGuard()
        guardState.setComposing(true)

        XCTAssertFalse(guardState.requestStructureChange(),
                       "조합 중에는 블록을 갈아 끼울 수 없다")
        XCTAssertTrue(guardState.hasPendingStructureChange, "미뤘다는 사실이 남아야 한다")
        XCTAssertFalse(guardState.takePendingStructureChange(),
                       "조합이 끝나기 전에는 가져갈 수 없다")

        guardState.setComposing(false)
        XCTAssertTrue(guardState.takePendingStructureChange(),
                      "조합이 끝나면 미뤄 둔 구조 변경이 반드시 일어나야 한다")
        XCTAssertFalse(guardState.takePendingStructureChange(),
                       "두 번 가져가지면 같은 편집이 두 번 적용된다")
    }

    func testStructureChangeRunsImmediatelyWhenNotComposing() {
        var guardState = BlockInputGuard()
        XCTAssertTrue(guardState.requestStructureChange())
        XCTAssertFalse(guardState.hasPendingStructureChange)
    }

    // MARK: 가시 범위 레이아웃 (§4)

    func testPlacementsStackWithSpacingAndTotalHeightExcludesTheTrailingGap() {
        let layout = BlockViewportLayout(spacing: 10, overscan: 0)
        let heights = [100.0, 50.0, 20.0]
        let placements = layout.placements(heights: heights)

        XCTAssertEqual(placements.map(\.y), [0, 110, 170])
        XCTAssertEqual(layout.totalHeight(heights: heights), 190,
                       "170 + 20 — 마지막 블록 뒤의 간격은 더하지 않는다")
    }

    func testOnlyBlocksNearTheViewportGetViews() {
        let layout = BlockViewportLayout(spacing: 0, overscan: 0)
        let heights = [Double](repeating: 100, count: 20)
        let placements = layout.placements(heights: heights)

        let visible = layout.visible(placements: placements, visibleOrigin: 500, visibleHeight: 300)
        XCTAssertEqual(visible.map(\.blockIndex), [5, 6, 7],
                       "보이는 범위를 벗어난 블록에 뷰를 만들면 500블록 문서에서 여는 순간이 체감된다")
    }

    func testOverscanWidensTheVisibleWindow() {
        let layout = BlockViewportLayout(spacing: 0, overscan: 150)
        let heights = [Double](repeating: 100, count: 20)
        let placements = layout.placements(heights: heights)

        let visible = layout.visible(placements: placements, visibleOrigin: 500, visibleHeight: 300)
        XCTAssertEqual(visible.map(\.blockIndex), [3, 4, 5, 6, 7, 8, 9],
                       "굴릴 때 끊겨 보이지 않도록 위아래로 더 만들어 둔다")
    }

    func testZeroHeightBlockAtTheBoundaryStillGetsAView() {
        let layout = BlockViewportLayout(spacing: 0, overscan: 0)
        // 빈 줄 블록은 높이가 0일 수 있다. 뷰가 없으면 그 자리에 캐럿을 놓을 수 없다.
        let placements = layout.placements(heights: [100, 0, 100])
        let visible = layout.visible(placements: placements, visibleOrigin: 100, visibleHeight: 50)
        XCTAssertTrue(visible.contains { $0.blockIndex == 1 })
    }

    func testEmptyDocumentHasNoPlacements() {
        let layout = BlockViewportLayout()
        XCTAssertTrue(layout.placements(heights: []).isEmpty)
        XCTAssertEqual(layout.totalHeight(heights: []), 0)
        XCTAssertTrue(layout.visible(placements: [], visibleOrigin: 0, visibleHeight: 600).isEmpty)
    }

    func testBlockIndexAtPointFindsTheBlockUnderTheClick() {
        let layout = BlockViewportLayout(spacing: 8, overscan: 0)
        let placements = layout.placements(heights: [100, 50, 70])
        XCTAssertEqual(layout.blockIndex(at: 10, placements: placements), 0)
        XCTAssertEqual(layout.blockIndex(at: 120, placements: placements), 1)
        XCTAssertEqual(layout.blockIndex(at: 10_000, placements: placements), 2,
                       "문서 아래 빈 곳을 클릭하면 마지막 블록이다")
    }
}
