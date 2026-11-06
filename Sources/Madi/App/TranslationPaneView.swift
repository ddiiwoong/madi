import AppKit

/// 나란히 보기의 오른쪽 — 번역본 하나를 고치는 칸.
///
/// 번역본은 **자기 문서**(`MarkdownDocument`)를 갖는다. 창은 없다: 원문 창의 오른쪽 절반이 이
/// 칸이다. 그래서 두 문서가 한 창에 있고, 무엇을 저장하는지는 **초점이 정한다** — 이 칸 안에
/// 캐럿이 있으면 `⌘S`가 번역본을, 원문에 있으면 원문을 저장한다(Xcode·VS Code의 나뉜 편집기와
/// 같다). 이 뷰가 응답자 연쇄에서 원문 창보다 앞에 있어 `saveDocument:`를 먼저 받는다.
///
/// 되돌리기도 따로다. 이 칸의 편집기는 번역본 문서의 실행 취소 관리자를 쓴다 — 창의 것을 쓰면
/// 번역본을 고칠 때 **원문이 '편집됨'이 되고**, `⌘Z`가 두 문서의 편집을 섞어 되돌린다.
@MainActor
final class TranslationPaneView: NSView, MarkdownEditorDelegate {

    let document: MarkdownDocument
    let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
    let band = SourceChangedBandView()
    private let frontMatterCard = FrontMatterCardView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: String(localized: "저장"), target: nil, action: nil)
    private let closeButton = NSButton()
    /// 번역본의 front matter. 원문 창과 같은 방식이다 — 편집기에는 본문만 싣고, 저장할 때 원래
    /// 블록에 다시 붙인다.
    private var frontMatter: FrontMatter?

    /// 칸을 닫아 달라(머리의 ×). 닫기는 원문 창이 한다 — 저장할지 물어야 한다.
    var onClose: (() -> Void)?
    /// 번역본 본문이 바뀌었다.
    var onChange: (() -> Void)?
    /// 번역본에서 링크를 ⌘클릭했다.
    var onLink: ((String) -> Void)?

    init(document: MarkdownDocument, direction: TranslationDirection) {
        self.document = document
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        build(direction: direction)
        document.changeCountDidChange = { [weak self] in self?.refreshStatus() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build(direction: TranslationDirection) {
        translatesAutoresizingMaskIntoConstraints = false
        editor.editorDelegate = self
        editor.undoManagerOverride = document.undoManager

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = direction.label
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.font = .systemFont(ofSize: 11)
        saveButton.target = self
        saveButton.action = #selector(saveDocument(_:))
        saveButton.toolTip = String(localized: "번역본 저장 — 이 칸에 캐럿이 있으면 ⌘S도 번역본을 저장합니다")

        closeButton.bezelStyle = .texturedRounded
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "번역본 닫기"))
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.toolTip = String(localized: "번역본 닫기 (⌃⌘T)")

        let header = NSStackView(views: [titleLabel, statusLabel, NSView(), saveButton, closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 6, right: 10)

        band.isHidden = true
        // 원문 창과 같다 — 카드는 편집기 안의 머리라 글과 함께 굴러간다.
        frontMatterCard.isHidden = true
        editor.headerView = frontMatterCard
        frontMatterCard.onToggle = { [weak editor] in editor?.headerDidChange() }

        let column = NSStackView(views: [header, band, editor])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            band.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 16),
            band.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -16),
            editor.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
        refreshStatus()
    }

    // MARK: 글

    /// 번역본 전체(front matter 포함)를 싣는다.
    func load(markdown: String) {
        let parsed = FrontMatter.parse(markdown)
        frontMatter = parsed
        frontMatterCard.update(with: parsed)
        editor.headerDidChange()
        editor.markdown = parsed?.body ?? markdown
        document.markdown = markdown
        refreshStatus()
    }

    /// 저장할 글 — 원래 front matter 블록 + 고친 본문.
    var composedMarkdown: String {
        guard let frontMatter else { return editor.markdown }
        return frontMatter.joined(withBody: editor.markdown)
    }

    /// 본문 전체를 바꾼다(다시 번역). 텍스트 뷰를 지나므로 `⌘Z`로 되돌릴 수 있다 — 번역본의
    /// 실행 취소 관리자에 실린다.
    func replaceBody(with text: String) {
        let textView = editor.textView
        let whole = NSRange(location: 0, length: (editor.markdown as NSString).length)
        guard textView.shouldChangeText(in: whole, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: whole, with: text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// 다시 번역이 방향을 바꿨을 수 있다(언어를 골라 다시 번역).
    func setDirection(_ direction: TranslationDirection) {
        statusLabel.stringValue = direction.label
    }

    var directionText: String { statusLabel.stringValue }

    func setSourceChangedBand(visible: Bool) {
        guard band.isHidden == visible else { return }
        band.isHidden = !visible
    }

    func markdownEditorDidChangeText(_ editor: MarkdownEditorView) {
        document.editorDidChange(markdown: composedMarkdown)
        onChange?()
    }

    func markdownEditor(_ editor: MarkdownEditorView, didClickLink url: String) {
        onLink?(url)
    }

    // MARK: 저장

    /// 파일 ▸ 저장(`⌘S`)이 이 칸 안에서 오면 번역본을 저장한다. 이름 없는 번역본이면 저장 패널이
    /// 원문 창 위에 뜬다(창 없는 문서의 시트는 주 창에 붙는다).
    @objc func saveDocument(_ sender: Any?) {
        document.save(sender)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        document.saveAs(sender)
    }

    @objc private func closeClicked(_ sender: Any?) { onClose?() }

    /// 머리 — 파일 이름과 상태. 고친 뒤 저장하지 않았으면 '편집됨'.
    func refreshStatus() {
        titleLabel.stringValue = document.displayName ?? String(localized: "번역본")
        saveButton.isEnabled = document.isDocumentEdited || document.fileURL == nil
        if document.isDocumentEdited {
            titleLabel.stringValue += " — " + String(localized: "편집됨")
        }
    }

    var statusText: String { titleLabel.stringValue }
}
