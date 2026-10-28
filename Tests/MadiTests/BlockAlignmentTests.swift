import XCTest
@testable import Madi

final class BlockAlignmentTests: XCTestCase {

    private typealias Key = BlockAlignment.Key

    private func pairs(_ a: BlockAlignment) -> [[Int]] {
        a.pairs.map { [$0.source, $0.target] }
    }

    // MARK: 짝짓기

    func testIdenticalSequencesPairOneToOne() {
        let keys: [Key] = [.heading(level: 1), .blankLines, .paragraph, .blankLines, .codeBlock]
        let alignment = BlockAlignment.align(source: keys, target: keys)
        XCTAssertEqual(pairs(alignment), [[0, 0], [1, 1], [2, 2], [3, 3], [4, 4]])
    }

    func testInsertedBlockInTargetIsLeftUnpaired() {
        let source: [Key] = [.heading(level: 1), .paragraph, .codeBlock]
        let target: [Key] = [.heading(level: 1), .paragraph, .quote, .codeBlock]
        let alignment = BlockAlignment.align(source: source, target: target)
        XCTAssertEqual(pairs(alignment), [[0, 0], [1, 1], [2, 3]])
    }

    func testRemovedBlockInTargetIsLeftUnpaired() {
        let source: [Key] = [.paragraph, .thematicBreak, .paragraph, .table]
        let target: [Key] = [.paragraph, .paragraph, .table]
        let alignment = BlockAlignment.align(source: source, target: target)
        XCTAssertEqual(pairs(alignment), [[0, 0], [2, 1], [3, 2]])
    }

    /// 앞뒤 깎기만으로 끝나지 않는 경우 — 가운데 구간에서 LCS가 돈다.
    func testMiddleDifferenceUsesLongestCommonSubsequence() {
        let source: [Key] = [.heading(level: 1), .paragraph, .list(ordered: false), .quote, .paragraph, .heading(level: 2)]
        let target: [Key] = [.heading(level: 1), .quote, .paragraph, .list(ordered: false), .paragraph, .heading(level: 2)]
        let alignment = BlockAlignment.align(source: source, target: target)
        // 가운데 [p ul q p] 대 [q p ul p]의 LCS 길이는 3이다(p ul p).
        XCTAssertEqual(alignment.pairs.count, 2 + 3)
        assertStrictlyIncreasing(alignment)
        for pair in alignment.pairs {
            XCTAssertEqual(source[pair.source], target[pair.target], "짝은 같은 꼴끼리만")
        }
    }

    /// 제목 수준이 다르면 다른 블록이다. 같다고 보면 `## 가`와 `### 나`가 엇갈려 짝지어진다.
    func testHeadingLevelIsPartOfTheKey() {
        XCTAssertNotEqual(Key(.heading(level: 2)), Key(.heading(level: 3)))
    }

    /// 표의 행 수와 코드 블록의 언어는 키에 없다 — 한쪽에서 행을 더해도 같은 블록이다.
    func testTableShapeAndCodeLanguageAreNotPartOfTheKey() {
        let small = TableModel(alignments: [.none], rows: [["a"], ["b"]])
        let large = TableModel(alignments: [.none, .none], rows: [["a", "x"], ["b", "y"], ["c", "z"]])
        XCTAssertEqual(Key(.table(small)), Key(.table(large)))
        XCTAssertEqual(Key(.codeBlock(language: "swift")), Key(.codeBlock(language: nil)))
    }

    func testEmptySidesProduceNoPairs() {
        XCTAssertEqual(BlockAlignment.align(source: [], target: [.paragraph]).pairs, [])
        XCTAssertEqual(BlockAlignment.align(source: [.paragraph], target: []).pairs, [])
    }

    /// 실제 문서로 — 같은 파서로 나눈 같은 글은 블록마다 짝지어진다.
    func testParsedDocumentAlignsWithItself() {
        let text = "# 제목\n\n첫 문단.\n\n- 하나\n- 둘\n\n```swift\nlet x = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        let blocks = BlockParser().parse(text).blocks
        let alignment = BlockAlignment.align(source: blocks, target: blocks)
        XCTAssertEqual(alignment.pairs.count, blocks.count)
        XCTAssertGreaterThan(blocks.count, 6, "전제: 블록이 여럿으로 나뉜다")
    }

    // MARK: 위치 옮기기

