import AppKit
import XCTest

/// 목록 키보드 규칙(`ListEditing`) — Enter 이어 쓰기·끝내기, Tab·⇧Tab, 체크박스 뒤집기.
///
/// 규칙은 순수 계산이라 글과 캐럿만으로 확인한다. 편집기에 **실제로 이어졌는지**(Enter가
/// 규칙을 지나는지, 한 번의 ⌘Z로 되돌아가는지)는 아래 `MarkdownEditorView` 쪽 테스트가 본다.
final class ListEditingTests: XCTestCase {

    private let syntax = MarkdownSyntax()

    /// `|`가 캐럿이다(선택은 `|` 두 개 사이). 편집 뒤 글을 같은 꼴로 돌려준다.
    private func enter(_ marked: String) -> String? {
        let (text, selection) = Self.unmark(marked)
        let ns = text as NSString
        guard let edit = ListEditing.newline(in: ns, selection: selection, lines: syntax.scanLines(in: ns))
        else { return nil }
        return Self.mark(edit.applied(to: text), edit.selection)
    }

    private func tab(_ marked: String, outdent: Bool = false) -> (handled: Bool, result: String?) {
        let (text, selection) = Self.unmark(marked)
        let ns = text as NSString
        let result = ListEditing.indentation(in: ns, selection: selection, lines: syntax.scanLines(in: ns),
                                             outdent: outdent)
        return (result.handled, result.edit.map { Self.mark($0.applied(to: text), $0.selection) })
    }

    static func unmark(_ marked: String) -> (String, NSRange) {
        let ns = marked as NSString
        let first = ns.range(of: "|")
        precondition(first.location != NSNotFound, "캐럿 표시가 없다")
        let rest = ns.range(of: "|", options: [], range: NSRange(location: first.location + 1,
                                                                 length: ns.length - first.location - 1))
        let text = marked.replacingOccurrences(of: "|", with: "")
        let length = rest.location == NSNotFound ? 0 : rest.location - first.location - 1
        return (text, NSRange(location: first.location, length: length))
    }

    static func mark(_ text: String, _ selection: NSRange) -> String {
        let ns = NSMutableString(string: text)
        if selection.length > 0 { ns.insert("|", at: NSMaxRange(selection)) }
        ns.insert("|", at: selection.location)
        return ns as String
    }

    // MARK: Enter — 이어 쓰기

    func testEnterContinuesABulletList() {
        XCTAssertEqual(enter("- 사과|"), "- 사과\n- |")
        XCTAssertEqual(enter("* 사과|"), "* 사과\n* |")
        XCTAssertEqual(enter("+ 사과|"), "+ 사과\n+ |")
    }

    func testEnterSplitsTheItemAtTheCaret() {
        XCTAssertEqual(enter("- 사과|배"), "- 사과\n- |배", "캐럿 뒤의 글은 새 항목으로 간다")
    }

    func testEnterIncrementsAnOrderedListAndKeepsItsDelimiter() {
        XCTAssertEqual(enter("1. 하나|"), "1. 하나\n2. |")
        XCTAssertEqual(enter("9) 아홉|"), "9) 아홉\n10) |")
    }

    func testEnterKeepsTheIndentAndTheGap() {
        XCTAssertEqual(enter("- 위\n  - 아래|"), "- 위\n  - 아래\n  - |")
        XCTAssertEqual(enter("-   넓게|"), "-   넓게\n-   |", "표지 뒤 공백도 그대로")
    }

    func testEnterContinuesATaskWithAnEmptyBox() {
        XCTAssertEqual(enter("- [x] 끝남|"), "- [x] 끝남\n- [ ] |", "새 항목은 아직 안 한 일이다")
        XCTAssertEqual(enter("1. [ ] 할 일|"), "1. [ ] 할 일\n2. [ ] |")
    }

