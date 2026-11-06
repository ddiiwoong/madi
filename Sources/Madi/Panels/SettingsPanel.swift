import AppKit

/// 설정 창.
///
/// 항목을 고를 때 지킨 규칙이 하나 있다 — **아무 일도 하지 않는 설정은 넣지 않는다.**
/// 여기의 전부가 실제 코드 경로에 닿는다(보기 항목은 테마와 스타일러의 각 패스,
/// 프린트 항목은 `NSPrintInfo`, 파일 연결은 `NSWorkspace`). 설정 화면이 허울이면
/// 사용자는 자기가 무엇을 잘못했는지 찾느라 시간을 버린다.
///
/// 탭으로 가른 이유: 항목이 열두 개가 되어 한 판에 담으면 읽히지 않는다. 각 탭 머리에
/// 그 탭이 무엇을 바꾸는지 한 줄을 적는다 — 보기 설정이 문서를 고치지 않는다는 사실은
/// 말해 주지 않으면 알 수 없다.
///
/// 기록 패널과 같은 창 설정을 쓴다: `isReleasedWhenClosed`를 끄고(컨트롤러가 창을
/// 계속 들고 있으므로 닫은 뒤 다시 열 수 있어야 한다) 가운데로 옮긴다.
@MainActor
final class SettingsPanel: NSWindowController {

    private let store: PreferenceStore
    private var preferences: EditorPreferences

