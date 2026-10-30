import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class FrontMatterTests: XCTestCase {

    // MARK: Round trip — the property that protects the user's file

    func testRoundTripWithBlankSeparator() {
        let text = "---\ntitle: Hello\n---\n\n# Body\n\ntext\n"
        let parsed = FrontMatter.parse(text)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.joined(withBody: parsed!.body), text)
    }

    func testRoundTripWithoutBlankSeparator() {
        let text = "---\ntitle: Hello\n---\n# Body\n"
        let parsed = FrontMatter.parse(text)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.joined(withBody: parsed!.body), text)
    }

    func testRoundTripPreservesConstructsTheParserDoesNotModel() {
        // An anchor, a nested mapping and a comment: none of these become
        // fields, but all must survive a save untouched.
        let text = """
        ---
        # a comment
        anchor: &ref value
        nested:
          deep:
            deeper: 1
        title: Kept
        ---

        body
        """
        let parsed = FrontMatter.parse(text)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.joined(withBody: parsed!.body), text)
        XCTAssertTrue(parsed!.raw.contains("# a comment"))
        XCTAssertTrue(parsed!.raw.contains("deeper: 1"))
    }

    func testEditingTheBodyDoesNotDisturbTheBlock() {
        let text = "---\ntitle: Hello\n---\n\noriginal\n"
        let parsed = FrontMatter.parse(text)!
        let rewritten = parsed.joined(withBody: "replaced\n")
        XCTAssertEqual(rewritten, "---\ntitle: Hello\n---\n\nreplaced\n")
    }

    // MARK: Absence

    func testNoFrontMatter() {
        XCTAssertNil(FrontMatter.parse("# Just a document\n"))
        XCTAssertNil(FrontMatter.parse(""))
    }

    func testUnclosedBlockIsNotFrontMatter() {
        // Opening a fence without closing it means the --- is just text, and
        // treating it as front matter would swallow the whole document.
        XCTAssertNil(FrontMatter.parse("---\ntitle: oops\n\nbody with no close\n"))
    }

    func testThematicBreakAtTopIsNotFrontMatter() {
        // "---\n\n---" would parse as an empty block; the body must survive.
        let parsed = FrontMatter.parse("---\n\n---\n\nbody\n")
        XCTAssertEqual(parsed?.fields.count, 0)
        XCTAssertEqual(parsed?.joined(withBody: parsed!.body), "---\n\n---\n\nbody\n")
    }

    // MARK: Field shapes

    private func fields(_ yaml: String) -> [FrontMatter.Field] {
        FrontMatter.parse("---\n\(yaml)\n---\n\nbody\n")?.fields ?? []
    }

    func testScalarFields() {
        let parsed = fields("title: Hello\nlayout: single\ncomments: true")
        XCTAssertEqual(parsed.map(\.key), ["title", "layout", "comments"])
        XCTAssertEqual(parsed[0].value, .scalar("Hello"))
        XCTAssertEqual(parsed[2].value, .scalar("true"))
    }

    func testQuotesAreStrippedForDisplay() {
        XCTAssertEqual(fields("title: \"Quoted: with colon\"")[0].value,
                       .scalar("Quoted: with colon"))
        XCTAssertEqual(fields("title: 'single'")[0].value, .scalar("single"))
    }

    func testBlockList() {
        let parsed = fields("tags:\n  - MLOps\n  - ML Platform\n  - Model Evaluation")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].key, "tags")
        XCTAssertEqual(parsed[0].value, .list(["MLOps", "ML Platform", "Model Evaluation"]))
    }

    func testInlineFlowList() {
        XCTAssertEqual(fields("categories: [MLOps, Platform]")[0].value,
                       .list(["MLOps", "Platform"]))
    }

    func testFoldedMultiLineScalar() {
        let parsed = fields("description: first part\n  second part\n  third part")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].value, .scalar("first part second part third part"))
    }

    func testBlockScalarMarker() {
        let parsed = fields("note: |\n  line one\n  line two")
        XCTAssertEqual(parsed[0].value, .scalar("line one line two"))
    }

    func testCommentsAndBlankLinesAreNotFields() {
        let parsed = fields("# comment\n\ntitle: Real")
        XCTAssertEqual(parsed.map(\.key), ["title"])
    }

    func testKeysObservedInTheRealDocumentAllParse() {
        // The field set Mark showed for a Jekyll-style post, so the card is
        // exercised against a shape that actually occurs rather than a toy.
        let yaml = """
        layout: single
        title: 모델보다 비즈니스 문제에서 출발하자
        comments: true
        classes: wide
        description: 여러 줄로 이어지는
          설명 문장입니다
        authors: jinwoong
        toc: true
        toc_label: Table of Contents
        slug: mlops/ml-platform-engineering-ch1-2
        date: 2026-10-23
        categories:
          - MLOps
        tags:
          - MLOps
          - ML Platform
          - Model Evaluation
        """
        let parsed = fields(yaml)
        XCTAssertEqual(parsed.map(\.key),
                       ["layout", "title", "comments", "classes", "description", "authors",
                        "toc", "toc_label", "slug", "date", "categories", "tags"])
        XCTAssertEqual(parsed.last?.value, .list(["MLOps", "ML Platform", "Model Evaluation"]))
        XCTAssertEqual(parsed[4].value, .scalar("여러 줄로 이어지는 설명 문장입니다"))
    }

    func testCRLFIsNormalizedDeliberately() {
        // Line endings are normalised on purpose; the round trip is then LF.
        let parsed = FrontMatter.parse("---\r\ntitle: X\r\n---\r\n\r\nbody\r\n")
        XCTAssertEqual(parsed?.fields.first?.value, .scalar("X"))
        XCTAssertFalse(parsed!.joined(withBody: parsed!.body).contains("\r"))
    }
}