    func testEnterContinuesAQuote() {
        XCTAssertEqual(enter("> 인용|"), "> 인용\n> |")
        XCTAssertEqual(enter(">> 깊게|"), ">> 깊게\n>> |")
        XCTAssertEqual(enter("> - 인용 속 목록|"), "> - 인용 속 목록\n> - |")
    }

    func testEnterReplacesTheSelection() {
        XCTAssertEqual(enter("- 사|과|배"), "- 사\n- |배")
    }

    // MARK: Enter — 끝내기

    func testEnterOnAnEmptyItemEndsTheList() {
        XCTAssertEqual(enter("- 사과\n- |"), "- 사과\n|", "표지를 떼고 빈 줄로 남는다")
        XCTAssertEqual(enter("1. 하나\n2. |"), "1. 하나\n|")
        XCTAssertEqual(enter("- [ ] |"), "|")
    }

    func testEnterOnAnEmptyNestedItemOutdentsIt() {
        XCTAssertEqual(enter("- 위\n  - |"), "- 위\n- |", "하위 목록을 끝내고 위 목록으로 돌아간다")
    }

    func testEnterOnAnEmptyQuoteLineEndsTheQuote() {
        XCTAssertEqual(enter("> 인용\n> |"), "> 인용\n|")
        XCTAssertEqual(enter("> - 항목\n> - |"), "> - 항목\n> |", "목록만 끝나고 인용은 남는다")
    }

    // MARK: Enter — 손대지 않는 자리

    func testEnterOutsideListsIsLeftToTheTextView() {
        XCTAssertNil(enter("그냥 문단|"))
        XCTAssertNil(enter("# 제목|"))
        XCTAssertNil(enter("---|"))
    }

    func testEnterInsideACodeBlockDoesNotContinueAList() {
        XCTAssertNil(enter("```\n- 코드|\n```"), "펜스 안의 `- `는 목록이 아니다")
    }

    func testEnterBeforeTheMarkerIsAPlainNewline() {
        XCTAssertNil(enter("|- 사과"), "줄 맨 앞의 Enter는 항목을 통째로 아래로 민다")
        XCTAssertNil(enter("-| 사과"), "표지 안도 마찬가지")
    }

    func testEnterWithASelectionAcrossLinesIsLeftAlone() {
        XCTAssertNil(enter("- 사|과\n- 배|"))
    }

    // MARK: Tab · ⇧Tab

    func testTabNestsUnderThePreviousItem() {
        XCTAssertEqual(tab("- 위\n- 아래|").result, "- 위\n  - 아래|")
        XCTAssertEqual(tab("1. 위\n2. 아래|").result, "1. 위\n   2. 아래|",
                       "`1. ` 아래는 세 칸이어야 그 항목에 속한다")
        XCTAssertEqual(tab("1. 위\n- 아래|").result, "1. 위\n   - 아래|", "위 항목의 표지 폭을 따른다")
    }

    func testTabWorksAnywhereInTheItem() {
        XCTAssertEqual(tab("- 위\n- 아|래").result, "- 위\n  - 아|래")
    }

    func testTabIndentsEveryItemInTheSelection() {
        XCTAssertEqual(tab("- 하나\n- |둘\n- 셋|").result, "- 하나\n  - |둘\n  - 셋|")
    }

    func testSelectionEndingAtALineStartDoesNotTakeThatLine() {
        XCTAssertEqual(tab("- 하나\n- |둘\n|- 셋").result, "- 하나\n  - |둘\n|- 셋")
    }

    func testTabUsesATabWhenTheDocumentIndentsWithTabs() {
        XCTAssertEqual(tab("- 위\n\t- 아래|").result, "- 위\n\t\t- 아래|")
    }

    func testShiftTabReturnsToTheParentDepth() {
        XCTAssertEqual(tab("- 위\n  - 아래|", outdent: true).result, "- 위\n- 아래|")
        XCTAssertEqual(tab("- a\n  - b\n    - c|", outdent: true).result, "- a\n  - b\n  - c|")
    }

