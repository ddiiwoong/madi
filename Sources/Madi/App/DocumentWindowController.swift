import AppKit

@MainActor
final class DocumentWindowController: NSWindowController {

    /// 나란히 보기(`SideBySideTranslation`)가 두 창의 편집기를 잇는 데 쓰므로 비공개가 아니다.
    let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 760, height: 620))
    private let frontMatterCard = FrontMatterCardView(frame: .zero)
    private let outlinePanel = OutlinePanelView(frame: .zero)
    private let browserPanel = FileBrowserPanelView(frame: .zero)
    private let recentPanel = RecentDocumentsPanelView(frame: .zero)
    private let sidebarTabs = NSTabView()
    private let matchLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let statusOverlay = StatusOverlayView(frame: .zero)

    private var splitController: NSSplitViewController!
    private var sidebarItem: NSSplitViewItem!
    private var searchDebounce: DispatchWorkItem?
    /// 떠 있는 기록 창. 처음 열 때 만들고 그다음부터 같은 것을 다시 보인다.
    private var logPanel: ActivityLogPanel?
    /// 설정 창도 같은 방식으로 하나만 둔다.
    private(set) var settingsPanel: SettingsPanel?
    /// 설정 창을 짓는다. 테스트가 바꾼다 — 사용자의 키체인과 화면 언어 설정에 닿지 않게.
    var makeSettingsPanel: (PreferenceStore) -> SettingsPanel = { SettingsPanel(store: $0) }
    /// 빠른 열기·명령 팔레트. 하나만 뜬다 — 새로 열면 앞의 것을 버린다.
    private(set) var quickPick: QuickPickPanel?
    /// 블록 편집기 창(설계 단계 1). 기본 편집기는 그대로 두고 평가용으로 띄운다.
    private var blockEditorWindow: BlockEditorWindowController?
    /// 이 창의 나란히 보기 — 오른쪽 칸의 번역본과 스크롤 잇기.
    private(set) var sideBySide: SideBySideTranslation?
    /// 편집기 영역을 좌우로 나눈다. 평소에는 원문 하나, 나란히 보기에서는 원문 | 번역본.
    let contentSplit = NSSplitView()
    /// 나란히 보기 때문에 넓힌 창의 원래 자리와 넓힌 자리. 끝날 때 창이 넓힌 자리에 그대로 있으면
    /// (사용자가 바꾸지 않았으면) 원래 자리로 돌린다.
    private var frameBeforeSplit: NSRect?
    private var splitFrame: NSRect?
    /// 설정 저장소. 앱은 표준 저장소이고, 테스트가 디스크에 쓰지 않는 저장소를 넣는다.
    private var preferences = PreferenceStore()
    /// 창 자리를 저장할지. 테스트·화면 밖 그리기는 끈다 — 켜 두면 그 프로세스의 설정 파일에
    /// 창 자리가 써진다(실측: 그림을 그린 실행 파일 이름의 plist가 생겼다).
    private var autosavesFrame = true

    /// The document's front matter, kept so the body can be re-joined with the
    /// ORIGINAL block on every save rather than a re-serialised one.
    private var frontMatter: FrontMatter?

    private var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }

    private enum Tab: Int {
        case outline = 0, browser = 1, recent = 2
    }

    private enum ItemID {
        static let search = NSToolbarItem.Identifier("search")
        static let matches = NSToolbarItem.Identifier("matches")
        /// 사이드바 묶음 — 목차 · 폴더 · 최근(사이드바 탭과 같은 차례, `Tab`의 raw 값이 칸 번호다).
        static let sidebar = NSToolbarItem.Identifier("sidebar")
        /// 보기 묶음 — 원본 보기 · 나란히 번역.
        static let view = NSToolbarItem.Identifier("view")
        /// 버거 메뉴 — 메뉴 바와 같은 메뉴, 그리고 설정.
        static let menu = NSToolbarItem.Identifier("burger")
    }

    /// 사이드바 묶음. 눌린 칸이 지금 열린 사이드바 탭이다(닫혀 있으면 눌린 칸이 없다).
    private(set) var sidebarGroup: NSToolbarItemGroup?
    /// 보기 묶음. 칸 0이 원본 보기, 칸 1이 나란히 번역이고 각각 켜고 끈다.
    private(set) var viewGroup: NSToolbarItemGroup?
    /// 버거 메뉴. 열 때마다 메뉴 바에서 채운다(`burgerFeeder`).
    private(set) var burgerItem: NSMenuToolbarItem?
    /// 메뉴의 `delegate`는 약하게 잡히므로 창이 붙든다.
    private let burgerFeeder = BurgerMenuFeeder()
    /// 도구 막대의 보이기(아이콘 · 이름)를 사용자가 바꾸면 기억한다.
    private var toolbarModeObservation: NSKeyValueObservation?

    /// 저장된 도구 막대 보이기. 없으면 아이콘만이다(macOS 앱의 기본 모양).
    static func displayMode(stored: String?) -> NSToolbar.DisplayMode {
        switch stored {
        case "iconAndLabel": .iconAndLabel
        case "labelOnly": .labelOnly
        default: .iconOnly
        }
    }

    static func stored(_ mode: NSToolbar.DisplayMode) -> String? {
        switch mode {
        case .iconOnly: "iconOnly"
        case .labelOnly: "labelOnly"
        case .iconAndLabel: "iconAndLabel"
        default: nil
        }
    }
    convenience init() {
        self.init(preferences: PreferenceStore(), autosavesFrame: true)
    }

    /// 테스트가 쓴다 — 설정 저장소를 바꾸고 창 자리를 저장하지 않는다.
    convenience init(preferences: PreferenceStore, autosavesFrame: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            // No .fullSizeContentView: with it the sidebar's tab row is laid
            // out under the title bar and collides with the traffic lights.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 520, height: 360)
        self.init(window: window)
        self.preferences = preferences
        self.autosavesFrame = autosavesFrame
        build()
    }

    // MARK: Build

    private func build() {
        editor.editorDelegate = self
        // 우클릭 메뉴의 마디 몫 — 글을 고르고 있으면 그 자리 번역(⌘⇧T와 같다). 원문 편집기에만 단다(나란히 보기의
        // 번역본 칸에서 고르면 원문의 선택이 번역된다).
        editor.contextMenuExtras = { [weak self] editor in
            guard let self, editor.textView.selectedRange().length > 0 else { return [] }
            let item = NSMenuItem(title: String(localized: "선택한 글 번역"),
                                  action: #selector(DocumentWindowController.translateAction(_:)), keyEquivalent: "")
            item.target = self
            return [item]
        }
        outlinePanel.delegate = self
        browserPanel.delegate = self
        recentPanel.delegate = self

        for (identifier, label, view) in [
            ("outline", String(localized: "목차"), outlinePanel as NSView),
            ("browser", String(localized: "폴더"), browserPanel as NSView),
            ("recent", String(localized: "최근"), recentPanel as NSView),
        ] {
            let tab = NSTabViewItem(identifier: identifier)
            tab.label = label
            tab.view = view
            sidebarTabs.addTabViewItem(tab)
        }
        sidebarTabs.tabViewType = .topTabsBezelBorder
        sidebarTabs.controlSize = .small
        sidebarTabs.font = .systemFont(ofSize: 11)
        sidebarTabs.delegate = self

        // 카드는 문서의 머리다 — 편집기 **안의** 맨 위에 두어 글과 함께 굴러간다(`headerView`).
        // 전에는 편집기 위에 따로 두어 굴려도 남았고, 항목이 많으면 읽을 자리를 먹었다.
        let documentArea = NSStackView(views: [editor])
        documentArea.orientation = .vertical
        documentArea.alignment = .leading
        documentArea.spacing = 0
        frontMatterCard.isHidden = true
        // 접어 둔 사람은 다음 문서도 접힌 채 본다(`collapsesFrontMatter`).
        frontMatterCard.setCollapsed(preferences.collapsesFrontMatter)
        editor.headerView = frontMatterCard
        frontMatterCard.onToggle = { [weak self] collapsed in
            self?.preferences.collapsesFrontMatter = collapsed
            self?.editor.headerDidChange()
        }

        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: documentArea.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: documentArea.trailingAnchor),
        ])

        let sidebarController = NSViewController()
        sidebarController.view = sidebarTabs
        let editorController = NSViewController()
        // 상태 표시가 편집기 **위에 떠야** 하므로 스택 뷰를 그대로 쓰지 못한다.
        // 스택에 넣으면 흐름에 끼어들어 편집기를 밀어낸다. 그래서 담는 뷰를 하나 두고
        // 편집기 영역을 꽉 채운 뒤 그 위에 겹친다.
        let editorContainer = NSView()
        // 나란히 보기가 오른쪽에 번역본 칸을 더한다. 평소에는 칸이 원문 하나다.
        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.translatesAutoresizingMaskIntoConstraints = false
        contentSplit.addArrangedSubview(documentArea)
        editorContainer.addSubview(contentSplit)
        editorContainer.addSubview(statusOverlay)
        NSLayoutConstraint.activate([
            contentSplit.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            contentSplit.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            contentSplit.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            contentSplit.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),

            statusOverlay.centerXAnchor.constraint(equalTo: editorContainer.centerXAnchor),
            statusOverlay.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor,
                                                  constant: -22),
            statusOverlay.widthAnchor.constraint(lessThanOrEqualTo: editorContainer.widthAnchor,
                                                 constant: -48),
        ])
        editorController.view = editorContainer

        splitController = NSSplitViewController()
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 380
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = true
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: editorController))
        window?.contentViewController = splitController
        // contentViewController를 넣으면 창이 내용의 **맞춤 크기**로 줄어든다. 편집기에는
        // 고유 크기가 없어 창의 contentRect와 상관없이 520×380 조각이 됐다. 그래서 여기서
        // 크기를 **한 번** 정한다. 저장된 창 자리는 바로 아래 자동 저장 이름이 되살린다.
        //
        // 전에는 `preferredContentSize`로 했는데, AppKit이 그것을 우선순위 501의 제약으로
        // 계속 걸어 둔다(실측). 창이 제자리에 있으려는 우선순위(500)보다 높아서 레이아웃이
        // 다시 돌 때마다 창이 860×752로 되돌아갔다 — 나란히 보기에서 반씩 놓은 두 창이
        // 0.3초 만에 되돌아갔고, 되돌린 호출이 `_changeWindowFrameFromConstraintsIfNecessary`
        // 였다. 나중에 `.zero`로 바꿔도 걸린 제약은 풀리지 않았다.
        window?.setContentSize(NSSize(width: 860, height: 700))
        // 이름이 Md → Madi로 바뀌어도 이 문자열은 그대로 둔다. 자동 저장 이름과
        // 도구 막대 식별자는 **저장된 상태를 찾는 열쇠**이고 사람이 읽는 이름이
        // 아니다. 바꾸면 기존 사용자의 창 위치·크기와 도구 막대 구성이 한 번
        // 사라진다. 번들 식별자를 그대로 둔 것과 같은 이유다.
        if autosavesFrame { window?.setFrameAutosaveName("MdDocumentWindow") }

        matchLabel.font = .systemFont(ofSize: 11)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.alignment = .right

        searchField.placeholderString = String(localized: "문서 내 검색")
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.delegate = self

        let toolbar = NSToolbar(identifier: "MdToolbar")
        toolbar.delegate = self
        // 아이콘만(macOS 앱의 기본 모양). 도구 막대를 우클릭해 '아이콘과 텍스트'로 바꾸면 칸마다 이름이 나오고
        // (macOS 15 이상), 고른 것은 기억한다 — 이름이 같은 도구 막대는 창끼리 함께 바뀐다.
        toolbar.displayMode = Self.displayMode(stored: preferences.toolbarDisplayMode)
        toolbar.allowsUserCustomization = false
        if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = true }
        toolbarModeObservation = toolbar.observe(\.displayMode, options: [.new]) { [weak self] toolbar, _ in
            // 도구 막대는 메인 스레드에서만 바뀐다. 읽기까지 이 안에서 한다(밖에서 읽으면 Swift 6 경고).
            MainActor.assumeIsolated {
                let mode = toolbar.displayMode
                // 기본과 같으면 적지 않는다(지운다). AppKit이 도구 막대를 창에 붙일 때도 이 값을 다시 매겨 알림이
                // 오는데, 그것까지 적으면 첫 실행의 기본값이 굳어 기본을 바꿔도 따라오지 않는다(실측: 이름을 보이던
                // 판의 값이 남아 아이콘만으로 바꾼 판에서도 이름이 나왔다).
                let stored = mode == Self.displayMode(stored: nil) ? nil : Self.stored(mode)
                self?.preferences.toolbarDisplayMode = stored
            }
        }
        window?.toolbar = toolbar
        if #available(macOS 11.0, *) { window?.toolbarStyle = .unified }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange(_:)),
            name: PreferenceStore.didChange, object: nil)
        editor.apply(preferences.current)
        // 새 창의 보기 초깃값. 창을 세울 때 한 번만 읽는다(위 `preferencesDidChange`의
        // 주석 참고) — 매번 싣으면 ⌘E로 바꿔 둔 보기가 설정에 되돌아간다.
        editor.isCodeView = preferences.current.openInCodeView
        syncCodeViewState()
        // 메뉴 바는 창 모두가 함께 쓴다. 다른 창이 앞으로 오면 그 창의 상태로 체크 표시를
        // 다시 달아야 한다 — 안 하면 뒤에 있는 창의 상태를 보여 준다.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: window)
    }

    /// 창이 닫힌다(원문 문서가 이미 저장할지 물었고, 닫기로 정해졌다). 번역본 칸이 있으면 걷는다.
    /// 번역본을 고치고 저장하지 않았으면 **자기 창으로 옮긴다** — 여기서는 닫기를 되돌릴 수 없으므로
    /// 물을 수가 없고, 말없이 버리면 고친 것이 사라진다.
    @objc private func windowWillClose(_ note: Notification) {
        guard let session = sideBySide else { return }
        removeTranslationPane(session, restoreFrame: false)
        let document = session.document
        if document.isDocumentEdited {
            document.hostWindow = nil
            keepUnsavedTranslation(document)
            AppLog.info(String(localized: "저장하지 않은 번역본을 자기 창으로 옮겼습니다"),
                        detail: document.displayName)
        } else {
            document.close()
        }
    }

    /// 원문 창이 닫힐 때 저장 안 한 번역본을 어떻게 살릴지. 앱은 자기 창을 열어 준다. 테스트가 바꾼다 —
    /// 창을 사용자 화면에 띄우지 않고, 창 자리를 설정 파일에 쓰지 않게.
    var keepUnsavedTranslation: (MarkdownDocument) -> Void = { document in
        document.makeWindowControllers()
        document.showWindows()
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        syncCodeViewState()
        syncSideBySideState()
    }

    // MARK: Document content

    func load(markdown: String) {
        let parsed = FrontMatter.parse(markdown)
        frontMatter = parsed
        frontMatterCard.update(with: parsed)
        editor.headerDidChange()
        // 셋이 각자 문서 전체를 칠한다. 묶어서 끝에서 한 번만 칠한다(22만 자에서 패스 하나가
        // 0.17초다). 위치와 설정이 글보다 먼저 정해져 있어야 그 한 번이 맞게 칠한다.
        editor.batchUpdates {
            editor.markdown = parsed?.body ?? markdown
            editor.documentURL = markdownDocument?.fileURL
            editor.apply(preferences.current)
        }
        refreshOutline()
        browserPanel.show(folderOf: markdownDocument?.fileURL)
        recentPanel.reload()
        window?.title = markdownDocument?.displayName ?? String(localized: "제목 없음")
        // 원문이 디스크에서 다시 읽혔을 때(다른 앱이 고침, 되돌리기)도 띠를 맞춘다 — 이 길은
        // 편집기 위임을 지나지 않는다.
        sideBySide?.sourceTextDidChange()
        AppLog.info(String(localized: "문서를 열었습니다: \(markdownDocument?.displayName ?? String(localized: "제목 없음"))"),
                    detail: String(localized: "\(markdown.count)자"))
    }

    func documentContentDidChange() {
        guard let text = markdownDocument?.markdown, text != composedMarkdown() else { return }
        load(markdown: text)
    }

    /// The full document: the preserved front matter block plus the edited body.
    private func composedMarkdown() -> String {
        guard let frontMatter else { return editor.markdown }
        return frontMatter.joined(withBody: editor.markdown)
    }

    private func refreshOutline() {
        outlinePanel.update(entries: editor.outline)
    }

    // MARK: Sidebar

    private func show(_ tab: Tab) {
        let alreadyShowing = !sidebarItem.isCollapsed
            && sidebarTabs.indexOfTabViewItem(sidebarTabs.selectedTabViewItem!) == tab.rawValue
        if alreadyShowing {
            sidebarItem.animator().isCollapsed = true
        } else {
            sidebarTabs.selectTabViewItem(at: tab.rawValue)
            if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
        }
        switch tab {
        case .outline: refreshOutline()
        case .browser: browserPanel.show(folderOf: markdownDocument?.fileURL)
        case .recent: recentPanel.reload()
        }
        // 접고 펴는 움직임은 이 차례 뒤에 끝나므로 isCollapsed를 다시 읽지 않고 목표를 바로 싣는다.
        markSidebarGroup(open: alreadyShowing ? nil : tab)
        DispatchQueue.main.async { [weak self] in self?.updateToggleStates() }
    }

    /// 지금 열린 사이드바 탭. 닫혀 있으면 nil.
    var openSidebarTab: Int? {
        guard !sidebarItem.isCollapsed, let item = sidebarTabs.selectedTabViewItem else { return nil }
        return sidebarTabs.indexOfTabViewItem(item)
    }

    /// 사이드바 묶음이 지금 열린 탭을 보이게 한다 — 눌린 칸이 곧 열린 탭이다(Mark.app의 도구 막대처럼
    /// 순간 단추가 아니라 토글이라, 무엇이 열려 있는지 보인다).
    private func updateToggleStates() {
        markSidebarGroup(open: openSidebarTab.flatMap(Tab.init(rawValue:)))
    }

    private func markSidebarGroup(open tab: Tab?) {
        guard let group = sidebarGroup else { return }
        for index in group.subitems.indices {
            group.setSelected(index == tab?.rawValue, at: index)
        }
    }

    /// 사이드바 묶음의 칸을 눌렀다. 묶음은 여러 칸이 눌릴 수 있는 꼴(`selectAny`)이라, AppKit이 바꿔 둔
    /// 칸과 지금 열린 탭을 견주어 **누른 칸**을 찾는다 — 열린 탭의 칸을 누르면 닫고, 다른 칸을 누르면 그 탭으로.
    /// 한 칸만 눌리는 꼴(`selectOne`)을 쓰지 않는 까닭: 사이드바가 닫혀 있으면 눌린 칸이 없어야 하고, 눌린
    /// 칸을 다시 눌러 닫을 수 있어야 한다.
    @objc func sidebarGroupClicked(_ sender: NSToolbarItemGroup) {
        let open = openSidebarTab
        let clicked = sender.subitems.indices.first { sender.isSelected(at: $0) != (open == $0) }
        guard let clicked, let tab = Tab(rawValue: clicked) else { return updateToggleStates() }
        show(tab)
    }

    /// 보기 묶음의 칸을 눌렀다. 사이드바 묶음과 같은 방식으로 누른 칸을 찾는다. 나란히 번역은 바로 켜지지
    /// 않을 수 있다(언어 시트, 번역 중) — 그래서 누른 뒤 지금 상태로 되돌려 싣고, 켜지면 그때 눌린다.
    @objc func viewGroupClicked(_ sender: NSToolbarItemGroup) {
        let state = [editor.isCodeView, sideBySide != nil]
        let clicked = sender.subitems.indices.first { $0 < state.count && sender.isSelected(at: $0) != state[$0] }
        switch clicked {
        case 0: toggleCodeViewAction(sender)
        case 1: toggleSideBySideAction(sender)
        default: break
        }
        syncCodeViewState()
        syncSideBySideState()
    }

    // MARK: Actions

    @objc func showOutlineAction(_ sender: Any?) { show(.outline) }
    @objc func showBrowserAction(_ sender: Any?) { show(.browser) }
    @objc func showRecentAction(_ sender: Any?) { show(.recent) }

    @objc func focusSearchAction(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    // MARK: 빠른 열기 · 명령 팔레트

    /// 빠른 열기 ⌥⌘O — 열린 문서, 최근 문서, 파일 브라우저 폴더(없으면 이 문서의 폴더)의 마크다운
    /// 파일에서 이름으로 고른다. 폴더는 뒤에서 훑고, 다 훑으면 목록에 더한다 — 큰 폴더에서도
    /// 창이 바로 뜬다.
    @objc func showQuickOpenAction(_ sender: Any?) {
        guard let window else { return }
        let panel = QuickPickPanel(placeholder: String(localized: "문서 이름으로 찾기"),
                                   emptyText: String(localized: "맞는 문서가 없습니다"))
        quickPick = panel
        let root = browserPanel.currentRoot ?? markdownDocument?.fileURL?.deletingLastPathComponent()
        panel.present(over: window, items: quickOpenItems(folderFiles: [], root: root))
        guard let root else { return }
        Task { @MainActor [weak self, weak panel] in
            let files = await Task.detached(priority: .userInitiated) {
                QuickOpenSource.markdownFiles(under: root)
            }.value
            guard let self, let panel, self.quickPick === panel else { return }
            panel.update(items: self.quickOpenItems(folderFiles: files, root: root))
        }
    }

    private func quickOpenItems(folderFiles: [URL], root: URL?) -> [QuickPickItem] {
        let controller = NSDocumentController.shared
        let open = controller.documents.compactMap(\.fileURL)
        return QuickOpenSource.candidates(open: open, recent: controller.recentDocumentURLs,
                                          folderFiles: folderFiles, root: root)
            .map { candidate in
                QuickPickItem(title: candidate.url.lastPathComponent, detail: candidate.detail) { [weak self] in
                    self?.open(candidate.url)
                }
            }
    }

    /// 명령 팔레트 ⇧⌘P — 메뉴의 명령을 이름으로 찾아 실행한다. 지금 쓸 수 없는 명령은 메뉴처럼 빠진다.
    @objc func showCommandPaletteAction(_ sender: Any?) {
        guard let window, let menu = NSApp.mainMenu else { return }
        let items = CommandPaletteSource.items(from: menu, excluding: [#selector(showCommandPaletteAction(_:))])
        let panel = QuickPickPanel(placeholder: String(localized: "명령 찾기"),
                                   emptyText: String(localized: "맞는 명령이 없습니다"))
        quickPick = panel
        panel.present(over: window, items: items)
    }

    // MARK: 글자 크기 (보기 ▸ 글자 크게 · 작게 · 기본 크기)

    @objc func makeTextLargerAction(_ sender: Any?) { changeTextSize { $0.steppingBodyPointSize(by: 1) } }
    @objc func makeTextSmallerAction(_ sender: Any?) { changeTextSize { $0.steppingBodyPointSize(by: -1) } }
    @objc func makeTextStandardSizeAction(_ sender: Any?) { changeTextSize { $0.withStandardBodyPointSize } }

    /// 설정 창의 `본문 글자 크기`와 **같은 값**을 바꾼다. 창마다 따로 두지 않는 이유: 설정의 값과
    /// 화면이 어긋나면 사용자는 어느 쪽이 맞는지 알 수 없고, 다음 창은 설정 값으로 열린다.
    /// 그래서 저장하고 알린다 — 열린 창 모두와 설정 창이 따라온다.
    private func changeTextSize(_ change: (EditorPreferences) -> EditorPreferences) {
        let current = preferences.current
        let next = change(current)
        guard next.bodyPointSize != current.bodyPointSize else {
            NSSound.beep()       // 범위 끝
            return
        }
        preferences.save(next)
        NotificationCenter.default.post(name: PreferenceStore.didChange, object: nil)
        statusOverlay.show(String(localized: "글자 크기 \(Int(next.bodyPointSize))pt"), duration: 1.2)
    }

    /// 코드 보기 (⌘E) — 렌더된 문서와 마크다운 원본을 **오가는 토글**이다.
    ///
    /// 세 곳이 같은 상태를 보여야 한다: 도구 막대 토글(눌린 모양), 메뉴 항목(체크 표시),
    /// 창 부제. 한 곳만 고치면 나머지가 거짓을 말한다.
    @objc func toggleCodeViewAction(_ sender: Any?) {
        editor.isCodeView.toggle()
        syncCodeViewState()
    }

    /// 지금 보기를 모든 표면에 싣는다.
    private func syncCodeViewState() {
        let isOn = editor.isCodeView
        window?.subtitle = isOn ? String(localized: "원본 보기") : ""
        viewGroup?.setSelected(isOn, at: 0)
        viewGroup?.subitems.first?.toolTip = Self.codeViewTip(isOn: isOn)
        if let main = NSApp.mainMenu { Self.markCodeView(in: main, isOn: isOn) }
    }

    /// 메뉴 항목에 체크 표시를 단다 — 토글의 macOS 관례다.
    ///
    /// **`validateMenuItem`으로 하지 않는다.** 한 번 그렇게 했다가 회귀를 냈다:
    /// `NSMenuItemValidation`을 구현하면 이 객체로 **오는 모든 항목**을 내가 판정하게
    /// 되고, 내가 응답하지 않는 동작(`save:` · `performClose:`)에 false를 돌려
    /// 그때 있던 버거 메뉴의 저장·다른 이름으로 저장·닫기가 비활성이 됐다. 체크 표시 하나를
    /// 붙이려고 메뉴 활성화 규칙 전체를 떠안을 이유가 없다.
    static func markCodeView(in menu: NSMenu, isOn: Bool) {
        mark(#selector(DocumentWindowController.toggleCodeViewAction(_:)), in: menu, isOn: isOn)
    }

    static func mark(_ action: Selector, in menu: NSMenu, isOn: Bool) {
        for item in menu.items {
            if item.action == action {
                item.state = isOn ? .on : .off
            }
            if let submenu = item.submenu { mark(action, in: submenu, isOn: isOn) }
        }
    }

    /// 도움말은 **누르면 무엇이 되는지**를 말한다. 지금 상태를 말하면 사용자가
    /// 누를지 말지를 그 문장에서 알 수 없다.
    private static func codeViewTip(isOn: Bool) -> String {
        isOn ? String(localized: "마크다운 문법으로 보기 (⌘E)") : String(localized: "마크다운 원본 보기 (⌘E)")
    }

    // MARK: Print and PDF

    /// 프린트와 PDF 내보내기가 **같은 설정**을 쓴다. 설정 하나가 양쪽에 걸리는 것이
    /// 맞다 — 화면에 보이는 것을 종이에 내든 파일에 내든 같은 쪽이어야 한다.
    func printInfo(forPDF pdfURL: URL?) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let settings = preferences.current

        // 용지를 먼저 정한다. 방향과 여백이 그 크기 위에서 계산된다.
        if let paper = settings.printPaper.portraitSize {
            // 방향은 아래에서 `orientation`으로 주므로 여기서는 늘 세로 크기를 넣는다 —
            // 가로 크기를 넣고 방향까지 가로로 주면 두 번 돌아간다.
            info.paperSize = NSSize(width: paper.width, height: paper.height)
        }
        info.orientation = settings.printOrientation == .landscape ? .landscape : .portrait

        let margin = settings.printMargin.points
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        if let pdfURL {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdfURL
        }
        return info
    }

    @objc func printDocumentAction(_ sender: Any?) {
        let operation = NSPrintOperation(view: editor.printableView, printInfo: printInfo(forPDF: nil))
        operation.jobTitle = markdownDocument?.displayName ?? String(localized: "문서")
        // 프린트 패널이 떠 있는 동안과 찍는 동안 캐럿 줄의 마커도 숨긴다. 끝나면(취소해도) 되돌린다.
        // 흰 종이에 기본 색으로 바뀌므로, 라이트로 다시 그리는 다이어그램을 기다린다.
        editor.isRenderingForOutput = true
        editor.waitForPendingDrawings()
        operation.runModal(for: window!, delegate: self,
                           didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                            contextInfo: UnsafeMutableRawPointer?) {
        editor.isRenderingForOutput = false
    }

    /// PDF 내보내기 — prints to a file instead of a printer, so the PDF matches
    /// exactly what the editor draws (hidden markers included).
    @objc func exportPDFAction(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (markdownDocument?.displayName as NSString?)?
            .deletingPathExtension.appending(".pdf") ?? String(localized: "문서.pdf")
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "내보내기")

        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if self.exportPDF(to: url) {
                self.revealExportedFile(url)
            } else {
                let alert = NSAlert()
                alert.messageText = String(localized: "PDF 내보내기에 실패했습니다")
                alert.informativeText = url.path
                alert.runModal()
            }
        }
    }

    /// PDF를 `url`에 쓴다 — 저장 패널 뒤의 일. 프린트와 같은 설정(`printInfo`)이다.
    @discardableResult
    func exportPDF(to url: URL, showsProgress: Bool = true) -> Bool {
        let operation = NSPrintOperation(view: editor.printableView, printInfo: printInfo(forPDF: url))
        operation.jobTitle = markdownDocument?.displayName ?? String(localized: "문서")
        operation.showsPrintPanel = false
        operation.showsProgressPanel = showsProgress
        editor.isRenderingForOutput = true
        defer { editor.isRenderingForOutput = false }
        editor.waitForPendingDrawings()
        guard operation.run() else {
            AppLog.error(String(localized: "PDF 내보내기에 실패했습니다"), detail: url.path)
            return false
        }
        AppLog.info(String(localized: "PDF로 내보냈습니다"), detail: url.path)
        return true
    }

    /// 내보낸 파일을 보여 준다. 앱은 Finder에서 그 파일을 띄우고, 테스트는 끈다.
    var revealExportedFile: (URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Translation

    private(set) var translationTask: Task<Void, Never>?

    /// 번역기 대역. nil이면 Apple 번역이다. 테스트가 넣는다 — 시스템의 언어 팩과 번역기에 기대지
    /// 않고 창의 번역 흐름(제자리·새 문서·나란히·실패)을 시험한다.
    struct TranslatorStub {
        /// 언어 팩이 받아져 있는 것으로 볼지.
        var installed = true
        var translate: @Sendable (String) async throws -> String
    }

    var translatorStub: TranslatorStub?

    /// 번역. 선택이 있으면 **그 자리에서** 바꾸고(되돌리기로 취소 가능), 선택이 없으면
    /// 문서 전체를 번역해 **새 문서**로 연다 — 원본을 건드리지 않는 쪽이 안전하다.
    ///
    /// 마크업은 번역기에 넘기지 않는다(`MarkdownTranslationPlan`). 코드 블록·인라인 코드·
    /// 링크 URL·표 구분선·마커는 그대로 남고 본문 조각만 번역된다.
    @objc func translateAction(_ sender: Any?) {
        // 메뉴 항목이 방향을 들고 온다(언어 하위 메뉴). 없으면 글에서 짐작한다.
        let requested = (sender as? NSMenuItem)?.representedObject as? TranslationDirection
        translate(direction: requested)
    }

    /// 번역 결과가 갈 곳.
    enum TranslationDestination: Equatable {
        /// 선택이 있으면 그 자리, 없으면 새 문서(⌘⇧T).
        case automatic
        /// 이 창의 오른쪽에 번역본 칸을 연다(⌃⌘T). 선택과 상관없이 문서 전체다.
        case sideBySide
        /// 이미 열린 나란히 보기의 번역본을 새 번역으로 바꾼다.
        case refresh
    }

    /// 번역을 시작한다. `direction`이 nil이면 글에서 짐작한다.
    private func translate(direction requested: TranslationDirection?,
                           destination: TranslationDestination = .automatic) {
        guard #available(macOS 26.0, *) else {
            report(String(localized: "Apple 번역은 macOS 26 이상에서만 됩니다."))
            return
        }
        guard translationTask == nil else {
            report(String(localized: "번역이 이미 진행 중입니다."))
            return
        }

        let selection = editor.textView.selectedRange()
        let inPlace = destination == .automatic && selection.length > 0
        let source = inPlace
            ? (editor.markdown as NSString).substring(with: selection)
            : editor.markdown
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report(String(localized: "번역할 글이 없습니다."))
            return
        }
        // 문서 전체를 새 문서로 옮길 때는 front matter의 `title`·`description`도 함께 옮긴다.
        // 번역을 시작한 때의 블록을 붙잡아 둔다 — 줄 번호가 그 블록의 것이다. 제자리 번역과
        // 다시 번역(번역본 창의 front matter를 그대로 둔다)에서는 옮기지 않는다.
        let sourceFrontMatter = frontMatter
        let frontValues = (inPlace || destination == .refresh)
            ? [] : (sourceFrontMatter?.translatableValues ?? [])

        let sheet = TranslationProgressSheet()
        sheet.onCancel = { [weak self] in self?.translationTask?.cancel() }

        // 진행 콜백은 Task 밖에서 한 번 만든다. Task 안에서 다시 `[weak self]`를 쓰면
        // 바깥 Task가 이미 붙잡은 약한 변수를 동시 실행 코드에서 참조하는 꼴이 된다.
        let onProgress: @Sendable (AppleTranslator.Progress) -> Void = { progress in
            Task { @MainActor in
                sheet.update(direction: nil, fraction: progress.fraction,
                             completed: progress.completedSegments, total: progress.totalSegments)
            }
        }

        translationTask = Task { @MainActor [weak self] in
            // **시트를 띄우기 전에 먼저 잰다.** 전에는 시트를 먼저 띄웠고, 언어 팩이
            // 없으면 시트가 떴다 사라진 뒤 경고창이 떠서 화면이 두 번 바뀌었다 —
            // 사용자가 읽을 틈이 없다. 재는 일은 싸다(계획 만들기 + 가용성 조회 한 번).
            let preflight = await AppleTranslator.preflight(
                markdown: source, direction: requested,
                preferredTarget: self?.preferences.current.translationTarget ?? "en",
                installed: self?.translatorStub?.installed)
            guard let self else { return }
            guard preflight.state == .ready else {
                self.translationTask = nil
                let failure: AppleTranslator.Failure
                switch preflight.state {
                case .nothingToTranslate: failure = .nothingToTranslate
                case .needsLanguagePack: failure = .languagePackMissing(direction: preflight.direction)
                case .unsupported: failure = .unsupported(direction: preflight.direction)
                case .sameLanguage:
                    failure = .sameLanguage(language: preflight.direction.sourceLanguageName)
                case .ready: return
                }
                self.presentTranslationFailure(failure)
                return
            }

            // 여기서부터 실제로 번역한다 — 이제 시트를 띄운다. 시트는 뷰 컨트롤러가
            // 띄운다(NSWindowController에는 presentAsSheet가 없다).
            self.splitController.presentAsSheet(sheet)
            defer {
                self.translationTask = nil
                self.splitController.dismiss(sheet)
            }
            do {
                let result = try await AppleTranslator.translate(
                    preflight, extras: frontValues.map(\.text), progress: onProgress,
                    translator: self.translatorStub?.translate)
                Self.logRepairs(result.repairs)
                let composed = Self.composed(result.text, frontMatter: sourceFrontMatter,
                                             values: frontValues, translations: result.extras)
                switch destination {
                case .automatic where inPlace:
                    self.replaceSelection(selection, with: result.text)
                    self.report(String(localized: "번역했습니다 (\(result.direction.label))"))
                case .automatic:
                    self.openTranslatedCopy(composed: composed, direction: result.direction)
                case .sideBySide:
                    self.openSideBySide(composed: composed, direction: result.direction,
                                        sourceBody: source)
                case .refresh:
                    self.finishRetranslation(result.text, direction: result.direction,
                                             sourceBody: source)
                }
            } catch is CancellationError {
                // 사용자가 취소한 것이다. 알릴 것이 없다.
            } catch {
                self.presentTranslationFailure(error)
            }
        }
    }

    /// 번역기가 자리표를 잃어 다시 번역한 것을 기록에 남긴다. 조각마다 따로 번역한 문장은 문맥을
    /// 잃어 어색할 수 있다 — 그 사실을 사용자가 알 수 있어야 한다.
    @available(macOS 26.0, *)
    static func logRepairs(_ repairs: AppleTranslator.Repairs) {
        guard !repairs.isEmpty else { return }
        var parts: [String] = []
        if repairs.reformed > 0 { parts.append(String(localized: "다른 자리표로 다시 번역 \(repairs.reformed)곳")) }
        if repairs.split > 0 { parts.append(String(localized: "조각마다 따로 번역 \(repairs.split)곳(문맥 없음 — 어색할 수 있음)")) }
        if repairs.tableRows > 0 { parts.append(String(localized: "표 행을 칸마다 다시 번역 \(repairs.tableRows)곳")) }
        AppLog.info(String(localized: "번역기가 링크·강조·각주 표시를 잃은 문장을 다시 번역했습니다"),
                    detail: parts.joined(separator: " · "))
    }

    /// 번역할 언어를 고른다 — 짐작이 틀렸거나 한국어를 다른 언어로 내보낼 때.
    ///
    /// 목록을 시스템에 묻는 일이 비동기이므로 시트를 **받은 뒤에** 띄운다. 먼저 띄우고
    /// 채우면 빈 목록이 한순간 보인다(진행 시트에서 겪은 것과 같은 종류의 깜빡임이다).
    @objc func chooseTranslationLanguageAction(_ sender: Any?) {
        guard #available(macOS 26.0, *) else {
            report(String(localized: "Apple 번역은 macOS 26 이상에서만 됩니다."))
            return
        }
        guard translationTask == nil else {
            report(String(localized: "번역이 이미 진행 중입니다."))
            return
        }
        let detected = TranslationDirection.resolve(
            editor.markdown, preferredTarget: preferences.current.translationTarget)

        Task { @MainActor [weak self] in
            let languages = await AppleTranslator.supportedLanguagesWithKorean()
            guard let self else { return }
            guard !languages.isEmpty else {
                self.report(String(localized: "이 Mac에서 한국어와 번역할 수 있는 언어를 찾지 못했습니다."))
                return
            }
            let sheet = TranslationLanguageSheet(
                detectedSource: detected.source,
                initialTarget: self.preferences.current.translationTarget,
                languages: languages)
            sheet.onTranslate = { [weak self] direction in
                guard let self else { return }
                // 한국어에서 내보낼 때 고른 언어를 기억한다. 가져올 때는 대상이 늘
                // 한국어이므로 기억할 것이 없다.
                if direction.source == "ko" {
                    var updated = self.preferences.current
                    updated.translationTarget = direction.target
                    self.preferences.save(updated)
                }
                self.translate(direction: direction)
            }
            self.splitController.presentAsSheet(sheet)
        }
    }

    /// 제자리 교체. `NSTextView`의 되돌리기에 등록되도록 텍스트 뷰를 통해 바꾼다 —
    /// 저장소를 직접 고치면 ⌘Z로 돌릴 수 없다.
    private func replaceSelection(_ range: NSRange, with text: String) {
        let textView = editor.textView
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
    }

    /// 번역한 본문 앞에 front matter를 붙인다. 블록은 원본 그대로이고 **번역한 값의 줄만**
    /// 바뀐다 — `slug`·`date`·`layout` 같은 값을 번역하면 사이트가 깨진다
    /// (`FrontMatter.translatableKeys`).
    static func composed(_ body: String, frontMatter: FrontMatter?,
                         values: [FrontMatter.TranslatableValue], translations: [String]) -> String {
        guard let frontMatter else { return body }
        var byLine: [Int: String] = [:]
        for (value, translated) in zip(values, translations)
        where !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            byLine[value.line] = translated
        }
        return frontMatter.joined(withBody: body, translatedValues: byLine)
    }

    /// 번역본을 새 문서로 연다.
    ///
    /// 문서를 직접 만든다. `openUntitledDocumentAndDisplay`는 문서 종류에서 클래스를 찾는데, 찾다
    /// 실패하면 오류 대화상자가 앱을 막는다(나란히 보기의 번역본에서 겪었다).
    func openTranslatedCopy(composed: String, direction: TranslationDirection) {
        let document = MarkdownDocument()
        document.fileType = MarkdownDocument.writableTypes.first
        document.markdown = composed
        // 이름을 제안한다 — 저장하지 않은 '무제'로 두면 사용자가 다른 이름으로
        // 저장에서 직접 적어야 한다. `displayName`을 주면 창 제목과 저장 대화상자의
        // 기본 이름이 그 값이 된다(저장 위치는 여전히 사용자가 고른다 — 원본 옆에
        // 말없이 파일을 만들지 않는다).
        if let suggested = direction.translatedFileName(for: markdownDocument?.fileURL) {
            document.displayName = suggested
        }
        NSDocumentController.shared.addDocument(document)
        document.updateChangeCount(.changeDone)
        presentTranslatedCopy(document)
        report(String(localized: "번역본을 새 문서로 열었습니다 (\(direction.label))"))
    }

    /// 새 문서가 된 번역본을 보인다. 앱은 창을 열고, 테스트가 바꾼다 — 사용자 화면에 창을 띄우지 않고
    /// 창 자리를 설정 파일에 쓰지 않게.
    var presentTranslatedCopy: (MarkdownDocument) -> Void = { document in
        document.makeWindowControllers()
        document.showWindows()
    }

    // MARK: 원문·번역 나란히 보기

    /// ⌃⌘T · 도구 막대 토글. 켜면 번역해서 이 창의 오른쪽에 번역본 칸을 열고, 끄면 칸을 닫는다
    /// (고친 번역본을 저장하지 않았으면 먼저 묻는다 — 취소하면 그대로 남는다).
    @objc func toggleSideBySideAction(_ sender: Any?) {
        if sideBySide != nil {
            closeSideBySide()
        } else {
            translate(direction: nil, destination: .sideBySide)
        }
        // 누른 버튼은 스스로 상태를 뒤집는다. 실제 상태로 되돌린다 — 번역이 끝나야
        // 켜지고, 닫기를 취소하면 켜진 채로 남는다.
        syncSideBySideState()
    }

    /// 번역본 문서를 만들고 이 창의 오른쪽 칸에 싣는다. 번역은 이미 끝났다(테스트가 이 길로 바로 연다).
    ///
    /// 문서는 문서 관리자에 넣는다 — 앱을 끝낼 때 저장 안 한 번역본을 묻게 하려면 관리자가 알아야
    /// 한다. 창은 만들지 않는다.
    func openSideBySide(composed: String, direction: TranslationDirection, sourceBody: String) {
        guard sideBySide == nil, let window else { return }
        // 문서를 직접 만든다. `makeUntitledDocument(ofType:)`은 Info.plist의 문서 종류에서 클래스를
        // 찾는데, 쓸 클래스는 이미 정해져 있다 — 찾다가 실패하면 오류 대화상자가 앱을 막는다(실측:
        // 문서 종류가 없는 테스트 프로세스에서 멈췄다).
        let document = MarkdownDocument()
        document.fileType = MarkdownDocument.writableTypes.first
        NSDocumentController.shared.addDocument(document)
        if let suggested = direction.translatedFileName(for: markdownDocument?.fileURL) {
            document.displayName = suggested
        }

        document.hostWindow = window
        let pane = TranslationPaneView(document: document, direction: direction)
        pane.setCardCollapsed(preferences.collapsesFrontMatter)
        pane.onCardToggle = { [weak self] collapsed in self?.preferences.collapsesFrontMatter = collapsed }
        pane.editor.apply(preferences.current)
        // 그림의 상대 경로는 원문 폴더를 기준으로 푼다 — 번역본은 보통 원문 옆에 저장한다.
        pane.editor.documentURL = markdownDocument?.fileURL
        pane.load(markdown: composed)
        document.updateChangeCount(.changeDone)       // 아직 저장하지 않은 번역이다
        pane.band.onRetranslate = { [weak self] in self?.retranslateSideBySide() }
        pane.onClose = { [weak self] in self?.closeSideBySide() }
        pane.onLink = { [weak self] url in
            guard let self else { return }
            self.markdownEditor(self.editor, didClickLink: url)
        }

        let session = SideBySideTranslation(source: self, pane: pane, direction: direction,
                                            sourceBody: sourceBody, translatedBody: pane.editor.markdown)
        sideBySide = session
        widenForSplit(window)
        contentSplit.addArrangedSubview(pane)
        contentSplit.adjustSubviews()
        contentSplit.layoutSubtreeIfNeeded()
        contentSplit.setPosition(floor(contentSplit.bounds.width / 2), ofDividerAt: 0)
        syncSideBySideState()
        // 초점은 원문에 남긴다 — 사용자는 원문에서 ⌃⌘T를 눌렀고, 하던 일을 이어서 해야 한다.
        window.makeFirstResponder(editor.textView)
        // 두 칸을 처음부터 같은 자리에 둔다 — 원문에서 보던 곳을 번역본도 보여 준다.
        session.link.follow(editor)
        report(String(localized: "번역본을 오른쪽에 열었습니다 (\(direction.label))"))
    }

    /// 칸을 나눌 자리를 만든다. 창이 좁으면 화면 안에서 넓힌다(전체 화면은 그대로).
    private func widenForSplit(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = window.frame
        let wanted = min(visible.width, max(frame.width, 1280))
        guard wanted > frame.width + 1 else { return }
        var widened = frame
        widened.size.width = wanted
        // 오른쪽으로 넓히되 화면을 넘으면 왼쪽으로 민다.
        if widened.maxX > visible.maxX { widened.origin.x = max(visible.minX, visible.maxX - wanted) }
        frameBeforeSplit = frame
        window.setFrame(widened, display: true)
        splitFrame = window.frame
    }

    /// 번역본 칸을 닫는다. 번역본을 고치고 저장하지 않았으면 저장할지 묻는다(시트) —
    /// 저장하거나 '저장 안 함'을 고르면 닫고, 취소하면 그대로 둔다.
    func closeSideBySide() {
        guard let session = sideBySide else { return }
        let document = session.document
        guard document.isDocumentEdited else {
            finishClosing(session)
            return
        }
        document.canClose(withDelegate: self,
                          shouldClose: #selector(translationDocument(_:shouldClose:contextInfo:)),
                          contextInfo: nil)
    }

    @objc private func translationDocument(_ document: NSDocument, shouldClose: Bool,
                                           contextInfo: UnsafeMutableRawPointer?) {
        guard shouldClose, let session = sideBySide, session.document === document else {
            syncSideBySideState()
            return
        }
        finishClosing(session)
    }

    private func finishClosing(_ session: SideBySideTranslation) {
        removeTranslationPane(session, restoreFrame: true)
        session.document.close()
        window?.makeFirstResponder(editor.textView)
    }

    /// 칸을 걷고 잇기를 끊는다. 넓힌 창은 사용자가 손대지 않았으면 원래 자리로.
    private func removeTranslationPane(_ session: SideBySideTranslation, restoreFrame: Bool) {
        session.disconnect()
        session.pane.removeFromSuperview()
        contentSplit.adjustSubviews()
        sideBySide = nil
        if restoreFrame, let window, let before = frameBeforeSplit, let widened = splitFrame,
           window.frame == widened {
            window.setFrame(before, display: true)
        }
        frameBeforeSplit = nil
        splitFrame = nil
        syncSideBySideState()
    }

    /// 번역본 칸의 띠에서 '다시 번역'을 눌렀다.
    private func retranslateSideBySide() {
        guard let session = sideBySide else { return }
        guard session.translationWasEdited, let window else {
            translate(direction: session.direction, destination: .refresh)
            return
        }
        // 고친 번역본을 말없이 덮지 않는다.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "번역본에서 고친 내용이 사라집니다")
        alert.informativeText = String(localized: "다시 번역하면 번역본 전체를 새 번역으로 바꿉니다. 바꾼 뒤에도 ⌘Z로 되돌릴 수 있습니다.")
        alert.addButton(withTitle: String(localized: "다시 번역"))
        alert.addButton(withTitle: String(localized: "취소"))
        alert.beginSheetModal(for: window) { [weak self, weak session] response in
            guard response == .alertFirstButtonReturn, let self, let session else { return }
            self.translate(direction: session.direction, destination: .refresh)
        }
    }

    /// 다시 번역한 결과를 번역본 칸에 싣는다.
    func finishRetranslation(_ text: String, direction: TranslationDirection, sourceBody: String) {
        guard let session = sideBySide else {
            // 번역하는 사이에 칸이 닫혔다. 결과를 버리지 않고 새 문서로 연다.
            // 다시 번역은 front matter를 옮기지 않았으므로 원본 블록을 그대로 붙인다.
            openTranslatedCopy(composed: Self.composed(text, frontMatter: frontMatter,
                                                       values: [], translations: []),
                               direction: direction)
            return
        }
        session.pane.replaceBody(with: text)
        session.pane.setDirection(direction)
        session.didRetranslate(direction: direction, sourceBody: sourceBody,
                               translatedBody: session.pane.editor.markdown)
        report(String(localized: "다시 번역했습니다 (\(direction.label))"))
    }

    /// 도구 막대 토글과 메뉴 체크 표시를 지금 상태로.
    func syncSideBySideState() {
        let isOn = sideBySide != nil
        viewGroup?.setSelected(isOn, at: 1)
        if let group = viewGroup, group.subitems.count > 1 { group.subitems[1].toolTip = Self.sideBySideTip(isOn: isOn) }
        if window?.isKeyWindow ?? false, let main = NSApp.mainMenu {
            Self.mark(#selector(toggleSideBySideAction(_:)), in: main, isOn: isOn)
        }
    }

    private static func sideBySideTip(isOn: Bool) -> String {
        isOn ? String(localized: "나란히 보기 끝내기 — 번역본을 닫습니다 (⌃⌘T)")
             : String(localized: "원문·번역 나란히 보기 (⌃⌘T)")
    }

    private func presentTranslationFailure(_ error: Error) {
        // 실패는 **두 곳에** 남는다. 경고창은 지금 알리기 위한 것이고, 기록은 나중에
        // 다시 볼 수 있게 하기 위한 것이다. 경고창만 띄우면 닫는 순간 사라진다.
        AppLog.error(String(localized: "번역하지 못했습니다"), detail: error.localizedDescription)

        let alert = NSAlert()
        // 무엇이 잘못됐는지와 **무엇을 해야 하는지**를 가른다. 경고창이 둘을 다른
        // 크기로 그리므로, 한 덩이로 적으면 할 일이 원인 문장에 묻힌다.
        //
        // `AppleTranslator`가 macOS 26 전용이라 그 아래에서는 분해할 수 없다 —
        // 그때는 받은 오류 문구를 그대로 보인다(그 경로는 "macOS 26 이상에서만
        // 됩니다"를 먼저 띄우므로 여기까지 오지 않는다).
        var cause = String(localized: "번역하지 못했습니다")
        var recovery = error.localizedDescription
        var offersSettings = false
        var isInformational = false
        if #available(macOS 26.0, *), let failure = error as? AppleTranslator.Failure {
            cause = failure.errorDescription ?? cause
            recovery = failure.recoverySuggestion ?? error.localizedDescription
            offersSettings = failure.suggestsLanguageSettings
            // 번역할 글이 없는 것은 잘못이 아니다 — 알려 주기만 한다.
            isInformational = failure == .nothingToTranslate
        }
        alert.messageText = cause
        alert.informativeText = recovery
        alert.alertStyle = isInformational ? .informational : .warning

        if offersSettings {
            alert.addButton(withTitle: String(localized: "언어 설정 열기"))
            alert.addButton(withTitle: String(localized: "닫기"))
        }
        // 이 창에 붙는 시트로 띄운다. 앱 전체를 막는 대화상자로 띄우면 다른 문서도 못 쓰고, 어느 문서의
        // 번역이 실패했는지도 알 수 없다.
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard offersSettings, response == .alertFirstButtonReturn else { return }
            Self.openLanguageSettings()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private static func openLanguageSettings() {
        // '언어 및 지역' 화면. 이 식별자는 이 Mac의
        // `/System/Library/ExtensionKit/Extensions/Localization.appex`와 같은 값이다.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")
        else { return }
        if !NSWorkspace.shared.open(url) {
            // 열지 못하면 길을 글로 남긴다 — 버튼을 눌렀는데 아무 일도 없는 것이
            // 가장 나쁘다.
            AppLog.warning(String(localized: "언어 설정을 열지 못했습니다"),
                           detail: String(localized: "시스템 설정 ▸ 일반 ▸ 언어 및 지역 ▸ 번역 언어"))
        }
    }

    /// 잘 된 일을 알린다. **가로막지 않는다** — 떠서 보이고 사라지며, 같은 내용이
    /// 기록에 남으므로 놓쳐도 다시 볼 수 있다.
    private func report(_ message: String) {
        AppLog.info(message)
        statusOverlay.show(message)
    }

    /// 잘 안 된 일 중 작업을 멈출 정도는 아닌 것. 기록에 남기고 떠서 알린다.
    private func reportWarning(_ message: String, detail: String? = nil) {
        AppLog.warning(message, detail: detail)
        statusOverlay.show(message)
    }

    /// 그림을 문서 안에 박아 **단일 파일**로 내보낸다.
    ///
    /// 원래 문서를 덮어쓰지 않는다. 포함시키면 파일이 몇 배로 커지고 `data:` 주소는
    /// 사람이 읽기 어려우므로, 원본은 그대로 두고 별도 파일을 만든다.
    @objc func exportWithImagesAction(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        let base = (markdownDocument?.displayName as NSString?)?.deletingPathExtension ?? String(localized: "문서")
        panel.nameFieldStringValue = String(localized: "\(base)-이미지포함.md")
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "내보내기")

        let source = composedMarkdown()
        let documentURL = markdownDocument?.fileURL

        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }

            let outcome = ImageEmbedder.embed(in: source, documentURL: documentURL) { imageURL in
                try? Data(contentsOf: imageURL)
            }
            do {
                try outcome.markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                AppLog.error(String(localized: "이미지 포함 내보내기에 실패했습니다"),
                             detail: "\(url.path) — \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = String(localized: "이미지 포함 내보내기에 실패했습니다")
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }

            // 건너뛴 것을 **하나하나** 기록에 남긴다. 숫자만 알려 주면 어느 그림이
            // 왜 빠졌는지 알 수 없어 사용자가 파일을 하나씩 열어 봐야 한다.
            for skip in outcome.skipped {
                AppLog.warning(String(localized: "그림을 포함하지 못했습니다: \(skip.reason.message)"),
                               detail: skip.path)
            }
            AppLog.info(String(localized: "이미지 포함으로 내보냈습니다"),
                        detail: String(localized: "그림 \(outcome.embedded)개 포함, \(outcome.skipped.count)개 건너뜀 · \(url.path)"))
            self.report(outcome.skipped.isEmpty
                        ? String(localized: "그림 \(outcome.embedded)개를 포함해 내보냈습니다")
                        : String(localized: "그림 \(outcome.embedded)개 포함, \(outcome.skipped.count)개 건너뜀 (기록 참조)"))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsPanel == nil {
            settingsPanel = makeSettingsPanel(preferences)
        }
        settingsPanel?.showWindow(nil)
        settingsPanel?.window?.makeKeyAndOrderFront(nil)
    }

    /// 보기 ▸ 테마 ▸ … — 문서 색 테마를 바꾼다. 항목의 `representedObject`가 테마의 raw 값이다.
    /// 모든 창과 열린 설정 창이 따라온다(`PreferenceStore.didChange`).
    @objc func chooseColorThemeAction(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let theme = EditorPreferences.ColorTheme(rawValue: raw) else { return }
        var changed = preferences.current
        guard changed.colorTheme != theme else { return }
        changed.colorTheme = theme
        preferences.save(changed)
        if let main = NSApp.mainMenu { AppMenu.markColorTheme(theme, in: main) }
        NotificationCenter.default.post(name: PreferenceStore.didChange, object: nil)
    }

    /// 보기 ▸ 글꼴… — 설정의 '글꼴' 탭을 연다.
    @objc func showFontSettings(_ sender: Any?) {
        showSettings(sender)
        settingsPanel?.selectTab(SettingsPanel.fontTab)
    }

    /// 설정이 바뀌면 이 창에 바로 싣는다. 창마다 따로 받으므로 여러 창이 함께 바뀐다.
    /// 새 창의 보기 초깃값을 설정에서 가져온다. **창을 세울 때 한 번만** 읽는다 —
    /// 설정이 바뀔 때마다 싣으면 지금 ⌘E로 바꿔 둔 보기를 설정이 되돌려 버린다.
    ///
    /// 이 배선이 없던 동안 `openInCodeView`는 **아무 일도 하지 않는 설정**이었다
    /// (읽는 곳이 0곳). 이 프로젝트가 스스로 금지한 것이고, 설정 화면에 켜고 끌 수
    /// 있는 것이 있는데 아무 일도 안 일어나면 사용자는 자기 잘못을 찾느라 시간을 버린다.
    @objc private func preferencesDidChange(_ note: Notification) {
        editor.apply(preferences.current)
        sideBySide?.pane.editor.apply(preferences.current)
    }

    /// 블록 편집기를 띄운다 — 설계의 단계 1.
    ///
    /// 기본 편집기는 건드리지 않는다(설계 §8). 블록 창의 편집은 이 창의 편집기에
    /// 그대로 실리므로 저장·⌘S·편집 표시는 평소처럼 `NSDocument`가 맡는다.
    /// 반대 방향으로 따라오지는 않는다 — 그 한계는 블록 창의 주석과 TODO에 적혀 있다.
    @objc func showBlockEditor(_ sender: Any?) {
        if let existing = blockEditorWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = BlockEditorWindowController(
            body: editor.markdown,
            documentURL: markdownDocument?.fileURL,
            preferences: preferences.current,
            title: markdownDocument?.displayName ?? String(localized: "무제"))
        controller.onBodyChange = { [weak self] body in
            guard let self else { return }
            self.editor.markdown = body
            self.markdownDocument?.editorDidChange(markdown: self.composedMarkdown())
            self.refreshOutline()
        }
        controller.onLinkClick = { [weak self] url in
            guard let self else { return }
            self.markdownEditor(self.editor, didClickLink: url)
        }
        blockEditorWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppLog.shared.append(.info, String(localized: "블록 편집기를 열었습니다"),
                             detail: String(localized: "설계 단계 1 · 표는 아직 글입니다"))
    }

    @objc func showActivityLog(_ sender: Any?) {        if logPanel == nil {
            let panel = ActivityLogPanel(log: AppLog.shared)
            logPanel = panel
            // 기록이 바뀌면 열려 있는 창이 따라오게 한다.
            AppLog.onChange = { [weak panel] in panel?.reload() }
        }
        logPanel?.reload()
        logPanel?.showWindow(nil)
        logPanel?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Search

    private func runSearch(_ query: String) {
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let matches = self.editor.applySearch(query: query)
            self.updateMatchLabel(count: matches.count, query: query)
            if let first = matches.first { self.editor.reveal(first) }
        }
        searchDebounce = work
        let delay = DocumentSearch.debounce(forDocumentLength: editor.markdown.utf16.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateMatchLabel(count: Int, query: String) {
        if DocumentSearch.normalize(query).isEmpty {
            matchLabel.stringValue = ""
        } else if count == 0 {
            matchLabel.stringValue = String(localized: "일치 없음")
        } else {
            matchLabel.stringValue = "\((editor.currentSearchMatch ?? 0) + 1) / \(count)"
        }
    }

    @objc func findNext(_ sender: Any?) {
        editor.stepSearch(forward: true)
        updateMatchLabel(count: editor.searchMatchCount, query: searchField.stringValue)
    }

    @objc func findPrevious(_ sender: Any?) {
        editor.stepSearch(forward: false)
        updateMatchLabel(count: editor.searchMatchCount, query: searchField.stringValue)
    }
}

// MARK: - Toolbar

extension DocumentWindowController: NSToolbarDelegate {
    /// 차례 — 제목 옆에 **사이드바** 묶음(목차 · 폴더 · 최근), 오른쪽에 찾기와 **보기** 묶음(원본 보기 · 나란히
    /// 번역), 맨 오른쪽에 **버거 메뉴**(메뉴 바와 같은 메뉴 · 설정).
    ///
    /// 2026-11-07에 두 번 고쳤다. 처음에는 단추 일곱이 따로 놓여 사이드바 셋이 두 곳에 갈렸고, 폴더 아이콘이
    /// '문서 열기'였다(이름을 붙이고 묶어 고쳤다). 그 뒤 "아이콘 디자인이 마음에 안 든다"(사용자) — 칸마다 따로
    /// 둥근 테두리가 생기고 '열기'만 테두리가 없어 제각각이었다. 시스템 분할 단추 둘로 바꾸고 '열기'는 뺐다
    /// (`⌘O`, 파일 메뉴, 빠른 열기 `⌥⌘O`가 있다).
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // 사이드바 위에 세우는 칸막이(`sidebarTrackingSeparator`)는 쓰지 않는다. 써 보니(실측) 사이드바를 열면 그 폭
        // (204pt)에 창 단추와 제목까지 들어가 묶음이 빈 펼침 단추로 접혔고, 닫혀 있을 때는 세로 줄만 남았다.
        [ItemID.sidebar, .flexibleSpace, ItemID.matches, ItemID.search, ItemID.view, ItemID.menu]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case ItemID.search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField = searchField
            item.resignsFirstResponderWithCancel = true
            item.preferredWidthForSearchField = 220
            item.label = String(localized: "검색")
            item.toolTip = String(localized: "문서 내 검색 (⌘F)")
            return item

        case ItemID.matches:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = matchLabel
            // 이름을 적지 않는다 — 찾는 동안에만 `3/12`가 뜨는 자리라, 이름만 남으면 빈 단추처럼 보인다.
            item.label = ""
            item.paletteLabel = String(localized: "일치")
            item.visibilityPriority = .low
            return item

        case ItemID.sidebar:
            // 사이드바 셋을 **한 덩이**로 — 목차 · 폴더 · 최근. 창 왼쪽(제목 옆)에 두어 왼쪽 사이드바를 연다는
            // 것을 자리로 알린다. 칸 차례와 이름은 사이드바 탭과 같다. 누르면 그 탭이 열리고, 눌린 칸을 다시
            // 누르면 닫힌다.
            let group = segmentedGroup(identifier, label: String(localized: "사이드바"), parts: [
                ("list.bullet.indent", String(localized: "목차"),
                 String(localized: "사이드바에 목차 (⌘⇧O) — 다시 누르면 닫습니다")),
                ("folder", String(localized: "폴더"),
                 String(localized: "사이드바에 이 문서의 폴더 (⌘⇧F) — 다시 누르면 닫습니다")),
                ("clock", String(localized: "최근"),
                 String(localized: "사이드바에 최근 문서 (⌘⇧R) — 다시 누르면 닫습니다")),
            ], action: #selector(sidebarGroupClicked(_:)))
            sidebarGroup = group
            updateToggleStates()
            return group

        case ItemID.view:
            // 보기 둘 — 원본 보기 · 나란히 번역. 각각 켜고 끄며, 눌린 칸이 지금 보기다. 나란히 번역의
            // 아이콘은 번역 기호다 — 전의 '두 칸 사각형'으로는 무엇을 나란히 보는지 알 수 없었다.
            let group = segmentedGroup(identifier, label: String(localized: "보기"), parts: [
                ("chevron.left.forwardslash.chevron.right", String(localized: "원본 보기"),
                 Self.codeViewTip(isOn: editor.isCodeView)),
                ("translate", String(localized: "나란히 번역"), Self.sideBySideTip(isOn: sideBySide != nil)),
            ], action: #selector(viewGroupClicked(_:)))
            viewGroup = group
            syncCodeViewState()
            syncSideBySideState()
            return group

        case ItemID.menu:
            // 맨 오른쪽의 버거 메뉴 — 메뉴 바와 같은 메뉴(파일 · 편집 · 보기 · 도구 · 윈도우)와 설정. 내용은 열 때마다
            // 메뉴 바에서 옮겨 싣는다(`AppMenu.burgerItems`). 펼침 화살표는 달지 않는다(아이콘이 이미 메뉴다).
            let label = String(localized: "메뉴")
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: label)
            item.label = label
            item.paletteLabel = label
            item.toolTip = String(localized: "메뉴 바와 같은 메뉴 · 설정")
            item.showsIndicator = false
            let menu = NSMenu(title: label)
            menu.delegate = burgerFeeder
            item.menu = menu
            burgerItem = item
            return item

        default:
            return nil
        }
    }

    /// 아이콘 칸 여럿을 한 덩이로 — 시스템이 그리는 분할 단추(`NSToolbarItemGroup`)다. 전에는 칸마다 직접 만든
    /// 단추(`NSButton`)를 끼워 넣어, macOS 26 도구 막대에서 칸마다 따로 둥근 테두리가 생기고 '열기'만 테두리가
    /// 없어 모양이 제각각이었다. 시스템 단추는 다른 macOS 앱과 같은 모양·크기·눌린 표시를 받는다.
    ///
    /// 여러 칸이 눌릴 수 있는 꼴(`selectAny`)로 두고, 눌린 칸은 이 창이 지금 상태로 싣는다.
    private func segmentedGroup(_ identifier: NSToolbarItem.Identifier, label: String,
                                parts: [(symbol: String, label: String, tip: String)],
                                action: Selector) -> NSToolbarItemGroup {
        let images = parts.map { part in
            NSImage(systemSymbolName: part.symbol, accessibilityDescription: part.label) ?? NSImage()
        }
        let group = NSToolbarItemGroup(itemIdentifier: identifier, images: images, selectionMode: .selectAny,
                                       labels: parts.map(\.label), target: self, action: action)
        group.label = label
        group.paletteLabel = label
        for (item, part) in zip(group.subitems, parts) {
            item.toolTip = part.tip
            item.paletteLabel = part.label
        }
        return group
    }
}

