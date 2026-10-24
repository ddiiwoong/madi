import AppKit

/// 편집기 위에 잠깐 떠서 알리고 사라지는 상태 표시.
///
/// 모달 경고창을 대신한다. 전에는 「번역했습니다」 같은 성공 문구까지 경고창으로 띄워
/// 확인을 눌러야 다음 일을 할 수 있었다. 성공은 **가로막을 일이 아니다** — 보이고
/// 사라지면 된다. 놓쳐도 괜찮은 이유는 같은 내용이 `ActivityLog`에 남기 때문이다.
///
/// 실패는 이것만으로 끝내지 않는다. 사라지는 문구로 실패를 알리면 놓치기 때문에,
/// 오류는 여전히 경고창으로 즉시 알리고 기록에도 남긴다.
@MainActor
final class StatusOverlayView: NSView {

    private let label = NSTextField(labelWithString: "")
    private let background = NSVisualEffectView()
    private var hideWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0
        // 보이지 않을 때 클릭을 먹지 않아야 한다 — 편집기 위에 얹혀 있기 때문이다.
        isHidden = true

        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(background)
        background.addSubview(label)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
        ])
    }

    /// 문구를 보이고 `duration` 뒤에 사라진다. 이미 보이는 중이면 문구를 갈고 시간을 다시 센다.
    func show(_ message: String, duration: TimeInterval = 2.5) {
        hideWorkItem?.cancel()
        label.stringValue = message
        isHidden = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // 투명해진 뒤에 숨긴다 — 숨기지 않으면 보이지 않는 채로 클릭을 먹는다.
            guard let self, self.alphaValue == 0 else { return }
            self.isHidden = true
        }
    }
}
