import AppKit

/// 원문·번역 나란히 보기 한 벌.
///
/// 번역본은 **자기 창을 가진 문서**다(`MarkdownDocument`). 그래서 고칠 수 있고, 저장하면
/// 원본과 따로 저장된다. 한 창을 둘로 나누지 않은 이유가 이것이다 — 한 창에 저장할 문서가
/// 둘이면 ⌘S가 무엇을 저장하는지, 닫을 때 무엇을 묻는지가 모호해진다. 창이 둘이면 그 답을
/// `NSDocument`가 이미 안다.
///
/// 이 객체가 하는 일: 두 창을 화면에 나란히 놓고, 두 편집기의 스크롤을 블록 단위로 잇고
/// (`SideBySideScrollLink`), 번역본이 원문의 **어느 판**에서 나왔는지 기억해 원문이 바뀌면
/// 번역본 창에 띠를 띄운다. 어느 창이든 닫히면 끝난다.
@MainActor
final class SideBySideTranslation: NSObject {

    private(set) weak var source: DocumentWindowController?
    private(set) weak var translation: DocumentWindowController?
    let link: SideBySideScrollLink
    private(set) var direction: TranslationDirection

    /// 마지막 번역이 받은 원문 본문. 원문이 이것과 다르면 번역본이 낡은 것이다.
    private(set) var translatedFromBody: String
    /// 마지막 번역이 내놓은 본문. 번역본 창의 글이 이것과 다르면 사용자가 고친 것이다.
    private(set) var translatedBody: String

    /// 나란히 놓기 전의 원문 창 자리, 그리고 놓은 자리. 끝날 때 원문 창이 그 자리에 그대로
    /// 있으면(사용자가 옮기지 않았으면) 원래 자리로 돌려놓는다 — 번역본을 닫았는데 원문
    /// 창만 반쪽으로 남으면 이 모드가 남긴 흔적이다.
    private var frameBeforeTiling: NSRect?
    private var tiledFrame: NSRect?
    private var ended = false

    init(source: DocumentWindowController, translation: DocumentWindowController,
         direction: TranslationDirection, sourceBody: String, translatedBody: String) {
        self.source = source
        self.translation = translation
        self.direction = direction
        self.translatedFromBody = sourceBody
        self.translatedBody = translatedBody
        self.link = SideBySideScrollLink(source: source.editor, target: translation.editor)
        super.init()
        for window in [source.window, translation.window].compactMap({ $0 }) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window)
        }
    }

    // MARK: 놓기

    /// 원문 창을 화면 왼쪽 절반에, 번역본 창을 오른쪽 절반에 놓는다.
    ///
    /// 전체 화면에서는 놓지 않는다 — 전체 화면 창의 프레임을 바꾸면 전체 화면에서 빠지지도
    /// 못하고 어정쩡한 상태가 된다. 그때 번역본은 따로 열리고 스크롤 잇기만 한다.
    /// - Returns: 나란히 놓았는가.
    @discardableResult
    func tile() -> Bool {
        guard let sourceWindow = source?.window, let translationWindow = translation?.window,
              !sourceWindow.styleMask.contains(.fullScreen),
              let screen = sourceWindow.screen ?? NSScreen.main else { return false }
        let visible = screen.visibleFrame
        let half = floor(visible.width / 2)
        let left = NSRect(x: visible.minX, y: visible.minY, width: half, height: visible.height)
        let right = NSRect(x: visible.minX + half, y: visible.minY,
                           width: visible.width - half, height: visible.height)
        frameBeforeTiling = sourceWindow.frame
        sourceWindow.setFrame(left, display: true)
        translationWindow.setFrame(right, display: true)
        // 최소 크기에 걸리면 요청한 자리와 다르다. 실제 자리를 기억해야 끝날 때 비교가 맞는다.
        tiledFrame = sourceWindow.frame
        return true
    }


    // MARK: 원문·번역본의 변화

    /// 원문이 바뀌었다. 번역본 창의 띠를 맞춘다(되돌려 같아지면 띠도 사라진다).
    func sourceTextDidChange() {
        guard let source, let translation else { return }
        translation.setSourceChangedBand(visible: source.editor.markdown != translatedFromBody)
    }

    /// 사용자가 번역본을 고쳤는가. 다시 번역하면 그 고친 것이 사라지므로 먼저 묻는다.
    var translationWasEdited: Bool {
        guard let translation else { return false }
        return translation.editor.markdown != translatedBody
    }

    /// 다시 번역한 결과가 번역본 창에 들어갔다.
    func didRetranslate(direction: TranslationDirection, sourceBody: String, translatedBody: String) {
        self.direction = direction
        self.translatedFromBody = sourceBody
        self.translatedBody = translatedBody
        sourceTextDidChange()
    }

    // MARK: 끝

    @objc private func windowWillClose(_ notification: Notification) {
        end()
    }

    /// 잇기를 끊고 두 창에서 이 모드를 걷는다. 두 번 불려도 된다.
    func end() {
        guard !ended else { return }
        ended = true
        NotificationCenter.default.removeObserver(self)
        link.disconnect()
        if let sourceWindow = source?.window, let before = frameBeforeTiling,
           let tiled = tiledFrame, sourceWindow.frame == tiled, sourceWindow.isVisible {
            sourceWindow.setFrame(before, display: true)
        }
        translation?.setSourceChangedBand(visible: false)
        let controllers = [source, translation]
        for controller in controllers {
            controller?.sideBySideDidEnd(self)
        }
    }
}

/// 번역본 창 위쪽의 띠: 원문이 번역한 뒤에 바뀌었다는 것과, 다시 번역하는 버튼.
///
/// 자동으로 다시 번역하지 않는다. 긴 문서는 수십 초가 걸리고(5,966자에 23~54초를 쟀다),
/// 사용자가 번역본을 고쳤으면 다시 번역이 그것을 덮는다.
@MainActor
final class SourceChangedBandView: NSView {

    var onRetranslate: (() -> Void)?

    private let label = NSTextField(labelWithString: String(localized: "원문이 번역한 뒤에 바뀌었습니다."))
    private let button = NSButton(title: String(localized: "다시 번역"), target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = self
        button.action = #selector(retranslate(_:))

        // 높이를 안의 줄이 정하게 한다. `NSBox`에 담았더니 상자가 내용 높이를 따르지 않아
        // 띠가 납작하게 눌려 위가 잘렸다(실측).
        let row = NSStackView(views: [label, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// 시스템 색은 외관(라이트·다크)에 따라 달라지므로 그릴 때마다 푼다.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    @objc private func retranslate(_ sender: Any?) { onRetranslate?() }
}