    // 보기
    private let sizeSlider = NSSlider()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let appearancePicker = NSPopUpButton()
    private let lineSpacingPicker = NSPopUpButton()
    private let widthPicker = NSPopUpButton()
    private let bodyFontPicker = NSPopUpButton()
    private let headingFontPicker = NSPopUpButton()
    private let codeFontPicker = NSPopUpButton()
    /// 고른 글꼴·크기·줄 간격으로 그린 미리보기. 실제 편집기라 문서 창과 같은 모양이다.
    let preview = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 420, height: 170))
    /// '받기…'를 골랐을 때 무엇을 열었는지 알린다.
    let fontNote = NSTextField(wrappingLabelWithString: "")
    /// 배포 페이지를 연다. 테스트가 바꾼다 — 브라우저를 띄우지 않게.
    private let openURL: (URL) -> Void
    /// 이 Mac의 패밀리(고정폭만이면 true). 테스트가 바꾼다 — 글꼴이 새로 설치된 것을 흉내 낸다.
    private let fontFamilies: (Bool) -> [String]
    /// 패밀리가 이 Mac에 있고 그 용도에 쓸 수 있는가.
    private let isFontUsable: (String, RecommendedFont.Use) -> Bool
    private var tabs: NSTabView?
    private let highlightCheck = NSButton(checkboxWithTitle: String(localized: "코드 블록 구문 강조"), target: nil, action: nil)
    private let alignCheck = NSButton(checkboxWithTitle: String(localized: "표 열 맞추기"), target: nil, action: nil)
    private let slantCheck = NSButton(checkboxWithTitle: String(localized: "한글·CJK 기울임 강제 적용"), target: nil, action: nil)
    private let codeViewCheck = NSButton(checkboxWithTitle: String(localized: "새 창을 마크다운 원본 보기로 열기"),
                                         target: nil, action: nil)

    // 일반
    private let remoteImageCheck = NSButton(checkboxWithTitle: String(localized: "원격 이미지 불러오기"),
                                            target: nil, action: nil)
    private let associationLabel = NSTextField(wrappingLabelWithString: "")
    private let associationButton = NSButton(title: String(localized: "마디 사용"), target: nil, action: nil)
    private let languagePicker = NSPopUpButton()
    /// 화면 언어는 편집기 설정이 아니라 앱 도메인의 `AppleLanguages`다(`InterfaceLanguage`).
    /// 테스트가 사용자의 실제 값을 건드리지 않도록 도메인을 주입받는다.
    private let languageDefaults: UserDefaults
    private let languageDomain: String?

    // AI 교정 — 키 두기와 확인
    private let servicePicker = NSPopUpButton()
    private let keyStatusLabel = NSTextField(labelWithString: "")
    private let keyField = NSSecureTextField()
    private let saveKeyButton = NSButton(title: String(localized: "키체인에 저장"), target: nil, action: nil)
    // 기록 창의 '지우기'(Clear)와 영어가 다르다(Remove Key) — 키를 따로 둔다.
    private let removeKeyButton = NSButton(title: String(localized: "llm.removeKey", defaultValue: "지우기"),
                                           target: nil, action: nil)
    private let regionRow = NSStackView()
    private let regionField = NSTextField()
    private let checkKeyButton = NSButton(title: String(localized: "키 확인"), target: nil, action: nil)
    private let checkResultLabel = NSTextField(wrappingLabelWithString: "")
    private let consoleLabel = NSTextField(labelWithString: "")
    private let secrets: SecretStore
    private let keyChecker: KeyChecking
    /// Bedrock 리전처럼 **비밀이 아닌** 값. 키는 여기 두지 않는다.
    private let llmDefaults: UserDefaults
    static let bedrockRegionKey = "llm.bedrock.region"

    // PDF·프린트
    private let paperPicker = NSPopUpButton()
    private let orientationPicker = NSPopUpButton()
    private let marginPicker = NSPopUpButton()

    private static let panelSize = NSSize(width: 500, height: 620)

    /// 글꼴 고르개의 '시스템' 항목에 다는 값. 패밀리 이름이 빈 문자열일 수는 없으므로
    /// 겹치지 않는다.
    static let systemFontTag = FontPickerMenu.systemTag

    /// 패밀리가 이 Mac에 있는가 — **이름으로 찾아** 본다. `availableFontFamilies`는 글꼴을 등록한 뒤
    /// 런루프가 한 번 돌아야 갱신된다(실측: 앱에 든 글꼴이 등록 직후에는 빠져 있었다). 코드는 고정폭만.
    static func isUsable(_ family: String, for use: RecommendedFont.Use) -> Bool {
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) else {
            return false
        }
        return use == .text || font.isFixedPitch
    }

    /// 이 Mac의 글꼴 패밀리. 코드 쪽은 **고정폭만** — 고정폭이 아니면 코드의 들여쓰기와
    /// 줄 맞춤이 어긋난다. (표 열 맞추기는 그 줄의 실제 글꼴로 폭을 재므로 이 제한의 이유가
    /// 아니다 — `MarkdownStyler.visibleWidth`.) 이름 순.
    static func installedFamilies(fixedPitchOnly: Bool) -> [String] {
        let manager = NSFontManager.shared
        let families = manager.availableFontFamilies.filter { !$0.hasPrefix(".") }
        guard fixedPitchOnly else { return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        return families.filter { family in
            manager.font(withFamily: family, traits: [], weight: 5, size: 13)?.isFixedPitch == true
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    init(store: PreferenceStore,
         languageDefaults: UserDefaults = .standard,
         languageDomain: String? = Bundle.main.bundleIdentifier,
         secrets: SecretStore = KeychainSecretStore.app,
         keyChecker: KeyChecking = LiveKeyChecker(),
         llmDefaults: UserDefaults = .standard,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         fontFamilies: @escaping (Bool) -> [String] = { SettingsPanel.installedFamilies(fixedPitchOnly: $0) },
         isFontUsable: @escaping (String, RecommendedFont.Use) -> Bool = { SettingsPanel.isUsable($0, for: $1) }) {
        self.store = store
        self.openURL = openURL
        self.fontFamilies = fontFamilies
        self.isFontUsable = isFontUsable
        self.preferences = store.current
        self.languageDefaults = languageDefaults
        self.languageDomain = languageDomain
        self.secrets = secrets
        self.keyChecker = keyChecker
        self.llmDefaults = llmDefaults
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = String(localized: "설정")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.contentViewController = makeContentController()
        // `contentViewController`를 넣으면 AppKit이 창을 콘텐츠의 fitting size로
        // 줄인다. 그래서 할당 뒤에 크기를 선언한다.
        panel.setContentSize(Self.panelSize)
        panel.center()
        load()
        // 설정은 이 창 밖에서도 바뀐다(⌘= · ⌘-). 열린 채로 낡은 값을 들고 있으면 다음에 다른
        // 항목을 고칠 때 **낡은 글자 크기를 다시 저장한다** — 모든 항목을 한 번에 저장하기 때문이다.
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChangedElsewhere(_:)),
                                               name: PreferenceStore.didChange, object: nil)
        // 글꼴을 설치·삭제하면 고르개를 다시 채운다 — '받기…'로 받아 설치한 글꼴이 창을 다시 열지
        // 않아도 바로 나온다.
        NotificationCenter.default.addObserver(self, selector: #selector(fontSetChanged(_:)),
                                               name: NSFont.fontSetChangedNotification, object: nil)
    }

    /// 목록은 알림 뒤 런루프가 한 번 돌아야 갱신된다(위 `isUsable`) — 다음 차례에 채운다.
    @objc func fontSetChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.reloadFonts() }
    }

    func reloadFonts() {
        MarkdownTheme.forgetResolvedFonts()
        refillFonts()
        load()
    }

    /// 탭을 고른다 — 보기 ▸ 글꼴…이 '글꼴' 탭을 연다.
    func selectTab(_ identifier: String) {
        tabs?.selectTabViewItem(withIdentifier: identifier)
    }

    static let fontTab = "font"
    var selectedTab: String? { tabs?.selectedTabViewItem?.identifier as? String }

    @objc private func preferencesChangedElsewhere(_ note: Notification) {
        guard (note.object as AnyObject?) !== self else { return }
        load()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // 파일 연결은 창 밖(시스템)에서 바뀔 수 있다 — 열 때마다 다시 읽는다.
        refreshAssociation()
    }

    // MARK: 화면 짓기

    private func makeContentController() -> NSViewController {
        let controller = NSViewController()
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab(Self.fontTab, String(localized: "글꼴"), view: makeFontTab()))
        tabs.addTabViewItem(tab("view", String(localized: "보기"), view: makeViewTab()))
        tabs.addTabViewItem(tab("general", String(localized: "일반"), view: makeGeneralTab()))
        tabs.addTabViewItem(tab("print", String(localized: "PDF·프린트"), view: makePrintTab()))
        tabs.addTabViewItem(tab("ai", String(localized: "AI 교정"), view: makeAITab()))
        tabs.addTabViewItem(tab("about", String(localized: "정보"), view: makeAboutTab()))
        self.tabs = tabs

        let reset = NSButton(title: String(localized: "기본값으로"), target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(tabs)
        root.addSubview(reset)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            reset.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            reset.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            tabs.bottomAnchor.constraint(equalTo: reset.topAnchor, constant: -10),
        ])
        controller.view = root
        controller.preferredContentSize = Self.panelSize
        return controller
    }

    private func tab(_ identifier: String, _ title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: identifier)
        item.label = title
        let holder = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 18),
            view.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -18),
            view.topAnchor.constraint(equalTo: holder.topAnchor, constant: 16),
        ])
        item.view = holder
        return item
    }

    /// 탭 머리의 설명 한 줄.
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 10
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        return stack
    }

    private func fill<T: RawRepresentable & CaseIterable>(
        _ picker: NSPopUpButton, _ cases: [T], label: (T) -> String
    ) where T.RawValue == String {
        picker.removeAllItems()
        for value in cases {
            picker.addItem(withTitle: label(value))
            // 열거형의 raw 값을 항목에 달아 둔다 — 순서가 아니라 값으로 읽으므로,
            // 나중에 항목을 더하거나 옮겨도 읽는 코드가 틀리지 않는다.
            picker.lastItem?.representedObject = value.rawValue
        }
        picker.target = self
        picker.action = #selector(changed)
    }

    /// 세 글꼴 고르개를 채운다(`FontPickerMenu`). 글꼴을 설치하면 다시 부른다.
    private func refillFonts() {
        let text = fontFamilies(false)
        FontPickerMenu.fill(bodyFontPicker, .init(use: .text, systemTitle: String(localized: "시스템 글꼴"),
                                                  families: text) { [isFontUsable] in isFontUsable($0, .text) })
        FontPickerMenu.fill(headingFontPicker, .init(use: .text, systemTitle: String(localized: "시스템 글꼴"),
                                                     includesSameAsBody: true,
                                                     families: text) { [isFontUsable] in isFontUsable($0, .text) })
        FontPickerMenu.fill(codeFontPicker, .init(use: .code, systemTitle: String(localized: "시스템 고정폭"),
                                                  families: fontFamilies(true)) { [isFontUsable] in
            isFontUsable($0, .code)
        })
        for picker in [bodyFontPicker, headingFontPicker, codeFontPicker] {
            picker.target = self
            picker.action = #selector(fontPicked(_:))
        }
    }

    /// 글꼴 고르개에서 골랐다. 아직 없는 추천 글꼴('받기…')이면 설정을 바꾸지 않고 배포 페이지를 연다.
    @objc func fontPicked(_ sender: NSPopUpButton) {
        guard let font = sender.selectedItem?.representedObject as? RecommendedFont,
              let page = font.downloadPage else {
            changed()
            return
        }
        let name = font.family
        openURL(page)
        selectFonts()
        fontNote.stringValue = String(localized: "‘\(name)’을 받는 곳을 열었습니다. 내려받아 설치하면 이 목록에 바로 나타납니다.")
        AppLog.info(String(localized: "글꼴 받는 곳을 열었습니다"), detail: "\(name) — \(page.absoluteString)")
    }

    /// 저장된 글꼴을 세 고르개에 싣는다.
    private func selectFonts() {
        selectFont(preferences.bodyFontFamily, in: bodyFontPicker)
        switch preferences.headingFont {
        case .sameAsBody: selectFont(FontPickerMenu.sameAsBodyTag, in: headingFontPicker)
        case .system: selectFont(nil, in: headingFontPicker)
        case let .family(name): selectFont(name, in: headingFontPicker)
        }
        selectFont(preferences.codeFontFamily, in: codeFontPicker)
    }

    /// 제목 고르개에서 고른 것.
    private func headingSelection() -> EditorPreferences.HeadingFont {
        guard let raw = headingFontPicker.selectedItem?.representedObject as? String,
              raw != FontPickerMenu.sameAsBodyTag else { return .sameAsBody }
        return EditorPreferences.family(raw).map(EditorPreferences.HeadingFont.family) ?? .system
    }

    /// 고른 패밀리. 시스템이면 nil.
    private func fontSelection(_ picker: NSPopUpButton) -> String? {
        EditorPreferences.family(picker.selectedItem?.representedObject as? String)
    }

    /// 저장된 패밀리를 고른다. 목록에 없으면(이 Mac에 없는 글꼴) 그 이름으로 항목을 하나
    /// 더해 고른다 — 시스템을 고른 것처럼 보이면 저장된 값과 화면이 다르게 말한다.
    private func selectFont(_ family: String?, in picker: NSPopUpButton) {
        let wanted = family ?? Self.systemFontTag
        if let index = picker.itemArray.firstIndex(where: { ($0.representedObject as? String) == wanted }) {
            picker.selectItem(at: index)
            return
        }
        picker.addItem(withTitle: String(localized: "\(wanted) (이 Mac에 없음)"))
        picker.lastItem?.representedObject = wanted
        picker.select(picker.lastItem)
    }

    private func selection<T: RawRepresentable>(_ picker: NSPopUpButton, _ fallback: T) -> T
    where T.RawValue == String {
        guard let raw = picker.selectedItem?.representedObject as? String,
              let value = T(rawValue: raw) else { return fallback }
        return value
    }

    private func select<T: RawRepresentable>(_ value: T, in picker: NSPopUpButton)
    where T.RawValue == String {
        let index = picker.itemArray.firstIndex {
            ($0.representedObject as? String) == value.rawValue
        }
        picker.selectItem(at: index ?? 0)
    }

    /// 글꼴 탭 — 본문 · 제목 · 코드 글꼴, 글자 크기, 미리보기.
    private func makeFontTab() -> NSView {
        sizeSlider.minValue = EditorPreferences.pointSizeRange.lowerBound
        sizeSlider.maxValue = EditorPreferences.pointSizeRange.upperBound
        sizeSlider.numberOfTickMarks = Int(EditorPreferences.pointSizeRange.upperBound
                                           - EditorPreferences.pointSizeRange.lowerBound) + 1
        sizeSlider.allowsTickMarkValuesOnly = true
        sizeSlider.target = self
        sizeSlider.action = #selector(changed)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor

        bodyFontPicker.identifier = NSUserInterfaceItemIdentifier("font.body")
        headingFontPicker.identifier = NSUserInterfaceItemIdentifier("font.heading")
        codeFontPicker.identifier = NSUserInterfaceItemIdentifier("font.code")
        refillFonts()

        let sizeRow = NSStackView(views: [sizeSlider, sizeLabel])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 10

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }
        let grid = NSGridView(views: [
            [label(String(localized: "본문")), bodyFontPicker],
            [label(String(localized: "제목")), headingFontPicker],
            [label(String(localized: "코드")), codeFontPicker],
            [label(String(localized: "크기")), sizeRow],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for picker in [bodyFontPicker, headingFontPicker, codeFontPicker] {
            picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        }

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.textView.isEditable = false
        preview.textView.isSelectable = false
        preview.showsVerticalScroller = false
        // 캐럿 줄의 마커도 숨긴다 — 미리보기에는 고칠 줄이 없다.
        preview.isRenderingForOutput = true
        preview.markdown = Self.previewMarkdown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = NSColor.separatorColor.cgColor
        preview.layer?.masksToBounds = true

        fontNote.font = .systemFont(ofSize: 11)
        fontNote.textColor = .secondaryLabelColor
        fontNote.stringValue = String(localized: "추천에서 ‘받기…’가 붙은 글꼴은 무료 배포처를 엽니다. 내려받아 설치하면 이 목록에 바로 나타납니다.")

        let stack = column([
            note(String(localized: "문서 내용은 바뀌지 않습니다. 고르는 대로 열린 창에 바로 보입니다.")),
            grid,
            note(String(localized: "⌘= · ⌘- · ⌘0으로도 크기를 바꿉니다. 제목 글꼴은 제목에만 쓰이고, 코드 글꼴은 고정폭만 고를 수 있습니다.")),
            preview,
            fontNote,
        ])
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            preview.heightAnchor.constraint(equalToConstant: 180),
            fontNote.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
        ])
        return stack
    }

    /// 미리보기 글. 제목 · 본문(굵게 · 기울임) · 인라인 코드가 스크롤 없이 한눈에 들어오게. 코드는
    /// 영문으로 둔다 — 고정폭 글꼴에는 한글이 없는 것이 많아 한글로 쓰면 코드 글꼴이 보이지 않는다.
    static var previewMarkdown: String {
        "## " + String(localized: "제목은 이렇게 보입니다") + "\n\n"
            + String(localized: "본문은 이렇게 보입니다. **굵게**와 *기울임*, 코드 `let title = 42`가 섞여도 한 줄로 읽힙니다.")
            + "\n"
    }

    /// 보기 탭 — 화면 모양과 그리는 방식.
    private func makeViewTab() -> NSView {
        fill(appearancePicker, EditorPreferences.Appearance.allCases) { $0.label }
        fill(lineSpacingPicker, EditorPreferences.LineSpacing.allCases) { $0.label }
        fill(widthPicker, EditorPreferences.DocumentWidth.allCases) { $0.label }

        for check in [highlightCheck, alignCheck, slantCheck, codeViewCheck] {
            check.target = self
            check.action = #selector(changed)
        }

        return column([
            note(String(localized: "문서 내용을 바꾸지 않고 읽기 화면만 조정합니다.")),
            row(String(localized: "화면 모양"), appearancePicker),
            row(String(localized: "줄 간격"), lineSpacingPicker),
            row(String(localized: "글 넓이"), widthPicker),
            highlightCheck, alignCheck, slantCheck, codeViewCheck,
        ])
    }

    private func makeGeneralTab() -> NSView {
        remoteImageCheck.target = self
        remoteImageCheck.action = #selector(changed)
        associationButton.bezelStyle = .rounded
        associationButton.target = self
        associationButton.action = #selector(claimAssociation)
        associationLabel.font = .systemFont(ofSize: 11)
        associationLabel.textColor = .secondaryLabelColor
        languagePicker.removeAllItems()
        for language in InterfaceLanguage.allCases {
            languagePicker.addItem(withTitle: language.label)
            languagePicker.lastItem?.representedObject = language.rawValue
        }
        languagePicker.target = self
        languagePicker.action = #selector(languageChanged)

        return column([
            row(String(localized: "화면 언어"), languagePicker),
            // 왜 바로 바뀌지 않는지 적는다 — 말하지 않으면 고른 것이 먹지 않은 것으로 보인다.
            note(String(localized: "바꾼 언어는 마디를 다시 열면 적용됩니다.")),
            spacer(),
            NSTextField(labelWithString: String(localized: "이미지")),
            remoteImageCheck,
            // 왜 기본이 꺼짐인지 **화면에** 적는다. 문서에만 적으면 읽지 않고,
            // 그러면 사용자가 켜는 결정을 모르고 한다.
            note(String(localized: """
            꺼져 있으면 문서에 적힌 웹 주소의 그림을 받아오지 않습니다. \
            문서를 열었을 뿐인데 바깥으로 요청이 나가면 그 주소를 가진 쪽이 \
            문서를 언제 열었는지 알 수 있고, 주소 자체가 추적용일 수 있습니다. \
            켜도 https 주소만 받고, 로컬 문서의 그림은 영향을 받지 않습니다.
            """)),
            spacer(),
            NSTextField(labelWithString: String(localized: "파일 연결")),
            associationLabel,
            associationButton,
        ])
    }

    private func makePrintTab() -> NSView {
        fill(paperPicker, EditorPreferences.PrintPaper.allCases) { $0.label }
        fill(orientationPicker, EditorPreferences.PrintOrientation.allCases) { $0.label }
        fill(marginPicker, EditorPreferences.PrintMargin.allCases) { $0.label }

        return column([
            note(String(localized: "프린트와 PDF 내보내기가 같은 설정을 씁니다.")),
            row(String(localized: "용지"), paperPicker),
            row(String(localized: "방향"), orientationPicker),
            row(String(localized: "여백"), marginPicker),
            spacer(),
            note(String(localized: "‘시스템 기본’ 용지는 시스템 프린트 설정의 용지를 그대로 씁니다.")),
        ])
    }

    // MARK: AI 교정

    /// 교정에 쓸 키를 키체인에 두고 확인하는 탭. **교정 자체는 아직 없다** — 문서를 바깥으로 보낼지
    /// 정하지 않았다(TODO '결정이 필요한 것'). 그래서 이 탭의 항목은 모두 키를 두고 확인하는 데에만
    /// 닿고, 그 사실을 탭 머리에 적는다.
    private func makeAITab() -> NSView {
        servicePicker.removeAllItems()
        for service in LLMService.allCases {
            servicePicker.addItem(withTitle: service.displayName)
            servicePicker.lastItem?.representedObject = service.rawValue
        }
        servicePicker.target = self
        servicePicker.action = #selector(serviceChanged)

        keyField.placeholderString = String(localized: "API 키를 붙여 넣으십시오")
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        for button in [saveKeyButton, removeKeyButton, checkKeyButton] { button.bezelStyle = .rounded }
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveKey)
        removeKeyButton.target = self
        removeKeyButton.action = #selector(removeKey)
        checkKeyButton.target = self
        checkKeyButton.action = #selector(checkKey)
        keyStatusLabel.font = .systemFont(ofSize: 11)
        keyStatusLabel.textColor = .secondaryLabelColor
        consoleLabel.font = .systemFont(ofSize: 11)
        consoleLabel.textColor = .secondaryLabelColor
        consoleLabel.isSelectable = true
        checkResultLabel.font = .systemFont(ofSize: 11)
        checkResultLabel.isSelectable = true

        regionField.placeholderString = LLMService.defaultBedrockRegion
        regionField.translatesAutoresizingMaskIntoConstraints = false
        regionField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        regionField.target = self
        regionField.action = #selector(regionChanged)
        regionField.stringValue = llmDefaults.string(forKey: Self.bedrockRegionKey) ?? ""
        let regionLabel = NSTextField(labelWithString: String(localized: "리전"))
        for view in [regionLabel, regionField] { regionRow.addArrangedSubview(view) }
        regionRow.orientation = .horizontal
        regionRow.spacing = 10

        let keyButtons = NSStackView(views: [saveKeyButton, removeKeyButton])
        keyButtons.orientation = .horizontal
        keyButtons.spacing = 8

        let stack = column([
            // 이 탭이 무엇을 하고 무엇을 하지 않는지 — 말하지 않으면 키를 넣는 순간 문서가 나간다고
            // 짐작하거나, 교정 기능을 찾아 헤맨다.
            note(String(localized: "교정에 쓸 API 키를 이 Mac의 키체인에 둡니다. 문서를 바깥 서비스로 보내는 교정은 아직 없습니다 — 보낼지는 정하지 않았습니다.")),
            row(String(localized: "서비스"), servicePicker),
            keyStatusLabel,
            row(String(localized: "API 키"), keyField),
            keyButtons,
            regionRow,
            spacer(),
            checkKeyButton,
            checkResultLabel,
            note(String(localized: "키 확인은 그 서비스에 모델 목록만 묻습니다. 문서는 보내지 않습니다.")),
            consoleLabel,
        ])
        refreshService()
        return stack
    }

    private var selectedService: LLMService {
        (servicePicker.selectedItem?.representedObject as? String).flatMap(LLMService.init(rawValue:)) ?? .anthropic
    }

    /// 고른 서비스에 맞춰 화면을 다시 쓴다. **키 값은 꺼내지 않는다** — 있는지만 묻는다
    /// (`KeychainSecretStore`의 설명: 값을 꺼내면 서명이 바뀐 빌드에서 키체인 창이 뜬다).
    private func refreshService() {
        let service = selectedService
        let stored = secrets.hasSecret(for: service.rawValue)
        keyStatusLabel.stringValue = stored
            ? String(localized: "키체인에 저장된 키가 있습니다")
            : String(localized: "저장된 키가 없습니다")
        removeKeyButton.isEnabled = stored
        checkKeyButton.isEnabled = stored
        regionRow.isHidden = !service.needsRegion
        consoleLabel.stringValue = String(localized: "키 받는 곳: \(service.keyConsole)")
        checkResultLabel.stringValue = ""
    }

    @objc private func serviceChanged() {
        keyField.stringValue = ""
        refreshService()
    }

    @objc private func saveKey() {
        let service = selectedService
        // 붙여 넣은 키 끝의 줄바꿈·공백을 뗀다 — 흔하고, 그대로 두면 서비스가 키를 거절한다.
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try secrets.setSecret(key, for: service.rawValue,
                                  label: String(localized: "마디 — \(service.displayName) API 키"))
            // 기록에 키를 남기지 않는다 — 서비스 이름만.
            AppLog.info(String(localized: "키를 키체인에 저장했습니다"), detail: service.displayName)
        } catch {
            AppLog.error(String(localized: "키를 저장하지 못했습니다"), detail: error.localizedDescription)
            checkResultLabel.stringValue = error.localizedDescription
            return
        }
        // 저장한 뒤에는 칸을 비운다 — 화면에 키가 남아 있을 이유가 없다.
        keyField.stringValue = ""
        refreshService()
    }

    @objc private func removeKey() {
        let service = selectedService
        secrets.removeSecret(for: service.rawValue)
        AppLog.info(String(localized: "키체인에서 키를 지웠습니다"), detail: service.displayName)
        refreshService()
    }

    @objc private func regionChanged() {
        let region = regionField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if region.isEmpty {
            llmDefaults.removeObject(forKey: Self.bedrockRegionKey)
        } else if LLMService.isValidRegion(region) {
            llmDefaults.set(region, forKey: Self.bedrockRegionKey)
        }
        regionField.stringValue = llmDefaults.string(forKey: Self.bedrockRegionKey) ?? ""
    }

    /// 키 확인 중인 일. 테스트가 끝나기를 기다린다.
    private(set) var keyCheckTask: Task<Void, Never>?

    @objc private func checkKey() {
        let service = selectedService
        regionChanged()     // 칸에 친 채 엔터를 누르지 않았어도 지금 값으로 묻는다
        guard let key = secrets.secret(for: service.rawValue) else {
            refreshService()
            return
        }
        let region = service.needsRegion
            ? llmDefaults.string(forKey: Self.bedrockRegionKey) ?? LLMService.defaultBedrockRegion : nil
        checkKeyButton.isEnabled = false
        checkResultLabel.stringValue = String(localized: "확인하는 중…")
        let checker = keyChecker
        keyCheckTask = Task { @MainActor [weak self] in
            let result = await checker.check(service, key: key, region: region)
            guard let self else { return }
            let line = result.line(for: service)
            // 확인하는 동안 다른 서비스로 옮겼으면 그 화면에 쓰지 않는다.
            if self.selectedService == service { self.checkResultLabel.stringValue = line }
            self.checkKeyButton.isEnabled = self.secrets.hasSecret(for: self.selectedService.rawValue)
            if case .accepted = result {
                AppLog.info(String(localized: "키를 확인했습니다"), detail: "\(service.displayName) — \(line)")
            } else {
                AppLog.warning(String(localized: "키를 확인하지 못했습니다"), detail: "\(service.displayName) — \(line)")
            }
        }
    }

    private func makeAboutTab() -> NSView {
        let name = NSTextField(labelWithString: String(localized: "마디 / Madi"))
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        let version = NSTextField(labelWithString: String(localized: "현재 버전: \(AppVersion.display)"))
        version.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true      // 문제를 신고할 때 복사할 수 있어야 한다
        // 앱에 든 글꼴의 라이선스(SIL OFL 1.1)는 전문을 사용자가 볼 수 있어야 한다(OFL 2조).
        let licenses = NSButton(title: String(localized: "글꼴 라이선스 보기"), target: self, action: #selector(showFontLicenses))
        licenses.bezelStyle = .rounded
        return column([
            name, version,
            spacer(),
            note(String(localized: "자동 업데이트는 아직 없습니다. 판 번호는 문제를 신고할 때 쓰십시오.")),
            spacer(),
            note(String(localized: "본문 글꼴 Pretendard(© Kil Hyung-jin)와 코드 글꼴 IBM Plex Mono(© IBM Corp.)가 앱에 들어 있습니다. 둘 다 SIL Open Font License 1.1입니다.")),
            licenses,
        ])
    }

    @objc private func showFontLicenses() {
        let urls = BundledFonts.licenseFiles.compactMap { BundledFonts.url(of: $0, in: nil) }
        guard !urls.isEmpty else {
            AppLog.warning(String(localized: "글꼴 라이선스 파일을 찾지 못했습니다"), detail: BundledFonts.licenseFiles.joined(separator: ", "))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return view
    }

    // MARK: 싣기와 저장

    /// 저장된 값을 화면에 싣는다.
    private func load() {
        preferences = store.current
        sizeSlider.doubleValue = preferences.bodyPointSize
        highlightCheck.state = preferences.highlightCode ? .on : .off
        alignCheck.state = preferences.alignTables ? .on : .off
        slantCheck.state = preferences.syntheticSlant ? .on : .off
        codeViewCheck.state = preferences.openInCodeView ? .on : .off
        remoteImageCheck.state = preferences.loadsRemoteImages ? .on : .off
        select(preferences.appearance, in: appearancePicker)
        select(preferences.lineSpacing, in: lineSpacingPicker)
        select(preferences.documentWidth, in: widthPicker)
        selectFonts()
        select(preferences.printPaper, in: paperPicker)
        select(preferences.printOrientation, in: orientationPicker)
        select(preferences.printMargin, in: marginPicker)
        select(currentLanguage, in: languagePicker)
        updateSizeLabel()
        refreshAssociation()
        preview.apply(preferences)
    }

    private var currentLanguage: InterfaceLanguage {
        InterfaceLanguage.current(in: languageDomain.flatMap { languageDefaults.persistentDomain(forName: $0) })
    }

    /// 화면 언어는 **기본값으로** 단추가 되돌리지 않는다 — 그 단추는 보기·프린트 설정을
    /// 되돌리는 것이고, 누른 사람이 다음 실행에 다른 언어를 보게 되면 놀란다.
    @objc private func languageChanged() {
        let language = selection(languagePicker, currentLanguage)
        language.apply(to: languageDefaults)
        AppLog.info(String(localized: "화면 언어를 바꿨습니다 — 마디를 다시 열면 적용됩니다"), detail: language.rawValue)
    }

    private func updateSizeLabel() {
        sizeLabel.stringValue = "\(Int(preferences.bodyPointSize.rounded()))pt"
    }

    private func refreshAssociation() {
        associationLabel.stringValue = FileAssociation.statusLine
        associationButton.isEnabled = !FileAssociation.isMadiDefault
    }

    /// 바뀌는 즉시 저장하고 알린다. 확인 버튼을 두지 않은 이유는, 보기 설정은
    /// 결과를 바로 보면서 고르는 것이 맞기 때문이다.
    @objc private func changed() {
        preferences = EditorPreferences(
            bodyPointSize: sizeSlider.doubleValue,
            highlightCode: highlightCheck.state == .on,
            alignTables: alignCheck.state == .on,
            syntheticSlant: slantCheck.state == .on,
            openInCodeView: codeViewCheck.state == .on,
            appearance: selection(appearancePicker, preferences.appearance),
            lineSpacing: selection(lineSpacingPicker, preferences.lineSpacing),
            documentWidth: selection(widthPicker, preferences.documentWidth),
            loadsRemoteImages: remoteImageCheck.state == .on,
            printMargin: selection(marginPicker, preferences.printMargin),
            printOrientation: selection(orientationPicker, preferences.printOrientation),
            printPaper: selection(paperPicker, preferences.printPaper),
            translationTarget: preferences.translationTarget,
            bodyFontFamily: fontSelection(bodyFontPicker),
            codeFontFamily: fontSelection(codeFontPicker),
            headingFont: headingSelection()
        )
        updateSizeLabel()
        preview.apply(preferences)
        store.save(preferences)
        NotificationCenter.default.post(name: PreferenceStore.didChange, object: self)
    }

    @objc private func claimAssociation() {
        FileAssociation.makeMadiDefault { [weak self] error in
            guard let self else { return }
            if let error {
                AppLog.error(String(localized: "기본 앱으로 등록하지 못했습니다"), detail: error.localizedDescription)
                let alert = NSAlert()
                alert.messageText = String(localized: "기본 앱으로 등록하지 못했습니다")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            } else {
                AppLog.info(String(localized: "Markdown 파일의 기본 앱이 마디로 바뀌었습니다"))
            }
            self.refreshAssociation()
        }
    }

    @objc private func resetAll() {
        store.reset()
        load()
        NotificationCenter.default.post(name: PreferenceStore.didChange, object: self)
    }
}
