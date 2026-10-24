import AppKit

/// 코드 블록 뒤에 **블록 전체 너비로** 배경을 그리는 텍스트 뷰.
///
/// 왜 그리기로 넘겼는가: 전에는 코드 줄의 글자마다 `.backgroundColor`를 줬다. 그러면
/// 글자가 있는 만큼만 칠해져서 줄마다 오른쪽 끝이 다르고, 블록이 하나의 덩이로 보이지
/// 않는다. 글자 수에 따라 배경이 들쭉날쭉해지는 것은 속성으로는 고칠 수 없다 —
/// 배경이 글자의 성질이 아니라 **블록의 성질**이기 때문이다.
///
/// `NSTextBlock`을 쓰는 길도 있지만 문단마다 블록이 생겨 줄 사이에 이음선이 보이고,
/// 여백을 다루기가 까다롭다. 직접 그리면 블록 하나가 둥근 사각형 하나가 된다.
public final class CodeBlockBackgroundTextView: NSTextView {

    /// 칠할 코드 블록의 문자 범위. `MarkdownStyler`가 계산해 넘긴다.
    public var codeBlockRanges: [NSRange] = [] {
        didSet {
            guard codeBlockRanges != oldValue else { return }
            needsDisplay = true
        }
    }

    public var codeBlockColor: NSColor = .quaternarySystemFill {
        didSet { needsDisplay = true }
    }

    /// 글자와 배경 사이의 여백.
    public var codeBlockPadding = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
    public var codeBlockCornerRadius: CGFloat = 6

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !codeBlockRanges.isEmpty,
              let layoutManager, let textContainer else { return }

        let origin = textContainerOrigin
        codeBlockColor.setFill()

        for range in codeBlockRanges {
            guard range.length > 0, NSMaxRange(range) <= (textStorage?.length ?? 0) else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                      actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }

            // 블록이 차지하는 줄들의 높이. 가로는 쓰지 않는다 — 글자 폭을 따라가면
            // 다시 들쭉날쭉해지므로 **글 넓이 전체**로 바꿔 끼운다.
            var box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            box.origin.x = origin.x + textContainer.lineFragmentPadding
            box.size.width = textContainer.size.width - textContainer.lineFragmentPadding * 2
            box.origin.y += origin.y

            let padded = NSRect(
                x: box.minX - codeBlockPadding.left,
                y: box.minY - codeBlockPadding.top,
                width: box.width + codeBlockPadding.left + codeBlockPadding.right,
                height: box.height + codeBlockPadding.top + codeBlockPadding.bottom
            )
            // 보이는 데만 그린다 — 큰 문서를 굴릴 때 블록 전부를 칠할 이유가 없다.
            guard padded.intersects(rect) else { continue }
            NSBezierPath(roundedRect: padded,
                         xRadius: codeBlockCornerRadius,
                         yRadius: codeBlockCornerRadius).fill()
        }
    }
}
