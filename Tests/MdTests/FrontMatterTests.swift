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