// MARK: - 번역할 값 (title · description)

/// front matter에서 사람이 읽는 값만 골라 번역하고, **그 줄의 값만** 바꾼다.
/// 나머지 줄은 바이트 그대로 — 파서가 모르는 구문이 다시 쓰이면 안 된다.
final class FrontMatterTranslationTests: XCTestCase {

    private func block(_ lines: [String], body: String = "\n본문\n") -> String {
        "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    func testPicksOnlyTitleAndDescription() throws {
        let text = block(["title: 안녕하세요", "slug: hello", "date: 2026-10-30",
                          "description: 짧은 소개", "layout: post", "tags: [a, b]"])
        let values = try XCTUnwrap(FrontMatter.parse(text)).translatableValues
        XCTAssertEqual(values.map(\.key), ["title", "description"])
        XCTAssertEqual(values.map(\.text), ["안녕하세요", "짧은 소개"])
    }

    func testReplacesOnlyTheValueAndKeepsEveryOtherByte() throws {
        let text = block(["# 주석은 남는다", "title:  안녕하세요", "anchor: &ref 값",
                          "nested:", "  deep: 1", "description: 짧은 소개"])
        let matter = try XCTUnwrap(FrontMatter.parse(text))
        let values = matter.translatableValues
        let out = matter.joined(withBody: matter.body,
                                translatedValues: [values[0].line: "Hello", values[1].line: "A short intro"])
        let expected = block(["# 주석은 남는다", "title:  Hello", "anchor: &ref 값",
                              "nested:", "  deep: 1", "description: A short intro"])
        XCTAssertEqual(out, expected)
        // 고친 결과도 같은 파서로 다시 읽힌다.
        let reparsed = try XCTUnwrap(FrontMatter.parse(out))
        XCTAssertEqual(reparsed.fields.first { $0.key == "title" }?.value, .scalar("Hello"))
    }

    func testNoTranslationsMeansTheOriginalDocument() throws {
        let text = block(["title: 안녕"])
        let matter = try XCTUnwrap(FrontMatter.parse(text))
        XCTAssertEqual(matter.joined(withBody: matter.body, translatedValues: [:]), text)
    }

    func testKeepsQuoteStyleAndEscapes() throws {
        let text = block(["title: \"큰따옴표\"", "description: '작은따옴표'"])
        let matter = try XCTUnwrap(FrontMatter.parse(text))
        let values = matter.translatableValues
        XCTAssertEqual(values.map(\.text), ["큰따옴표", "작은따옴표"])
        let out = matter.joined(withBody: matter.body, translatedValues: [
            values[0].line: "Say \"hi\" \\ there",
            values[1].line: "Madi's editor",
        ])
        XCTAssertTrue(out.contains("title: \"Say \\\"hi\\\" \\\\ there\""), out)
        XCTAssertTrue(out.contains("description: 'Madi''s editor'"), out)
    }

    /// 따옴표 없던 값이라도 번역문이 YAML에서 다른 뜻이 되면 큰따옴표로 감싼다.
    func testPlainValueIsQuotedWhenTheTranslationWouldChangeMeaning() {
        for risky in ["Madi: an editor", "# not a comment", "- not a list", "yes", "Null", "42",
                      "3.14", "[x]", "a #b", "ends with:"] {
            let encoded = FrontMatter.encoded(risky, like: .plain)
            XCTAssertTrue(encoded.hasPrefix("\"") && encoded.hasSuffix("\""), "\(risky) → \(encoded)")
        }
        for safe in ["Hello world", "마디 소개", "C++ tips", "Version 2 notes"] {
            XCTAssertEqual(FrontMatter.encoded(safe, like: .plain), safe)
        }
    }

    /// 번역기가 줄을 나눠 내놓아도 한 줄 값으로 붙인다 — 줄바꿈이 들어가면 블록이 깨진다.
    func testNewlinesInTheTranslationAreJoined() {
        XCTAssertEqual(FrontMatter.encoded("첫 줄\n둘째 줄\n", like: .plain), "첫 줄 둘째 줄")
        XCTAssertEqual(FrontMatter.encoded("a\r\nb", like: .double), "\"a b\"")
    }

    /// 이 방식으로 뜻을 지킨다고 장담할 수 없는 값은 고르지 않는다.
    func testSkipsValuesThatAreNotSingleLineScalars() throws {
        let text = block([
            "title: |", "  여러 줄", "  블록",
            "description: 이어지는", "  값",
            "x: 1",
        ])
        XCTAssertEqual(try XCTUnwrap(FrontMatter.parse(text)).translatableValues, [])
        for line in ["title: [a, b]", "title: &anchor 값", "title: *alias", "title: !!str 값",
                     "title: \"이스케이프 \\n 있음\"", "title: 'it''s'", "title: 값 # 주석",
                     "title:", "title: \"\"", "  title: 들여쓴 키", "title : 띄운 키"] {
            let values = try XCTUnwrap(FrontMatter.parse(block([line]))).translatableValues
            XCTAssertEqual(values, [], line)
        }
    }

    /// 블록과 본문 사이의 빈 줄 모양을 지킨다.
    func testKeepsTheBlankSeparatorShape() throws {
        for body in ["\n본문\n", "본문\n"] {
            let text = block(["title: 안녕"], body: body)
            let matter = try XCTUnwrap(FrontMatter.parse(text))
            let out = matter.joined(withBody: matter.body,
                                    translatedValues: [matter.translatableValues[0].line: "Hi"])
            XCTAssertEqual(out, block(["title: Hi"], body: body))
        }
    }
}
