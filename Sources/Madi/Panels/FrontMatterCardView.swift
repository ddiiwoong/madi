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
            // 항목 칸은 카드 폭을 다 쓴다 — 칩이 그 폭에서 줄을 바꾼다. 카드의 폭은 글 칸이 정하고, 항목이 카드를
            // 넓히지 않는다.
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -(stack.edgeInsets.left + stack.edgeInsets.right)),
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

    /// 카드에 보이는 글 — 머리, 키, 값, 칩, 단추의 제목을 차례로(시험이 본다).
    var visibleText: String {
        func texts(_ view: NSView) -> [String] {
            guard !view.isHidden else { return [] }
            var own: [String] = []
            if let field = view as? NSTextField { own.append(field.stringValue) }
            if let button = view as? NSButton, !button.title.isEmpty { own.append(button.title) }
            return own + view.subviews.flatMap(texts)
        }
        return texts(self).joined(separator: "\n")
    }

    func update(with frontMatter: FrontMatter?) {
        grid.views.forEach { grid.removeView($0) }
        listToggles = []
        scalarLabels = []

        guard let frontMatter, !frontMatter.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        summary.stringValue = String(localized: "문서 메타데이터 · \(frontMatter.fields.count)개 항목")

        for field in frontMatter.fields {
            let row = row(for: field)
            grid.addView(row, in: .top)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        grid.isHidden = isCollapsed
        needsLayout = true
    }

    /// 글 값. 줄을 바꿀 폭(`preferredMaxLayoutWidth`)을 카드 폭에 맞춘다 — 정해 둔 420pt가 좁은 창의 카드보다 넓으면
    /// 카드를 밀어낸다.
    private var scalarLabels: [NSTextField] = []
    private var preferredWidthApplied: CGFloat = -1

    override func layout() {
        super.layout()
        let available = floor(bounds.width - stack.edgeInsets.left - stack.edgeInsets.right - Self.keyWidth - 10)
        let preferred = max(60, min(420, available))
        guard preferred != preferredWidthApplied else { return }
        preferredWidthApplied = preferred
        for label in scalarLabels { label.preferredMaxLayoutWidth = preferred }
    }

    static let keyWidth: CGFloat = 96

    private func row(for field: FrontMatter.Field) -> NSView {
        let key = NSTextField(labelWithString: field.key)
        key.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        key.textColor = .secondaryLabelColor
        key.alignment = .right
        key.lineBreakMode = .byTruncatingTail
        key.translatesAutoresizingMaskIntoConstraints = false
        key.widthAnchor.constraint(equalToConstant: Self.keyWidth).isActive = true

        let valueView: NSView
        switch field.value {
        case let .scalar(text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .labelColor
            label.isSelectable = true
            label.preferredMaxLayoutWidth = preferredWidthApplied > 0 ? preferredWidthApplied : 420
            scalarLabels.append(label)
            valueView = label
        case let .list(items):
            valueView = listView(items)
        }
        valueView.translatesAutoresizingMaskIntoConstraints = false
        valueView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 값은 키 뒤의 남은 폭을 다 쓰고, 그보다 넓어지지 않는다 — 줄 쌓기(`NSStackView`)는 칸을 늘려 주지 않고
        // 내용의 폭을 그대로 요구한다.
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(key)
        row.addSubview(valueView)
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            key.firstBaselineAnchor.constraint(equalTo: valueView.firstBaselineAnchor),
            valueView.leadingAnchor.constraint(equalTo: key.trailingAnchor, constant: 10),
            valueView.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            valueView.topAnchor.constraint(equalTo: row.topAnchor),
            valueView.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            key.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
        ])
        if case .list = field.value {
            // 칩은 남은 폭 전체에서 줄을 바꾼다.
            valueView.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        }
        return row
    }

    /// 목록 값 — 칩을 줄을 바꿔 가며 늘어놓는다. 많으면 앞의 몇 개만 두고 나머지는 `외 n개`로 접는다.
    ///
    /// 왜(앱에서 처음 본 것, Notion 내보내기의 `links:` — 링크 180개): 칩을 한 줄로 늘어놓아 카드가 수만 pt를
    /// 요구했고, 카드의 양옆은 글 칸의 여백을 따르는데 여백은 텍스트 뷰 폭에서 정해지므로 창이 넓어질수록 카드도
    /// 더 넓어져 **창이 끝없이 넓어졌다**(960 → 324,914pt). 모두 펴 놓으면 링크 하나가 한 줄이라 카드가 몇 화면을
    /// 먹는다 — 그래서 접는다.
    private func listView(_ items: [String]) -> NSView {
        let flow = ChipFlowView()
        let chips = items.map(chip)
        chips.forEach(flow.addSubview)
        let hidden = items.count - Self.visibleListItems
        guard hidden > 0 else { return flow }
        chips.dropFirst(Self.visibleListItems).forEach { $0.isHidden = true }
        let more = NSButton(title: String(localized: "외 \(hidden)개"), target: nil, action: nil)
        more.isBordered = false
        more.font = .systemFont(ofSize: 10, weight: .medium)
        more.contentTintColor = .linkColor
        more.setButtonType(.momentaryPushIn)
        let toggle = ListToggle(chips: Array(chips.dropFirst(Self.visibleListItems)), button: more,
                                collapsedTitle: more.title, flow: flow)
        more.target = toggle
        more.action = #selector(ListToggle.toggle)
        listToggles.append(toggle)
        flow.addSubview(more)
        return flow
    }

    /// 목록 값에서 처음에 보이는 칩 수.
    static let visibleListItems = 8

    /// `외 n개` ↔ `접기`. 단추는 대상을 약하게 쥐므로 카드가 쥔다.
    private var listToggles: [ListToggle] = []

    @MainActor
    private final class ListToggle: NSObject {
        let chips: [NSView]
        weak var button: NSButton?
        let collapsedTitle: String
        weak var flow: ChipFlowView?

        init(chips: [NSView], button: NSButton, collapsedTitle: String, flow: ChipFlowView) {
            self.chips = chips
            self.button = button
            self.collapsedTitle = collapsedTitle
            self.flow = flow
        }

        @objc func toggle() {
            let expand = chips.first?.isHidden == true
            chips.forEach { $0.isHidden = !expand }
            button?.title = expand ? String(localized: "접기") : collapsedTitle
            flow?.contentDidChange()
        }
    }

    private func chip(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        // 칸보다 긴 값(600자 넘는 주소)은 가운데를 줄여 보인다 — 앞(도메인)과 끝(파일 이름)이 남는다. 다 보려면 위에
        // 머문다.
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

/// 칩을 왼쪽부터 늘어놓다가 폭이 차면 다음 줄로 넘기는 뷰. 높이는 받은 폭에서 정해진다.
///
/// **폭을 요구하지 않는다**(`intrinsicContentSize`의 폭은 없다) — 받은 폭 안에 늘어놓을 뿐이다. 칩 하나가 폭보다
/// 넓으면 그 칩을 폭에 맞게 줄인다(칩의 글은 가운데가 줄어든다). 숨긴 칩은 자리를 차지하지 않는다.
@MainActor
final class ChipFlowView: NSView {

    static let spacing: CGFloat = 4
    static let lineSpacing: CGFloat = 4

    private var laidOutWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    /// 칩을 보이거나 숨겼다 — 다시 늘어놓는다.
    func contentDidChange() {
        laidOutWidth = -1
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // 칩은 이 뷰가 직접 놓는다.
        subview.translatesAutoresizingMaskIntoConstraints = true
        contentDidChange()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = arrange(in: width, place: true)
        laidOutWidth = width
        if abs(height - measuredHeight) > 0.5 {
            measuredHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    /// 폭 `width`에 늘어놓은 높이. `place`면 칩의 자리도 정한다.
    @discardableResult
    func arrange(in width: CGFloat, place: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews where !view.isHidden {
            var size = view.fittingSize
            size.width = min(ceil(size.width), width)
            size.height = ceil(size.height)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + Self.lineSpacing
                lineHeight = 0
            }
            if place { view.frame = NSRect(x: x, y: y, width: size.width, height: size.height) }
            x += size.width + Self.spacing
            lineHeight = max(lineHeight, size.height)
        }
        return y + lineHeight
    }

    override var firstBaselineOffsetFromTop: CGFloat {
        guard let first = subviews.first(where: { !$0.isHidden }) else { return 0 }
        return first.frame.minY + first.firstBaselineOffsetFromTop
    }
}
