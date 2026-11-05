import AppKit

/// 고를 것 하나 — 빠른 열기의 문서, 명령 팔레트의 메뉴 명령.
struct QuickPickItem {
    /// 굵게 보이는 이름. 걸러내기는 먼저 이것에 맞춘다.
    let title: String
    /// 흐린 둘째 줄(경로, 메뉴 위치). 이름에 안 맞으면 이것에 맞춘다.
    let detail: String?
    /// 오른쪽 끝의 단축키.
    let shortcut: String?
    let perform: @MainActor () -> Void

    init(title: String, detail: String? = nil, shortcut: String? = nil,
         perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
        self.perform = perform
    }
}

/// 창 위에 뜨는 고르개 — 글을 치면 걸러지고, ↑↓로 고르고, ↩로 실행하고, ⎋로 닫는다.
///
/// 빠른 열기(⌥⌘O)와 명령 팔레트(⇧⌘P)가 함께 쓴다. 문서 창의 **자식 창**으로 띄워 창과 함께
/// 움직이고, 다른 곳을 누르면(키 창을 잃으면) 닫힌다. 고른 것은 창을 닫고 문서 창이 다시 키 창이
/// 된 **다음에** 실행한다 — 메뉴 명령은 키 창의 응답자 연쇄로 가므로, 이 창이 키인 채로
/// 실행하면 엉뚱한 곳(이 창의 검색 칸)으로 간다.
@MainActor
final class QuickPickPanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
                            NSTableViewDataSource, NSTableViewDelegate {

    private let field = NSTextField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var items: [QuickPickItem] = []
    private(set) var visible: [QuickPickItem] = []
    private weak var parentWindow: NSWindow?
    private var isClosing = false

    static let size = NSSize(width: 560, height: 340)
    static let rowHeight: CGFloat = 38

    init(placeholder: String, emptyText: String) {
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.titled, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: panel)
        panel.delegate = self
        field.placeholderString = placeholder
        emptyLabel.stringValue = emptyText
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 키 창이 될 수 있는 패널. 제목 없는 패널은 기본으로 키 창이 되지 않아 글을 칠 수 없다.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        field.font = .systemFont(ofSize: 17)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        for view in [field, rule, scroll, emptyLabel] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            rule.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
        ])
    }

    // MARK: 띄우기와 닫기

    /// `parent` 위쪽 가운데에 띄운다.
    func present(over parent: NSWindow, items: [QuickPickItem]) {
        parentWindow = parent
        isClosing = false
        field.stringValue = ""
        update(items: items)
        guard let panel = window else { return }
        let frame = parent.frame
        let origin = NSPoint(x: frame.midX - Self.size.width / 2,
                             y: frame.maxY - 90 - Self.size.height)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// 고를 것을 바꾼다(빠른 열기는 폴더를 다 훑은 뒤 한 번 더 싣는다). 친 글은 그대로 둔다.
    func update(items: [QuickPickItem]) {
        self.items = items
        applyFilter()
    }

    func dismiss() {
        guard let panel = window, !isClosing else { return }
        isClosing = true
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        parentWindow?.makeKeyAndOrderFront(nil)
    }

    var query: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            applyFilter()
        }
    }

    /// 지금 고른 것을 실행한다 — 창을 닫고 문서 창이 키가 된 다음 차례에.
    func chooseSelected() {
        let row = table.selectedRow
        guard row >= 0, row < visible.count else { return }
        let item = visible[row]
        dismiss()
        DispatchQueue.main.async { item.perform() }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    // MARK: 걸러내기

    private func applyFilter() {
        visible = FuzzyMatch.rank(items, query: field.stringValue) { ($0.title, $0.detail) }
        table.reloadData()
        emptyLabel.isHidden = !visible.isEmpty
        if !visible.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            chooseSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    func moveSelection(by step: Int) {
        guard !visible.isEmpty else { return }
        let current = max(0, table.selectedRow)
        let next = min(max(current + step, 0), visible.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        chooseSelected()
    }

    // MARK: 표

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = visible[row]
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.detail ?? "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let shortcut = NSTextField(labelWithString: item.shortcut ?? "")
        shortcut.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shortcut.textColor = .secondaryLabelColor
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = NSStackView(views: item.detail == nil ? [title] : [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [text, shortcut])
        row.orientation = .horizontal
        row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        return row
    }
}
