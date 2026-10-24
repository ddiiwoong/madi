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

    // MARK: 새로 넣은 여섯 언어 — 각자의 함정을 하나씩 못박는다

    func testNewLanguageNamesAndAliases() {
        XCTAssertEqual(CodeLanguage.named("rs"), .rust)
        XCTAssertEqual(CodeLanguage.named("golang"), .go)
        XCTAssertEqual(CodeLanguage.named("yml"), .yaml)
        XCTAssertEqual(CodeLanguage.named("SCSS"), .css)
        XCTAssertEqual(CodeLanguage.named("svg"), .html)
        XCTAssertEqual(CodeLanguage.named("postgresql"), .sql)
    }

    func testRustLifetimeIsNotReadAsAString() {
        // 함정: `'`를 문자열 구분자로 두면 `&'a str`에서 문자열이 시작돼 줄 끝까지
        // 빨갛게 된다. 수명이 문자 리터럴보다 훨씬 흔하므로 `'`를 쓰지 않는다.
        let code = "fn f<'a>(s: &'a str) -> &'a str { s }"
        XCTAssertTrue(text(code, .rust, .string).isEmpty,
                      "수명이 문자열로 읽혔다: \(text(code, .rust, .string))")
        XCTAssertEqual(text(code, .rust, .keyword), ["fn"])
        XCTAssertEqual(text(code, .rust, .type), ["str", "str"])
    }

    func testRustBlockCommentsNest() {
        let code = "/* a /* b */ c */ fn main() {}"
        XCTAssertEqual(text(code, .rust, .comment), ["/* a /* b */ c */"])
        XCTAssertEqual(text(code, .rust, .keyword), ["fn"])
    }

    func testGoRawStringSpansLines() {
        let code = "s := `여러\n줄`\nfunc f() {}"
        XCTAssertEqual(text(code, .go, .string), ["`여러\n줄`"])
        XCTAssertEqual(text(code, .go, .keyword), ["func"])
    }

    func testCssHasNoLineCommentsSoUrlsSurvive() {
        // 함정: CSS에 `//`는 주석이 아니다. 주석으로 다루면 URL의 뒷부분이 사라진다.
        let code = "a { background: url(//example.com/a.png); }"
        XCTAssertTrue(text(code, .css, .comment).isEmpty,
                      "URL이 주석으로 먹혔다: \(text(code, .css, .comment))")
    }

    func testCssBlockCommentStillWorks() {
        let code = "/* 설명 */ a { color: red; }"
        XCTAssertEqual(text(code, .css, .comment), ["/* 설명 */"])
    }

    func testHtmlCommentDelimiters() {
        let code = "<!-- 숨긴 <div> -->\n<p>본문</p>"
        XCTAssertEqual(text(code, .html, .comment), ["<!-- 숨긴 <div> -->"])
        // 주석 안의 div는 키워드가 아니고, 주석 밖의 p는 키워드다.
        XCTAssertEqual(text(code, .html, .keyword), ["p", "p"])
    }

    func testSqlKeywordsAreCaseInsensitive() {
        // 함정: `SELECT`와 `select`가 같은 키워드다. 대소문자를 가리면 한쪽만 칠해진다.
        XCTAssertEqual(text("SELECT * FROM t", .sql, .keyword), ["SELECT", "FROM"])
        XCTAssertEqual(text("select * from t", .sql, .keyword), ["select", "from"])
        XCTAssertEqual(text("Select * From t", .sql, .keyword), ["Select", "From"])
    }

    func testSqlUsesDoubleDashForLineComments() {
        let code = "-- 설명\nSELECT 1"
        XCTAssertEqual(text(code, .sql, .comment), ["-- 설명"])
        XCTAssertEqual(text(code, .sql, .keyword), ["SELECT"])
    }

    func testSqlSingleQuotedStrings() {
        let code = "SELECT * FROM t WHERE name = '한국어'"
        XCTAssertEqual(text(code, .sql, .string), ["'한국어'"])
    }

    func testYamlCommentAndLiterals() {
        let code = "# 설명\nenabled: true\nname: \"값\""
        XCTAssertEqual(text(code, .yaml, .comment), ["# 설명"])
        XCTAssertEqual(text(code, .yaml, .keyword), ["true"])
        XCTAssertEqual(text(code, .yaml, .string), ["\"값\""])
    }

    func testEveryLanguageSurvivesKoreanWithoutShiftingOffsets() {
        // 언어를 더할 때마다 UTF-16 오프셋을 깨뜨릴 수 있다. 전부 한 번에 지킨다.
        for language in CodeLanguage.allCases {
            let code = "한국어 주석과 \"한국어 문자열\" 그리고 🎉\nx = 1"
            let ns = code as NSString
            for span in CodeHighlighter.spans(in: code, language: language) {
                XCTAssertLessThanOrEqual(NSMaxRange(span.range), ns.length,
                                         "\(language)에서 구간이 문서를 넘었다")
                XCTAssertGreaterThanOrEqual(span.range.location, 0)
            }
        }
    }

    func testEveryLanguageProducesOrderedNonOverlappingSpans() {
        for language in CodeLanguage.allCases {
            let code = "a \"s\" 1 b\nc = 2"
            var previousEnd = 0
            for span in CodeHighlighter.spans(in: code, language: language) {
                XCTAssertGreaterThanOrEqual(span.range.location, previousEnd,
                                            "\(language)에서 구간이 겹쳤다")
                previousEnd = NSMaxRange(span.range)
            }
        }
    }
}
