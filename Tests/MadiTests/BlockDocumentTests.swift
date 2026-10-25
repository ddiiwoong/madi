import XCTest

/// 블록 편집기 단계 0 — `BlockParser` / `BlockSerializer`.
///
/// 이 묶음의 핵심 불변식은 **파싱 후 바로 직렬화하면 원본과 바이트가 같다**는 것이다.
/// 그런데 그 검사 하나만 두면 직렬화가 `return 원문`이어도 통과한다. 그래서
/// `testSerializerActuallyAssemblesFromBlocks`와 `testParserDoesNotMakeOneGiantBlock`을
/// 함께 둔다 — 앞의 검사가 **무엇을 보고 있는지**를 고정하는 자리다.
final class BlockDocumentTests: XCTestCase {

    private let parser = BlockParser()
    private let serializer = BlockSerializer()

    private func roundTrip(_ text: String) -> String {
        serializer.serialize(parser.parse(text))
    }

    // MARK: 왕복 — 손으로 쓴 경우

    func testRoundTripPreservesPlainDocument() {
        let text = """
        # 제목

        글줄 하나.
        이어지는 줄.

        - 항목
        - 항목 둘

        """
        XCTAssertEqual(roundTrip(text), text)
    }

    func testRoundTripPreservesDocumentWithoutTrailingNewline() {
        let text = "# 제목\n\n끝에 줄바꿈이 없다."
        XCTAssertEqual(roundTrip(text), text)
    }

    func testRoundTripPreservesEmptyAndWhitespaceOnlyDocuments() {
        XCTAssertEqual(roundTrip(""), "")
        XCTAssertEqual(roundTrip("\n"), "\n")
        XCTAssertEqual(roundTrip("\n\n\n"), "\n\n\n")
        XCTAssertEqual(roundTrip("   \n\t\n"), "   \n\t\n")
    }

    /// 웹 API나 윈도우에서 온 문서는 `\r\n`이다. 줄 끝이 섞여도 왕복해야 한다 —
    /// 저장이 줄 끝을 바꾸면 git diff가 파일 전체로 번진다.
    func testRoundTripPreservesCRLF() {
        let text = "# 제목\r\n\r\n글줄.\r\n\r\n| 열 | 값 |\r\n| --- | ---: |\r\n| 하나 | 1 |\r\n"
        XCTAssertEqual(roundTrip(text), text)
    }

    /// 원문의 칸 너비 맞춤은 의미가 없지만 **보존 대상**이다. 고치지 않은 표를
    /// 다시 쓰면서 하이픈 개수나 덧댄 공백이 바뀌면 그것이 곧 diff다.
    func testRoundTripPreservesTableWhitespaceAndHyphenCounts() {
        let text = """
        | 이름       | 값 |
        |:-----------|---------:|
        | 하나 | 1 |
        |둘|2|

        """
        XCTAssertEqual(roundTrip(text), text)
    }

    func testRoundTripPreservesFrontMatter() {
        let text = """
        ---
        title: 제목
        tags: [가, 나]
        ---

        # 본문

        글줄.

        """
        let document = parser.parse(text)
        XCTAssertNotNil(document.frontMatter, "front matter가 있는 문서인데 못 읽었다")
        XCTAssertEqual(serializer.serialize(document), text)
    }

    func testRoundTripPreservesUnterminatedCodeFence() {
        let text = "```swift\nlet a = 1\n# 제목처럼 보이지만 코드다\n"
        XCTAssertEqual(roundTrip(text), text)
    }

    /// 파서가 모르는 구문(HTML 덩어리, 각주)도 왕복해야 한다. 종류를 만들지 않고
    /// 원문 조각으로 보존하는 설계가 실제로 성립하는지 보는 자리다.
    func testRoundTripPreservesUnknownConstructs() {
        let text = """
        <div class="note">
          <p>HTML 덩어리</p>
        </div>

        각주[^1]를 쓴 글줄.

        [^1]: 각주 본문.

        | a | b |

        """
        XCTAssertEqual(roundTrip(text), text)
    }

    // MARK: 왕복 — 실제 문서 코퍼스

    /// 손으로 쓴 픽스처는 영원히 통과한다. 실제 문서로 돌려야 설계 §6이 말한
    /// "실제 문서들을 코퍼스로 두고 왕복을 돌린다"가 된다.
    func testRoundTripIsByteIdenticalOnRealCorpus() throws {
        let documents = try Self.corpus()

        // 코퍼스가 조용히 비면 이 테스트는 아무것도 검사하지 않고 초록으로 끝난다.
        // 그 경우를 먼저 막는다.
        XCTAssertGreaterThanOrEqual(documents.count, 6,
                                    "코퍼스가 \(documents.count)개다 — 파일을 못 찾았거나 이름이 겹쳐 덮였다")
        let totalCharacters = documents.values.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(totalCharacters, 10_000,
                             "코퍼스가 \(totalCharacters)자뿐이다 — 잘려 읽혔다")

        for (name, text) in documents {
            let result = roundTrip(text)
            if result != text {
                XCTFail("왕복이 바이트 동일하지 않다: \(name) "
                        + "(원본 \(text.count)자, 결과 \(result.count)자)")
            }
        }
    }

