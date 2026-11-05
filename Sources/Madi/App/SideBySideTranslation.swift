import AppKit

/// 원문·번역 나란히 보기 한 벌 — **한 창** 안에서 왼쪽이 원문, 오른쪽이 번역본이다.
///
/// 번역본은 자기 문서(`MarkdownDocument`)라 고칠 수 있고 원문과 따로 저장된다. 창은 없다 —
/// 원문 창의 오른쪽 칸(`TranslationPaneView`)이 그 문서를 보인다. 한 창에 문서가 둘이라 생기는
/// 물음(⌘S가 무엇을 저장하나, ⌘Z가 무엇을 되돌리나)은 **초점**이 답한다: 캐럿이 있는 쪽이다.
/// (전에는 번역본에 창을 따로 주고 화면을 반씩 나눠 가졌다. 창이 둘이면 그 답을 `NSDocument`가
/// 이미 알지만, 원문을 옮기면 번역본이 따라오지 않고 창 하나를 닫으면 반쪽만 남았다.)
///
/// 이 객체가 하는 일: 두 편집기의 스크롤을 블록 단위로 잇고(`SideBySideScrollLink`), 번역본이
/// 원문의 **어느 판**에서 나왔는지 기억해 원문이 바뀌면 번역본 칸에 띠를 띄운다.
@MainActor
final class SideBySideTranslation: NSObject {

    private(set) weak var source: DocumentWindowController?
    let pane: TranslationPaneView
    var document: MarkdownDocument { pane.document }
    let link: SideBySideScrollLink
    private(set) var direction: TranslationDirection

    /// 마지막 번역이 받은 원문 본문. 원문이 이것과 다르면 번역본이 낡은 것이다.
    private(set) var translatedFromBody: String
    /// 마지막 번역이 내놓은 본문. 번역본 칸의 글이 이것과 다르면 사용자가 고친 것이다.
    private(set) var translatedBody: String

    init(source: DocumentWindowController, pane: TranslationPaneView,
         direction: TranslationDirection, sourceBody: String, translatedBody: String) {
        self.source = source
        self.pane = pane
        self.direction = direction
        self.translatedFromBody = sourceBody
        self.translatedBody = translatedBody
        self.link = SideBySideScrollLink(source: source.editor, target: pane.editor)
        super.init()
    }

    // MARK: 원문·번역본의 변화

    /// 원문이 바뀌었다. 번역본 칸의 띠를 맞춘다(되돌려 같아지면 띠도 사라진다).
    func sourceTextDidChange() {
        guard let source else { return }
        pane.setSourceChangedBand(visible: source.editor.markdown != translatedFromBody)
    }

    /// 사용자가 번역본을 고쳤는가. 다시 번역하면 그 고친 것이 사라지므로 먼저 묻는다.
    var translationWasEdited: Bool {
        pane.editor.markdown != translatedBody
    }

    /// 다시 번역한 결과가 번역본 칸에 들어갔다.
    func didRetranslate(direction: TranslationDirection, sourceBody: String, translatedBody: String) {
        self.direction = direction
        self.translatedFromBody = sourceBody
        self.translatedBody = translatedBody
        sourceTextDidChange()
    }

    /// 스크롤 잇기를 끊는다. 칸을 걷는 일은 원문 창이 한다.
    func disconnect() {
        link.disconnect()
    }
}

/// 번역본 칸 위쪽의 띠: 원문이 번역한 뒤에 바뀌었다는 것과, 다시 번역하는 버튼.
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
