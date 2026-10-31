import AppKit

/// 기록을 보는 창. 떠 있는 유틸리티 패널이라 **열어 둔 채로 계속 일할 수 있다.**
///
/// 시트나 모달로 하지 않은 이유: 기록을 보는 목적은 보통 "방금 뭐가 실패했지"를 확인하며
/// 다시 해 보는 것이다. 작업을 가로막으면 그 용도를 스스로 막는다.
@MainActor
final class ActivityLogPanel: NSWindowController {

    private let log: ActivityLog
    private let table = NSTableView()
    private let formatter = ActivityLog.timeFormatter()
    private var shown: [ActivityLog.Entry] = []
    private var floor: ActivityLog.Level = .info

    init(log: ActivityLog) {
        self.log = log
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = String(localized: "기록")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // 프로그램으로 만든 NSWindow는 닫힐 때 스스로 해제된다. 그런데 이 컨트롤러는
        // 창을 계속 들고 있으므로, 사용자가 한 번 닫고 다시 열면 이미 해제된 창을
        // 보이려 들게 된다. 실제 버그다 — 끄는 것이 맞다.
        panel.isReleasedWhenClosed = false
        // 저장된 창 위치를 찾는 열쇠다. 앱 이름이 바뀌어도 그대로 둔다.
        panel.setFrameAutosaveName("MdActivityLogPanel")
        super.init(window: panel)
        panel.contentViewController = makeContentController()
        // contentViewController를 넣으면 창이 콘텐츠 맞춤 크기로 줄어든다. 그 뒤에
        // 가운데로 옮긴다 — contentRect의 (0,0)은 화면 **왼쪽 아래 구석**이라
        // 거기 그대로 두면 Dock에 가리거나 눈에 띄지 않는다.
        panel.center()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContentController() -> NSViewController {
        let controller = NSViewController()
        let root = NSView()

        let filter = NSSegmentedControl(labels: [String(localized: "전체"), String(localized: "주의 이상"), String(localized: "실패만")],
                                        trackingMode: .selectOne,
                                        target: self, action: #selector(filterChanged(_:)))
        filter.selectedSegment = 0
        filter.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: String(localized: "모두 복사"), target: self, action: #selector(copyAll))
        let clearButton = NSButton(title: String(localized: "지우기"), target: self, action: #selector(clearLog))
        for button in [copyButton, clearButton] {
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        table.headerView = nil
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for subview in [filter, copyButton, clearButton, scroll] { root.addSubview(subview) }

        NSLayoutConstraint.activate([
            filter.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            filter.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),

            clearButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            clearButton.centerYAnchor.constraint(equalTo: filter.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: filter.centerYAnchor),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        controller.view = root
        controller.preferredContentSize = NSSize(width: 560, height: 320)
        return controller
    }

    /// 기록이 바뀌면 호출한다. 창이 닫혀 있어도 안전하다.
    func reload() {
        shown = log.entries(atLeast: floor)
        table.reloadData()
    }

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        floor = [ActivityLog.Level.info, .warning, .error][max(0, min(2, sender.selectedSegment))]
        reload()
    }

    @objc private func copyAll() {
        let text = shown.map { ActivityLog.line(for: $0, formatter: formatter) }
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func clearLog() {
        log.clear()
        reload()
    }
}

extension ActivityLogPanel: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < shown.count else { return nil }
        let entry = shown[row]
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
        }
        field.stringValue = ActivityLog.line(for: entry, formatter: formatter)
        // 실패는 색으로도 구별한다 — 기호만으로는 훑을 때 눈에 걸리지 않는다.
        switch entry.level {
        case .error: field.textColor = .systemRed
        case .warning: field.textColor = .systemOrange
        case .info: field.textColor = .labelColor
        }
        return field
    }
}