    /// 코퍼스에 실제로 표·코드·목록이 들어 있는지 확인한다. 전부 평범한 글줄이면
    /// 위 테스트는 어려운 경우를 하나도 보지 않은 것이다.
    func testRealCorpusExercisesTablesAndCodeBlocks() throws {
        var tables = 0
        var codeBlocks = 0
        var lists = 0
        for text in try Self.corpus().values {
            for block in parser.parse(text).blocks {
                switch block.kind {
                case .table: tables += 1
                case .codeBlock: codeBlocks += 1
                case .list: lists += 1
                default: break
                }
            }
        }
        XCTAssertGreaterThan(tables, 0, "코퍼스에 표가 없다")
        XCTAssertGreaterThan(codeBlocks, 0, "코퍼스에 코드 블록이 없다")
        XCTAssertGreaterThan(lists, 0, "코퍼스에 목록이 없다")
    }

    // MARK: 바이트 동일 검사가 무엇을 보고 있는가

    /// 직렬화가 블록들을 **이어붙여** 만든 결과인지 본다. 원문을 그대로 돌려주는
    /// 구현이라면 블록을 지워도 출력이 안 변하므로 이 테스트가 빨개진다.
    func testSerializerActuallyAssemblesFromBlocks() throws {
        let text = """
        # 제목

        지워질 글줄: 자두나무.

        남을 글줄.

        """
        var document = parser.parse(text)
        let index = try XCTUnwrap(document.blocks.firstIndex {
            $0.sourceSlice.contains("자두나무")
        }, "지울 블록을 찾지 못했다")
        document.blocks.remove(at: index)

        let result = serializer.serialize(document)
        XCTAssertFalse(result.contains("자두나무"), "블록을 지웠는데 출력에 남아 있다")
        XCTAssertTrue(result.contains("남을 글줄"))
        XCTAssertTrue(result.contains("# 제목"))
    }

    /// 파서가 문서를 덩어리 하나로 삼키면 왕복은 통과하지만 블록 편집기는
    /// 아무것도 할 수 없다. 종류와 개수를 고정한다.
    func testParserDoesNotMakeOneGiantBlock() {
        let text = """
        # 제목

        글줄.

        ```swift
        let a = 1
        ```

        - 항목

        | 열 | 값 |
        | --- | --- |
        | 하나 | 1 |

        ---

        > 인용.

        """
        let kinds = parser.parseBlocks(text).map(\.kind)
        XCTAssertEqual(kinds.count, 13, "블록 개수: \(kinds.count)\n\(kinds)")

        func isKind(_ index: Int, _ check: (Block.Kind) -> Bool) -> Bool {
            kinds.indices.contains(index) && check(kinds[index])
        }
        XCTAssertTrue(isKind(0) { if case .heading(let l) = $0 { return l == 1 } else { return false } })
        XCTAssertTrue(isKind(1) { $0 == .blankLines })
        XCTAssertTrue(isKind(2) { $0 == .paragraph })
        XCTAssertTrue(isKind(4) { if case .codeBlock(let lang) = $0 { return lang == "swift" } else { return false } })
        XCTAssertTrue(isKind(6) { if case .list(let ordered) = $0 { return ordered == false } else { return false } })
        XCTAssertTrue(isKind(8) { if case .table = $0 { return true } else { return false } })
        XCTAssertTrue(isKind(10) { $0 == .thematicBreak })
        XCTAssertTrue(isKind(12) { $0 == .quote })
    }

    /// 구분 행이 없는 연속 행은 표가 아니다. 그렇지 않으면 `| 뭐 |` 한 줄짜리 글이
    /// 격자로 둔갑한다.
    func testPipeLinesWithoutDelimiterAreNotTables() {
        let kinds = parser.parseBlocks("| 이건 표가 아니다 |\n| 구분 행이 없다 |\n").map(\.kind)
        XCTAssertFalse(kinds.contains { if case .table = $0 { return true } else { return false } })
    }

    /// 코드 블록 안의 표 문법은 표가 아니다.
    func testTableSyntaxInsideCodeFenceIsNotATable() {
        let text = "```\n| 열 | 값 |\n| --- | --- |\n```\n"
        let kinds = parser.parseBlocks(text).map(\.kind)
        XCTAssertEqual(kinds.count, 1)
        XCTAssertTrue(kinds.contains { if case .codeBlock = $0 { return true } else { return false } })
    }

