import XCTest
@testable import Madi

/// 번역이 **블록 구조**를 지키는가. 나란히 보기가 블록 번호로 두 창을 맞추므로, 번역본의
/// 블록이 원문과 어긋나면 스크롤 맞추기도 어긋난다. 실제 Apple 번역으로 저장소 문서
/// 다섯을 돌려 찾은 두 결함을 번역기 없이 못박는다.
final class TranslationStructureTests: XCTestCase {

    private let open = "\u{E000}"
    private let close = "\u{E001}"
    private func token(_ index: Int) -> String { "\(open)\(index)\(close)" }

    private func kinds(_ text: String) -> [BlockAlignment.Key] {
        BlockParser().parse(text).blocks.map { BlockAlignment.Key($0.kind) }
    }

    /// 번역기를 흉내 낸다: 자리표는 그대로 두고, 앞뒤 공백은 **버린다**(실제 Apple 번역이
    /// 그렇게 했다).
    private func trimmingTranslator(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "이어지는 줄", with: "continued line")
            .replacingOccurrences(of: "첫 줄", with: "first line")
    }

    // MARK: D1 — 들여쓴 이어지는 줄

    func testIndentedContinuationLineIsNotSentWithItsIndent() {
        let made = MarkdownTranslationPlan.make("1. 첫 줄\n   이어지는 줄\n")
        XCTAssertEqual(made.translatableTexts, ["첫 줄", "이어지는 줄"])
    }

    /// 실측한 증상 그대로: 번역기가 앞 공백을 버려도 이어지는 줄이 목록 안에 남는다.
    func testListContinuationStaysInTheListAfterATrimmingTranslator() throws {
        let source = "1. 첫 줄\n   이어지는 줄\n2. 둘째\n\n문단.\n"
        let made = MarkdownTranslationPlan.make(source)
        let translated = try made.assembled(with: made.translatableTexts.map(trimmingTranslator))
        XCTAssertEqual(translated, "1. first line\n   continued line\n2. 둘째\n\n문단.\n")
        XCTAssertEqual(kinds(translated), kinds(source))
    }

    /// 뒤 공백 둘은 하드 줄바꿈이다 — 번역기에 넘기면 사라진다.
    func testTrailingHardBreakSpacesStayOutsideTheUnit() throws {
        let source = "첫 줄  \n이어지는 줄\n"
        let made = MarkdownTranslationPlan.make(source)
        XCTAssertEqual(made.translatableTexts, ["첫 줄", "이어지는 줄"])
        let translated = try made.assembled(with: made.translatableTexts.map(trimmingTranslator))
        XCTAssertEqual(translated, "first line  \ncontinued line\n")
    }

    func testTrimmingDoesNotBreakTheRoundTrip() {
        for text in ["  들여쓴 문단\n", "- 항목  \n    더 들여쓴 줄\n", "> 인용  \n", "   \n"] {
            let made = MarkdownTranslationPlan.make(text)
            XCTAssertEqual(made.source, text)
            XCTAssertEqual(try? made.assembled(with: made.translatableTexts), text)
        }
    }

    // MARK: D2 — 표 행의 자리표

    private func rowUnit(_ row: String) -> MarkdownTranslationPlan.Unit {
        let made = MarkdownTranslationPlan.make(row)
        XCTAssertEqual(made.units.count, 1, "전제: 행 하나가 단위 하나")
        return made.units[0]
    }

    func testSeparatorsAreMarkedAndInlineSpansAreNot() {
        let unit = rowUnit("| **가** | 나 |\n")
        XCTAssertEqual(unit.protected.map(\.text), ["|", "**", "**", "|", "|"])
        XCTAssertEqual(unit.protected.map(\.isCellSeparator), [true, false, false, true, true])
    }

    func testUntouchedRowKeepsStructure() {
        let unit = rowUnit("| **가** | 나 |\n")
        XCTAssertTrue(unit.keepsStructure(unit.text))
    }

    /// 실측 1: 닫는 `**`가 마지막 `|` 뒤로 갔다 → 칸이 하나 늘었다.
    func testInlineTokenMovedIntoAnotherCellBreaksStructure() {
        let unit = rowUnit("| **가** | 나 |\n")
        let moved = "\(token(0)) \(token(1))A \(token(3)) B \(token(4))\(token(2))"
        XCTAssertFalse(unit.keepsStructure(moved))
        // 이것이 정말 표를 깨뜨리는지(검사의 근거) — 옛 경로로 복원하면 칸 수가 달라진다.
        // 구분선 행이 있어야 표로 읽히므로 붙여서 잰다.
        let restored = unit.restored(from: moved)
        XCTAssertEqual(columnCount(restored + "\n|---|---|\n"), 3, restored)
        XCTAssertEqual(columnCount("| **가** | 나 |\n|---|---|\n"), 2)
    }

    private func columnCount(_ text: String) -> Int? {
        guard case let .table(model)? = BlockParser().parse(text).blocks.first?.kind else { return nil }
        return model.columnCount
    }

    /// 실측 2: 구분자 하나가 두 번 나와 `|`가 다섯 개가 됐다.
    func testDuplicatedSeparatorBreaksStructure() {
        let unit = rowUnit("| 가 | 나 | 다 |\n")
        let duplicated = "\(token(0)) A \(token(1)) B \(token(2)) word \(token(2)) C \(token(3))"
        XCTAssertFalse(unit.keepsStructure(duplicated))
    }

    func testSeparatorsOutOfOrderBreakStructure() {
        let unit = rowUnit("| 가 | 나 | 다 |\n")
        XCTAssertFalse(unit.keepsStructure("\(token(0)) A \(token(2)) B \(token(1)) C \(token(3))"))
    }

    /// 빠진 자리표는 `restored`가 행 끝(마지막 `|` 뒤)에 붙인다 — 그것도 칸을 만든다.
    func testMissingPlaceholderBreaksStructure() {
        let unit = rowUnit("| `코드` | 나 |\n")
        XCTAssertFalse(unit.keepsStructure("\(token(0)) A \(token(2)) B \(token(3))"))
    }

    func testTextOutsideTheOuterBarsBreaksStructure() {
        let unit = rowUnit("| 가 | 나 |\n")
        XCTAssertFalse(unit.keepsStructure("The \(token(0)) A \(token(1)) B \(token(2))"))
        XCTAssertFalse(unit.keepsStructure("\(token(0)) A \(token(1)) B \(token(2)) here"))
        XCTAssertTrue(unit.keepsStructure(" \(token(0)) A \(token(1)) B \(token(2)) "))
    }

    /// 칸 안에서 인라인 자리표의 순서가 바뀌는 것은 괜찮다 — 어순이 바뀌면 링크도 옮겨간다.
    func testReorderingInsideOneCellIsAllowed() {
        let unit = rowUnit("| `a` 와 `b` | 나 |\n")
        XCTAssertTrue(unit.keepsStructure("\(token(0)) \(token(2)) and \(token(1)) \(token(3)) B \(token(4))"))
    }

    func testNonTableUnitsAlwaysKeepStructure() {
        let made = MarkdownTranslationPlan.make("**가** 나\n")
        XCTAssertNil(made.units[0].cellFallback)
        XCTAssertTrue(made.units[0].keepsStructure("anything"))
    }

    func testCellFallbackSplitsTheRowIntoCells() {
        let unit = rowUnit("|  가 | **나** |\n")
        let fallback = try? XCTUnwrap(unit.cellFallback)
        XCTAssertEqual(fallback?.translatableTexts, ["가", "\(token(0))나\(token(1))"])
        XCTAssertEqual(fallback?.source, "|  가 | **나** |")
    }

    // MARK: 수선 경로 — 번역기를 주입해 끝까지

    @available(macOS 26.0, *)
    func testBrokenRowIsRetranslatedCellByCell() async throws {
        let source = "| 가 | **나** |\n|---|---|\n| 다 | 라 |\n"
        let made = MarkdownTranslationPlan.make(source)
        XCTAssertEqual(made.units.count, 2, "전제: 행 둘")

        // 첫 행만 깨진 번역: 닫는 `**`가 마지막 막대 뒤로 갔다.
        var rows = made.translatableTexts
        rows[0] = "\(token(0)) A \(token(1)) \(token(2))B \(token(4)) \(token(3))"
        rows[1] = rows[1].replacingOccurrences(of: "다", with: "C").replacingOccurrences(of: "라", with: "D")

        var calls: [String] = []
        let repairs = try await AppleTranslator.structureRepairs(plan: made, translations: rows) { text in
            calls.append(text)
            return text.replacingOccurrences(of: "가", with: "A").replacingOccurrences(of: "나", with: "B")
        }
        XCTAssertEqual(Array(repairs.keys), [0], "깨진 행만 다시 번역한다")
        XCTAssertEqual(calls.count, 2, "칸마다 한 번")

        let assembled = try made.assembled(with: rows, replacing: repairs)
        XCTAssertEqual(assembled, "| A | **B** |\n|---|---|\n| C | D |\n")
        XCTAssertEqual(kinds(assembled), kinds(source))
        // 표의 칸 수까지 같다(종류 키는 칸 수를 보지 않으므로 따로 잰다).
        guard case let .table(model)? = BlockParser().parse(assembled).blocks.first?.kind else {
            return XCTFail("표가 아니다")
        }
        XCTAssertEqual(model.columnCount, 2)
    }

    @available(macOS 26.0, *)
    func testIntactRowsAreNotRetranslated() async throws {
        let made = MarkdownTranslationPlan.make("| 가 | 나 |\n| 다 | 라 |\n")
        var called = false
        let repairs = try await AppleTranslator.structureRepairs(
            plan: made, translations: made.translatableTexts) { text in
            called = true
            return text
        }
        XCTAssertTrue(repairs.isEmpty)
        XCTAssertFalse(called)
    }
}
