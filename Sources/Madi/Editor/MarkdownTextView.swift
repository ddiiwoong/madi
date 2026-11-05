import AppKit

/// 기본 편집기의 텍스트 뷰. 그리기는 `DecoratedTextView`가 하고, 여기서는 **글자 위의
/// 클릭**만 편집기에 먼저 묻는다 — 체크박스 누르기, ⌘클릭으로 링크 열기와 각주 오가기.
///
/// 판단은 편집기(`MarkdownEditorView`)가 한다. 여기는 클릭이 어느 글자 위인지만 잰다.
/// 블록 편집기의 텍스트 뷰는 이것을 물려받지 않는다(그쪽은 자기 클릭 규칙이 있다).
public final class MarkdownTextView: DecoratedTextView {

    /// 클릭한 글자의 위치와 보조 키를 받는다. true를 돌려주면 클릭을 먹는다 — 캐럿이
    /// 옮겨 가지 않는다.
    var clickHandler: ((_ characterIndex: Int, _ modifiers: NSEvent.ModifierFlags) -> Bool)?

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, !hasMarkedText(), let clickHandler,
           let index = characterIndex(under: convert(event.locationInWindow, from: nil)),
           clickHandler(index, event.modifierFlags.intersection(.deviceIndependentFlagsMask)) {
            return
        }
        super.mouseDown(with: event)
    }

    /// 점이 **글자 위에** 있을 때 그 글자의 위치. 줄 끝 너머의 빈 자리나 숨은 마커(폭 0)는
    /// 아무 글자도 아니다 — `characterIndexForInsertion`은 가장 가까운 글자를 돌려주므로
    /// 줄 끝 오른쪽을 눌러도 마지막 글자의 링크가 열리게 된다.
    func characterIndex(under point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else {
            return nil
        }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer,
                                             fractionOfDistanceThroughGlyph: nil)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                             in: textContainer)
        guard box.width > 0, box.contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < storage.length ? index : nil
    }
}
