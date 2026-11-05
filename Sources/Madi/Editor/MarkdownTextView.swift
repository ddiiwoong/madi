import AppKit

/// 기본 편집기의 텍스트 뷰. 그리기는 `DecoratedTextView`가 하고, 여기서는 편집기에 먼저
/// 묻는 것 두 가지를 받는다 — **글자 위의 클릭**(체크박스 누르기, ⌘클릭으로 링크 열기와 각주
/// 오가기)과 **그림 넣기**(붙여넣기·끌어놓기).
///
/// 판단은 편집기(`MarkdownEditorView`)가 한다. 여기는 클릭이 어느 글자 위인지만 잰다.
/// 블록 편집기의 텍스트 뷰는 이것을 물려받지 않는다(그쪽은 자기 클릭 규칙이 있다).
public final class MarkdownTextView: DecoratedTextView {

    /// 클릭한 글자의 위치와 보조 키를 받는다. true를 돌려주면 클릭을 먹는다 — 캐럿이
    /// 옮겨 가지 않는다.
    var clickHandler: ((_ characterIndex: Int, _ modifiers: NSEvent.ModifierFlags) -> Bool)?

    /// 대지에 그림이 있으면 받는다(붙여넣기·끌어놓기). 범위가 nil이면 지금 선택을 바꾼다.
    /// true를 돌려주면 처리한 것이다 — 평소의 붙여넣기(파일 이름이나 경로를 글로)를 하지 않는다.
    var imageInsertHandler: ((_ pasteboard: NSPasteboard, _ range: NSRange?) -> Bool)?

    public override func paste(_ sender: Any?) {
        if let imageInsertHandler, ImagePasteboard.holdsImages(.general), imageInsertHandler(.general, nil) {
            return
        }
        super.paste(sender)
    }

    /// 파일과 그림 데이터도 끌어놓을 수 있게 한다. 글만 받는 텍스트 뷰는 이것들을 받지 않는다.
    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        for type in [NSPasteboard.PasteboardType.fileURL, .png, .tiff] where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    public override func dragOperation(for dragInfo: NSDraggingInfo,
                                       type: NSPasteboard.PasteboardType) -> NSDragOperation {
        if isEditable, imageInsertHandler != nil, isForeign(dragInfo),
           ImagePasteboard.holdsImages(dragInfo.draggingPasteboard) {
            return .copy
        }
        return super.dragOperation(for: dragInfo, type: type)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isEditable, let imageInsertHandler, isForeign(sender),
           ImagePasteboard.holdsImages(sender.draggingPasteboard) {
            let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
            if imageInsertHandler(sender.draggingPasteboard, NSRange(location: index, length: 0)) {
                return true
            }
        }
        return super.performDragOperation(sender)
    }

    /// 이 뷰 안에서 글을 끌어 옮기는 것은 그림 넣기가 아니다.
    private func isForeign(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as AnyObject?) !== self
    }

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
