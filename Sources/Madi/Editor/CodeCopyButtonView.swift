import AppKit

/// 코드 블록의 오른쪽 위에 뜨는 `복사` 단추(사용자 — "코드 복사 버튼도 있으면 좋겠어"). 마우스가 코드 블록 위에
/// 있을 때만 보인다 — GitHub · Docusaurus와 같다. 누르면 펜스를 뺀 코드를 대지에 넣고 잠깐 `복사됨`으로 바뀐다.
///
/// 텍스트 뷰 **안의** 보조 뷰라 글과 함께 굴러간다. 서식 막대(`FormatBarView`)와 같은 까닭으로 클릭은 이 뷰가 직접
/// 받는다 — 텍스트 뷰 안의 `NSButton`은 누름 · 뗌을 따라가는 동안 뗌이 오지 않아 동작하지 않았다(실측).
@MainActor
final class CodeCopyButtonView: NSView {

    /// 단추가 가리키는 블록. 편집기가 정한다.
    var block: CodeBlockCopy.Block?
    /// 누르면 부른다.
    var onPress: ((CodeBlockCopy.Block) -> Void)?

    /// `복사됨`을 보이는 시간. 테스트가 줄인다.
    var copiedDuration: TimeInterval = 1.4

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var resetWork: DispatchWorkItem?
    private(set) var showsCopied = false

    static let symbolPointSize: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 0.5
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showCopied(false)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 보이는 글 — `복사` 또는 `복사됨`.
    var title: String { label.stringValue }

    /// `복사됨`(체크)으로 바꾸거나 `복사`로 되돌린다.
    func showCopied(_ copied: Bool) {
        resetWork?.cancel()
        resetWork = nil
        showsCopied = copied
        let symbol = copied ? "checkmark" : "doc.on.doc"
        let text = copied ? String(localized: "복사됨") : String(localized: "복사")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.symbolPointSize, weight: .medium))
        icon.image = image
        label.stringValue = text
        setAccessibilityLabel(copied ? String(localized: "코드를 복사했습니다") : String(localized: "코드 복사"))
        toolTip = copied ? nil : String(localized: "코드 복사")
        // 오른쪽 끝을 그대로 둔다 — `복사됨`이 `복사`보다 넓어 오른쪽으로 자라면 상자 밖으로 나갔다(그림으로 봄).
        let right = frame.maxX
        setFrameSize(fittingSize)
        if right > 0 { setFrameOrigin(NSPoint(x: (right - frame.width).rounded(), y: frame.minY)) }
        if copied {
            let work = DispatchWorkItem { [weak self] in self?.showCopied(false) }
            resetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + copiedDuration, execute: work)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// 텍스트 뷰는 위에 올린 뷰에도 글자 커서(I)를 그린다 — 단추 위에서는 화살표.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        press()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    /// 누른 것과 같다.
    func press() {
        guard let block else { return }
        onPress?(block)
        showCopied(true)
    }
}