    func testIdenticalAlignmentIsIdentityMapping() {
        let keys: [Key] = [.paragraph, .blankLines, .paragraph]
        let alignment = BlockAlignment.align(source: keys, target: keys)
        for x in [0.0, 0.25, 1.0, 1.5, 2.99, 3.0] {
            XCTAssertEqual(alignment.targetPosition(forSource: x), x, accuracy: 1e-9)
            XCTAssertEqual(alignment.sourcePosition(forTarget: x), x, accuracy: 1e-9)
        }
    }

    /// 짝지어진 블록 안에서는 비율이 그대로 옮겨진다 — 앞에 짝 없는 블록이 있어도.
    func testFractionWithinPairedBlockIsPreserved() {
        let source: [Key] = [.paragraph, .codeBlock]
        let target: [Key] = [.paragraph, .quote, .codeBlock]
        let alignment = BlockAlignment.align(source: source, target: target)
        // 원문의 코드 블록(1)의 30% 지점 → 번역본의 코드 블록(2)의 30% 지점.
        XCTAssertEqual(alignment.targetPosition(forSource: 1.3), 2.3, accuracy: 1e-9)
        XCTAssertEqual(alignment.sourcePosition(forTarget: 2.3), 1.3, accuracy: 1e-9)
    }

    /// 번역본에만 있는 블록을 지나는 동안 원문은 **제자리에 서 있다.**
    func testOtherSideHoldsStillAcrossAnUnpairedBlock() {
        let source: [Key] = [.paragraph, .codeBlock]
        let target: [Key] = [.paragraph, .quote, .codeBlock]
        let alignment = BlockAlignment.align(source: source, target: target)
        for y in [1.0, 1.2, 1.5, 1.99, 2.0] {
            XCTAssertEqual(alignment.sourcePosition(forTarget: y), 1.0, accuracy: 1e-9,
                           "번역본 \(y)")
        }
        // 반대 방향: 원문 코드 블록의 처음은 번역본의 **코드 블록** 처음이다 —
        // 인용 블록 처음(1.0)이 아니다.
        XCTAssertEqual(alignment.targetPosition(forSource: 1.0), 2.0, accuracy: 1e-9)
    }

    func testPositionsAreClampedToTheDocument() {
        let alignment = BlockAlignment.align(source: [.paragraph, .paragraph], target: [.paragraph])
        XCTAssertEqual(alignment.targetPosition(forSource: -5), 0, accuracy: 1e-9)
        XCTAssertEqual(alignment.targetPosition(forSource: 99), 1, accuracy: 1e-9)
        XCTAssertEqual(alignment.targetPosition(forSource: .nan), 0, accuracy: 1e-9)
    }

    /// 사상은 단조여야 한다 — 한쪽을 아래로 굴리는데 상대가 위로 튀면 안 된다.
    func testMappingIsMonotonicBothWays() {
        let source: [Key] = [.heading(level: 1), .paragraph, .quote, .paragraph, .table, .paragraph]
        let target: [Key] = [.heading(level: 1), .paragraph, .paragraph, .list(ordered: true), .table]
        let alignment = BlockAlignment.align(source: source, target: target)
        var previous = -1.0
        for step in 0...600 {
            let y = alignment.targetPosition(forSource: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(y, previous - 1e-12)
            previous = y
        }
        previous = -1.0
        for step in 0...500 {
            let x = alignment.sourcePosition(forTarget: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(x, previous - 1e-12)
            previous = x
        }
    }

    /// 너무 큰 가운데 구간은 짝을 짓지 않는다 — 앞뒤 짝은 그대로 남고, 가운데는 비율로 옮긴다.
    func testOversizedMiddleSkipsLCSButKeepsHeadAndTail() {
        let side = 1_500  // (1500+1)^2 > 2,000,000
        let a: [Key] = [.heading(level: 1)] + Array(repeating: .paragraph, count: side) + [.table]
        let b: [Key] = [.heading(level: 1)] + Array(repeating: .quote, count: side) + [.table]
        XCTAssertGreaterThan((side + 1) * (side + 1), BlockAlignment.cellLimit, "전제")
        let alignment = BlockAlignment.align(source: a, target: b)
        XCTAssertEqual(pairs(alignment), [[0, 0], [side + 1, side + 1]])
        XCTAssertEqual(alignment.targetPosition(forSource: 1 + Double(side) / 2),
                       1 + Double(side) / 2, accuracy: 1e-9)
    }

    private func assertStrictlyIncreasing(_ alignment: BlockAlignment,
                                          file: StaticString = #filePath, line: UInt = #line) {
        for (p, q) in zip(alignment.pairs, alignment.pairs.dropFirst()) {
            XCTAssertLessThan(p.source, q.source, file: file, line: line)
            XCTAssertLessThan(p.target, q.target, file: file, line: line)
        }
    }
}