    /// 바이트 동일이 **어디서 오는지**를 고정한다.
    ///
    /// 왕복 테스트는 렌더러가 항등 함수(`return sourceSlice`)여도 통과한다. 그러면
    /// 표를 고쳐도 아무 일이 없는 구현이 초록으로 보인다. 그래서 같은 블록을
    /// 고치지 않은 상태와 고친 상태로 각각 그려, 앞은 원문과 같고 뒤는 **달라야**
    /// 한다는 것을 본다 — 즉 보존은 `isModified`가 하는 일이다.
    func testByteIdentityComesFromIsModifiedNotFromAnIdentityRenderer() throws {
        let text = "| 이름       | 값 |\n|:-----------|---------:|\n| 하나 | 1 |\n"
        let document = parser.parse(text)
        var block = try XCTUnwrap(document.blocks.first)
        XCTAssertFalse(block.isModified)
        XCTAssertEqual(serializer.render(block), text, "고치지 않은 블록은 원문 그대로다")

        XCTAssertTrue(block.mutateTable { $0.setCell(row: 1, column: 1, plainText: "2") })
        let rendered = serializer.render(block)
        XCTAssertNotEqual(rendered, text, "렌더러가 원문을 그대로 돌려주고 있다")
        XCTAssertFalse(rendered.contains("|:-----------|"),
                       "다시 그렸는데 원문의 칸 맞춤이 남아 있다 — 렌더러를 거치지 않았다")
        XCTAssertTrue(rendered.contains("| :--- | ---: |"), "정렬이 다시 그려지지 않았다\n\(rendered)")
        XCTAssertTrue(rendered.contains("| 하나 | 2 |"), "고친 값이 없다\n\(rendered)")
    }

    // MARK: 표 모델 읽기

