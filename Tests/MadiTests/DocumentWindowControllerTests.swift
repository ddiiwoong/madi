import AppKit
import XCTest

/// 문서 창(`DocumentWindowController`) — 전에는 앱을 띄워 눈으로만 확인하던 것들.
///
/// 창은 화면 밖에 만든다. 설정은 디스크에 쓰지 않는 저장소(`MemoryDefaults`)이고 창 자리도
/// 저장하지 않는다 — 켜 두면 테스트 프로세스의 설정 파일에 창 자리가 써진다.
@MainActor
final class DocumentWindowControllerTests: XCTestCase {

    private var controllers: [DocumentWindowController] = []
    /// 문서를 쥐고 있는다. 창 컨트롤러의 `document`는 **잡지 않는 참조**라, 문서가 먼저 풀리면
    /// 매달린 포인터가 된다(실측: 정리하다 죽었다). 앱에서는 문서 컨트롤러가 쥔다.
    private var documents: [MarkdownDocument] = []
    private var savedMainMenu: NSMenu?

    override func setUp() async throws {
        // 체크 표시는 앱 메뉴에 단다. 테스트 프로세스에는 메뉴가 없으므로 앱의 것을 세운다.
        // 앱을 띄우지 않는 테스트라 `NSApp`은 누가 `shared`를 부르기 전까지 nil이다.
        let app = NSApplication.shared
        savedMainMenu = app.mainMenu
        app.mainMenu = AppMenu.mainMenu()
    }

    override func tearDown() async throws {
        for controller in controllers {
            controller.document?.removeWindowController(controller)
            controller.window?.orderOut(nil)
        }
        controllers = []
        documents = []
        NSApplication.shared.mainMenu = savedMainMenu
    }

    private func open(_ markdown: String, preferences: EditorPreferences = .standard)
        -> (MarkdownDocument, DocumentWindowController) {
        let store = PreferenceStore(defaults: MemoryDefaults())
        store.save(preferences)
        let document = MarkdownDocument()
        document.markdown = markdown
        let controller = DocumentWindowController(preferences: store, autosavesFrame: false)
        document.addWindowController(controller)
        controller.window?.setFrameOrigin(NSPoint(x: -20000, y: 0))
        controller.window?.orderBack(nil)
        controller.load(markdown: markdown)
        controllers.append(controller)
        documents.append(document)
        return (document, controller)
    }

    /// 도구 막대 단추. 정해 둔 식별자로 찾는다.
    private func toolbarButton(_ identifier: String, in controller: DocumentWindowController) -> NSButton? {
        controller.window?.toolbar?.items
            .first { $0.itemIdentifier.rawValue == identifier }?.view as? NSButton
    }

