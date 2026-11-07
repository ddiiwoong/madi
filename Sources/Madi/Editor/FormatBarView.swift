import AppKit

/// 글을 고르면 그 위에 뜨는 서식 막대 — 제목 ▾ · 굵게 · 기울임 · 취소선 · 인라인 코드 · 링크(사용자 — "글을 고르면 위에 뜨는
/// 서식 막대"). Notion · Medium의 방식이다.
///
/// 텍스트 뷰 **안의** 보조 뷰라 글과 함께 굴러간다. 단추는 첫 응답자가 되지 않는다 — 눌러도 캐럿과 선택이 편집기에
/// 남아, 굵게를 누른 뒤 바로 기울임을 누를 수 있다. 위치와 보이기는 편집기가 정한다(`MarkdownEditorView.updateFormatBar`).
@MainActor
final class FormatBarView: NSVisualEffectView {

    /// 막대의 단추 하나. `action`은 편집기(`MarkdownEditorView`)의 서식 명령이다. 제목은 단계를 고르는 메뉴를 연다.
    struct Item {
        let symbol: String
        let title: String
        let shortcut: String
        let action: Selector?
    }

    static let items: [Item] = [
        // `#` — 마크다운의 제목 표식. `textformat.size`는 한국어 화면에서 '가가'로 그려진다.
        Item(symbol: "number", title: String(localized: "제목"), shortcut: "⌘1~⌘6", action: nil),
        Item(symbol: "bold", title: String(localized: "굵게"), shortcut: "⌘B",
             action: #selector(MarkdownEditorView.formatBoldAction(_:))),
        Item(symbol: "italic", title: String(localized: "기울임"), shortcut: "⌘I",
             action: #selector(MarkdownEditorView.formatItalicAction(_:))),
        Item(symbol: "strikethrough", title: String(localized: "취소선"), shortcut: "⇧⌘X",
             action: #selector(MarkdownEditorView.formatStrikethroughAction(_:))),
        Item(symbol: "curlybraces", title: String(localized: "인라인 코드"), shortcut: "⇧⌘C",
             action: #selector(MarkdownEditorView.formatInlineCodeAction(_:))),
        Item(symbol: "link", title: String(localized: "링크"), shortcut: "⌘K",
             action: #selector(MarkdownEditorView.formatLinkAction(_:))),
    ]

    /// 아이콘 크기(pt) — 도구 막대(`DocumentWindowController.toolbarSymbolPointSize`)와 같다(사용자 — "서식 막대
    /// 아이콘도 줄여 줘"). 전에는 SF Symbol 기본(13pt)이었다.
    static let symbolPointSize: CGFloat = 10
    /// 단추 하나의 크기. 아이콘을 줄이며 함께 줄였다(30 × 26 → 26 × 22).
    static let buttonSize = NSSize(width: 26, height: 22)

    private(set) var buttons: [NSButton] = []
    /// 제목 단추가 여는 메뉴 — 본문 · 제목 1~6, `tag`가 단계다.
    let headingMenu = NSMenu(title: String(localized: "제목"))
    private weak var editor: MarkdownEditorView?

    init(editor: MarkdownEditorView) {
        self.editor = editor
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        isHidden = true
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "서식 막대"))

        let heading = #selector(MarkdownEditorView.formatHeadingAction(_:))
        let body = headingMenu.addItem(withTitle: String(localized: "본문"), action: heading, keyEquivalent: "")
        body.tag = 0
        body.target = editor
        for level in 1...6 {
            let entry = headingMenu.addItem(withTitle: String(localized: "제목 \(level)"), action: heading,
                                            keyEquivalent: "")
            entry.tag = level
            entry.target = editor
        }

        for (index, item) in Self.items.enumerated() {
            let symbol = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title) ?? NSImage()
            let image = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .regular)) ?? symbol
            let button = NSButton(image: image, target: nil, action: nil)
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .labelColor
            button.refusesFirstResponder = true
            button.toolTip = "\(item.title) (\(item.shortcut))"
            button.setAccessibilityLabel(item.title)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.buttonSize.width),
                button.heightAnchor.constraint(equalToConstant: Self.buttonSize.height),
            ])
            if let action = item.action {
                button.target = editor
                button.action = action
            } else {
                button.target = self
                button.action = #selector(showHeadingMenu(_:))
            }
            button.tag = index
            buttons.append(button)
        }

        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setFrameSize(fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 텍스트 뷰는 위에 올린 뷰에도 글자 커서(I)를 그린다 — 막대 위에서는 화살표.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    /// 막대 안의 클릭은 **막대가** 받는다. 단추가 받게 두면 단추가 누름 · 뗌을 따라가는 동안 뗌이 오지 않아 명령이 가지
    /// 않았다(실측: 앱에서 눌러도, 창을 거친 누름 · 뗌으로도 그대로였다 — 단추는 맞게 맞혀졌다). 누르는 순간 그 단추의
    /// 명령을 보낸다(Notion의 막대도 누르는 순간이다). 단추는 접근성(누르기)과 모양을 위해 그대로 둔다.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let button = buttons.first(where: { $0.convert($0.bounds, to: self).contains(point) }) else { return }
        press(button)
    }

    /// 단추 하나를 누른 것과 같다 — 명령을 편집기로, 제목은 단계 메뉴를 연다.
    func press(_ button: NSButton) {
        if let action = button.action { button.sendAction(action, to: button.target) }
    }

    @objc private func showHeadingMenu(_ sender: NSButton) {
        headingMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
}