    func testTableModelReadsCellsAndAlignments() throws {
        let text = "| 이름 | 수 | 끝 |\n| :--- | :---: | ---: |\n| 하나 | 1 | 가 |\n"
        let model = try XCTUnwrap(firstTable(in: text))

        XCTAssertEqual(model.headerRowCount, 1)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.rows[0], ["이름", "수", "끝"])
        XCTAssertEqual(model.rows[1], ["하나", "1", "가"])
        XCTAssertEqual(model.alignments, [.left, .center, .right])
    }

    /// 칸 안의 `\|`는 칸을 나누지 않는다. 모델은 원문 꼴로 들고, 사람이 읽는 글자는
    /// escape를 되돌려 준다.
    func testTableModelKeepsEscapedPipesAsSourceAndUnescapesForDisplay() throws {
        let model = try XCTUnwrap(firstTable(in: "| a \\| b | c |\n| --- | --- |\n"))
        XCTAssertEqual(model.rows[0][0], "a \\| b")
        XCTAssertEqual(model.plainText(row: 0, column: 0), "a | b")
    }

    func testTableEscapeRoundTripsThroughSerializerAndParser() throws {
        var document = parser.parse("| a | b |\n| --- | --- |\n| 하나 | 둘 |\n")
        XCTAssertTrue(document.blocks[0].mutateTable {
            $0.setCell(row: 1, column: 0, plainText: "막대 | 포함")
        })

        let reparsed = try XCTUnwrap(firstTable(in: serializer.serialize(document)))
        XCTAssertEqual(reparsed.plainText(row: 1, column: 0), "막대 | 포함",
                       "escape한 막대가 왕복에서 살아남지 못했다")
        XCTAssertEqual(reparsed.rows[1].count, 2, "막대가 칸을 하나 더 쪼갰다")
    }

    // MARK: 표 모델 고치기

    func testEditingOneCellLeavesEveryOtherBlockByteIdentical() throws {
        let text = """
        # 제목

        고치지 않을 글줄.

        | 열 | 값 |
        |:---|----:|
        | 하나 | 1 |

        뒤의 글줄.

        """
        var document = parser.parse(text)
        let index = try XCTUnwrap(document.blocks.firstIndex {
            if case .table = $0.kind { return true } else { return false }
        })
        XCTAssertTrue(document.blocks[index].mutateTable { $0.setCell(row: 1, column: 1, plainText: "99") })
        XCTAssertTrue(document.blocks[index].isModified)
        XCTAssertTrue(document.hasModifiedBlocks)

        let result = serializer.serialize(document)

        // 고친 블록 밖은 글자 하나도 달라지지 않는다.
        for (offset, block) in document.blocks.enumerated() where offset != index {
            XCTAssertTrue(result.contains(block.sourceSlice),
                          "고치지 않은 블록이 달라졌다: \(block.kind)")
        }
        let reparsed = try XCTUnwrap(firstTable(in: result))
        XCTAssertEqual(reparsed.plainText(row: 1, column: 1), "99")
        XCTAssertEqual(reparsed.alignments, [.left, .right], "정렬이 보존되지 않았다")
    }

    /// 고친 표를 두 번 직렬화하면 같은 결과가 나와야 한다. 그렇지 않으면 저장할
    /// 때마다 문서가 조금씩 흔들린다.
    func testSerializingAModifiedTableIsIdempotent() throws {
        var document = parser.parse("| 열 | 값 |\n|:---|----:|\n| 하나 | 1 |\n")
        XCTAssertTrue(document.blocks[0].mutateTable { $0.setCell(row: 1, column: 0, plainText: "바뀜") })

        let once = serializer.serialize(document)
        let twice = serializer.serialize(parser.parse(once))
        XCTAssertEqual(twice, once, "두 번째 직렬화가 달라졌다")
        XCTAssertTrue(once.hasSuffix("\n"), "끝의 줄바꿈이 사라졌다")
    }

    func testInsertRowAndColumnKeepAlignmentsAligned() throws {
        var document = parser.parse("| a | b |\n| :--- | ---: |\n| 1 | 2 |\n")
        // 이 테스트의 기댓값이 기대는 전제를 먼저 고정한다 — 머리글 1행 + 본문 1행.
        let before = try XCTUnwrap(firstTable(in: serializer.serialize(document)))
        XCTAssertEqual(before.rows.count, 2)
        XCTAssertEqual(before.columnCount, 2)

        XCTAssertTrue(document.blocks[0].mutateTable { model in
            model.insertColumn(at: 1)
            model.insertRow(at: model.rows.count)
            model.setCell(row: 0, column: 1, plainText: "새 열")
        })

        let model = try XCTUnwrap(firstTable(in: serializer.serialize(document)))
        XCTAssertEqual(model.rows[0], ["a", "새 열", "b"])
        XCTAssertEqual(model.alignments, [.left, .none, .right],
                       "열을 넣었는데 정렬이 옆으로 밀렸다")
        XCTAssertEqual(model.rows.count, 3, "행 하나를 넣었으니 2 + 1이다")
        XCTAssertEqual(model.columnCount, 3)
    }

    /// 머리글 행은 뺄 수 없다 — 머리글 없는 마크다운 표는 표가 아니다.
    func testHeaderRowCannotBeRemoved() {
        var model = TableModel(alignments: [.none], rows: [["머리"], ["본문"]], headerRowCount: 1)
        XCTAssertFalse(model.removeRow(at: 0))
        XCTAssertTrue(model.removeRow(at: 1))
        XCTAssertEqual(model.rows, [["머리"]])
    }

    func testMutateTableOnNonTableBlockDoesNothing() {
        var block = Block(kind: .paragraph, sourceSlice: "글줄.\n")
        XCTAssertFalse(block.mutateTable { $0.setCell(row: 0, column: 0, plainText: "x") })
        XCTAssertFalse(block.isModified)
        XCTAssertEqual(block.sourceSlice, "글줄.\n")
    }

    /// 값이 실제로 바뀌지 않았으면 블록을 고친 것으로 표시하지 않는다. 그렇지 않으면
    /// 캐럿만 옮겨도 저장이 표를 다시 써서 diff를 만든다.
    func testNoOpEditDoesNotMarkBlockModified() {
        var document = parser.parse("| 열 | 값 |\n|:---|----:|\n| 하나 | 1 |\n")
        XCTAssertFalse(document.blocks[0].mutateTable { $0.setCell(row: 9, column: 9, plainText: "밖") })
        XCTAssertFalse(document.blocks[0].isModified)
        XCTAssertFalse(document.hasModifiedBlocks)
    }

    // MARK: 도우미

    private func firstTable(in text: String) -> TableModel? {
        for block in parser.parseBlocks(text) {
            if case .table(let model) = block.kind { return model }
        }
        return nil
    }

    /// 저장소 안의 실제 마크다운 문서들. 테스트 번들은 이들을 리소스로 들고 있지
    /// 않으므로 `#filePath`에서 저장소 뿌리를 거슬러 찾는다.
    private static func corpus() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MadiTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 저장소 뿌리
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: root,
                                              includingPropertiesForKeys: nil,
                                              options: [.skipsHiddenFiles]) else { return [:] }
        var documents: [String: String] = [:]
        for case let url as URL in walker {
            // 생성물과 외부 의존성은 코퍼스가 아니다.
            if url.pathComponents.contains(".build") || url.pathComponents.contains("node_modules") {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension == "md" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // 이름이 아니라 **상대 경로**를 열쇠로 쓴다. `README.md`가 저장소 뿌리와
            // `web-prototype/`에 둘 있어서, 이름으로 묶으면 한쪽이 조용히 덮인다 —
            // 코퍼스에서 문서 하나가 사라지는데 테스트는 초록으로 끝난다.
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            documents[relative] = text
        }
        return documents
    }
}
