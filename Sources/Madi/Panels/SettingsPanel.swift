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
    private let codeFontPicker = NSPopUpButton()
    private let highlightCheck = NSButton(checkboxWithTitle: "코드 블록 구문 강조", target: nil, action: nil)
    private let alignCheck = NSButton(checkboxWithTitle: "표 열 맞추기", target: nil, action: nil)
    private let slantCheck = NSButton(checkboxWithTitle: "한글·CJK 기울임 강제 적용", target: nil, action: nil)
    private let codeViewCheck = NSButton(checkboxWithTitle: "새 창을 마크다운 원본 보기로 열기",
                                         target: nil, action: nil)

    // 일반
    private let remoteImageCheck = NSButton(checkboxWithTitle: "원격 이미지 불러오기",
                                            target: nil, action: nil)
    private let associationLabel = NSTextField(wrappingLabelWithString: "")
    private let associationButton = NSButton(title: "마디 사용", target: nil, action: nil)

    // PDF·프린트
    private let paperPicker = NSPopUpButton()
    private let orientationPicker = NSPopUpButton()
    private let marginPicker = NSPopUpButton()

    private static let panelSize = NSSize(width: 460, height: 500)

    /// 글꼴 고르개의 '시스템' 항목에 다는 값. 패밀리 이름이 빈 문자열일 수는 없으므로
    /// 겹치지 않는다.
    static let systemFontTag = ""

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

    init(store: PreferenceStore) {
        self.store = store
        self.preferences = store.current
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "설정"
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
        tabs.addTabViewItem(tab("보기", view: makeViewTab()))
        tabs.addTabViewItem(tab("일반", view: makeGeneralTab()))
        tabs.addTabViewItem(tab("PDF·프린트", view: makePrintTab()))
        tabs.addTabViewItem(tab("정보", view: makeAboutTab()))

        let reset = NSButton(title: "기본값으로", target: self, action: #selector(resetAll))
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

    private func tab(_ title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
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

    /// 글꼴 고르개를 채운다. 맨 위가 시스템 글꼴이고 그 아래가 패밀리 이름이다. 각 이름은
    /// 그 글꼴로 그린다 — 고르기 전에 모양을 볼 수 있어야 한다.
    private func fillFonts(_ picker: NSPopUpButton, system: String, families: [String]) {
        picker.removeAllItems()
        picker.addItem(withTitle: system)
        picker.lastItem?.representedObject = Self.systemFontTag
        picker.menu?.addItem(.separator())
        for family in families {
            picker.addItem(withTitle: family)
            guard let item = picker.lastItem else { continue }
            item.representedObject = family
            if let font = MarkdownTheme.font(family: family, size: 13) {
                item.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
            }
        }
        picker.target = self
        picker.action = #selector(changed)
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
        picker.addItem(withTitle: "\(wanted) (이 Mac에 없음)")
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

    private func makeViewTab() -> NSView {
        sizeSlider.minValue = EditorPreferences.pointSizeRange.lowerBound
        sizeSlider.maxValue = EditorPreferences.pointSizeRange.upperBound
        sizeSlider.numberOfTickMarks = Int(EditorPreferences.pointSizeRange.upperBound
                                           - EditorPreferences.pointSizeRange.lowerBound) + 1
        sizeSlider.allowsTickMarkValuesOnly = true
        sizeSlider.target = self
        sizeSlider.action = #selector(changed)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor

        fill(appearancePicker, EditorPreferences.Appearance.allCases) { $0.label }
        fill(lineSpacingPicker, EditorPreferences.LineSpacing.allCases) { $0.label }
        fill(widthPicker, EditorPreferences.DocumentWidth.allCases) { $0.label }
        fillFonts(bodyFontPicker, system: "시스템 글꼴",
                  families: Self.installedFamilies(fixedPitchOnly: false))
        fillFonts(codeFontPicker, system: "시스템 고정폭",
                  families: Self.installedFamilies(fixedPitchOnly: true))

        for check in [highlightCheck, alignCheck, slantCheck, codeViewCheck] {
            check.target = self
            check.action = #selector(changed)
        }

        let sizeRow = NSStackView(views: [sizeSlider, sizeLabel])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 10

        let stack = column([
            note("문서 내용을 바꾸지 않고 읽기 화면만 조정합니다."),
            row("화면 모양", appearancePicker),
            row("줄 간격", lineSpacingPicker),
            row("글 넓이", widthPicker),
            row("본문 글꼴", bodyFontPicker),
            row("코드 글꼴", codeFontPicker),
            // 코드 목록에 글꼴이 적은 이유를 화면에 적는다 — 말하지 않으면 빠진 것으로 보인다.
            note("코드 글꼴은 고정폭만 고를 수 있습니다. 글자 폭이 다르면 코드의 들여쓰기와 줄 맞춤이 어긋납니다."),
            NSTextField(labelWithString: "본문 글자 크기"),
            sizeRow,
            highlightCheck, alignCheck, slantCheck, codeViewCheck,
        ])
        // 수직 스택은 내재 폭 자식을 늘려 주지 않는다 — 슬라이더만 따로 늘린다.
        NSLayoutConstraint.activate([
            sizeRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            sizeRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        return stack
    }

    private func makeGeneralTab() -> NSView {
        remoteImageCheck.target = self
        remoteImageCheck.action = #selector(changed)
        associationButton.bezelStyle = .rounded
        associationButton.target = self
        associationButton.action = #selector(claimAssociation)
        associationLabel.font = .systemFont(ofSize: 11)
        associationLabel.textColor = .secondaryLabelColor

        return column([
            NSTextField(labelWithString: "이미지"),
            remoteImageCheck,
            // 왜 기본이 꺼짐인지 **화면에** 적는다. 문서에만 적으면 읽지 않고,
            // 그러면 사용자가 켜는 결정을 모르고 한다.
            note("""
            꺼져 있으면 문서에 적힌 웹 주소의 그림을 받아오지 않습니다. \
            문서를 열었을 뿐인데 바깥으로 요청이 나가면 그 주소를 가진 쪽이 \
            문서를 언제 열었는지 알 수 있고, 주소 자체가 추적용일 수 있습니다. \
            켜도 https 주소만 받고, 로컬 문서의 그림은 영향을 받지 않습니다.
            """),
            spacer(),
            NSTextField(labelWithString: "파일 연결"),
            associationLabel,
            associationButton,
        ])
    }

    private func makePrintTab() -> NSView {
        fill(paperPicker, EditorPreferences.PrintPaper.allCases) { $0.label }
        fill(orientationPicker, EditorPreferences.PrintOrientation.allCases) { $0.label }
        fill(marginPicker, EditorPreferences.PrintMargin.allCases) { $0.label }

        return column([
            note("프린트와 PDF 내보내기가 같은 설정을 씁니다."),
            row("용지", paperPicker),
            row("방향", orientationPicker),
            row("여백", marginPicker),
            spacer(),
            note("‘시스템 기본’ 용지는 시스템 프린트 설정의 용지를 그대로 씁니다."),
        ])
    }

    private func makeAboutTab() -> NSView {
        let name = NSTextField(labelWithString: "마디 / Madi")
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        let version = NSTextField(labelWithString: "현재 버전: \(AppVersion.display)")
        version.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true      // 문제를 신고할 때 복사할 수 있어야 한다
        return column([
            name, version,
            spacer(),
            note("자동 업데이트는 아직 없습니다. 판 번호는 문제를 신고할 때 쓰십시오."),
        ])
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
        selectFont(preferences.bodyFontFamily, in: bodyFontPicker)
        selectFont(preferences.codeFontFamily, in: codeFontPicker)
        select(preferences.printPaper, in: paperPicker)
        select(preferences.printOrientation, in: orientationPicker)
        select(preferences.printMargin, in: marginPicker)
        updateSizeLabel()
        refreshAssociation()
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
            codeFontFamily: fontSelection(codeFontPicker)
        )
        updateSizeLabel()
        store.save(preferences)
        NotificationCenter.default.post(name: PreferenceStore.didChange, object: nil)
    }

    @objc private func claimAssociation() {
        FileAssociation.makeMadiDefault { [weak self] error in
            guard let self else { return }
            if let error {
                AppLog.error("기본 앱으로 등록하지 못했습니다", detail: error.localizedDescription)
                let alert = NSAlert()
                alert.messageText = "기본 앱으로 등록하지 못했습니다"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            } else {
                AppLog.info("Markdown 파일의 기본 앱이 마디로 바뀌었습니다")
            }
            self.refreshAssociation()
        }
    }

    @objc private func resetAll() {
        store.reset()
        load()
        NotificationCenter.default.post(name: PreferenceStore.didChange, object: nil)
    }
}
