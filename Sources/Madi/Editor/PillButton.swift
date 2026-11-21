import AppKit

/// 글 위에 뜨는 알약 모양 단추(편집기의 `새 줄 N개 ↓`). 바탕을 강조색으로 꽉 칠해 뒤의 글이 비치지 않는다.
///
/// 처음에는 보통 둥근 단추(`.rounded`)를 썼다. 그 단추는 반투명이라 빽빽한 로그 위에서 단추 글과 뒤의 글이 겹쳐 읽을 수
/// 없었다(확인용 사본, 400줄 로그를 위에서 읽는 동안).
@MainActor
final class PillButton: NSButton {

    private static let padding = NSSize(width: 12, height: 4)

    init() {
        super.init(frame: .zero)
        isBordered = false
        font = .systemFont(ofSize: 11, weight: .semibold)
        focusRingType = .none
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
    }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: titleAttributes)
        return NSSize(width: ceil(text.width) + Self.padding.width * 2, height: ceil(text.height) + Self.padding.height * 2)
    }

    /// 시스템 색은 외관(라이트 · 다크)과 강조색 설정에 따라 달라지므로 그릴 때마다 푼다.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let fill = isHighlighted ? NSColor.controlAccentColor.shadow(withLevel: 0.2) ?? .controlAccentColor
            : NSColor.controlAccentColor
        fill.setFill()
        path.fill()
        let text = (title as NSString).size(withAttributes: titleAttributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - text.width) / 2, y: (bounds.height - text.height) / 2),
                                 withAttributes: titleAttributes)
    }
}
