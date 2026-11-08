import AppKit
import XCTest

/// 코드 블록의 `복사` 단추 — 베낄 글(`CodeBlockCopy`)과 단추(`CodeCopyButtonView`, 사용자 — "코드 복사 버튼도 있으면
/// 좋겠어").
final class CodeBlockCopyTests: XCTestCase {

    private func copies(_ markdown: String) -> [String] {
        let text = markdown as NSString
        let lines = MarkdownSyntax().scanLines(in: text)
        return CodeBlockCopy.blocks(in: lines, text: text).map { CodeBlockCopy.text(of: $0, in: text) }
    }

    func testCopiesTheCodeWithoutFencesOrLanguage() {
        let text = "글\n\n```bash\necho 1\necho 2\n```\n뒤\n" as NSString
        let blocks = CodeBlockCopy.blocks(in: MarkdownSyntax().scanLines(in: text), text: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].language, "bash")
        XCTAssertEqual(text.substring(with: blocks[0].range), "```bash\necho 1\necho 2\n```")
        XCTAssertEqual(CodeBlockCopy.text(of: blocks[0], in: text), "echo 1\necho 2")
    }

    /// 닫는 펜스 바로 다음 줄에 다음 블록이 열려도 블록은 둘이다 — 회색 상자는 하나로 이어져 그려진다.
    func testAdjacentBlocksAreSeparate() {
        XCTAssertEqual(copies("```\na\n```\n```py\nb\n```\n"), ["a", "b"])
    }

    func testKeepsBlankLinesAndMarkupInsideTheCode() {
        XCTAssertEqual(copies("```\na\n\nb\n```"), ["a\n\nb"])
        XCTAssertEqual(copies("```bash\n-L **18080**:127.0.0.1\n```"), ["-L **18080**:127.0.0.1"],
                       "코드 안의 `**`는 글자다(Notion 내보내기)")
        XCTAssertEqual(copies("~~~\nx\n~~~"), ["x"])
    }

    func testEmptyAndUnclosedBlocks() {
        XCTAssertEqual(copies("```\n```\n"), [""])
        XCTAssertEqual(copies("앞\n```\na\nb"), ["a\nb"], "문서 끝까지 열린 블록")
    }

    /// 목록 안의 블록은 펜스의 들여쓰기만큼 코드 줄에서 뺀다 — 더 들여 쓴 줄은 그 차이가 남는다.
    func testIndentedBlockDropsTheFenceIndent() {
        XCTAssertEqual(copies("- 항목\n  ```bash\n  ls -la\n    nested\n  ```\n"), ["ls -la\n  nested"])
    }
}

