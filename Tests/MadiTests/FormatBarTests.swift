import AppKit
import XCTest

/// 글을 고르면 그 위에 뜨는 서식 막대(`FormatBarView`) — 사용자 — "글을 고르면 위에 뜨는 서식 막대".
@MainActor
final class FormatBarTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func editor(_ markdown: String) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        editor.formatBarDelay = 0
        window.contentView = editor
        window.orderBack(nil)
        window.makeFirstResponder(editor.textView)
        windows.append(window)
        editor.markdown = markdown
        return editor
    }

    /// 메인 큐에 걸린 일(막대 띄우기)이 돌 때까지.
    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    private func rect(of fragment: String, in view: MarkdownEditorView) throws -> NSRect {
        let range = (view.markdown as NSString).range(of: fragment)
        let layout = try XCTUnwrap(view.textView.layoutManager)
        let container = try XCTUnwrap(view.textView.textContainer)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = view.textView.textContainerOrigin
        return layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
    }

    private let source = "첫 줄\n\n둘째 문단입니다\n\n셋째 문단 글자\n"

    /// 글을 고르면 고르기가 멈춘 뒤 막대가 그 글의 위에 뜨고, 고른 것이 없어지면 거둔다.
    func testSelectingTextShowsTheBarAboveAndClearingHidesIt() async throws {
        let view = editor(source)
        view.textView.setSelectedRange((view.markdown as NSString).range(of: "셋째"))
        await settle()
        let bar = try XCTUnwrap(view.formatBar)
        XCTAssertFalse(bar.isHidden)
        XCTAssertTrue(bar.superview === view.textView, "글과 함께 굴러간다")
        let word = try rect(of: "셋째", in: view)
        XCTAssertLessThanOrEqual(bar.frame.maxY, word.minY, "고른 글의 위(뒤집힌 좌표에서 더 작은 y)")
        XCTAssertTrue(view.textView.visibleRect.contains(bar.frame), "보이는 칸 안")

        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(bar.isHidden, "고른 것이 없으면 바로 거둔다")
    }

    /// 맨 윗줄을 고르면 위에 자리가 없다 — 아래에 띄운다.
    func testTopLineGetsTheBarBelow() async throws {
        let view = editor(source)
        view.textView.setSelectedRange((view.markdown as NSString).range(of: "첫 줄"))
        await settle()
        let bar = try XCTUnwrap(view.formatBar)
        XCTAssertFalse(bar.isHidden)
        XCTAssertGreaterThanOrEqual(bar.frame.minY, try rect(of: "첫 줄", in: view).maxY)
    }

    /// 단추 — 제목 ▾ · 굵게 · 기울임 · 취소선 · 인라인 코드 · 링크. 누르면 그 자리에서 고치고, 첫 응답자가 되지 않아
    /// 선택이 편집기에 남는다(이어서 다른 단추를 누를 수 있다).
    func testButtonsFormatTheSelectionAndKeepItSelected() async throws {
        let view = editor(source)
        view.textView.setSelectedRange((view.markdown as NSString).range(of: "문단입니다"))
        await settle()
        let bar = try XCTUnwrap(view.formatBar)
        XCTAssertEqual(bar.buttons.map { $0.toolTip ?? "" },
                       ["제목 (⌘1~⌘6)", "굵게 (⌘B)", "기울임 (⌘I)", "취소선 (⇧⌘X)", "인라인 코드 (⇧⌘C)", "링크 (⌘K)"])
        XCTAssertTrue(bar.buttons.allSatisfy { $0.refusesFirstResponder && $0.image != nil })

        bar.buttons[1].performClick(nil)                                 // 굵게
        XCTAssertEqual(view.markdown, "첫 줄\n\n둘째 **문단입니다**\n\n셋째 문단 글자\n")
        XCTAssertEqual((view.markdown as NSString).substring(with: view.textView.selectedRange()), "문단입니다")
        bar.buttons[2].performClick(nil)                                 // 기울임
        XCTAssertEqual(view.markdown, "첫 줄\n\n둘째 ***문단입니다***\n\n셋째 문단 글자\n")
        XCTAssertTrue(view.window?.firstResponder === view.textView)

        let headings = bar.headingMenu.items
        XCTAssertEqual(headings.map(\.title), ["본문", "제목 1", "제목 2", "제목 3", "제목 4", "제목 5", "제목 6"])
        XCTAssertEqual(headings.map(\.tag), Array(0...6))
        XCTAssertTrue(headings.allSatisfy { $0.target === view })
    }

    /// 막대 위의 클릭은 막대가 받는다 — 아래의 텍스트 뷰가 아니라(그러면 캐럿이 옮겨 가 선택이 풀린다).
    func testClicksOnTheBarReachTheBar() async throws {
        let view = editor(source)
        view.textView.setSelectedRange((view.markdown as NSString).range(of: "셋째"))
        await settle()
        let bar = try XCTUnwrap(view.formatBar)
        for button in bar.buttons {
            let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
            let inSuperview = view.textView.superview.map { button.convert(center, to: $0) } ?? .zero
            XCTAssertTrue(view.textView.hitTest(inSuperview) === bar, button.toolTip ?? "")
        }
    }

    /// 창을 거치는 진짜 누름으로 굵게 단추를 누른다 — 막대가 받아 명령을 보내고, 아래 글의 선택은 그대로다. 단추가 직접
    /// 받던 판은 이 시험이 빨갰다(누름 · 뗌을 따라가다 명령이 가지 않았다 — 앱에서도 같았다).
    func testARealClickThroughTheWindowPressesTheButton() async throws {
        let view = editor(source)
        view.textView.setSelectedRange((view.markdown as NSString).range(of: "셋째"))
        await settle()
        let bar = try XCTUnwrap(view.formatBar)
        let window = try XCTUnwrap(view.window)
        let bold = bar.buttons[1]
        let point = bold.convert(NSPoint(x: bold.bounds.midX, y: bold.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        window.sendEvent(try event(.leftMouseDown))
        window.sendEvent(try event(.leftMouseUp))
        XCTAssertEqual(view.markdown, "첫 줄\n\n둘째 문단입니다\n\n**셋째** 문단 글자\n")
        XCTAssertEqual((view.markdown as NSString).substring(with: view.textView.selectedRange()), "셋째")
    }

    /// 한글을 조합하는 중이거나, 프린트 · PDF로 내보내는 동안에는 띄우지 않는다(내보내면 그림에 찍힌다).
    func testHiddenWhileRenderingForOutput() async throws {
        let view = editor(source)
        view.textView.setSelectedRange((view.markdown as NSString).range(of: "셋째"))
        await settle()
        XCTAssertEqual(view.formatBar?.isHidden, false)
        view.isRenderingForOutput = true
        XCTAssertEqual(view.formatBar?.isHidden, true)
        view.updateFormatBar()
        XCTAssertEqual(view.formatBar?.isHidden, true, "내보내는 동안 다시 띄우지 않는다")
        view.isRenderingForOutput = false
    }

    /// 다른 곳으로 캐럿이 가면 거둔다.
    func testLeavingTheEditorHidesTheBar() async throws {
        let view = editor(source)
        view.textView.setSelectedRange((view.markdown as NSString).range(of: "셋째"))
        await settle()
        XCTAssertEqual(view.formatBar?.isHidden, false)
        view.window?.makeFirstResponder(nil)
        XCTAssertEqual(view.formatBar?.isHidden, true)
    }
}
