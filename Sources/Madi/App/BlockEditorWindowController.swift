import AppKit

/// 블록 편집기 창 — 설계의 **단계 1**을 평가할 수 있는 표면.
///
/// ## 왜 기존 편집기를 바꾸지 않고 창을 따로 두는가
///
/// 설계 §8이 "현재 구조를 지우지 말 것. 단계 1이 실패했을 때 돌아올 곳이다"라고
/// 적었고, §7의 단계 1 끝 조건은 "**지금과 동작이 같다**"다. 기본 경로를 블록 편집기로
/// 갈면 그 조건을 확인할 길이 없어진다 — 검색·번역·프린트·PDF가 모두 기존 편집기의
/// `NSTextView` 하나를 보고 있어서, 갈아 끼우는 순간 그 기능들이 한꺼번에 흔들린다.
///
/// 그래서 단계 1은 **같은 문서를 블록으로 편집하는 두 번째 창**이다. 기본 창은 한
/// 줄도 달라지지 않고(끝 조건이 자명하게 참이 된다), 한글 조합·되돌리기·블록 넘는
/// 선택을 실제로 눌러 가릴 수 있다. 단계 1이 평가를 넘기면 그때 기본 경로를 옮긴다.
///
/// ## 두 창이 같은 문서를 보는 문제
///
/// 블록 창의 편집은 **주 창의 편집기에 그대로 실린다**(`onBodyChange`). 그래서
/// 저장·⌘S·편집 표시는 평소처럼 `NSDocument`가 맡고, 버퍼가 둘로 갈라지지 않는다.
/// 반대 방향(주 창에서 고친 것을 블록 창이 따라오기)은 **하지 않는다** — 양방향으로
/// 실으면 한쪽의 캐럿이 다른 쪽의 재파싱에 밀려 쓰는 중에 글자가 튄다. 블록 창은
/// 열 때 한 번 읽고, 주 창에서 고치면 닫고 다시 열어야 한다. 단계 1의 한계로
/// TODO에 적어 두었다.
@MainActor
final class BlockEditorWindowController: NSWindowController {

    private let container = BlockContainerView(frame: NSRect(x: 0, y: 0, width: 760, height: 620))
    private let footer = NSTextField(labelWithString: "")
    /// 블록 창의 편집을 주 창에 싣는 길.
    var onBodyChange: ((String) -> Void)?
    var onLinkClick: ((String) -> Void)?

    init(body: String, documentURL: URL?, preferences: EditorPreferences, title: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "블록 편집기 — \(title)"
        window.subtitle = "설계 단계 1 · 표는 아직 글입니다"
        window.setFrameAutosaveName("MdBlockEditorWindow")
        super.init(window: window)

        container.containerDelegate = self
        container.documentURL = documentURL
        container.apply(preferences)
        container.markdown = body

        footer.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(container)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            footer.topAnchor.constraint(equalTo: container.bottomAnchor, constant: 4),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])

        let controller = NSViewController()
        controller.view = root
        // `contentViewController`를 할당하면 AppKit이 창을 콘텐츠의 fitting size로
        // 줄인다. 그래서 크기를 선언해 둔다 — 전에 창이 520x380 조각으로 떴던 원인이다.
        controller.preferredContentSize = NSSize(width: 760, height: 640)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 760, height: 640))
        updateFooter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// 되돌리기는 **블록 문서의 것**이다(설계 §5.2). 창이 자기 undo manager를
    /// 내놓으면 ⌘Z가 이 스택을 본다.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        container.documentUndoManager
    }

    private func updateFooter() {
        let kinds = container.blockKindSummary
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
        footer.stringValue = "블록 \(container.blockCount)개 · 뷰 \(container.liveViewCount)개"
            + (kinds.isEmpty ? "" : " · \(kinds)")
    }
}

extension BlockEditorWindowController: BlockContainerDelegate {

    func blockContainerDidChangeText(_ container: BlockContainerView) {
        onBodyChange?(container.markdown)
        updateFooter()
    }

    func blockContainer(_ container: BlockContainerView, didClickLink url: String) {
        onLinkClick?(url)
    }
}
