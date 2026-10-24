import AppKit

/// 설정 창.
///
/// 항목을 고를 때 지킨 규칙이 하나 있다 — **아무 일도 하지 않는 설정은 넣지 않는다.**
/// 아래 다섯 개는 모두 실제 코드 경로에 닿는다(글자 크기는 테마, 나머지는 스타일러의
/// 각 패스). 설정 화면이 허울이면 사용자는 자기가 무엇을 잘못했는지 찾느라 시간을 버린다.
///
/// 기록 패널과 같은 창 설정을 쓴다: `isReleasedWhenClosed`를 끄고(컨트롤러가 창을
/// 계속 들고 있으므로 닫은 뒤 다시 열 수 있어야 한다) 가운데로 옮긴다.
@MainActor
final class SettingsPanel: NSWindowController {

    private let store: PreferenceStore
    private var preferences: EditorPreferences

    private let sizeSlider = NSSlider()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let highlightCheck = NSButton(checkboxWithTitle: "코드 블록 구문 강조", target: nil, action: nil)
    private let alignCheck = NSButton(checkboxWithTitle: "표 열 맞추기", target: nil, action: nil)
    private let slantCheck = NSButton(checkboxWithTitle: "한글·CJK 기울임 강제 적용", target: nil, action: nil)
    private let codeViewCheck = NSButton(checkboxWithTitle: "새 창을 코드 보기로 열기", target: nil, action: nil)

    init(store: PreferenceStore) {
        self.store = store
        self.preferences = store.current
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "설정"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.contentViewController = makeContentController()
        panel.center()
        load()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContentController() -> NSViewController {
        let controller = NSViewController()
        let root = NSView()

        let heading = NSTextField(labelWithString: "보기")
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        let sizeTitle = NSTextField(labelWithString: "본문 글자 크기")
        sizeSlider.minValue = EditorPreferences.pointSizeRange.lowerBound
        sizeSlider.maxValue = EditorPreferences.pointSizeRange.upperBound
        sizeSlider.numberOfTickMarks = Int(EditorPreferences.pointSizeRange.upperBound
                                           - EditorPreferences.pointSizeRange.lowerBound) + 1
        sizeSlider.allowsTickMarkValuesOnly = true
        sizeSlider.target = self
        sizeSlider.action = #selector(changed)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor

        for check in [highlightCheck, alignCheck, slantCheck, codeViewCheck] {
            check.target = self
            check.action = #selector(changed)
        }

        let reset = NSButton(title: "기본값으로", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded

        let stack = NSStackView(views: [
            heading, sizeTitle, sizeSlider, sizeLabel,
            highlightCheck, alignCheck, slantCheck, codeViewCheck,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        reset.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addSubview(reset)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            // 수직 스택은 내재 폭 자식을 늘려 주지 않는다 — 슬라이더만 따로 늘린다.
            sizeSlider.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            sizeSlider.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

            reset.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            reset.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            reset.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 12),
        ])

        controller.view = root
        controller.preferredContentSize = NSSize(width: 420, height: 300)
        return controller
    }

    /// 저장된 값을 화면에 싣는다.
    private func load() {
        preferences = store.current
        sizeSlider.doubleValue = preferences.bodyPointSize
        highlightCheck.state = preferences.highlightCode ? .on : .off
        alignCheck.state = preferences.alignTables ? .on : .off
        slantCheck.state = preferences.syntheticSlant ? .on : .off
        codeViewCheck.state = preferences.openInCodeView ? .on : .off
        updateSizeLabel()
    }

    private func updateSizeLabel() {
        sizeLabel.stringValue = "\(Int(preferences.bodyPointSize.rounded()))pt"
    }

    /// 바뀌는 즉시 저장하고 알린다. 확인 버튼을 두지 않은 이유는, 보기 설정은
    /// 결과를 바로 보면서 고르는 것이 맞기 때문이다.
    @objc private func changed() {
        preferences = EditorPreferences(
            bodyPointSize: sizeSlider.doubleValue,
            highlightCode: highlightCheck.state == .on,
            alignTables: alignCheck.state == .on,
            syntheticSlant: slantCheck.state == .on,
            openInCodeView: codeViewCheck.state == .on
        )
        updateSizeLabel()
        store.save(preferences)
        NotificationCenter.default.post(name: PreferenceStore.didChange, object: nil)
    }

    @objc private func resetAll() {
        store.reset()
        load()
        NotificationCenter.default.post(name: PreferenceStore.didChange, object: nil)
    }
}