    func testShiftTabOnATopLevelItemDoesNothingButIsHandled() {
        let result = tab("- 맨 앞|", outdent: true)
        XCTAssertTrue(result.handled, "목록 줄의 ⇧Tab을 텍스트 뷰에 넘기면 안 된다")
        XCTAssertNil(result.result)
    }

    func testTabOutsideListsIsLeftToTheTextView() {
        XCTAssertFalse(tab("문단|").handled)
        XCTAssertFalse(tab("```\n- 코드|\n```").handled)
    }

    // MARK: 체크박스

    func testToggleTaskFlipsTheMark() {
        let text = "- [ ] 할 일\n- [x] 끝남\n- [X] 대문자" as NSString
        let open = text.range(of: "[ ]").location
        XCTAssertEqual(ListEditing.toggleTask(in: text, box: open, selection: NSRange())?.applied(to: text as String),
                       "- [x] 할 일\n- [x] 끝남\n- [X] 대문자")
        let done = text.range(of: "[x]").location
        XCTAssertEqual(ListEditing.toggleTask(in: text, box: done, selection: NSRange())?.replacement, " ")
        let upper = text.range(of: "[X]").location
        XCTAssertEqual(ListEditing.toggleTask(in: text, box: upper, selection: NSRange())?.replacement, " ")
    }

    func testToggleTaskRefusesAnythingButABox() {
        let text = "- [보류] 글" as NSString
        XCTAssertNil(ListEditing.toggleTask(in: text, box: 2, selection: NSRange()))
        XCTAssertNil(ListEditing.toggleTask(in: text, box: 100, selection: NSRange()))
    }
}

/// 줄 편집(`LineEditing`) — 옮기기·복제·지우기.
final class LineEditingTests: XCTestCase {

    private func run(_ rule: (NSString, NSRange) -> TextEdit?, _ marked: String) -> String? {
        let (text, selection) = ListEditingTests.unmark(marked)
        guard let edit = rule(text as NSString, selection) else { return nil }
        return ListEditingTests.mark(edit.applied(to: text), edit.selection)
    }

    func testMoveUpSwapsWithThePreviousLine() {
        XCTAssertEqual(run(LineEditing.moveUp, "하나\n둘|\n셋\n"), "둘|\n하나\n셋\n")
        XCTAssertNil(run(LineEditing.moveUp, "맨|위\n아래"))
    }

    func testMoveUpTheLastLineWithoutANewline() {
        XCTAssertEqual(run(LineEditing.moveUp, "하나\n둘|"), "둘|\n하나", "줄바꿈이 옮겨 와 줄이 붙지 않는다")
    }

    func testMoveDownSwapsWithTheNextLine() {
        XCTAssertEqual(run(LineEditing.moveDown, "하|나\n둘\n셋\n"), "둘\n하|나\n셋\n")
        XCTAssertEqual(run(LineEditing.moveDown, "하|나\n둘"), "둘\n하|나")
        XCTAssertNil(run(LineEditing.moveDown, "위\n맨|아래"))
        XCTAssertNil(run(LineEditing.moveDown, "위\n맨|아래\n"), "끝의 빈 줄 아래로는 내리지 않는다")
    }

    func testMoveKeepsTheSelectionOnTheMovedLines() {
        XCTAssertEqual(run(LineEditing.moveDown, "|하나\n둘|\n셋\n넷"), "셋\n|하나\n둘|\n넷")
        XCTAssertEqual(run(LineEditing.moveUp, "하나\n|둘\n셋\n|넷"), "|둘\n셋\n|하나\n넷",
                       "다음 줄의 맨 앞에서 끝나는 선택은 그 줄을 데려가지 않는다")
    }

    func testMoveKeepsWindowsLineEndings() {
        XCTAssertEqual(run(LineEditing.moveUp, "하나\r\n둘|"), "둘|\r\n하나")
    }

