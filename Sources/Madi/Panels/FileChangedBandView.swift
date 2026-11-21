import AppKit

/// 문서 위쪽의 띠: 여기서 고친 것을 아직 저장하지 않았는데 파일이 바깥에서 바뀌었다 — 어느 쪽을 남길지 고른다.
///
/// 섞지 않는다. 두 쪽을 줄마다 합치면 어느 줄이 누구 것인지 알 수 없게 되고, 틀리게 합친 것을 자동 저장이 곧 파일에 쓴다. 고를
/// 때까지 자동 저장은 멈춘다(`MarkdownDocument.hasExternalConflict`).
@MainActor
final class FileChangedBandView: NSView {

    var onReload: (() -> Void)?
    var onKeepMine: (() -> Void)?

    /// 띠의 글. 시험이 잰다.
    let label = NSTextField(wrappingLabelWithString: String(localized: """
        이 파일이 다른 곳에서 바뀌었습니다. 여기서 고친 것은 아직 저장하지 않았습니다. ‘다시 읽기’는 여기서 고친 것을 버리고, \
        ‘내 것 지키기’는 다른 곳에서 바뀐 것을 덮어씁니다.
        """))
    let reloadButton = NSButton(title: String(localized: "다시 읽기"), target: nil, action: nil)
    let keepButton = NSButton(title: String(localized: "내 것 지키기"), target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for button in [reloadButton, keepButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        reloadButton.action = #selector(reload(_:))
        keepButton.action = #selector(keepMine(_:))

        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, label, reloadButton, keepButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // 글칸의 `preferredMaxLayoutWidth`는 두지 않는다. 0이면 AppKit이 놓인 폭에 맞춰 줄을 바꾼다(`testBandWrapsToItsWidth`).
    // 전에는 `layout()`에서 글칸 자신의 폭을 알렸는데, 그 폭이 다시 그 값을 따르므로 둘이 서로를 바꾸며 끝나지 않았고 창이
    // "Update Constraints in Window" 횟수를 넘겼다고 멈췄다(나란히 보기 시험 10개).

    /// 시스템 색은 외관(라이트·다크)에 따라 달라지므로 그릴 때마다 푼다(`SourceChangedBandView`와 같다).
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.systemOrange.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    @objc private func reload(_ sender: Any?) { onReload?() }
    @objc private func keepMine(_ sender: Any?) { onKeepMine?() }
}
