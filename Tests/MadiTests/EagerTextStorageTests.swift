import AppKit
import XCTest

/// 속성을 바로 고치는 저장소(`EagerTextStorage`).
///
/// 시간을 재지 않는다(기계마다 흔들린다). 느렸던 원인 — 한 글자에 65,536자를 두 번 고친 것 — 을
/// **고친 글자 수**로 못박는다. 실측 숫자는 `TODO.md` '큰 문서 — 남은 것'에 있다.
@MainActor
final class EagerTextStorageTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func editor(_ markdown: String) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 760, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        window.contentView = editor
        window.orderBack(nil)
        windows.append(window)
        editor.markdown = markdown
        return editor
    }

    /// 한 글자를 치면 **그 문단만** 고친다. 기본 저장소는 편집 지점 뒤를 전부 고칠 것으로 잡아,
    /// 문서 앞쪽에서 한 글자에 65,536자를 두 번(131,072자) 고쳤다.
    func testTypingNearTheStartFixesOnlyTheEditedParagraph() throws {
        var markdown = "# 제목\n\n"
        for index in 0 ..< 2500 {
            markdown += "문단 \(index)입니다. 한글과 English가 섞인 줄이 화면 밖까지 이어집니다.\n\n"
        }
        let view = editor(markdown)
        let storage = try XCTUnwrap(view.textView.textStorage as? EagerTextStorage, "편집기가 이 저장소를 쓴다")
        XCTAssertFalse(storage.fixesAttributesLazily)
        XCTAssertGreaterThan(storage.length, 100_000, "전제: 큰 문서")

        let tv = view.textView
        let at = (markdown as NSString).range(of: "문단 3입니다").location
        tv.setSelectedRange(NSRange(location: at, length: 0))
        tv.window?.displayIfNeeded()

        let before = storage.fixedCharacterCount
        tv.insertText("가", replacementRange: tv.selectedRange())
        tv.window?.displayIfNeeded()
        let fixed = storage.fixedCharacterCount - before
        XCTAssertGreaterThan(fixed, 0, "고친 글을 고쳤다")
        XCTAssertLessThan(fixed, 1_000, "한 글자에 고친 글자 수 — 문단 하나(쳐 넣기 + 다시 칠하기)여야 한다")
    }

    /// 레이아웃 없이도 고쳐져 있다 — 한글이 없는 글꼴을 준 자리에 대체 글꼴이 붙는다.
    func testFontsAreFixedWithoutLayout() {
        let storage = EagerTextStorage()
        storage.replaceCharacters(in: NSRange(), with: "가나다 abc")
        storage.setAttributes([.font: NSFont(name: "Helvetica", size: 13)!],
                              range: NSRange(location: 0, length: storage.length))
        let hangul = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let latin = storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        XCTAssertEqual(latin?.familyName, "Helvetica")
        XCTAssertNotEqual(hangul?.familyName, "Helvetica", "한글 자리는 대체 글꼴이다")
    }

    /// 읽기 셀렉터는 Swift를 거치지 않는 블록으로 바꿔 끼웠다 — 그 길이 맞게 읽는지.
    func testAttributeReadsGoThroughTheFastPathCorrectly() {
        let storage = EagerTextStorage()
        storage.replaceCharacters(in: NSRange(), with: "앞 굵게 뒤")
        let bold = NSRange(location: 2, length: 2)
        storage.addAttribute(.kern, value: 3.0, range: bold)

        var range = NSRange()
        let attributes = storage.attributes(at: 2, effectiveRange: &range)
        XCTAssertEqual(attributes[.kern] as? Double, 3.0)
        XCTAssertEqual(range, bold)

        var single = NSRange()
        XCTAssertEqual(storage.attribute(.kern, at: 3, effectiveRange: &single) as? Double, 3.0)
        XCTAssertEqual(single, bold)
        XCTAssertNil(storage.attribute(.kern, at: 0, effectiveRange: nil))

        var longest = NSRange()
        _ = storage.attribute(.kern, at: 2, longestEffectiveRange: &longest,
                              in: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(longest, bold)
    }

    /// `string`은 고칠 때마다 새 글이다 — 사본을 갈아 끼우지 않으면 낡은 글을 돌려준다.
    func testStringFollowsEveryEdit() {
        let storage = EagerTextStorage()
        storage.replaceCharacters(in: NSRange(), with: "마디")
        storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: " 편집기")
        XCTAssertEqual(storage.string, "마디 편집기")
        storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "")
        XCTAssertEqual(storage.string, "편집기")
        XCTAssertEqual(storage.length, 3)
    }

    /// 한글 조합(표시된 글)·되돌리기가 이 저장소에서도 그대로다.
    func testMarkedTextAndUndoStillWork() {
        let view = editor("첫 줄\n")
        let tv = view.textView
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.markdown, "첫 줄\n한")
        tv.undoManager?.undo()
        XCTAssertEqual(view.markdown, "첫 줄\n")
    }
}
