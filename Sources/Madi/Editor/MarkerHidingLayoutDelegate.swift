import AppKit

/// 마커를 폭 0으로 만드는 `NSLayoutManager` 대리자 — 블록 편집기용.
///
/// `MarkdownEditorView`가 같은 일을 자기 확장으로 하고 있다. 블록 편집기는 블록마다
/// layout manager를 하나씩 갖기 때문에 대리자도 블록마다 필요하고, 편집기 뷰를
/// 대리자로 쓸 수 없어 떼어 냈다. **일부러 남긴 중복이다** — 단계 1이 평가를 넘기면
/// 기존 편집기도 이 클래스를 쓰도록 모아야 한다. 지금 기존 편집기를 건드리지 않는
/// 이유는 설계 §8이 "현재 구조를 지우지 말 것, 단계 1이 실패했을 때 돌아올 곳"이라고
/// 적었기 때문이다.
///
/// `.null` 글리프 속성을 쓰지 않는 이유는 실측으로 확인된 것이다: 같은 런의 뒤쪽
/// 문자 매핑이 깨져 제목의 첫 낱말 뒤가 아예 그려지지 않았다. 제어문자 +
/// `zeroAdvancement`가 문서화된 안전한 길이다.
public final class MarkerHidingLayoutDelegate: NSObject, NSLayoutManagerDelegate {

    private weak var storage: NSTextStorage?

    public init(storage: NSTextStorage) {
        self.storage = storage
        super.init()
    }

    public func layoutManager(_ layoutManager: NSLayoutManager,
                              shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                              properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                              characterIndexes charIndexes: UnsafePointer<Int>,
                              font aFont: NSFont,
                              forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage else { return 0 }
        let count = glyphRange.length
        var adjusted = [NSLayoutManager.GlyphProperty](repeating: [], count: count)
        var changed = false

        for i in 0 ..< count {
            adjusted[i] = props[i]
            let charIndex = charIndexes[i]
            guard charIndex < storage.length else { continue }
            if storage.attribute(.mdHiddenMarker, at: charIndex, effectiveRange: nil) != nil {
                adjusted[i].insert(.controlCharacter)
                changed = true
            }
        }

        guard changed else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: &adjusted, characterIndexes: charIndexes,
                                font: aFont, forGlyphRange: glyphRange)
        return count
    }

    public func layoutManager(_ layoutManager: NSLayoutManager,
                              shouldUse action: NSLayoutManager.ControlCharacterAction,
                              forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if let storage, charIndex < storage.length,
           storage.attribute(.mdHiddenMarker, at: charIndex, effectiveRange: nil) != nil {
            return .zeroAdvancement
        }
        return action
    }
}
