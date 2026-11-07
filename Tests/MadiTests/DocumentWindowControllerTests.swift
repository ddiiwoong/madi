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
            if let session = controller.sideBySide {
                controller.window?.attachedSheet.map { controller.window?.endSheet($0) }
                session.document.updateChangeCount(.changeCleared)
                controller.closeSideBySide()
            }
        }
        for controller in controllers {
            controller.document?.removeWindowController(controller)
            controller.window?.orderOut(nil)
        }
        controllers = []
        documents = []
        NSApplication.shared.mainMenu = savedMainMenu
    }

    private func open(_ markdown: String, preferences: EditorPreferences = .standard,
                      store given: PreferenceStore? = nil)
        -> (MarkdownDocument, DocumentWindowController) {
        let store = given ?? PreferenceStore(defaults: MemoryDefaults())
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

    /// 도구 막대의 칸이 눌려 있는가. 묶음은 사이드바(`목차 · 폴더 · 최근`)와 보기(`원본 보기 · 나란히 번역`) 둘이다.
    private func isPressed(_ label: String, in controller: DocumentWindowController) -> Bool? {
        for group in [controller.sidebarGroup, controller.viewGroup].compactMap({ $0 }) {
            if let index = group.subitems.firstIndex(where: { $0.label == label }) { return group.isSelected(at: index) }
        }
        return nil
    }

    /// 칸을 누른다 — AppKit이 하듯 그 칸의 눌림을 뒤집고 묶음의 action을 보낸다.
    private func press(_ label: String, in controller: DocumentWindowController) {
        for group in [controller.sidebarGroup, controller.viewGroup].compactMap({ $0 }) {
            guard let index = group.subitems.firstIndex(where: { $0.label == label }) else { continue }
            group.setSelected(!group.isSelected(at: index), at: index)
            guard let action = group.action else { return XCTFail("\(label) 묶음에 action이 없다") }
            XCTAssertTrue(NSApp.sendAction(action, to: group.target, from: group))
            return
        }
        XCTFail("\(label) 칸이 없다")
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

    /// 목차·폴더·최근은 순간 단추가 아니라 **토글**이다 — 눌린 칸이 곧 열린 사이드바 탭이다. 단축키·메뉴로 열어도
    /// 칸이 따라온다.
    func testSidebarTogglesShowWhichPanelIsOpen() async {
        let (_, controller) = open("# 제목\n\n본문\n")
        XCTAssertEqual(isPressed("목차", in: controller), false, "처음에는 사이드바가 닫혀 있다")

        controller.showOutlineAction(nil)
        await settle()
        XCTAssertEqual(isPressed("목차", in: controller), true)
        XCTAssertEqual(isPressed("최근", in: controller), false)

        controller.showRecentAction(nil)
        await settle()
        XCTAssertEqual(isPressed("목차", in: controller), false, "다른 탭으로 바꾸면 앞의 칸이 풀린다")
        XCTAssertEqual(isPressed("최근", in: controller), true)

        controller.showRecentAction(nil)
        await settle()
        XCTAssertEqual(isPressed("최근", in: controller), false, "같은 칸을 다시 누르면 닫힌다")
    }

    /// 칸을 **눌러서**: 목차를 누르면 열리고, 폴더를 누르면 폴더 탭으로 바뀌며(한 칸만 눌린다), 눌린 칸을 다시
    /// 누르면 닫힌다.
    func testPressingSidebarSegmentsOpensSwitchesAndCloses() async {
        let (_, controller) = open("# 제목\n\n본문\n")
        press("목차", in: controller)
        await settle()
        XCTAssertEqual(controller.openSidebarTab, 0)
        XCTAssertEqual(["목차", "폴더", "최근"].map { isPressed($0, in: controller) }, [true, false, false])

        press("폴더", in: controller)
        await settle()
        XCTAssertEqual(controller.openSidebarTab, 1)
        XCTAssertEqual(["목차", "폴더", "최근"].map { isPressed($0, in: controller) }, [false, true, false],
                       "두 칸이 함께 눌리지 않는다")

        press("폴더", in: controller)
        await settle()
        XCTAssertNil(controller.openSidebarTab, "닫혔다")
        XCTAssertEqual(["목차", "폴더", "최근"].map { isPressed($0, in: controller) }, [false, false, false])
    }

    /// 보기 묶음의 원본 보기 칸을 누르면 원본 보기가 켜지고 꺼진다.
    func testPressingTheSourceSegmentTogglesCodeView() {
        let (_, controller) = open("**굵게**\n")
        press("원본 보기", in: controller)
        XCTAssertTrue(controller.editor.isCodeView)
        XCTAssertEqual(isPressed("원본 보기", in: controller), true)
        XCTAssertEqual(isPressed("나란히 번역", in: controller), false, "다른 칸은 그대로")
        press("원본 보기", in: controller)
        XCTAssertFalse(controller.editor.isCodeView)
        XCTAssertEqual(isPressed("원본 보기", in: controller), false)
    }

    // MARK: 원본 보기 — 세 곳이 같은 상태

    func testCodeViewIsShownOnEverySurface() {
        let (_, controller) = open("**굵게**\n")
        let toggle = #selector(DocumentWindowController.toggleCodeViewAction(_:))
        guard let item = menuItem(for: toggle) else { return XCTFail("원본 보기 메뉴 항목이 없다") }

        controller.toggleCodeViewAction(nil)
        XCTAssertTrue(controller.editor.isCodeView)
        XCTAssertEqual(isPressed("원본 보기", in: controller), true, "도구 막대")
        XCTAssertEqual(item.state, .on, "메뉴 체크")
        XCTAssertEqual(controller.window?.subtitle, "원본 보기", "창 부제")

        controller.toggleCodeViewAction(nil)
        XCTAssertFalse(controller.editor.isCodeView)
        XCTAssertEqual(isPressed("원본 보기", in: controller), false)
        XCTAssertEqual(item.state, .off)
        XCTAssertEqual(controller.window?.subtitle, "")
    }

    /// 도구 막대는 시스템 분할 단추 두 덩이다 — 사이드바(목차 · 폴더 · 최근) | 찾기 | 보기(원본 보기 · 나란히
    /// 번역). 직접 만든 단추(`NSButton`)를 끼워 넣은 칸이 없다(그렇게 하면 칸마다 따로 테두리가 생겨 제각각이었다).
    /// 사이드바 칸은 사이드바 탭과 같은 이름·차례다. '열기'와 버거 메뉴는 없다. 처음에는 아이콘만 보인다.
    func testToolbarIsTwoSystemGroups() throws {
        let (_, controller) = open("본문\n")
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        XCTAssertEqual(toolbar.displayMode, .iconOnly, "macOS 앱의 기본 모양")
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier.rawValue), [
            "sidebar", NSToolbarItem.Identifier.flexibleSpace.rawValue, "matches", "search", "view",
        ])
        let sidebar = try XCTUnwrap(controller.sidebarGroup)
        let view = try XCTUnwrap(controller.viewGroup)
        XCTAssertEqual(sidebar.subitems.map(\.label), ["목차", "폴더", "최근"])
        XCTAssertEqual(view.subitems.map(\.label), ["원본 보기", "나란히 번역"])
        XCTAssertEqual(sidebar.selectionMode, .selectAny, "사이드바가 닫히면 눌린 칸이 없어야 한다")
        for group in [sidebar, view] {
            XCTAssertNil(group.view, "시스템이 그리는 분할 단추다")
            XCTAssertTrue(group.subitems.allSatisfy { $0.image != nil && $0.view == nil && !($0.toolTip ?? "").isEmpty })
        }
        // 사이드바 칸의 이름은 사이드바 탭의 이름과 같다.
        let tabs = try XCTUnwrap(controller.window?.contentView.map(Self.views)?.compactMap { $0 as? NSTabView }
            .first { $0.tabViewItems.count == 3 })
        XCTAssertEqual(tabs.tabViewItems.map(\.label), sidebar.subitems.map(\.label))
        XCTAssertFalse(toolbar.items.contains { $0.view is NSButton }, "직접 만든 단추가 없다")
    }

    private static func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views)
    }

    /// 도구 막대를 우클릭해 '아이콘과 텍스트'로 바꾸면 기억해, 다음 창도 그렇게 연다. 기본(아이콘만)으로 돌리면
    /// 적어 둔 값을 지운다 — 기본을 적어 두면 기본이 바뀌어도 따라오지 않는다(실측: 이름을 보이던 판의 값이 남았다).
    func testToolbarDisplayModeIsRemembered() throws {
        let store = PreferenceStore(defaults: MemoryDefaults())
        let (_, first) = open("본문\n", store: store)
        XCTAssertNil(store.toolbarDisplayMode, "창을 여는 것만으로는 적지 않는다")
        let toolbar = try XCTUnwrap(first.window?.toolbar)
        toolbar.displayMode = .iconAndLabel
        XCTAssertEqual(store.toolbarDisplayMode, "iconAndLabel")
        let (_, second) = open("본문\n", store: store)
        XCTAssertEqual(second.window?.toolbar?.displayMode, .iconAndLabel)
        if #available(macOS 15.0, *) { XCTAssertTrue(toolbar.allowsDisplayModeCustomization) }
        // 이름이 같은 도구 막대는 한 프로세스 안에서 보이기를 함께 쓴다 — 기본으로 돌려 다음 시험에 남기지 않는다.
        toolbar.displayMode = .iconOnly
        XCTAssertNil(store.toolbarDisplayMode)
    }

    /// 체크 표시를 `validateMenuItem`으로 달면 안 된다. 한 번 그렇게 했다가 **이 객체로 오는 모든
    /// 항목**을 떠맡아, 응답하지 않는 저장·다른 이름으로 저장·닫기를 비활성으로 만들었다.
    func testControllerDoesNotTakeOverMenuValidation() {
        let (_, controller) = open("본문\n")
        XCTAssertFalse((controller as AnyObject) is NSMenuItemValidation)
        // 메뉴 바의 저장·닫기는 대상을 비워 응답자 연쇄(문서·창)가 받게 둔다.
        for action in [#selector(NSDocument.save(_:)), #selector(NSWindow.performClose(_:))] {
            guard let item = menuItem(for: action) else { return XCTFail("\(action) 항목이 없다") }
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
        XCTAssertEqual(isPressed("원본 보기", in: controller), true)

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

    // MARK: 테마

    /// 보기 ▸ 테마에 다섯 테마가 견본과 함께 있고, `글꼴…` 바로 앞이다. 고르면 저장되고, 창이 그 색으로
    /// 칠하고, 그 항목에만 체크가 붙는다.
    func testThemeMenuChoosesAndChecksTheTheme() throws {
        let fonts = try XCTUnwrap(menuItem(for: #selector(DocumentWindowController.showFontSettings(_:))))
        let menu = try XCTUnwrap(fonts.menu)
        let index = try XCTUnwrap(menu.items.firstIndex(of: fonts))
        let themeItem = menu.items[index - 1]
        let themes = try XCTUnwrap(themeItem.submenu, "글꼴… 앞이 테마 하위 메뉴다")
        XCTAssertEqual(themes.items.compactMap { $0.representedObject as? String },
                       EditorPreferences.ColorTheme.allCases.map(\.rawValue))
        XCTAssertTrue(themes.items.allSatisfy { $0.image != nil }, "견본이 붙어 있다")

        let store = PreferenceStore(defaults: MemoryDefaults())
        let (_, controller) = open("본문\n", store: store)
        let paper = try XCTUnwrap(themes.items.first { ($0.representedObject as? String) == "paper" })
        controller.chooseColorThemeAction(paper)
        XCTAssertEqual(store.current.colorTheme, .paper)
        XCTAssertTrue(controller.editor.textView.backgroundColor === ThemePalette.palette(for: .paper).background)
        XCTAssertEqual(themes.items.filter { $0.state == .on }.map { $0.representedObject as? String }, ["paper"])
    }

    // MARK: 문서 메타데이터 카드

    /// 카드는 편집기의 텍스트 뷰 안에 있어 글과 함께 굴러간다. 글은 카드 아래에서 시작하고, 저장하는
    /// 글은 그대로다.
    func testFrontMatterCardScrollsWithTheText() throws {
        let source = "---\ntitle: 제목\ntags: [a, b]\n---\n# 본문 제목\n\n본문\n"
        let (document, controller) = open(source)
        let editor = controller.editor
        let card = try XCTUnwrap(editor.textView.subviews.compactMap { $0 as? FrontMatterCardView }.first,
                                 "카드가 텍스트 뷰 안에 없다")
        XCTAssertFalse(card.isHidden)
        XCTAssertGreaterThan(card.frame.height, 40)
        XCTAssertGreaterThan(editor.textView.textContainerOrigin.y, card.frame.maxY, "글이 카드 아래에서 시작한다")
        XCTAssertEqual(editor.markdown, "# 본문 제목\n\n본문\n", "편집기에는 본문만 있다")
        XCTAssertEqual(document.markdown, source)

        // front matter가 없는 글을 실으면 카드가 숨고 자리도 사라진다.
        controller.load(markdown: "본문만\n")
        XCTAssertTrue(card.isHidden)
        XCTAssertEqual(editor.textView.topAccessoryHeight, 0)
    }

    private func card(in controller: DocumentWindowController) throws -> FrontMatterCardView {
        try XCTUnwrap(controller.editor.textView.subviews.compactMap { $0 as? FrontMatterCardView }.first)
    }

    private func disclosure(of card: FrontMatterCardView) throws -> NSButton {
        func buttons(_ view: NSView) -> [NSButton] {
            view.subviews.compactMap { $0 as? NSButton } + view.subviews.flatMap(buttons)
        }
        return try XCTUnwrap(buttons(card).first { $0.bezelStyle == .disclosure })
    }

    /// 카드를 접으면 기억한다 — 다음에 여는 문서의 카드도 접힌 채 열리고, 글은 접힌 카드 아래에서
    /// 시작한다. 펴면 다시 펴진 채 열린다.
    func testCollapsedCardIsRemembered() throws {
        let source = "---\ntitle: 제목\nauthor: 이름\ndate: 2026-11-07\n---\n본문\n"
        let store = PreferenceStore(defaults: MemoryDefaults())
        let (_, first) = open(source, store: store)
        let firstCard = try card(in: first)
        XCTAssertFalse(firstCard.isCollapsed, "처음에는 펴져 있다")
        let expanded = first.editor.textView.topAccessoryHeight

        try disclosure(of: firstCard).performClick(nil)
        XCTAssertTrue(firstCard.isCollapsed)
        XCTAssertTrue(store.collapsesFrontMatter)
        XCTAssertLessThan(first.editor.textView.topAccessoryHeight, expanded, "접은 만큼 글이 올라온다")

        let (_, second) = open(source, store: store)
        let reopened = try card(in: second)
        XCTAssertTrue(reopened.isCollapsed, "다음 문서도 접힌 채 연다")
        XCTAssertEqual(second.editor.textView.topAccessoryHeight, first.editor.textView.topAccessoryHeight,
                       accuracy: 0.5)

        try disclosure(of: reopened).performClick(nil)
        XCTAssertFalse(store.collapsesFrontMatter)
        let (_, third) = open(source, store: store)
        XCTAssertFalse(try card(in: third).isCollapsed)
    }

    /// 나란히 보기의 번역본 칸도 기억한 접힘으로 열고, 거기서 접고 편 것도 기억한다.
    func testTranslationPaneCardFollowsTheRememberedState() throws {
        let store = PreferenceStore(defaults: MemoryDefaults())
        store.collapsesFrontMatter = true
        let (_, controller) = open("---\ntitle: 제목\n---\n# 제목\n\n본문\n", store: store)
        controller.openSideBySide(composed: "---\ntitle: Title\n---\n# Title\n\nBody\n",
                                  direction: TranslationDirection(source: "ko", target: "en"),
                                  sourceBody: controller.editor.markdown)
        let pane = try XCTUnwrap(controller.sideBySide?.pane)
        XCTAssertTrue(pane.isCardCollapsed)

        func buttons(_ view: NSView) -> [NSButton] {
            view.subviews.compactMap { $0 as? NSButton } + view.subviews.flatMap(buttons)
        }
        let card = try XCTUnwrap(pane.editor.textView.subviews.compactMap { $0 as? FrontMatterCardView }.first)
        try XCTUnwrap(buttons(card).first { $0.bezelStyle == .disclosure }).performClick(nil)
        XCTAssertFalse(pane.isCardCollapsed)
        XCTAssertFalse(store.collapsesFrontMatter)
    }

    /// 접힘은 화면 상태라 `기본값으로`가 되돌리지 않는다.
    func testCollapsedCardSurvivesReset() {
        let store = PreferenceStore(defaults: MemoryDefaults())
        XCTAssertFalse(store.collapsesFrontMatter)
        store.collapsesFrontMatter = true
        store.reset()
        XCTAssertTrue(store.collapsesFrontMatter)
    }

    // MARK: 글꼴

    /// 보기 ▸ 글꼴…은 글자 크기 명령 바로 앞에 있다.
    func testFontSettingsCommandIsInTheViewMenu() throws {
        let fonts = try XCTUnwrap(menuItem(for: #selector(DocumentWindowController.showFontSettings(_:))))
        let larger = try XCTUnwrap(menuItem(for: #selector(DocumentWindowController.makeTextLargerAction(_:))))
        XCTAssertTrue(fonts.menu === larger.menu, "같은 메뉴(보기)에 있다")
        let items = try XCTUnwrap(fonts.menu?.items)
        XCTAssertEqual(items.firstIndex(of: fonts).map { $0 + 1 }, items.firstIndex(of: larger))
    }

    /// 다른 탭을 보고 있었어도 글꼴…은 설정 창을 **글꼴 탭으로** 연다.
    func testFontSettingsOpensTheFontTab() throws {
        let (_, controller) = open("본문\n")
        let languageDomain = "madi.tests.font-settings"
        let languageDefaults = MemoryDefaults(name: languageDomain)
        controller.makeSettingsPanel = { store in
            let panel = SettingsPanel(store: store, languageDefaults: languageDefaults, languageDomain: languageDomain,
                                      secrets: MemorySecretStore(), llmDefaults: languageDefaults,
                                      openURL: { _ in XCTFail("브라우저를 열지 않는다") })
            panel.window?.setFrameOrigin(NSPoint(x: -20000, y: 0))
            return panel
        }
        defer { controller.settingsPanel?.close() }

        controller.showSettings(nil)
        let panel = try XCTUnwrap(controller.settingsPanel)
        panel.selectTab("print")
        controller.showFontSettings(nil)
        XCTAssertTrue(controller.settingsPanel === panel, "같은 창을 다시 쓴다")
        XCTAssertEqual(panel.selectedTab, SettingsPanel.fontTab)
    }

    // MARK: 나란히 보기 — 한 창 안의 좌우

    private let english = TranslationDirection(source: "ko", target: "en")

    /// 번역은 Apple 번역이 하므로(macOS 26 + 언어 팩) 테스트는 번역이 끝난 자리에서 연다.
    private func openSideBySide(_ source: String = "# 제목\n\n본문\n",
                                translation: String = "# Title\n\nBody\n")
        -> (MarkdownDocument, DocumentWindowController, SideBySideTranslation) {
        let (document, controller) = open(source)
        controller.openSideBySide(composed: translation, direction: english,
                                  sourceBody: controller.editor.markdown)
        guard let session = controller.sideBySide else {
            XCTFail("나란히 보기가 열리지 않았다")
            fatalError()
        }
        return (document, controller, session)
    }

    func testSideBySideOpensInTheSameWindow() throws {
        let (_, controller, session) = openSideBySide()
        XCTAssertTrue(session.pane.window === controller.window, "번역본은 같은 창의 오른쪽 칸이다")
        XCTAssertEqual(controller.contentSplit.arrangedSubviews.count, 2)
        XCTAssertTrue(controller.contentSplit.arrangedSubviews.last === session.pane)
        XCTAssertTrue(session.document.windowControllers.isEmpty, "번역본 문서에는 창이 없다")
        XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === session.document },
                      "문서 관리자가 안다 — 앱을 끝낼 때 저장 안 한 번역본을 묻는다")
        XCTAssertEqual(session.pane.editor.markdown, "# Title\n\nBody\n")
        XCTAssertEqual(isPressed("나란히 번역", in: controller), true)

        controller.window?.layoutIfNeeded()
        let left = try XCTUnwrap(controller.contentSplit.arrangedSubviews.first).frame.width
        let right = session.pane.frame.width
        XCTAssertEqual(left, right, accuracy: 4, "반씩 나눈다")
    }

    func testTranslationFrontMatterGoesToItsCardNotTheEditor() {
        let front = "---\ntitle: Title\n---\n"
        let (_, _, session) = openSideBySide(translation: front + "Body\n")
        XCTAssertEqual(session.pane.editor.markdown, "Body\n", "편집기에는 본문만 — 원문 칸과 같다")
        XCTAssertEqual(session.pane.composedMarkdown, front + "Body\n", "저장할 글은 블록째")
    }

    func testEditingTheTranslationDoesNotMarkTheSourceEdited() throws {
        let (document, controller, session) = openSideBySide()
        document.updateChangeCount(.changeCleared)
        let tv = session.pane.editor.textView
        XCTAssertTrue(tv.undoManager === session.document.undoManager, "번역본은 자기 실행 취소 관리자를 쓴다")
        XCTAssertFalse(tv.undoManager === controller.editor.textView.undoManager)

        tv.setSelectedRange(NSRange(location: (session.pane.editor.markdown as NSString).length, length: 0))
        tv.insertText("More", replacementRange: tv.selectedRange())
        XCTAssertTrue(session.document.isDocumentEdited)
        XCTAssertEqual(session.document.markdown, "# Title\n\nBody\nMore", "번역본 문서가 고친 글을 든다")
        XCTAssertFalse(document.isDocumentEdited, "원문은 '편집됨'이 되지 않는다")
        XCTAssertTrue(session.pane.statusText.contains(String(localized: "편집됨")))
    }

    /// `⌘S`는 초점을 따른다 — 번역본 칸 안이면 번역본, 원문이면 원문.
    func testSaveFollowsTheFocus() {
        let (_, controller, session) = openSideBySide()
        func firstSaver(from responder: NSResponder) -> NSResponder? {
            var current: NSResponder? = responder
            while let item = current {
                if item.responds(to: #selector(NSDocument.save(_:))) { return item }
                current = item.nextResponder
            }
            return nil
        }
        XCTAssertTrue(firstSaver(from: session.pane.editor.textView) === session.pane,
                      "번역본 칸 안에서는 칸이 먼저 받는다")
        XCTAssertFalse(firstSaver(from: controller.editor.textView) === session.pane,
                       "원문 쪽에서는 칸을 지나지 않는다 — 원문 문서가 저장된다")
    }

    func testSourceChangesRaiseTheBandAndRetranslationClearsIt() throws {
        let (_, controller, session) = openSideBySide()
        XCTAssertTrue(session.pane.band.isHidden)
        let tv = controller.editor.textView
        tv.setSelectedRange(NSRange(location: (controller.editor.markdown as NSString).length, length: 0))
        tv.insertText("더", replacementRange: tv.selectedRange())
        XCTAssertFalse(session.pane.band.isHidden, "원문이 번역한 뒤에 바뀌었다")

        controller.finishRetranslation("# Title\n\nBody more\n", direction: english,
                                       sourceBody: controller.editor.markdown)
        XCTAssertEqual(session.pane.editor.markdown, "# Title\n\nBody more\n")
        XCTAssertTrue(session.pane.band.isHidden, "다시 번역하면 띠가 사라진다")
        XCTAssertFalse(session.translationWasEdited)

        try XCTUnwrap(session.document.undoManager).undo()
        XCTAssertEqual(session.pane.editor.markdown, "# Title\n\nBody\n", "다시 번역도 ⌘Z로 돌아간다")
    }

    func testClosingAnUnchangedTranslationRestoresTheWindow() throws {
        let (_, controller) = open("본문\n")
        let before = try XCTUnwrap(controller.window?.frame)
        controller.openSideBySide(composed: "Body\n", direction: english, sourceBody: "본문\n")
        let session = try XCTUnwrap(controller.sideBySide)
        XCTAssertGreaterThanOrEqual(controller.window?.frame.width ?? 0, before.width, "좁으면 넓힌다")

        session.document.updateChangeCount(.changeCleared)        // 저장한 것과 같다
        controller.closeSideBySide()
        XCTAssertNil(controller.sideBySide)
        XCTAssertNil(session.pane.superview)
        XCTAssertEqual(controller.contentSplit.arrangedSubviews.count, 1)
        XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === session.document },
                       "번역본 문서를 닫는다")
        XCTAssertEqual(controller.window?.frame, before, "넓힌 창을 원래대로")
        XCTAssertEqual(isPressed("나란히 번역", in: controller), false)
    }

    func testClosingAnEditedTranslationAsksFirst() throws {
        let (_, controller, session) = openSideBySide()
        XCTAssertTrue(session.document.isDocumentEdited, "막 번역한 것은 아직 저장하지 않았다")
        controller.closeSideBySide()
        XCTAssertNotNil(controller.window?.attachedSheet, "저장할지 원문 창에 묻는다")
        XCTAssertNotNil(controller.sideBySide, "답하기 전에는 닫지 않는다")
        XCTAssertTrue(session.pane.superview != nil)
    }

    func testClosingTheWindowKeepsAnUnsavedTranslation() throws {
        let (_, controller, session) = openSideBySide()
        var kept: [MarkdownDocument] = []
        controller.keepUnsavedTranslation = { kept.append($0) }
        controller.window?.close()
        XCTAssertTrue(kept.first === session.document, "저장 안 한 번역본은 버리지 않고 자기 창으로")
        XCTAssertNil(controller.sideBySide)
        kept.first?.updateChangeCount(.changeCleared)
        kept.first?.close()
    }
}
