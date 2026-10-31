import AppKit

@MainActor
protocol OutlinePanelDelegate: AnyObject {
    func outlinePanel(_ panel: OutlinePanelView, didSelect entry: OutlineEntry)
}

/// 목차 — the document's headings, indented by level.
@MainActor
final class OutlinePanelView: NSView {

    weak var delegate: OutlinePanelDelegate?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "제목이 없습니다"))
    private var entries: [OutlineEntry] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        let column = NSTableColumn(identifier: .init("title"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .small
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
        ])
    }

    func update(entries newEntries: [OutlineEntry]) {
        entries = newEntries
        emptyLabel.isHidden = !newEntries.isEmpty
        tableView.reloadData()
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard entries.indices.contains(row) else { return }
        delegate?.outlinePanel(self, didSelect: entries[row])
    }
}

/// Holds its own leading constraint so a reused row can be re-indented without
/// hunting for a constraint whose owner is the cell, not the text field.
@MainActor
private final class OutlineCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        let leadingConstraint = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        NSLayoutConstraint.activate([
            leadingConstraint,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        leading = leadingConstraint
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(with entry: OutlineEntry) {
        label.stringValue = entry.title
        label.font = .systemFont(ofSize: entry.level <= 1 ? 12 : 11,
                                 weight: entry.level <= 1 ? .semibold : .regular)
        label.textColor = entry.level >= 5 ? .secondaryLabelColor : .labelColor
        leading?.constant = CGFloat(6 + (entry.level - 1) * 12)
    }
}

extension OutlinePanelView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("outlineCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? OutlineCellView
            ?? {
                let created = OutlineCellView(frame: .zero)
                created.identifier = identifier
                return created
            }()
        cell.configure(with: entries[row])
        return cell
    }
}
