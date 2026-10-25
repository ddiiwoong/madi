import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class MarkdownTableTests: XCTestCase {

    private func tables(_ markdown: String) -> [MarkdownTable] {
        let text = markdown as NSString
        return MarkdownTable.blocks(in: text, lines: MarkdownSyntax().scanLines(in: text))
    }

    private func cellText(_ markdown: String) -> [[String]] {
        let text = markdown as NSString
        return tables(markdown).first?.rows.map { row in
            row.cells.map { text.substring(with: $0) }
        } ?? []
    }

    // MARK: 기본

    func testASimpleTableIsSplitIntoCells() {
        let md = """
        | 이름 | 값 |
        | --- | --- |
        | 가 | 1 |
        """
        XCTAssertEqual(cellText(md), [["이름", "값"], ["---", "---"], ["가", "1"]])
    }

    func testRowKindsAreHeaderDelimiterBody() {
        let md = "| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n"
        XCTAssertEqual(tables(md).first?.rows.map(\.kind),
                       [.header, .delimiter, .body, .body])
    }

    func testTableWithoutLeadingAndTrailingPipes() {
        let md = "a | b\n--- | ---\nc | d\n"
        XCTAssertEqual(cellText(md), [["a", "b"], ["---", "---"], ["c", "d"]])
    }

    // MARK: 표로 보지 않아야 하는 것

    func testAParagraphWithPipesIsNotATable() {
        // 구분 행이 없으면 표가 아니다. 평범한 글이 격자로 그려지면 안 된다.
        XCTAssertTrue(tables("이것은 | 그냥 | 글입니다\n또 한 줄 | 입니다\n").isEmpty)
    }

    func testADelimiterRowAloneIsNotATable() {
        // 머리글 행이 앞에 없으면 표가 아니다.
        XCTAssertTrue(tables("| --- | --- |\n").isEmpty)
    }

    // MARK: 칸을 잘못 쪼개는 두 함정

    func testEscapedPipeDoesNotSplitACell() {
        let md = "| 가\\|나 | 다 |\n| --- | --- |\n"
        XCTAssertEqual(cellText(md).first, ["가\\|나", "다"],
                       "역슬래시로 막은 막대가 칸을 쪼갰다")
    }

    func testPipeInsideInlineCodeDoesNotSplitACell() {
        let md = "| `a|b` | 다 |\n| --- | --- |\n"
        XCTAssertEqual(cellText(md).first, ["`a|b`", "다"],
                       "인라인 코드 안의 막대가 칸을 쪼갰다")
    }

    // MARK: 정렬

    func testAlignmentsAreReadFromTheDelimiterRow() {
        let md = "| a | b | c | d |\n| :--- | :---: | ---: | --- |\n"
        XCTAssertEqual(tables(md).first?.alignments, [.left, .center, .right, .none])
    }

    func testAlignmentForColumnBeyondTheDelimiterIsNone() {
        let md = "| a | b |\n| :--- | :--- |\n"
        let table = tables(md).first
        XCTAssertEqual(table?.alignment(forColumn: 0), .left)
        // `.none`을 그대로 쓰면 Swift가 `Optional.none`(즉 nil)으로 읽는다.
        // 타입을 밝혀야 정렬의 `.none`과 비교된다.
        XCTAssertEqual(table?.alignment(forColumn: 9), MarkdownTable.Alignment.none)
    }

    // MARK: 칸 범위가 원문을 가리킨다

    func testCellRangesPointAtTheOriginalDocument() {
        let md = "| 이름 | 값 |\n| --- | --- |\n"
        let text = md as NSString
        guard let first = tables(md).first?.rows.first else { return XCTFail("표가 없다") }
        for cell in first.cells {
            XCTAssertLessThanOrEqual(NSMaxRange(cell), text.length)
        }
        XCTAssertEqual(text.substring(with: first.cells[0]), "이름")
    }

    func testCellContentExcludesSurroundingSpaces() {
        let md = "|    넓은 칸    | 좁은|\n| --- | --- |\n"
        XCTAssertEqual(cellText(md).first, ["넓은 칸", "좁은"])
    }

    func testEmptyCellKeepsZeroLengthRange() {
        let md = "| a |  | c |\n| --- | --- | --- |\n"
        let row = tables(md).first?.rows.first
        XCTAssertEqual(row?.cells.count, 3)
        XCTAssertEqual(row?.cells[1].length, 0)
    }

    // MARK: 열 수

    func testColumnCountFollowsTheWidestRow() {
        // 행마다 칸 수가 다른 표가 현실에 있다. 좁은 행을 기준으로 삼으면 잘린다.
        let md = "| a | b |\n| --- | --- |\n| c | d | e |\n"
        XCTAssertEqual(tables(md).first?.columnCount, 3)
    }

    func testSeparatorsAreRecordedForDrawing()  {
        let md = "| a | b |\n| --- | --- |\n"
        let row = tables(md).first?.rows.first
        // `| a | b |`에는 막대가 셋이다.
        XCTAssertEqual(row?.separators.count, 3)
    }

    // MARK: 여러 표

    func testTwoTablesSeparatedByProseAreTwoBlocks() {
        let md = """
        | a |
        | --- |

        사이 글

        | b |
        | --- |
        """
        XCTAssertEqual(tables(md).count, 2)
    }

    func testKoreanAndEmojiDoNotShiftCellRanges() {
        let md = "| 한국어 🎉 | 값 |\n| --- | --- |\n"
        let text = md as NSString
        guard let row = tables(md).first?.rows.first else { return XCTFail("표가 없다") }
        XCTAssertEqual(text.substring(with: row.cells[0]), "한국어 🎉")
        XCTAssertEqual(text.substring(with: row.cells[1]), "값")
    }
}
