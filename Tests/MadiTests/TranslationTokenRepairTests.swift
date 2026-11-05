import XCTest
@testable import Madi

/// 번역기가 자리표를 잃었을 때 — 링크·각주·강조가 깨지지 않게 다시 번역한다.
///
/// 실제로 겪었다(Apple 번역 ko→en, macOS 27.0.1): `본문에 각주[^1]가 있고 [링크](https://example.com)도
/// 있다.`가 `There are footnotes 0 and 1 in the text and a link 2.[^1][](https://example.com)`이 됐다.
/// 그때의 자리표(U+E000 n U+E001)에서 번역기가 감싼 문자를 버리고 숫자만 남겼고, 잃은 구간이 문장 끝에
/// 붙어 링크 글이 사라졌다. 번역기 없이 그 경우를 흉내 낸다.
@available(macOS 26.0, *)
final class TranslationTokenRepairTests: XCTestCase {

    private let source = "본문에 각주[^1]가 있고 [링크](https://example.com)도 있다.\n\n[^1]: 각주의 글이다.\n"

    /// 낱말 사전으로 옮기는 번역기 흉내. 자리표는 그대로 둔다. 글 전체가 사전에 있으면 그 값을, 아니면
    /// 긴 낱말부터 바꾼다.
    private static let dictionary: [String: String] = [
        "본문에 각주": "There are footnotes", "가 있고 ": " in the text and ", "링크": "links",
        "도 있다.": ".", "각주의 글이다.": "It is a footnote.", "본문은": "The text has",
        "굵게": "bold", "와": "and", "를 포함합니다.": ".", "이름": "name", "값": "value",
    ]

