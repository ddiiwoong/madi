import AppKit

/// 번역 진행 시트. 진행률과 **취소** 버튼을 보인다.
///
/// 시트로 띄우는 것이 편한 선택이 아니라 **옳은 선택**이다. 제자리 번역은 시작할 때 잡은
/// 선택 범위에 결과를 써넣으므로, 번역 중에 사용자가 문서를 고치면 그 범위가 어긋나 엉뚱한
/// 자리를 덮어쓴다. 시트가 편집을 막아 그 경로를 아예 없앤다.
@MainActor
final class TranslationProgressSheet: NSViewController {

    private let titleLabel = NSTextField(labelWithString: String(localized: "번역 중…"))
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancelButton = NSButton(title: String(localized: "취소"), target: nil, action: nil)
    private let startedAt = Date()

    /// 취소를 눌렀을 때 호출된다. 시트를 닫는 것은 호출자의 몫이다.
    var onCancel: (() -> Void)?

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.controlSize = .regular

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"   // Esc

        for subview in [titleLabel, detailLabel, bar, cancelButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),

            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),

            detailLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -10),
            detailLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),

            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            view.widthAnchor.constraint(equalToConstant: 380),
        ])

        self.view = view
    }

    func update(direction: TranslationDirection?, fraction: Double, completed: Int, total: Int) {
        if let direction { titleLabel.stringValue = String(localized: "번역 중… (\(direction.label))") }
        bar.doubleValue = fraction
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let time = elapsed < 60 ? String(localized: "\(elapsed)초") : String(localized: "\(elapsed / 60)분 \(elapsed % 60)초")
        detailLabel.stringValue = String(localized: "\(completed)/\(total) 조각 · \(Int(fraction * 100))% · \(time) 경과")
    }

    /// 취소를 누른 뒤에는 버튼을 막는다 — 두 번 눌러 같은 작업을 두 번 취소하지 않게.
    @objc private func cancelPressed() {
        cancelButton.isEnabled = false
        titleLabel.stringValue = String(localized: "취소 중…")
        onCancel?()
    }
}
