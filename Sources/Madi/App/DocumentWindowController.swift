import AppKit

@MainActor
final class DocumentWindowController: NSWindowController {

    private let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 760, height: 620))
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
    private var settingsPanel: SettingsPanel?
    /// 블록 편집기 창(설계 단계 1). 기본 편집기는 그대로 두고 평가용으로 띄운다.
    private var blockEditorWindow: BlockEditorWindowController?
    private let preferences = PreferenceStore()

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
        static let outline = NSToolbarItem.Identifier("outline")
        static let recent = NSToolbarItem.Identifier("recent")
        static let open = NSToolbarItem.Identifier("open")
        static let browser = NSToolbarItem.Identifier("browser")
        static let codeView = NSToolbarItem.Identifier("codeView")
        static let burger = NSToolbarItem.Identifier("burger")
    }

    private var toggleButtons: [Tab: NSButton] = [:]
    /// 원본 보기 토글. 사이드바 탭과 달리 `Tab`에 묶이지 않으므로 따로 들고 있는다.
    private weak var codeViewButton: NSButton?

    convenience init() {
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
        build()
    }

    // MARK: Build

    private func build() {
        editor.editorDelegate = self
        outlinePanel.delegate = self
        browserPanel.delegate = self
        recentPanel.delegate = self

        for (identifier, label, view) in [
            ("outline", "목차", outlinePanel as NSView),
            ("browser", "폴더", browserPanel as NSView),
            ("recent", "최근", recentPanel as NSView),
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

        // The card sits above the editor and is the document's header, not part
        // of the text. A vertical NSStackView does NOT stretch a child that has
        // its own intrinsic width — the card ended up hugging its content on
        // the right — so both children get explicit width constraints.
        let documentArea = NSStackView(views: [frontMatterCard, editor])
        documentArea.orientation = .vertical
        documentArea.alignment = .leading
        documentArea.spacing = 0
        documentArea.detachesHiddenViews = true
        documentArea.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        frontMatterCard.isHidden = true
        frontMatterCard.onToggle = { [weak documentArea] in documentArea?.needsLayout = true }

        NSLayoutConstraint.activate([
            frontMatterCard.leadingAnchor.constraint(equalTo: documentArea.leadingAnchor, constant: 24),
            frontMatterCard.trailingAnchor.constraint(equalTo: documentArea.trailingAnchor, constant: -24),
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
        documentArea.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(documentArea)
        editorContainer.addSubview(statusOverlay)
        NSLayoutConstraint.activate([
            documentArea.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            documentArea.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            documentArea.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            documentArea.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),

            statusOverlay.centerXAnchor.constraint(equalTo: editorContainer.centerXAnchor),
            statusOverlay.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor,
                                                  constant: -22),
            statusOverlay.widthAnchor.constraint(lessThanOrEqualTo: editorContainer.widthAnchor,
                                                 constant: -48),
        ])
        editorController.view = editorContainer
        // Assigning contentViewController resizes the window to the content's
        // FITTING size. The editor has no intrinsic size, so that came out a
        // 520x380 sliver regardless of the window's contentRect. Declaring a
        // preferred size is the fix that does not fight window restoration: a
        // frame the user has sized and the system restored still wins later.
        editorController.preferredContentSize = NSSize(width: 860, height: 700)

        splitController = NSSplitViewController()
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 380
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = true
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: editorController))
        window?.contentViewController = splitController
        // 이름이 Md → Madi로 바뀌어도 이 문자열은 그대로 둔다. 자동 저장 이름과
        // 도구 막대 식별자는 **저장된 상태를 찾는 열쇠**이고 사람이 읽는 이름이
        // 아니다. 바꾸면 기존 사용자의 창 위치·크기와 도구 막대 구성이 한 번
        // 사라진다. 번들 식별자를 그대로 둔 것과 같은 이유다.
        window?.setFrameAutosaveName("MdDocumentWindow")

        matchLabel.font = .systemFont(ofSize: 11)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.alignment = .right

        searchField.placeholderString = "문서 내 검색"
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.delegate = self

        let toolbar = NSToolbar(identifier: "MdToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
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
    }

    // MARK: Document content

    func load(markdown: String) {
        let parsed = FrontMatter.parse(markdown)
        frontMatter = parsed
        frontMatterCard.update(with: parsed)
        editor.markdown = parsed?.body ?? markdown
        refreshOutline()
        browserPanel.show(folderOf: markdownDocument?.fileURL)
        recentPanel.reload()
        window?.title = markdownDocument?.displayName ?? "제목 없음"
        editor.documentURL = markdownDocument?.fileURL
        editor.apply(preferences.current)
        AppLog.info("문서를 열었습니다: \(markdownDocument?.displayName ?? "제목 없음")",
                    detail: "\(markdown.count)자")
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
        // The animation finishes after this turn, so read the target state.
        DispatchQueue.main.async { [weak self] in self?.updateToggleStates() }
    }

    /// Mark.app's toolbar reports panel state: 목차 / 최근 문서 / 파일 브라우저 are
    /// toggles, not momentary buttons, so the user can see what is open.
    private func updateToggleStates() {
        let open = !sidebarItem.isCollapsed
        let selected = sidebarTabs.selectedTabViewItem
            .map { sidebarTabs.indexOfTabViewItem($0) } ?? -1
        for (tab, button) in toggleButtons {
            button.state = (open && selected == tab.rawValue) ? .on : .off
        }
    }

    // MARK: Actions

    @objc func showOutlineAction(_ sender: Any?) { show(.outline) }
    @objc func showBrowserAction(_ sender: Any?) { show(.browser) }
    @objc func showRecentAction(_ sender: Any?) { show(.recent) }

    @objc func focusSearchAction(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    @objc func openDocumentAction(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
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
        window?.subtitle = isOn ? "원본 보기" : ""
        codeViewButton?.state = isOn ? .on : .off
        codeViewButton?.toolTip = Self.codeViewTip(isOn: isOn)
        if let main = NSApp.mainMenu { Self.markCodeView(in: main, isOn: isOn) }
    }

    /// 메뉴 항목에 체크 표시를 단다 — 토글의 macOS 관례다.
    ///
    /// **`validateMenuItem`으로 하지 않는다.** 한 번 그렇게 했다가 회귀를 냈다:
    /// `NSMenuItemValidation`을 구현하면 이 객체로 **오는 모든 항목**을 내가 판정하게
    /// 되고, 내가 응답하지 않는 동작(`save:` · `performClose:`)에 false를 돌려
    /// 버거 메뉴의 저장·다른 이름으로 저장·닫기가 비활성이 됐다. 체크 표시 하나를
    /// 붙이려고 메뉴 활성화 규칙 전체를 떠안을 이유가 없다.
    static func markCodeView(in menu: NSMenu, isOn: Bool) {
        for item in menu.items {
            if item.action == #selector(DocumentWindowController.toggleCodeViewAction(_:)) {
                item.state = isOn ? .on : .off
            }
            if let submenu = item.submenu { markCodeView(in: submenu, isOn: isOn) }
        }
    }

    /// 도움말은 **누르면 무엇이 되는지**를 말한다. 지금 상태를 말하면 사용자가
    /// 누를지 말지를 그 문장에서 알 수 없다.
    private static func codeViewTip(isOn: Bool) -> String {
        isOn ? "마크다운 문법으로 보기 (⌘E)" : "마크다운 원본 보기 (⌘E)"
    }

    @objc func showBurgerAction(_ sender: Any?) {
        let menu = AppMenu.burgerMenu(target: self)
        // 버거 메뉴는 열 때마다 새로 만들어지므로 여기서 체크 표시를 단다.
        Self.markCodeView(in: menu, isOn: editor.isCodeView)
        guard let view = (sender as? NSView) ?? (sender as? NSToolbarItem)?.view else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    // MARK: Print and PDF

    /// 프린트와 PDF 내보내기가 **같은 설정**을 쓴다. 설정 하나가 양쪽에 걸리는 것이
    /// 맞다 — 화면에 보이는 것을 종이에 내든 파일에 내든 같은 쪽이어야 한다.
    private func printInfo(forPDF pdfURL: URL?) -> NSPrintInfo {
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
        operation.jobTitle = markdownDocument?.displayName ?? "문서"
        operation.runModal(for: window!, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// PDF 내보내기 — prints to a file instead of a printer, so the PDF matches
    /// exactly what the editor draws (hidden markers included).
    @objc func exportPDFAction(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (markdownDocument?.displayName as NSString?)?
            .deletingPathExtension.appending(".pdf") ?? "문서.pdf"
        panel.canCreateDirectories = true
        panel.prompt = "내보내기"

        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let operation = NSPrintOperation(view: self.editor.printableView,
                                             printInfo: self.printInfo(forPDF: url))
            operation.jobTitle = self.markdownDocument?.displayName ?? "문서"
            operation.showsPrintPanel = false
            operation.showsProgressPanel = true
            if operation.run() {
                AppLog.info("PDF로 내보냈습니다", detail: url.path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                AppLog.error("PDF 내보내기에 실패했습니다", detail: url.path)
                let alert = NSAlert()
                alert.messageText = "PDF 내보내기에 실패했습니다"
                alert.informativeText = url.path
                alert.runModal()
            }
        }
    }

    // MARK: Translation

    private var translationTask: Task<Void, Never>?

    /// 번역. 선택이 있으면 **그 자리에서** 바꾸고(되돌리기로 취소 가능), 선택이 없으면
    /// 문서 전체를 번역해 **새 문서**로 연다 — 원본을 건드리지 않는 쪽이 안전하다.
    ///
    /// 마크업은 번역기에 넘기지 않는다(`MarkdownTranslationPlan`). 코드 블록·인라인 코드·
    /// 링크 URL·표 구분선·마커는 그대로 남고 본문 조각만 번역된다.
    @objc func translateAction(_ sender: Any?) {
        guard #available(macOS 26.0, *) else {
            report("Apple 번역은 macOS 26 이상에서만 됩니다.")
            return
        }
        guard translationTask == nil else {
            report("번역이 이미 진행 중입니다.")
            return
        }

        let selection = editor.textView.selectedRange()
        let inPlace = selection.length > 0
        let source = inPlace
            ? (editor.markdown as NSString).substring(with: selection)
            : editor.markdown
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report("번역할 글이 없습니다.")
            return
        }

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
            let preflight = await AppleTranslator.preflight(markdown: source)
            guard let self else { return }
            guard preflight.state == .ready else {
                self.translationTask = nil
                let failure: AppleTranslator.Failure
                switch preflight.state {
                case .nothingToTranslate: failure = .nothingToTranslate
                case .needsLanguagePack: failure = .languagePackMissing(direction: preflight.direction)
                case .unsupported: failure = .unsupported(direction: preflight.direction)
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
                let result = try await AppleTranslator.translate(preflight, progress: onProgress)
                if inPlace {
                    self.replaceSelection(selection, with: result.text)
                    self.report("번역했습니다 (\(result.direction.label))")
                } else {
                    self.openTranslatedCopy(result.text, direction: result.direction)
                }
            } catch is CancellationError {
                // 사용자가 취소한 것이다. 알릴 것이 없다.
            } catch {
                self.presentTranslationFailure(error)
            }
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

    private func openTranslatedCopy(_ text: String, direction: TranslationDirection) {
        let controller = NSDocumentController.shared
        do {
            guard let document = try controller.openUntitledDocumentAndDisplay(true) as? MarkdownDocument else {
                report("번역 결과를 새 문서로 열지 못했습니다.")
                return
            }
            // front matter는 원본 블록을 그대로 앞에 둔다 — 메타데이터를 번역하면
            // slug·date·layout 같은 값이 망가진다.
            let composed = frontMatter.map { $0.joined(withBody: text) } ?? text
            document.markdown = composed
            document.updateChangeCount(.changeDone)
            (document.windowControllers.first as? DocumentWindowController)?.load(markdown: composed)
            report("번역본을 새 문서로 열었습니다 (\(direction.label))")
        } catch {
            NSApp.presentError(error)
        }
    }

    private func presentTranslationFailure(_ error: Error) {
        // 실패는 **두 곳에** 남는다. 경고창은 지금 알리기 위한 것이고, 기록은 나중에
        // 다시 볼 수 있게 하기 위한 것이다. 경고창만 띄우면 닫는 순간 사라진다.
        AppLog.error("번역하지 못했습니다", detail: error.localizedDescription)

        let alert = NSAlert()
        // 무엇이 잘못됐는지와 **무엇을 해야 하는지**를 가른다. 경고창이 둘을 다른
        // 크기로 그리므로, 한 덩이로 적으면 할 일이 원인 문장에 묻힌다.
        //
        // `AppleTranslator`가 macOS 26 전용이라 그 아래에서는 분해할 수 없다 —
        // 그때는 받은 오류 문구를 그대로 보인다(그 경로는 "macOS 26 이상에서만
        // 됩니다"를 먼저 띄우므로 여기까지 오지 않는다).
        var cause = "번역하지 못했습니다"
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

        guard offersSettings else {
            alert.runModal()
            return
        }
        alert.addButton(withTitle: "언어 설정 열기")
        alert.addButton(withTitle: "닫기")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // '언어 및 지역' 화면. 이 식별자는 이 Mac의
        // `/System/Library/ExtensionKit/Extensions/Localization.appex`와 같은 값이다.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")
        else { return }
        if !NSWorkspace.shared.open(url) {
            // 열지 못하면 길을 글로 남긴다 — 버튼을 눌렀는데 아무 일도 없는 것이
            // 가장 나쁘다.
            AppLog.warning("언어 설정을 열지 못했습니다",
                           detail: "시스템 설정 ▸ 일반 ▸ 언어 및 지역 ▸ 번역 언어")
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
        let base = (markdownDocument?.displayName as NSString?)?.deletingPathExtension ?? "문서"
        panel.nameFieldStringValue = "\(base)-이미지포함.md"
        panel.canCreateDirectories = true
        panel.prompt = "내보내기"

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
                AppLog.error("이미지 포함 내보내기에 실패했습니다",
                             detail: "\(url.path) — \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "이미지 포함 내보내기에 실패했습니다"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }

            // 건너뛴 것을 **하나하나** 기록에 남긴다. 숫자만 알려 주면 어느 그림이
            // 왜 빠졌는지 알 수 없어 사용자가 파일을 하나씩 열어 봐야 한다.
            for skip in outcome.skipped {
                AppLog.warning("그림을 포함하지 못했습니다: \(skip.reason.message)",
                               detail: skip.path)
            }
            AppLog.info("이미지 포함으로 내보냈습니다",
                        detail: "그림 \(outcome.embedded)개 포함, \(outcome.skipped.count)개 건너뜀 · \(url.path)")
            self.report(outcome.skipped.isEmpty
                        ? "그림 \(outcome.embedded)개를 포함해 내보냈습니다"
                        : "그림 \(outcome.embedded)개 포함, \(outcome.skipped.count)개 건너뜀 (기록 참조)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsPanel == nil {
            settingsPanel = SettingsPanel(store: preferences)
        }
        settingsPanel?.showWindow(nil)
        settingsPanel?.window?.makeKeyAndOrderFront(nil)
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
            title: markdownDocument?.displayName ?? "무제")
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
        AppLog.shared.append(.info, "블록 편집기를 열었습니다",
                             detail: "설계 단계 1 · 표는 아직 글입니다")
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
            matchLabel.stringValue = "일치 없음"
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
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ItemID.matches, ItemID.search, ItemID.codeView, ItemID.outline,
         ItemID.recent, ItemID.open, ItemID.browser, .space, ItemID.burger]
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
            item.label = "검색"
            item.toolTip = "문서 내 검색 (⌘F)"
            return item

        case ItemID.matches:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = matchLabel
            item.label = "일치"
            item.visibilityPriority = .low
            return item

        case ItemID.outline:
            return toggle(identifier, tab: .outline, symbol: "list.bullet.indent",
                          label: "목차", tip: "목차 (⌘⇧O)", action: #selector(showOutlineAction(_:)))

        case ItemID.recent:
            return toggle(identifier, tab: .recent, symbol: "clock.arrow.circlepath",
                          label: "최근 문서", tip: "최근 문서 (⌘⇧R)", action: #selector(showRecentAction(_:)))

        case ItemID.browser:
            return toggle(identifier, tab: .browser, symbol: "sidebar.left",
                          label: "파일 브라우저", tip: "파일 브라우저 (⌘⇧F)",
                          action: #selector(showBrowserAction(_:)))

        case ItemID.codeView:
            // 켜짐/꺼짐이 곧 어느 보기인지다. 도구 막대의 다른 토글과 같은 꼴이어서
            // 눌린 모양이 상태를 말한다 — 메뉴 명령만 있던 때는 창 부제를 읽어야
            // 알 수 있었다.
            let item = NSToolbarItem(itemIdentifier: identifier)
            let control = button(symbol: "chevron.left.forwardslash.chevron.right",
                                 label: "원본 보기", tip: Self.codeViewTip(isOn: false),
                                 action: #selector(toggleCodeViewAction(_:)))
            control.setButtonType(.pushOnPushOff)
            control.state = editor.isCodeView ? .on : .off
            item.view = control
            item.label = "원본 보기"
            item.paletteLabel = "원본 보기"
            item.toolTip = Self.codeViewTip(isOn: editor.isCodeView)
            codeViewButton = control
            return item

        case ItemID.open:
            return push(identifier, symbol: "folder", label: "문서 열기",
                        tip: "문서 열기 (⌘O)", action: #selector(openDocumentAction(_:)))

        case ItemID.burger:
            return push(identifier, symbol: "line.3.horizontal", label: "더 많은 작업",
                        tip: "더 많은 작업", action: #selector(showBurgerAction(_:)))

        default:
            return nil
        }
    }

    private func button(symbol: String, label: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.target = self
        button.action = action
        button.toolTip = tip
        button.setAccessibilityLabel(label)
        return button
    }

    private func push(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String,
                      tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let control = button(symbol: symbol, label: label, tip: tip, action: action)
        control.isBordered = false
        item.view = control
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        return item
    }

    /// A toggle, so the toolbar shows which panel is open.
    private func toggle(_ identifier: NSToolbarItem.Identifier, tab: Tab, symbol: String,
                        label: String, tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let control = button(symbol: symbol, label: label, tip: tip, action: action)
        control.setButtonType(.pushOnPushOff)
        control.state = .off
        item.view = control
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        toggleButtons[tab] = control
        return item
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