    /// 사이드바 토글은 상태를 다음 순회에서 싣는다(접히는 움직임이 끝난 뒤의 상태를 읽는다).
    private func settle() async {
        // 메인 큐에 걸린 일(`DispatchQueue.main.async`)이 돌 때까지 기다린다.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func menuItem(for action: Selector, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let found = menuItem(for: action, in: item.submenu) { return found }
        }
        return nil
    }

    // MARK: 도구 막대 토글

    /// 목차·최근 문서·파일 브라우저는 순간 단추가 아니라 **토글**이다 — 무엇이 열려 있는지 보여야 한다.
    func testSidebarTogglesShowWhichPanelIsOpen() async {
        let (_, controller) = open("# 제목\n\n본문\n")
        guard let outline = toolbarButton("outline", in: controller),
              let recent = toolbarButton("recent", in: controller) else {
            return XCTFail("도구 막대에 목차·최근 문서 토글이 없다")
        }
        XCTAssertEqual(outline.state, .off, "처음에는 사이드바가 닫혀 있다")

        controller.showOutlineAction(nil)
        await settle()
        XCTAssertEqual(outline.state, .on)
        XCTAssertEqual(recent.state, .off)

        controller.showRecentAction(nil)
        await settle()
        XCTAssertEqual(outline.state, .off, "다른 패널로 바꾸면 앞의 토글이 풀린다")
        XCTAssertEqual(recent.state, .on)

        controller.showRecentAction(nil)
        await settle()
        XCTAssertEqual(recent.state, .off, "같은 토글을 다시 누르면 닫힌다")
    }

    // MARK: 원본 보기 — 세 곳이 같은 상태

    func testCodeViewIsShownOnEverySurface() {
        let (_, controller) = open("**굵게**\n")
        let toggle = #selector(DocumentWindowController.toggleCodeViewAction(_:))
        guard let button = toolbarButton("codeView", in: controller),
              let item = menuItem(for: toggle) else { return XCTFail("원본 보기 토글·메뉴 항목이 없다") }

        controller.toggleCodeViewAction(nil)
        XCTAssertTrue(controller.editor.isCodeView)
        XCTAssertEqual(button.state, .on, "도구 막대")
        XCTAssertEqual(item.state, .on, "메뉴 체크")
        XCTAssertEqual(controller.window?.subtitle, "원본 보기", "창 부제")

        controller.toggleCodeViewAction(nil)
        XCTAssertFalse(controller.editor.isCodeView)
        XCTAssertEqual(button.state, .off)
        XCTAssertEqual(item.state, .off)
        XCTAssertEqual(controller.window?.subtitle, "")
    }

    /// 버거 메뉴는 열 때마다 새로 만든다 — 그때도 지금 보기로 체크를 단다.
    func testBurgerMenuMarksTheCurrentView() {
        let (_, controller) = open("본문\n")
        controller.toggleCodeViewAction(nil)
        let menu = AppMenu.burgerMenu(target: controller)
        DocumentWindowController.markCodeView(in: menu, isOn: controller.editor.isCodeView)
        XCTAssertEqual(menuItem(for: #selector(DocumentWindowController.toggleCodeViewAction(_:)), in: menu)?.state, .on)
    }

    /// 체크 표시를 `validateMenuItem`으로 달면 안 된다. 한 번 그렇게 했다가 **이 객체로 오는 모든
    /// 항목**을 떠맡아, 응답하지 않는 저장·다른 이름으로 저장·닫기를 비활성으로 만들었다.
    func testControllerDoesNotTakeOverMenuValidation() {
        let (_, controller) = open("본문\n")
        XCTAssertFalse((controller as AnyObject) is NSMenuItemValidation)
        // 버거 메뉴의 저장·닫기는 대상을 비워 응답자 연쇄(문서·창)가 받게 둔다.
        let menu = AppMenu.burgerMenu(target: controller)
        for action in [#selector(NSDocument.save(_:)), #selector(NSWindow.performClose(_:))] {
            guard let item = menuItem(for: action, in: menu) else { return XCTFail("\(action) 항목이 없다") }
            XCTAssertNil(item.target, "\(action)은 응답자 연쇄로 가야 한다")
        }
    }

    // MARK: 새 창의 초기 보기

    /// 설정 '새 창을 마크다운 원본 보기로 열기'가 새 창에 닿는다. 전에는 저장만 되고 아무 데도
    /// 닿지 않던 설정이었다.
    /// 테스트의 창은 자리를 저장하지 않는다 — 저장하면 테스트 프로세스의 설정 파일에 써진다.
    func testTestWindowsDoNotAutosaveTheirFrame() {
        let (_, controller) = open("본문\n")
        XCTAssertEqual(controller.window?.frameAutosaveName, "")
    }

    func testNewWindowOpensInCodeViewWhenSetSo() {
        var preferences = EditorPreferences.standard
        preferences.openInCodeView = true
        let (_, controller) = open("본문\n", preferences: preferences)
        XCTAssertTrue(controller.editor.isCodeView)
        XCTAssertEqual(toolbarButton("codeView", in: controller)?.state, .on)

        let (_, plain) = open("본문\n")
        XCTAssertFalse(plain.editor.isCodeView)
    }

    // MARK: 문서

    /// front matter는 편집기에 싣지 않고 **원문 블록 그대로** 들고 있다가 저장할 문서에 다시 붙인다.
    /// 다시 직렬화하면 따옴표·순서·주석이 바뀐다.
    func testFrontMatterIsKeptVerbatimThroughEdits() {
        let front = "---\ntitle: \"마디\"   # 주석도 그대로\ntags: [a, b]\n---\n"
        let (document, controller) = open(front + "본문\n")
        XCTAssertEqual(controller.editor.markdown, "본문\n", "편집기에는 본문만")

        let tv = controller.editor.textView
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.insertText("이", replacementRange: tv.selectedRange())

        XCTAssertEqual(document.markdown, front + "본문이\n")
        XCTAssertTrue(document.isDocumentEdited, "고치면 문서가 바뀐 것으로 표시된다")
    }

    /// 디스크에서 다시 읽힌 문서(다른 앱이 고침, 되돌리기)가 창에 실린다.
    func testDocumentReloadReachesTheEditor() {
        let (document, controller) = open("처음\n")
        document.markdown = "다른 앱이 고친 글\n"
        XCTAssertEqual(controller.editor.markdown, "다른 앱이 고친 글\n")
    }

    // MARK: 글자 크기

    /// ⌘= · ⌘- · ⌘0이 **설정의 글자 크기**를 바꾸고 편집기가 그 크기로 다시 칠한다.
    func testTextSizeCommandsChangeTheEditor() throws {
        let (_, controller) = open("본문\n")
        func size() -> CGFloat? {
            (controller.editor.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        }
        let standard = try XCTUnwrap(size())
        XCTAssertEqual(Double(standard), EditorPreferences.standard.bodyPointSize, accuracy: 0.01)

        controller.makeTextLargerAction(nil)
        controller.makeTextLargerAction(nil)
        XCTAssertEqual(try XCTUnwrap(size()), standard + 2, accuracy: 0.01)
        controller.makeTextSmallerAction(nil)
        XCTAssertEqual(try XCTUnwrap(size()), standard + 1, accuracy: 0.01)
        controller.makeTextStandardSizeAction(nil)
        XCTAssertEqual(try XCTUnwrap(size()), standard, accuracy: 0.01)
    }

    func testTextSizeCommandsAreInTheViewMenuWithTheirShortcuts() throws {
        let larger = try XCTUnwrap(menuItem(for: #selector(DocumentWindowController.makeTextLargerAction(_:))))
        XCTAssertEqual(larger.keyEquivalent, "=")
        XCTAssertEqual(menuItem(for: #selector(DocumentWindowController.makeTextSmallerAction(_:)))?.keyEquivalent, "-")
        XCTAssertEqual(menuItem(for: #selector(DocumentWindowController.makeTextStandardSizeAction(_:)))?
            .keyEquivalent, "0")
        let hiddenPlus = larger.menu?.items.first {
            $0.action == larger.action && $0.keyEquivalent == "+"
        }
        XCTAssertNotNil(hiddenPlus, "⌘+도 받는다")
        XCTAssertEqual(hiddenPlus?.isHidden, true)
        XCTAssertEqual(hiddenPlus?.allowsKeyEquivalentWhenHidden, true)
    }
}
