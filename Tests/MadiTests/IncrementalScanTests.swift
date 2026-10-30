import XCTest

/// 고친 자리부터 다시 훑기(`MarkdownSyntax.rescan`)가 **처음부터 훑기와 같은 답**을 내는지.
///
/// 틀리면 문서가 틀리게 그려진다(코드가 본문으로, 제목이 문단으로) — 그래서 무작위 편집을
/// 수천 번 넣고 매번 전체 다시 훑기와 견준다. 앞 편집의 결과를 다음 편집의 출발점으로 쓴다
/// (편집기가 그렇게 쓴다). 씨앗이 고정이라 실패하면 같은 편집이 다시 나온다.
final class IncrementalScanTests: XCTestCase {

    private let syntax = MarkdownSyntax()

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 판정이 갈리기 쉬운 조각 — 펜스를 열고 닫는 것, setext 밑줄, 줄바꿈의 여러 꼴.
    private let inserts = ["\n", "\r", "\r\n", "\n\n", "```", "```swift\n", "\n```\n", "~~~\n",
                           "===", "\n===\n", "---", "\n---\n", "# ", "> ", "- ", "1. ", "| a | b |\n",
                           "|---|---|\n", "[r]: http://x\n", "가", "abc", " ", "\t", "\u{2028}",
                           "본문 한 줄\n", "**굵게**", "`코드`"]

    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return bound <= 0 ? 0 : Int((state >> 33) % UInt64(bound))
        }
    }

    /// `text`에 편집 하나를 넣고 (편집 뒤 범위, 길이 변화)를 돌려준다 — `NSTextStorage`가
    /// 대리자에게 주는 값과 같은 뜻이다.
    private func randomEdit(_ text: NSMutableString, _ random: inout Generator) -> (NSRange, Int) {
        let length = text.length
        // 줄의 시작·끝·문서 끝처럼 경계에 자주 놓는다.
        var location: Int
        switch random.next(4) {
        case 0: location = length
        case 1:
            let probe = random.next(length + 1)
            location = text.lineRange(for: NSRange(location: min(probe, length), length: 0)).location
        default: location = random.next(length + 1)
        }
        // 서로게이트 쌍 가운데를 자르지 않는다(실제 편집기는 그렇게 자르지 않는다).
        if location > 0, location < length, UTF16.isTrailSurrogate(text.character(at: location)) {
            location -= 1
        }
        var removeLength = random.next(3) == 0 ? random.next(min(40, length - location) + 1) : 0
        if removeLength > 0, location + removeLength < length,
           UTF16.isTrailSurrogate(text.character(at: location + removeLength)) {
            removeLength += 1
        }
        let insert = random.next(3) == 0 ? "" : inserts[random.next(inserts.count)]
        text.replaceCharacters(in: NSRange(location: location, length: removeLength), with: insert)
        let inserted = (insert as NSString).length
        return (NSRange(location: location, length: inserted), inserted - removeLength)
    }

    private func check(_ document: String, edits: Int, seed: UInt64, name: String) {
        let text = NSMutableString(string: document)
        var random = Generator(state: seed)
        var scan = syntax.scan(text)
        for step in 0..<edits {
            let before = text.copy() as! String
            let (range, delta) = randomEdit(text, &random)
            let next = syntax.rescan(text, after: scan, editedRange: range, changeInLength: delta)
            let full = syntax.scan(text)
            guard let next else {
                return XCTFail("\(name) 편집 \(step): 맞는 입력인데 다시 훑기를 거절했다 \(range) Δ\(delta)")
            }
            guard next.lines == full.lines, next.raw == full.raw, next.states == full.states else {
                // 실패한 편집을 그대로 보인다 — 짧은 재현이 이것이다.
                let firstDiff = zip(next.lines, full.lines).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                    ?? min(next.lines.count, full.lines.count)
                XCTFail("""
                \(name) 편집 \(step): \(range) Δ\(delta)
                앞 글 길이 \(before.utf16.count), 줄 \(next.lines.count) vs \(full.lines.count), 처음 다른 줄 \(firstDiff)
                증분: \(firstDiff < next.lines.count ? String(describing: next.lines[firstDiff]) : "-")
                전체: \(firstDiff < full.lines.count ? String(describing: full.lines[firstDiff]) : "-")
                """)
                return
            }
            scan = next
        }
    }

    func testRandomEditsOnRepositoryDocuments() throws {
        for (index, name) in ["README.md", "TODO.md", "docs/features.md", "docs/block-editor-design.md"].enumerated() {
            let text = try String(contentsOf: repoRoot().appendingPathComponent(name), encoding: .utf8)
            check(text, edits: 300, seed: UInt64(17 + index), name: name)
        }
    }

    /// 펜스·setext·줄바꿈 꼴이 빽빽한 작은 문서 — 경계 경우가 자주 부딪힌다.
    func testRandomEditsOnDenseSyntax() {
        let dense = """
        제목
        ===
        문단
        ---
        ```swift
        let x = 1
        ```
        ~~~
        코드
        ~~~
        > 인용
        - 목록
        | a | b |
        |---|---|
        [r]: http://x
        끝\r\n줄\r\n
        """
        for seed in 0..<6 {
            check(dense, edits: 400, seed: 1000 + UInt64(seed), name: "dense#\(seed)")
        }
    }

    func testEdgeDocuments() {
        for (index, document) in ["", "\n", "\r", "```", "```\n", "a\n===", "===\n", "\r\n\r\n"].enumerated() {
            check(document, edits: 200, seed: 500 + UInt64(index), name: "edge#\(index)")
        }
    }

    /// 편집기 배선 — `NSTextStorage`가 대리자에게 주는 `editedRange`·`changeInLength`의 뜻이
    /// `rescan`이 가정하는 뜻과 같은지. 편집 여럿을 한 `beginEditing` 안에 묶어도(범위가 합쳐져
    /// 온다) 맞아야 한다.
    @MainActor
    func testEditorLinesStayEqualToAFullScanThroughStorageEdits() throws {
        let document = try String(contentsOf: repoRoot().appendingPathComponent("docs/features.md"),
                                  encoding: .utf8)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        editor.markdown = document
        _ = editor.currentLines()
        let storage = editor.textView.textStorage!
        var random = Generator(state: 4242)
        for step in 0..<150 {
            let grouped = random.next(4) == 0
            if grouped { storage.beginEditing() }
            for _ in 0 ..< (grouped ? 3 : 1) {
                let scratch = NSMutableString(string: storage.string)
                let (range, delta) = randomEdit(scratch, &random)
                let replaced = NSRange(location: range.location, length: range.length - delta)
                storage.replaceCharacters(in: replaced, with: (scratch as NSString).substring(with: range))
            }
            if grouped { storage.endEditing() }
            let expected = syntax.scanLines(in: storage.string as NSString)
            guard editor.currentLines() == expected else {
                return XCTFail("편집 \(step)\(grouped ? " (묶음)" : "") 뒤 편집기의 줄 판정이 전체 다시 훑기와 다르다")
            }
        }
        // 처음 한 번 말고는 전체를 훑지 않았다 — 배선이 틀린 값을 넘기면 다시 훑기가 거절되고
        // 결과는 여전히 맞지만 여기서 드러난다.
        XCTAssertEqual(editor.fullScanCount, 1, "편집이 전체 다시 훑기로 떨어졌다")
    }

    /// 앞뒤가 맞지 않는 입력(다른 글의 결과)은 거절한다 — 틀린 답을 내지 않고, 부르는 쪽이
    /// 전체를 훑는다.
    func testMismatchedPreviousIsRefused() {
        let old = syntax.scan("하나\n둘\n" as NSString)
        let text = "전혀 다른 글\n```\n코드\n" as NSString
        XCTAssertNil(syntax.rescan(text, after: old, editedRange: NSRange(location: 0, length: 1),
                                   changeInLength: 0))
    }

    /// 문서 맨 앞에서 한 글자를 넣으면 뒤쪽 줄은 판정이 그대로이고 위치만 한 칸 밀린다.
    /// (다시 판정하지 않았다는 것은 여기서 보지 않는다 — 편집기 배선 테스트의 `fullScanCount`가
    /// 전체 다시 훑기로 떨어지지 않았음을 본다.)
    func testFarLinesAreShiftedByTheEdit() {
        var document = "앞 문단\n\n"
        for index in 0..<200 { document += "문단 \(index)\n\n" }
        let text = NSMutableString(string: document)
        let before = syntax.scan(text)
        text.replaceCharacters(in: NSRange(location: 0, length: 0), with: "가")
        guard let after = syntax.rescan(text, after: before, editedRange: NSRange(location: 0, length: 1),
                                        changeInLength: 1) else { return XCTFail("거절했다") }
        XCTAssertEqual(after.lines.count, before.lines.count)
        XCTAssertEqual(after.lines.last?.range.location, before.lines.last.map { $0.range.location + 1 })
        XCTAssertEqual(after.lines, syntax.scan(text).lines)
    }
}