    private static func translateWords(_ text: String) -> String {
        if let exact = dictionary[text] { return exact }
        var out = text
        for (korean, english) in dictionary.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: korean, with: english)
        }
        return out
    }

    /// 실제로 본 실패: 자리표 `{{n}}`의 감싼 표시를 버리고 숫자만 남긴다. 다른 꼴은 지킨다.
    private func stripsBraces(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"\{\{(\d+)\}\}"#)
        let stripped = regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1")
        return Self.translateWords(stripped)
    }

    private func firstUnit(_ text: String) -> MarkdownTranslationPlan.Unit {
        MarkdownTranslationPlan.make(text).units[0]
    }

    // MARK: 온전한가

    func testIntactNeedsEveryTokenExactlyOnceAndOpeningsFirst() {
        let unit = firstUnit(source)
        XCTAssertEqual(unit.form, .braces)
        XCTAssertEqual(unit.text, "본문에 각주{{0}}가 있고 {{1}}링크{{2}}도 있다.")
        XCTAssertTrue(unit.isIntact("Footnotes{{0}} and {{1}}links{{2}}."))
        XCTAssertFalse(unit.isIntact("There are footnotes 0 and 1 in the text and a link 2."), "잃었다")
        XCTAssertFalse(unit.isIntact("Footnotes{{0}} and {{2}}links{{1}}."), "링크의 닫는 쪽이 여는 쪽보다 앞")
        XCTAssertFalse(unit.isIntact("Footnotes{{0}}{{0}} and {{1}}links{{2}}."), "복제")
        XCTAssertTrue(unit.isIntact("Footnotes{{ 0 }} and {{1 }}links{{2}}."), "자리표 안의 공백은 걷어 낸다")
        XCTAssertEqual(unit.restored(from: "Footnotes{{ 0 }} and {{1 }}links{{2}}."),
                       "Footnotes[^1] and [links](https://example.com).")
    }

    func testAUnitWithoutProtectionIsAlwaysIntact() {
        let unit = firstUnit("그냥 문장이다.\n")
        XCTAssertTrue(unit.protected.isEmpty)
        XCTAssertTrue(unit.isIntact("Just a sentence."))
    }

    // MARK: 꼴 고르기

    func testAFormWhoseMarkersAppearInTheTextIsNotUsed() throws {
        let made = MarkdownTranslationPlan.make("템플릿 {{name}}과 **굵게**가 있다.\n")
        let unit = try XCTUnwrap(made.units.first)
        XCTAssertEqual(unit.form, .brackets, "글에 `{{`가 있으면 그 꼴은 자리표로 쓸 수 없다")
        XCTAssertEqual(unit.text, "템플릿 {{name}}과 ⟦0⟧굵게⟦1⟧가 있다.")
        XCTAssertFalse(unit.alternateForms.contains(.braces))
        XCTAssertEqual(try made.assembled(with: made.translatableTexts), made.source, "항등 번역은 원문")
    }

    func testEveryFormRoundTrips() {
        let unit = firstUnit(source)
        for form in MarkdownTranslationPlan.TokenForm.preference {
            XCTAssertEqual(unit.restored(from: unit.text(in: form), form: form),
                           "본문에 각주[^1]가 있고 [링크](https://example.com)도 있다.", "\(form)")
        }
    }

    // MARK: 다시 번역

    func testALostTokenIsRetranslatedWithAnotherForm() async throws {
        let made = MarkdownTranslationPlan.make(source)
        let first = made.translatableTexts.map(stripsBraces)
        XCTAssertEqual(first[0], "There are footnotes0 in the text and 1links2.", "전제: 실제로 본 실패")

        let repairs = try await AppleTranslator.repairs(plan: made, translations: first,
                                                        translate: stripsBraces)
        XCTAssertEqual(repairs.reformed, 1)
        XCTAssertEqual(repairs.split, 0)
        let text = try made.assembled(with: first, replacing: repairs.replacing)
        XCTAssertEqual(text, "There are footnotes[^1] in the text and [links](https://example.com).\n\n"
                       + "[^1]: It is a footnote.\n")
    }

    func testWhenEveryFormIsLostTheSentenceIsTranslatedPieceByPiece() async throws {
        let made = MarkdownTranslationPlan.make("본문은 **굵게**와 [링크](https://example.com)를 포함합니다.\n")
        // 어느 꼴이든 자리표를 지우는 번역기.
        let dropsAll: (String) -> String = { text in
            let regex = try! NSRegularExpression(pattern: #"\{\{\d+\}\}|⟦\d+⟧|§\d+§"#)
            return Self.translateWords(regex.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: ""))
        }
        let first = made.translatableTexts.map(dropsAll)
        let repairs = try await AppleTranslator.repairs(plan: made, translations: first, translate: dropsAll)
        XCTAssertEqual(repairs.split, 1)
        let text = try made.assembled(with: first, replacing: repairs.replacing)
        XCTAssertEqual(text, "The text has **bold** and [links](https://example.com).\n",
                       "구간은 번역기를 거치지 않아 깨지지 않는다. 조사가 붙던 자리는 띄운다")
    }

    func testPieceByPieceDoesNotAddSpacesForJapanese() throws {
        let unit = firstUnit("본문은 **굵게**와 있다.\n")
        XCTAssertEqual(unit.runTexts, ["본문은", "굵게", "와 있다."])
        XCTAssertEqual(unit.reassembled(runs: ["本文は", "太字", "とある。"], wordSpacing: false),
                       "本文は **太字**とある。", "원문의 공백만 남는다 — 일본어는 띄우지 않는다")
        XCTAssertEqual(unit.reassembled(runs: ["The text has", "bold", "and."], wordSpacing: true),
                       "The text has **bold** and.")
    }

    func testRunsSkipPunctuationAndNumbers() {
        let unit = firstUnit("값은 `x`, 그리고 2026년 **굵게**.\n")
        XCTAssertEqual(unit.runTexts, ["값은", ", 그리고 2026년", "굵게"], "끝의 `.`는 번역기에 넘기지 않는다")
    }

    func testIntactTranslationsAreLeftAlone() async throws {
        let made = MarkdownTranslationPlan.make(source)
        let first = made.translatableTexts.map(Self.translateWords)
        var calls = 0
        let repairs = try await AppleTranslator.repairs(plan: made, translations: first) { text in
            calls += 1
            return text
        }
        XCTAssertTrue(repairs.isEmpty)
        XCTAssertEqual(calls, 0, "온전하면 다시 부르지 않는다")
    }

    func testTableCellsAreCheckedToo() async throws {
        let table = "| 이름 | 값 |\n|---|---|\n| **굵게** | [링크](https://example.com) |\n"
        let made = MarkdownTranslationPlan.make(table)
        let row = try XCTUnwrap(made.units.firstIndex { $0.protected.contains { $0.text == "**" } })
        // 행 번역이 칸 구조를 잃고, 칸마다 다시 번역할 때도 `{{n}}`는 잃는다 → 칸은 다른 꼴로.
        var first = made.translatableTexts.map(Self.translateWords)
        first[row] = "broken"
        let repairs = try await AppleTranslator.repairs(plan: made, translations: first, translate: stripsBraces)
        XCTAssertEqual(repairs.tableRows, 1)
        XCTAssertGreaterThan(repairs.reformed, 0, "칸 안의 자리표도 다시 번역한다")
        let text = try made.assembled(with: first, replacing: repairs.replacing)
        XCTAssertTrue(text.contains("| **bold** | [links](https://example.com) |"), text)
    }

    // MARK: 방향과 조각기

    func testWordSpacingByTargetLanguage() {
        XCTAssertTrue(TranslationDirection(source: "ko", target: "en").targetUsesWordSpaces)
        XCTAssertTrue(TranslationDirection(source: "en", target: "ko").targetUsesWordSpaces)
        XCTAssertFalse(TranslationDirection(source: "ko", target: "ja").targetUsesWordSpaces)
        XCTAssertFalse(TranslationDirection(source: "ko", target: "zh-Hant").targetUsesWordSpaces)
    }

    func testTheChunkerNeverSplitsAnyForm() {
        for token in ["{{12}}", "⟦12⟧", "§12§"] {
            let text = String(repeating: "x", count: 97) + token + String(repeating: "y", count: 97)
            let chunks = TranslationChunker.split(text, limit: 100)
            XCTAssertEqual(chunks.joined(), text)
            XCTAssertTrue(chunks.contains { $0.contains(token) }, "\(token)이 갈렸다: \(chunks)")
        }
    }

    // MARK: 강조 안의 코드, 비어 버린 강조

    /// 저장소 설계 문서에서 실제로 잃은 것: `**`가 보호받지 못해 번역기가 지웠다. 강조 안에 인라인 코드가
    /// 있으면 코드가 먼저 자리를 차지해 강조가 통째로 빠졌기 때문이다.
    func testEmphasisAroundInlineCodeIsProtected() {
        let unit = firstUnit("**문서 레벨 `NSUndoManager` 하나**에 등록한다.\n")
        XCTAssertEqual(unit.protected.map(\.text), ["**", "`NSUndoManager`", "**"])
        XCTAssertEqual(unit.protected.map(\.role), [.opening, .standalone, .closing])
        XCTAssertEqual(unit.text, "{{0}}문서 레벨 {{1}} 하나{{2}}에 등록한다.")
    }

    func testAPairWhoseTextWasMovedOutIsNotIntact() {
        // 실측: `**서로를 가린다**`가 `cover each other with ****`가 됐다 — 자리표는 다 있지만 글이 빠졌다.
        let unit = firstUnit("가드가 둘이고 **서로를 가린다**.\n")
        XCTAssertFalse(unit.isIntact("two guards cover each other with {{0}}{{1}}."))
        XCTAssertFalse(unit.isIntact("two guards {{0}}  {{1}} cover each other."), "공백만 남아도 비었다")
        XCTAssertTrue(unit.isIntact("two guards {{0}}cover each other{{1}}."))
        let empty = firstUnit("빈 링크 [](https://example.com)는 그대로.\n")
        XCTAssertTrue(empty.isIntact("An empty link {{0}} stays."), "원래 비었던 것은 비어도 된다")
    }
}