    func testDuplicatePutsTheCopyBelowAndSelectsIt() {
        XCTAssertEqual(run(LineEditing.duplicate, "하|나\n둘"), "하나\n하|나\n둘")
        XCTAssertEqual(run(LineEditing.duplicate, "하나\n둘|"), "하나\n둘\n둘|", "마지막 줄은 사이에 줄바꿈을 넣는다")
        XCTAssertEqual(run(LineEditing.duplicate, "|하나\n둘|"), "하나\n둘\n|하나\n둘|")
    }

    func testDeleteRemovesTheWholeLine() {
        XCTAssertEqual(run(LineEditing.delete, "하나\n둘|\n셋"), "하나\n|셋")
        XCTAssertEqual(run(LineEditing.delete, "하나\n둘|"), "|하나", "마지막 줄은 위 줄의 줄바꿈까지 지운다")
        XCTAssertEqual(run(LineEditing.delete, "혼|자"), "|")
        XCTAssertNil(run(LineEditing.delete, "|"))
    }
}

/// 규칙이 **편집기에 실제로 이어졌는지** — Enter·Tab이 규칙을 지나고, 결과가 실행 취소 한 번에
/// 되돌아가고, 체크박스를 누르면 뒤집히고, ⌘클릭이 링크를 연다.
@MainActor
final class EditorCommandWiringTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
        hosts = []
    }

    private final class LinkRecorder: MarkdownEditorDelegate {
        var links: [String] = []
        var changes = 0
        func markdownEditorDidChangeText(_ editor: MarkdownEditorView) { changes += 1 }
        func markdownEditor(_ editor: MarkdownEditorView, didClickLink url: String) { links.append(url) }
    }

    /// 창의 실행 취소 관리자는 **이벤트마다** 묶음을 닫는다. 테스트는 이벤트 고리를 돌지 않아
    /// 그대로 두면 모든 편집이 한 묶음에 들어가 ⌘Z 한 번에 다 돌아간다. 그래서 묶음을 손으로
    /// 여닫는 관리자를 창에 주고, 사람이 키를 한 번 누를 때마다 닫히는 묶음을 `step`이 여닫는다.
    @MainActor
    private final class UndoHost: NSObject, NSWindowDelegate {
        let undo: UndoManager = {
            let manager = UndoManager()
            manager.groupsByEvent = false
            return manager
        }()
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }
    }

    private var hosts: [UndoHost] = []

    /// 키 한 번 — 그 안의 편집이 한 묶음이다.
    private func step(_ view: MarkdownEditorView, _ body: () -> Void) {
        let undo = view.textView.undoManager
        undo?.beginUndoGrouping()
        body()
        undo?.endUndoGrouping()
    }

    private func editor(_ markdown: String) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = UndoHost()
        hosts.append(host)
        window.delegate = host
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = editor
        window.orderBack(nil)
        window.makeFirstResponder(editor.textView)
        windows.append(window)
        editor.markdown = markdown
        return editor
    }

    func testEnterInAListGoesThroughTheRuleAndUndoesInOneStep() throws {
        let view = editor("- 사과")
        let tv = view.textView
        tv.setSelectedRange(NSRange(location: (view.markdown as NSString).length, length: 0))
        step(view) { tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        XCTAssertEqual(view.markdown, "- 사과\n- ")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 7, length: 0))

        let undo = try XCTUnwrap(tv.undoManager)
        undo.undo()
        XCTAssertEqual(view.markdown, "- 사과", "Enter 한 번이 ⌘Z 한 번으로 돌아간다 — 표지만 남지 않는다")
    }

    func testEnterOutsideAListIsAPlainNewline() {
        let view = editor("문단")
        let tv = view.textView
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        step(view) { tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        XCTAssertEqual(view.markdown, "문단\n")
    }

    func testTabNestsAndShiftTabReturns() throws {
        let view = editor("- 위\n- 아래")
        let tv = view.textView
        tv.setSelectedRange(NSRange(location: (view.markdown as NSString).length, length: 0))
        step(view) { tv.doCommand(by: #selector(NSResponder.insertTab(_:))) }
        XCTAssertEqual(view.markdown, "- 위\n  - 아래")
        XCTAssertEqual(tv.undoManager?.undoActionName, String(localized: "들여쓰기"))
        step(view) { tv.doCommand(by: #selector(NSResponder.insertBacktab(_:))) }
        XCTAssertEqual(view.markdown, "- 위\n- 아래")
        step(view) { tv.doCommand(by: #selector(NSResponder.insertBacktab(_:))) }
        XCTAssertEqual(view.markdown, "- 위\n- 아래", "맨 앞 항목의 ⇧Tab은 아무것도 하지 않는다")
    }

    func testTabOutsideAListStillInsertsATab() {
        let view = editor("문단")
        view.textView.setSelectedRange(NSRange(location: 2, length: 0))
        step(view) { view.textView.doCommand(by: #selector(NSResponder.insertTab(_:))) }
        XCTAssertEqual(view.markdown, "문단\t")
    }

    func testLineCommandsEditAndNameTheirUndo() throws {
        let recorder = LinkRecorder()
        let view = editor("하나\n둘\n셋")
        view.editorDelegate = recorder
        let tv = view.textView
        tv.setSelectedRange(NSRange(location: 3, length: 0))     // 둘
        step(view) { view.moveLinesUpAction(nil) }
        XCTAssertEqual(view.markdown, "둘\n하나\n셋")
        XCTAssertEqual(tv.undoManager?.undoActionName, String(localized: "줄 옮기기"))
        XCTAssertGreaterThan(recorder.changes, 0, "창이 문서가 바뀐 것을 안다(저장 표시)")
        step(view) { view.moveLinesDownAction(nil) }
        XCTAssertEqual(view.markdown, "하나\n둘\n셋")
        step(view) { view.duplicateLinesAction(nil) }
        XCTAssertEqual(view.markdown, "하나\n둘\n둘\n셋")
        step(view) { view.deleteLinesAction(nil) }
        XCTAssertEqual(view.markdown, "하나\n둘\n셋")

        let undo = try XCTUnwrap(tv.undoManager)
        undo.undo()
        XCTAssertEqual(view.markdown, "하나\n둘\n둘\n셋", "줄 편집은 하나씩 되돌아간다")
    }

    func testTheEditMenuReachesTheLineCommandsThroughTheResponderChain() {
        // 메뉴 항목은 대상 없이 보낸다 — 텍스트 뷰에서 편집기까지 응답자 연쇄로 닿아야 한다.
        // 화면 밖 창은 키 창이 되지 못할 수 있어, 연쇄를 직접 따라간다.
        let view = editor("하나\n둘")
        XCTAssertTrue(view.textView.window?.firstResponder === view.textView)
        var responder: NSResponder? = view.textView
        var found = false
        while let current = responder {
            if current.responds(to: #selector(MarkdownEditorView.moveLinesDownAction(_:))) {
                found = current === view
                break
            }
            responder = current.nextResponder
        }
        XCTAssertTrue(found, "텍스트 뷰 다음에 이 명령에 답하는 것이 편집기여야 한다")
    }

    func testClickingACheckboxTogglesItWithoutMovingTheCaret() throws {
        let view = editor("- [ ] 할 일\n\n문단")
        let tv = view.textView
        let caret = NSRange(location: (view.markdown as NSString).length, length: 0)
        tv.setSelectedRange(caret)
        let box = (view.markdown as NSString).range(of: "[ ]")
        let attribute = tv.textStorage?.attribute(.mdTaskBox, at: box.location + 1, effectiveRange: nil) as? Int
        XCTAssertEqual(attribute, box.location, "스타일러가 체크박스를 누를 수 있게 표시한다")

        var handled = false
        step(view) { handled = view.handleClick(at: box.location + 1, modifiers: []) }
        XCTAssertTrue(handled)
        XCTAssertEqual(view.markdown, "- [x] 할 일\n\n문단")
        XCTAssertEqual(tv.selectedRange(), caret, "누르기는 캐럿을 옮기지 않는다")
        XCTAssertEqual(tv.undoManager?.undoActionName, String(localized: "할 일 표시"))
        try XCTUnwrap(tv.undoManager).undo()
        XCTAssertEqual(view.markdown, "- [ ] 할 일\n\n문단")
    }

    /// 같은 누르기(번호·시각이 같은 이벤트)가 두 번 오면 한 번만 뒤집는다. 뒤에 있던 창을 누를 때
    /// 실제로 두 번 왔고, 뒤집기가 두 번이라 아무 일도 없는 것처럼 보였다(문서만 '편집됨').
    func testTheSameMouseDownDeliveredTwiceTogglesOnce() throws {
        let view = editor("- [ ] 할 일")
        let tv = view.textView
        tv.window?.displayIfNeeded()
        let layout = try XCTUnwrap(tv.layoutManager)
        let container = try XCTUnwrap(tv.textContainer)
        let box = (view.markdown as NSString).range(of: "[ ]")
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: box.location + 1, length: 1),
                                       actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let local = NSPoint(x: rect.midX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y)
        func press(number: Int, time: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: tv.convert(local, to: nil),
                                             modifierFlags: [], timestamp: time,
                                             windowNumber: tv.window?.windowNumber ?? 0, context: nil,
                                             eventNumber: number, clickCount: 1, pressure: 1))
        }
        let first = try press(number: 7, time: 100)
        step(view) {
            tv.mouseDown(with: first)
            tv.mouseDown(with: first)
        }
        XCTAssertEqual(view.markdown, "- [x] 할 일", "같은 이벤트는 한 번")
        let second = try press(number: 8, time: 101)
        step(view) { tv.mouseDown(with: second) }
        XCTAssertEqual(view.markdown, "- [ ] 할 일", "다음 누르기는 다시 뒤집는다")
    }

    func testCheckboxWithAModifierIsAPlainClick() {
        let view = editor("- [ ] 할 일")
        let box = (view.markdown as NSString).range(of: "[ ]")
        XCTAssertFalse(view.handleClick(at: box.location, modifiers: .shift), "⇧클릭은 선택 늘리기다")
        XCTAssertEqual(view.markdown, "- [ ] 할 일")
    }

    func testCommandClickOpensALinkAndAPlainClickDoesNot() {
        let recorder = LinkRecorder()
        let view = editor("앞 [마디](https://example.com/madi) 뒤")
        view.editorDelegate = recorder
        let label = (view.markdown as NSString).range(of: "마디")
        XCTAssertFalse(view.handleClick(at: label.location, modifiers: []), "그냥 클릭은 캐럿을 놓는다")
        XCTAssertTrue(recorder.links.isEmpty)
        XCTAssertTrue(view.handleClick(at: label.location, modifiers: .command))
        XCTAssertEqual(recorder.links, ["https://example.com/madi"])
    }

    func testClickMeasuresTheCharacterUnderThePoint() throws {
        let view = editor("- [ ] 할 일")
        let tv = view.textView
        tv.window?.displayIfNeeded()
        let layout = try XCTUnwrap(tv.layoutManager)
        let container = try XCTUnwrap(tv.textContainer)
        let box = (view.markdown as NSString).range(of: "[ ]")
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: box.location + 1, length: 1),
                                       actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let point = NSPoint(x: rect.midX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y)
        XCTAssertEqual(tv.characterIndex(under: point), box.location + 1)
        let farRight = NSPoint(x: tv.bounds.maxX - 2, y: point.y)
        XCTAssertNil(tv.characterIndex(under: farRight), "줄 끝 너머는 어느 글자도 아니다")
    }
}
