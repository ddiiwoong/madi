import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class MarkdownSyntaxTests: XCTestCase {

    private let syntax = MarkdownSyntax()

    private func kinds(_ source: String) -> [BlockKind] {
        syntax.scanLines(in: source as NSString).map(\.kind)
    }

    func testBaselineBlockClassification() {
        XCTAssertEqual(kinds("# Title"), [.heading(level: 1)])
        XCTAssertEqual(kinds("### Deep"), [.heading(level: 3)])
        XCTAssertEqual(kinds("> quoted"), [.quote(depth: 1)])
        XCTAssertEqual(kinds("- item"), [.listItem(ordered: false, checked: nil)])
        XCTAssertEqual(kinds("1. item"), [.listItem(ordered: true, checked: nil)])
        XCTAssertEqual(kinds("- [x] done"), [.listItem(ordered: false, checked: true)])
        XCTAssertEqual(kinds("- [ ] todo"), [.listItem(ordered: false, checked: false)])
        XCTAssertEqual(kinds("---"), [.thematicBreak])
        XCTAssertEqual(kinds("plain"), [.paragraph])
        XCTAssertEqual(kinds(""), [.blank])
    }

    func testFenceTrackingMakesInteriorLinesCode() {
        XCTAssertEqual(kinds("```js\n# not a heading\n```\n# real"),
                       [.codeFence, .codeBody, .codeFence, .heading(level: 1)])
    }

    func testHeadingMarkerRangeCoversHashesAndTheSpace() {
        let source = "## 검색" as NSString
        let line = syntax.scanLines(in: source)[0]
        XCTAssertEqual(line.markerRanges.count, 1)
        XCTAssertEqual(source.substring(with: line.markerRanges[0]), "## ")
        XCTAssertEqual(source.substring(with: line.contentRange), "검색")
    }

    func testInlineStrongAndEmphasis() {
        let source = "a **bold** and *em* here" as NSString
        let tokens = syntax.scanInline(in: source, range: NSRange(location: 0, length: source.length))
        XCTAssertEqual(tokens.filter { $0.kind == .strong }.count, 1)
        XCTAssertEqual(tokens.filter { $0.kind == .emphasis }.count, 1)
        let strong = tokens.first { $0.kind == .strong }!
        XCTAssertEqual(source.substring(with: strong.contentRange), "bold")
        XCTAssertEqual(strong.markerRanges.count, 2)
    }

    func testInlineCodeIsNotParsedFurther() {
        let source = "use `**not bold**` here" as NSString
        let tokens = syntax.scanInline(in: source, range: NSRange(location: 0, length: source.length))
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .code)
        XCTAssertEqual(source.substring(with: tokens[0].contentRange), "**not bold**")
    }

    func testLinkCapturesItsTarget() {
        let source = "see [docs](https://example.com) now" as NSString
        let tokens = syntax.scanInline(in: source, range: NSRange(location: 0, length: source.length))
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .link(url: "https://example.com"))
        XCTAssertEqual(source.substring(with: tokens[0].contentRange), "docs")
    }

    func testUnderscoreInsideAWordIsNotEmphasis() {
        let source = "snake_case_name" as NSString
        let tokens = syntax.scanInline(in: source, range: NSRange(location: 0, length: source.length))
        XCTAssertTrue(tokens.isEmpty, "got \(tokens.map(\.kind))")
    }

    func testRangesAreDocumentAbsolute() {
        let source = "first\n## second" as NSString
        let lines = syntax.scanLines(in: source)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(source.substring(with: lines[1].range), "## second")
        XCTAssertEqual(source.substring(with: lines[1].contentRange), "second")
    }
}

final class OutlineTests: XCTestCase {

    func testOutlineSkipsHeadingsInsideFences() {
        let source = "# Real\n\n```\n# Fake\n```\n\n## Second" as NSString
        let entries = Outline.entries(in: source)
        XCTAssertEqual(entries.map(\.title), ["Real", "Second"])
        XCTAssertEqual(entries.map(\.level), [1, 2])
    }

    func testOutlineReportsLineNumbersAndRanges() {
        let source = "intro\n\n## 검색\nbody" as NSString
        let entries = Outline.entries(in: source)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].lineNumber, 3)
        XCTAssertEqual(source.substring(with: entries[0].range), "## 검색")
    }

    func testHeadingWithNoTitleIsNotAnEntry() {
        XCTAssertTrue(Outline.entries(in: "#" as NSString).isEmpty)
        XCTAssertTrue(Outline.entries(in: "###   " as NSString).isEmpty)
    }
}
