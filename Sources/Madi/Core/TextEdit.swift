import Foundation

/// 편집 하나 — 글의 `range`를 `replacement`로 바꾸고 선택을 `selection`에 둔다.
///
/// 편집 규칙(목록 이어 쓰기, 줄 옮기기 등)은 이 값만 계산하고 글을 직접 고치지 않는다.
/// 고치는 일은 편집기가 한 곳에서 한다(`MarkdownEditorView.perform`) — 그래야 모든 편집이
/// 같은 길로 실행 취소에 실리고, 규칙은 AppKit 없이 테스트된다.
///
/// 편집 하나는 **이어진 범위 하나**다. 여러 줄을 들여쓰는 것도 그 줄들을 통째로 바꾸는
/// 편집 하나로 만든다. 범위를 여럿 두면 실행 취소가 조각마다 따로 남는다.
public struct TextEdit: Equatable, Sendable {
    /// 바꿀 범위. 편집 **전** 글의 오프셋(UTF-16)이다.
    public let range: NSRange
    public let replacement: String
    /// 편집 **뒤** 글에서의 선택.
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// 이 편집을 적용한 글. 테스트와 순수 계산이 쓴다.
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}
