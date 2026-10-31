import AppKit

@MainActor
protocol RecentDocumentsPanelDelegate: AnyObject {
    func recentDocumentsPanel(_ panel: RecentDocumentsPanelView, didOpen url: URL)
}

/// 최근 문서 — a sidebar panel rather than a popup menu, so the toolbar item
/// can be a toggle that shows whether the panel is open (which is how Mark.app
/// presents it). The list itself is `NSDocumentController`'s, so it can never
/// disagree with File ▸ Open Recent.
@MainActor
final class RecentDocumentsPanelView: NSView {

    weak var delegate: RecentDocumentsPanelDelegate?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "최근 문서 없음"))
    private let clearButton = NSButton(title: String(localized: "메뉴 지우기"), target: nil, action: nil)
    private var urls: [URL] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        let column = NSTableColumn(identifier: .init("recent"))
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

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: 11)
        clearButton.target = self
        clearButton.action = #selector(clearList)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -4),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            clearButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            clearButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    func reload() {
        urls = NSDocumentController.shared.recentDocumentURLs
        emptyLabel.isHidden = !urls.isEmpty
        clearButton.isHidden = urls.isEmpty
        tableView.reloadData()
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard urls.indices.contains(row) else { return }
        delegate?.recentDocumentsPanel(self, didOpen: urls[row])
    }

    @objc private func clearList() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        reload()
    }
}

extension RecentDocumentsPanelView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard urls.indices.contains(row) else { return nil }
        let url = urls[row]
        let identifier = NSUserInterfaceItemIdentifier("recentCell")

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            let created = NSTableCellView()
            created.identifier = identifier
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            let field = NSTextField(labelWithString: "")
            field.font = .systemFont(ofSize: 11)
            field.lineBreakMode = .byTruncatingMiddle
            field.translatesAutoresizingMaskIntoConstraints = false
            created.addSubview(image)
            created.addSubview(field)
            created.imageView = image
            created.textField = field
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: created.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: created.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 14),
                image.heightAnchor.constraint(equalToConstant: 14),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                field.trailingAnchor.constraint(equalTo: created.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: created.centerYAnchor),
            ])
            cell = created
        }

        cell.textField?.stringValue = url.lastPathComponent
        cell.textField?.toolTip = url.path
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 14, height: 14)
        cell.imageView?.image = icon
        return cell
    }
}
