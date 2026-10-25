import AppKit

@MainActor
protocol FileBrowserPanelDelegate: AnyObject {
    func fileBrowserPanel(_ panel: FileBrowserPanelView, didOpen url: URL)
}

/// 디렉토리 보기 — the markdown files next to the open document, so the sidebar
/// works as a lightweight folder navigator.
@MainActor
final class FileBrowserPanelView: NSView {

    weak var delegate: FileBrowserPanelDelegate?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let pathButton = NSButton(title: "폴더 선택…", target: nil, action: nil)
    private var rootURL: URL?
    private var children: [URL: [URL]] = [:]

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "txt"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        pathButton.bezelStyle = .inline
        pathButton.controlSize = .small
        pathButton.font = .systemFont(ofSize: 11)
        pathButton.target = self
        pathButton.action = #selector(chooseFolder)
        pathButton.lineBreakMode = .byTruncatingMiddle
        pathButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathButton)

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .small
        outlineView.style = .inset
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.action = #selector(rowClicked)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            pathButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pathButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: pathButton.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Point the browser at the folder holding the current document.
    func show(folderOf documentURL: URL?) {
        guard let documentURL else { return }
        setRoot(documentURL.deletingLastPathComponent())
    }

    func setRoot(_ url: URL) {
        rootURL = url
        children.removeAll()
        pathButton.title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        pathButton.toolTip = url.path
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: false)
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRoot(url)
    }

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let url = outlineView.item(atRow: row) as? URL else { return }
        guard !isDirectory(url) else { return }
        delegate?.fileBrowserPanel(self, didOpen: url)
    }

    @objc private func rowDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let url = outlineView.item(atRow: row) as? URL else { return }
        if isDirectory(url) {
            if outlineView.isItemExpanded(url) {
                outlineView.collapseItem(url)
            } else {
                outlineView.expandItem(url)
            }
        } else {
            delegate?.fileBrowserPanel(self, didOpen: url)
        }
    }

    // MARK: Directory reading

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func entries(of url: URL) -> [URL] {
        if let cached = children[url] { return cached }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []

        let filtered = contents.filter { candidate in
            if isDirectory(candidate) { return true }
            return Self.markdownExtensions.contains(candidate.pathExtension.lowercased())
        }.sorted { lhs, rhs in
            let lhsDir = isDirectory(lhs), rhsDir = isDirectory(rhs)
            if lhsDir != rhsDir { return lhsDir }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }

        children[url] = filtered
        return filtered
    }
}

extension FileBrowserPanelView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let root = rootURL else { return 0 }
        let parent = (item as? URL) ?? root
        return entries(of: parent).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let parent = (item as? URL) ?? rootURL else { return URL(fileURLWithPath: "/") }
        let list = entries(of: parent)
        guard list.indices.contains(index) else { return URL(fileURLWithPath: "/") }
        return list[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let url = item as? URL else { return false }
        return isDirectory(url)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let url = item as? URL else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("fileCell")

        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            let created = NSTableCellView()
            created.identifier = identifier
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingMiddle
            field.font = .systemFont(ofSize: 11)
            field.translatesAutoresizingMaskIntoConstraints = false
            created.addSubview(image)
            created.addSubview(field)
            created.imageView = image
            created.textField = field
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: created.leadingAnchor, constant: 2),
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
        let symbol = isDirectory(url) ? "folder" : "doc.text"
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.imageView?.contentTintColor = isDirectory(url) ? .secondaryLabelColor : .tertiaryLabelColor
        return cell
    }
}
