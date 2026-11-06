import AppKit

/// 문서 메타데이터 — the YAML front matter rendered as a key/value card above
/// the editor, so the block is readable at a glance instead of being three
/// screens of `key: value` the writer has to scroll past.
///
/// Read-only by design in this version: the card renders what the file says and
/// the file stays the source of truth. Editing a field here would mean
/// re-serialising YAML, which is how a save starts rewriting constructs the
/// parser does not model.
@MainActor
final class FrontMatterCardView: NSView {

    private let stack = NSStackView()
    private let disclosure = NSButton()
    private let summary = NSTextField(labelWithString: "")
    private let grid = NSStackView()
    /// 접혀 있는가 — 머리 줄(`문서 메타데이터 · n개 항목`)만 남는다.
    private(set) var isCollapsed = false

    /// 사람이 삼각형을 눌러 접거나 폈다. 값은 새 상태다(`setCollapsed`로 바꾼 것은 알리지 않는다).
    var onToggle: ((Bool) -> Void)?

    /// 접힘을 정한다 — 기억해 둔 상태로 열 때 쓴다.
    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        disclosure.state = collapsed ? .off : .on
        grid.isHidden = collapsed
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.onOff)
        disclosure.title = ""
        disclosure.state = .on
        disclosure.target = self
        disclosure.action = #selector(toggleCollapsed)

        summary.font = .systemFont(ofSize: 11, weight: .medium)
        summary.textColor = .secondaryLabelColor

        let header = NSStackView(views: [disclosure, summary])
        header.orientation = .horizontal
        header.spacing = 4
        header.alignment = .centerY

        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 5

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        stack.addView(header, in: .top)
        stack.addView(grid, in: .top)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// 카드는 텍스트 뷰 안에 놓인다(`MarkdownEditorView.headerView`). 그대로 두면 텍스트 뷰의 글자
    /// 커서(I자)가 카드 위에도 나와 글을 칠 수 있는 자리처럼 보인다.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    private func applyColors() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    @objc private func toggleCollapsed() {
        setCollapsed(disclosure.state == .off)
        onToggle?(isCollapsed)
    }

    // MARK: Content

    func update(with frontMatter: FrontMatter?) {
        grid.views.forEach { grid.removeView($0) }

        guard let frontMatter, !frontMatter.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        summary.stringValue = String(localized: "문서 메타데이터 · \(frontMatter.fields.count)개 항목")

        for field in frontMatter.fields {
            grid.addView(row(for: field), in: .top)
        }
        grid.isHidden = isCollapsed
    }

    private func row(for field: FrontMatter.Field) -> NSView {
        let key = NSTextField(labelWithString: field.key)
        key.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        key.textColor = .secondaryLabelColor
        key.alignment = .right
        key.lineBreakMode = .byTruncatingTail
        key.translatesAutoresizingMaskIntoConstraints = false
        key.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let valueView: NSView
        switch field.value {
        case let .scalar(text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .labelColor
            label.isSelectable = true
            label.preferredMaxLayoutWidth = 420
            valueView = label
        case let .list(items):
            let chips = NSStackView(views: items.map(chip))
            chips.orientation = .horizontal
            chips.spacing = 4
            chips.alignment = .centerY
            valueView = chips
        }

        let row = NSStackView(views: [key, valueView])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        return row
    }

    private func chip(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        container.layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
        container.addSubview(label)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
    }
}
