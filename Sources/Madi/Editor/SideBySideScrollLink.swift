import AppKit

/// 원문 편집기와 번역본 편집기의 스크롤을 블록 단위로 잇는다.
///
/// 두 창은 각자의 문서다. 이 객체는 둘 중 **사용자가 움직인 쪽**을 읽어 다른 쪽을 같은
/// 블록 자리로 옮긴다. 블록 짝짓기는 `BlockAlignment`(Core)가 하고, 픽셀과 블록 좌표를
/// 오가는 일은 각 편집기가 한다(`scrollReferencePosition`, `scroll(toReferencePosition:)`).
///
/// **되먹임을 플래그로 막지 않는다.** 이쪽이 옮긴 창도 경계 변경 알림을 보내는데, 그
/// 알림이 언제 오는지에 기대면 깨진다 — 블록 편집기에서 선택 변경 알림이 플래그가 내려간
/// 뒤에 도착해 같은 방식이 실패했다. 대신 **옮겨 놓은 자리를 기억한다.** 알림을 받았을 때
/// 그 창이 기억한 자리에 그대로 있으면 이쪽이 만든 메아리이고, 다른 자리에 있으면 사용자가
/// 움직인 것이다. 알림이 바로 오든 나중에 오든 판정이 같다.
@MainActor
public final class SideBySideScrollLink: NSObject {

    public private(set) weak var source: MarkdownEditorView?
    public private(set) weak var target: MarkdownEditorView?

    /// 이쪽이 옮겨 놓은 원점. 열쇠는 편집기의 `ObjectIdentifier`.
    private var placed: [ObjectIdentifier: CGFloat] = [:]
    private var alignment: (sourceRevision: Int, targetRevision: Int, value: BlockAlignment)?

    /// 메아리로 볼 거리. 클립 뷰가 원점을 픽셀 경계에 맞추므로 정확히 같지 않을 수 있다.
    static let echoTolerance: CGFloat = 0.5

    public init(source: MarkdownEditorView, target: MarkdownEditorView) {
        self.source = source
        self.target = target
        super.init()
        // 선택자 방식으로 듣는다 — 이 객체가 풀리면 알림 센터가 스스로 지운다(그래서
        // `deinit`이 필요 없다. Swift 6에서 `deinit`은 메인 액터 밖이라 저장 프로퍼티를
        // 만질 수 없다).
        for editor in [source, target] {
            editor.clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification, object: editor.clipView)
        }
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView else { return }
        for editor in [source, target] where editor?.clipView === clip {
            if let editor { boundsDidChange(in: editor) }
        }
    }

    /// 잇기를 끊는다. 창이 닫힐 때 부른다.
    public func disconnect() {
        NotificationCenter.default.removeObserver(self)
        placed.removeAll()
        source = nil
        target = nil
    }

    public var isConnected: Bool { source != nil && target != nil }

    /// 지금의 짝짓기. 어느 쪽 글이든 바뀌었으면 다시 짓는다.
    public func currentAlignment() -> BlockAlignment? {
        guard let source, let target else { return nil }
        if let cached = alignment, cached.sourceRevision == source.blockRevision,
           cached.targetRevision == target.blockRevision {
            return cached.value
        }
        let value = BlockAlignment.align(source: source.blocks, target: target.blocks)
        alignment = (source.blockRevision, target.blockRevision, value)
        return value
    }

    /// `editor`의 자리를 다른 쪽에 옮긴다. 창을 처음 붙일 때와 시험에서 부른다.
    public func follow(_ editor: MarkdownEditorView) {
        guard let source, let target, let alignment = currentAlignment() else { return }
        let position = editor.scrollReferencePosition()
        let other: MarkdownEditorView
        let mapped: Double
        if editor === source {
            other = target
            mapped = alignment.targetPosition(forSource: position)
        } else if editor === target {
            other = source
            mapped = alignment.sourcePosition(forTarget: position)
        } else {
            return
        }
        // 먼저 기억하고 옮긴다 — 알림이 `scroll` 안에서 바로 올 수도, 나중에 올 수도 있다.
        // 옮긴 뒤에는 실제로 놓인 자리로 다시 적는다(클립 뷰가 픽셀에 맞출 수 있다).
        let key = ObjectIdentifier(other)
        placed[key] = other.originForReferencePosition(mapped)
        placed[key] = other.scroll(toReferencePosition: mapped)
    }

    private func boundsDidChange(in editor: MarkdownEditorView) {
        let key = ObjectIdentifier(editor)
        if let expected = placed[key],
           abs(editor.clipView.bounds.origin.y - expected) <= Self.echoTolerance {
            return   // 이쪽이 옮긴 것의 메아리다
        }
        placed[key] = nil
        follow(editor)
    }
}