extension DocumentWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        updateToggleStates()
    }
}

// MARK: - Editor and panel delegates

extension DocumentWindowController: MarkdownEditorDelegate {

    func markdownEditorDidChangeText(_ editor: MarkdownEditorView) {
        markdownDocument?.editorDidChange(markdown: composedMarkdown())
        refreshOutline()
        sideBySide?.sourceTextDidChange()
    }

    func markdownEditor(_ editor: MarkdownEditorView, didClickLink url: String) {
        if let resolved = URL(string: url), resolved.scheme != nil {
            NSWorkspace.shared.open(resolved)
            return
        }
        guard let base = markdownDocument?.fileURL?.deletingLastPathComponent() else { return }
        let target = base.appendingPathComponent(url)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        open(target)
    }

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
}

extension DocumentWindowController: OutlinePanelDelegate {
    func outlinePanel(_ panel: OutlinePanelView, didSelect entry: OutlineEntry) {
        editor.moveCaret(to: entry.range)
        window?.makeFirstResponder(editor.textView)
    }
}

extension DocumentWindowController: FileBrowserPanelDelegate {
    func fileBrowserPanel(_ panel: FileBrowserPanelView, didOpen url: URL) {
        open(url)
    }
}

extension DocumentWindowController: RecentDocumentsPanelDelegate {
    func recentDocumentsPanel(_ panel: RecentDocumentsPanelView, didOpen url: URL) {
        open(url)
    }
}

extension DocumentWindowController: NSSearchFieldDelegate {

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            findNext(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            searchField.stringValue = ""
            editor.clearSearch()
            matchLabel.stringValue = ""
            window?.makeFirstResponder(editor.textView)
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        runSearch(searchField.stringValue)
    }
}