@MainActor
final class CodeCopyButtonTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func editor(_ markdown: String, height: CGFloat = 480) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 640, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 640, height: height))
        editor.codePasteboard = NSPasteboard(name: NSPasteboard.Name("madi-test-\(UUID().uuidString)"))
        window.contentView = editor
        window.orderBack(nil)
        windows.append(window)
        editor.markdown = markdown
        editor.textView.layoutManager?.ensureLayout(for: editor.textView.textContainer!)
        editor.layoutSubtreeIfNeeded()
        return editor
    }

    /// 글 조각의 자리(텍스트 뷰 좌표).
    private func rect(of fragment: String, in view: MarkdownEditorView) throws -> NSRect {
        let range = (view.markdown as NSString).range(of: fragment)
        let layout = try XCTUnwrap(view.textView.layoutManager)
        let container = try XCTUnwrap(view.textView.textContainer)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: view.textView.textContainerOrigin.x, dy: view.textView.textContainerOrigin.y)
    }

    private let source = "앞 문단\n\n```bash\necho hello\nls -la\n```\n\n뒤 문단\n"

    /// 마우스가 코드 블록 위에 오면 단추가 블록의 오른쪽 위에 뜨고, 블록 밖으로 나가면 거둔다.
    func testHoveringACodeBlockShowsTheButtonAtItsTopRight() throws {
        let view = editor(source)
        let code = try rect(of: "echo hello", in: view)
        view.updateCodeCopyButton(at: NSPoint(x: code.midX, y: code.midY))
        let button = try XCTUnwrap(view.codeCopyButton)
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(button.superview === view.textView, "글과 함께 굴러간다")
        XCTAssertEqual(button.title, "복사")
        XCTAssertGreaterThan(button.frame.minX, code.maxX, "오른쪽에")
        XCTAssertLessThan(button.frame.minY, code.minY, "블록의 위쪽(첫 코드 줄보다 위)")
        XCTAssertGreaterThan(button.frame.maxX, view.textView.bounds.width * 0.7)

        let outside = try rect(of: "뒤 문단", in: view)
        view.updateCodeCopyButton(at: NSPoint(x: outside.midX, y: outside.midY))
        XCTAssertTrue(button.isHidden, "블록 밖이면 거둔다")
    }

    /// 마우스 이동은 텍스트 뷰의 추적 영역이 편집기에 알린다 — 창 좌표의 사건이 블록 위면 단추가 뜨고, 텍스트 뷰를
    /// 벗어나면 거둔다.
    func testMouseMovedEventsDriveTheButton() throws {
        let view = editor(source)
        let area = try XCTUnwrap(view.textView.trackingAreas.first { $0.owner === view })
        XCTAssertTrue(area.options.contains(.mouseMoved))
        XCTAssertTrue(area.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(area.options.contains(.inVisibleRect))
        XCTAssertTrue(area.options.contains(.activeInActiveApp))

        let code = try rect(of: "echo hello", in: view)
        let inWindow = view.textView.convert(NSPoint(x: code.midX, y: code.midY), to: nil)
        let window = try XCTUnwrap(view.window)
        let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: inWindow, modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.mouseMoved(with: moved)
        XCTAssertEqual(view.codeCopyButton?.isHidden, false)
        let exited = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: inWindow, modifierFlags: [],
                                                          timestamp: 0, windowNumber: window.windowNumber,
                                                          context: nil, eventNumber: 0, trackingNumber: 0,
                                                          userData: nil))
        view.mouseExited(with: exited)
        XCTAssertEqual(view.codeCopyButton?.isHidden, true)
    }

    /// 누르면 펜스 · 언어 이름을 뺀 코드가 대지에 들어가고 `복사됨`이 됐다가 돌아온다.
    func testPressingCopiesTheCodeAndShowsCopied() async throws {
        let view = editor(source)
        let code = try rect(of: "ls -la", in: view)
        view.updateCodeCopyButton(at: NSPoint(x: code.midX, y: code.midY))
        let button = try XCTUnwrap(view.codeCopyButton)
        button.copiedDuration = 0.05
        XCTAssertTrue(button.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button,
                      "클릭은 단추가 받는다(텍스트 뷰 안의 NSButton은 뗌이 오지 않았다)")
        let right = button.frame.maxX
        button.press()
        XCTAssertEqual(view.codePasteboard.string(forType: .string), "echo hello\nls -la")
        XCTAssertEqual(button.title, "복사됨")
        XCTAssertEqual(button.frame.maxX, right, accuracy: 1, "넓어져도 오른쪽 끝은 그대로 — 상자 밖으로 나가지 않는다")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(button.title, "복사", "잠깐 뒤 돌아온다")
        XCTAssertTrue(button.accessibilityPerformPress(), "VoiceOver로도 누를 수 있다")
    }

    /// 닫자마자 다음 블록이 열리면 상자는 하나로 이어지지만 단추는 마우스 아래의 블록을 베낀다.
    func testAdjacentBlocksCopyTheBlockUnderTheMouse() throws {
        let view = editor("```\n첫 블록\n```\n```\n둘째 블록\n```\n")
        let second = try rect(of: "둘째 블록", in: view)
        view.updateCodeCopyButton(at: NSPoint(x: second.midX, y: second.midY))
        try XCTUnwrap(view.codeCopyButton).press()
        XCTAssertEqual(view.codePasteboard.string(forType: .string), "둘째 블록")
    }

    /// 긴 블록을 굴려 위가 가려지면 단추는 보이는 칸의 맨 위에 — 블록 안에서만.
    func testButtonFollowsTheVisibleTopOfALongBlock() throws {
        let lines = (1 ... 80).map { "line \($0)" }.joined(separator: "\n")
        let view = editor("앞\n\n```\n\(lines)\n```\n\n뒤\n", height: 300)
        let target = try rect(of: "line 40", in: view)
        view.clipView.scroll(to: NSPoint(x: 0, y: target.minY - 100))
        view.updateCodeCopyButton(at: NSPoint(x: target.midX, y: target.midY))
        let button = try XCTUnwrap(view.codeCopyButton)
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(view.textView.visibleRect.contains(button.frame), "보이는 칸 안")
        XCTAssertLessThan(button.frame.minY - view.textView.visibleRect.minY, 12, "보이는 칸의 맨 위")
    }

    /// 다이어그램처럼 그림이 된 블록과 원본 보기, 내보내는 동안에는 단추가 없다.
    func testNoButtonInCodeViewOrWhileExporting() throws {
        let view = editor(source)
        let code = try rect(of: "echo hello", in: view)
        let point = NSPoint(x: code.midX, y: code.midY)
        view.isRenderingForOutput = true
        view.updateCodeCopyButton(at: point)
        XCTAssertTrue(view.codeCopyButton?.isHidden ?? true, "내보내는 동안")
        view.isRenderingForOutput = false
        view.updateCodeCopyButton(at: point)
        XCTAssertEqual(view.codeCopyButton?.isHidden, false)
        view.isRenderingForOutput = true
        XCTAssertEqual(view.codeCopyButton?.isHidden, true, "내보내기를 시작하면 거둔다")
        view.isRenderingForOutput = false

        view.isCodeView = true
        view.updateCodeCopyButton(at: point)
        XCTAssertTrue(view.codeCopyButton?.isHidden ?? true, "원본 보기에는 상자가 없다")
    }
}
