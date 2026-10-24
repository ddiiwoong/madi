import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class CodeHighlighterTests: XCTestCase {

    private func roles(_ code: String, _ language: CodeLanguage) -> [CodeHighlighter.Span.Role] {
        CodeHighlighter.spans(in: code, language: language).map(\.role)
    }

    private func text(_ code: String, _ language: CodeLanguage,
                      _ role: CodeHighlighter.Span.Role) -> [String] {
        let ns = code as NSString
        return CodeHighlighter.spans(in: code, language: language)
            .filter { $0.role == role }
            .map { ns.substring(with: $0.range) }
    }

    // MARK: 언어 이름

    func testLanguageNamesAndAliases() {
        XCTAssertEqual(CodeLanguage.named("swift"), .swift)
        XCTAssertEqual(CodeLanguage.named("JS"), .javascript)
        XCTAssertEqual(CodeLanguage.named("typescript"), .javascript)
        XCTAssertEqual(CodeLanguage.named("py"), .python)
        XCTAssertEqual(CodeLanguage.named("bash"), .shell)
        XCTAssertEqual(CodeLanguage.named("json"), .json)
    }

    func testUnknownLanguageIsNotGuessed() {
        // 모르는 언어에 아무 규칙이나 대면 틀린 강조가 나온다. nil이어야 한다.
        XCTAssertNil(CodeLanguage.named("brainfuck"))
        XCTAssertNil(CodeLanguage.named(""))
        XCTAssertNil(CodeLanguage.named(nil))
    }

    // MARK: 우선순위 — 주석과 문자열이 모든 것을 이긴다

    func testKeywordsInsideACommentAreNotHighlighted() {
        let code = "// if let guard return\nlet x = 1"
        XCTAssertEqual(text(code, .swift, .comment), ["// if let guard return"])
        // 주석 밖의 `let`만 키워드다.
        XCTAssertEqual(text(code, .swift, .keyword), ["let"])
    }

    func testKeywordsInsideAStringAreNotHighlighted() {
        let code = #"let s = "if let guard""#
        XCTAssertEqual(text(code, .swift, .keyword), ["let"])
        XCTAssertEqual(text(code, .swift, .string), [#""if let guard""#])
    }

    func testEscapedQuoteDoesNotEndTheString() {
        let code = #"let s = "a\"b" + x"#
        XCTAssertEqual(text(code, .swift, .string), [#""a\"b""#])
    }

    // MARK: 여러 줄에 걸친 구문 — 블록 단위로 넘겨야 맞는 부분

    func testBlockCommentSpansLines() {
        let code = "let a = 1\n/* if let\n   guard */\nlet b = 2"
        XCTAssertEqual(text(code, .swift, .comment), ["/* if let\n   guard */"])
        XCTAssertEqual(text(code, .swift, .keyword), ["let", "let"])
    }

    func testSwiftBlockCommentsNest() {
        // Swift는 블록 주석이 중첩된다. 안쪽 `*/`에서 끝내면 뒤가 전부 틀어진다.
        let code = "/* outer /* inner */ still comment */ let x = 1"
        XCTAssertEqual(text(code, .swift, .comment), ["/* outer /* inner */ still comment */"])
        XCTAssertEqual(text(code, .swift, .keyword), ["let"])
    }

    func testPythonDocstringSpansLines() {
        let code = "def f():\n    \"\"\"설명\n    여러 줄\"\"\"\n    return 1"
        XCTAssertEqual(text(code, .python, .string), ["\"\"\"설명\n    여러 줄\"\"\""])
        XCTAssertEqual(text(code, .python, .keyword), ["def", "return"])
    }

    func testJavaScriptTemplateLiteralSpansLines() {
        let code = "const a = `line1\nline2`;\nconst b = 1;"
        XCTAssertEqual(text(code, .javascript, .string), ["`line1\nline2`"])
        XCTAssertEqual(text(code, .javascript, .keyword), ["const", "const"])
    }

    func testAnUnterminatedQuoteStopsAtTheLineEnd() {
        // 치는 중에 늘 생기는 상태다. 따옴표 하나가 블록의 나머지 전부를 삼키면 안 된다.
        let code = "let a = \"oops\nlet b = 2"
        XCTAssertEqual(text(code, .swift, .string), ["\"oops"])
        XCTAssertEqual(text(code, .swift, .keyword), ["let", "let"])
    }

    // MARK: UTF-16 오프셋 — 한글·이모지가 있어도 구간이 밀리지 않는다

    func testOffsetsAreUTF16SoKoreanDoesNotShiftSpans() {
        let code = "// 한국어 주석\nlet x = 1"
        let ns = code as NSString
        let spans = CodeHighlighter.spans(in: code, language: .swift)
        for span in spans {
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), ns.length, "구간이 문서를 넘었다")
        }
        XCTAssertEqual(text(code, .swift, .keyword), ["let"], "한글 뒤의 키워드가 밀렸다")
    }

    func testEmojiInStringDoesNotShiftLaterSpans() {
        let code = "let a = \"🎉 축하\"\nlet b = 2"
        XCTAssertEqual(text(code, .swift, .keyword), ["let", "let"])
        let ns = code as NSString
        for span in CodeHighlighter.spans(in: code, language: .swift) {
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), ns.length)
        }
    }

    // MARK: 숫자와 식별자

    func testNumbersInsideIdentifiersAreNotNumbers() {
        // `utf8`의 8은 숫자가 아니다.
        XCTAssertEqual(text("let utf8 = 1", .swift, .number), ["1"])
    }

    func testHexAndFloatAreOneSpan() {
        XCTAssertEqual(text("let a = 0xFF", .swift, .number), ["0xFF"])
        XCTAssertEqual(text("let b = 3.14", .swift, .number), ["3.14"])
    }

    // MARK: 언어별 확인

    func testShellTreatsHashAsComment() {
        let code = "# 주석\necho \"hi\"\nif true; then"
        XCTAssertEqual(text(code, .shell, .comment), ["# 주석"])
        XCTAssertEqual(text(code, .shell, .keyword), ["echo", "if", "then"])
    }

    func testJsonHighlightsStringsNumbersAndLiterals() {
        let code = #"{"name": "Md", "count": 3, "ok": true, "none": null}"#
        XCTAssertEqual(text(code, .json, .string), [#""name""#, #""Md""#, #""count""#, #""ok""#, #""none""#])
        XCTAssertEqual(text(code, .json, .number), ["3"])
        XCTAssertEqual(text(code, .json, .keyword), ["true", "null"])
    }

    func testJsonHasNoComments() {
        // JSON에는 주석이 없다. `//`를 주석으로 칠하면 URL이 사라진다.
        let code = #"{"url": "https://example.com/a"}"#
        XCTAssertTrue(text(code, .json, .comment).isEmpty)
        XCTAssertEqual(text(code, .json, .string), [#""url""#, #""https://example.com/a""#])
    }

    func testSpansAreOrderedAndDoNotOverlap() {
        let code = "// c\nlet s = \"x\"\nlet n = 42 /* t */"
        let spans = CodeHighlighter.spans(in: code, language: .swift)
        var previousEnd = 0
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.range.location, previousEnd, "구간이 겹쳤다")
            previousEnd = NSMaxRange(span.range)
        }
        XCTAssertFalse(spans.isEmpty)
    }

    func testEmptyCodeProducesNoSpans() {
        XCTAssertTrue(CodeHighlighter.spans(in: "", language: .swift).isEmpty)
    }
}
