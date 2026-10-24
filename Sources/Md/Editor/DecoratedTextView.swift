import AppKit

/// 글자 속성으로는 그릴 수 없는 것을 그리는 텍스트 뷰 — 코드 블록 배경과 인라인 그림.
///
/// 왜 그리기로 넘겼는가: 전에는 코드 줄의 글자마다 `.backgroundColor`를 줬다. 그러면
/// 글자가 있는 만큼만 칠해져서 줄마다 오른쪽 끝이 다르고, 블록이 하나의 덩이로 보이지
/// 않는다. 글자 수에 따라 배경이 들쭉날쭉해지는 것은 속성으로는 고칠 수 없다 —
/// 배경이 글자의 성질이 아니라 **블록의 성질**이기 때문이다.
///
/// `NSTextBlock`을 쓰는 길도 있지만 문단마다 블록이 생겨 줄 사이에 이음선이 보이고,
/// 여백을 다루기가 까다롭다. 직접 그리면 블록 하나가 둥근 사각형 하나가 된다.
public final class DecoratedTextView: NSTextView {

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

    /// 그림 자리. `MarkdownStyler`가 계산해 넘긴다.
    public var imagePlacements: [MarkdownStyler.ImagePlacement] = [] {
        didSet {
            guard imagePlacements != oldValue else { return }
            needsDisplay = true
        }
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCodeBlocks(in: rect)
        drawImages(in: rect)
    }

    private func drawCodeBlocks(in rect: NSRect) {
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

    /// 그림을 그린다.
    ///
    /// 문서에 첨부 글자(U+FFFC)를 끼워 넣지 않는다. 그 길은 **실측으로 막혔다**:
    /// 보통 글자에 `.attachment` 속성만 주면 줄 높이가 18pt에서 꼼짝도 하지 않았고
    /// (U+FFFC를 넣은 쪽은 80pt가 됐다), 글자를 끼워 넣으면 원문이 달라진다.
    /// 그래서 스타일러가 `minimumLineHeight`로 자리를 비우고(문서 불변, 실측 80pt
    /// 확보) 여기서 그 자리에 그린다.
    private func drawImages(in rect: NSRect) {
        guard !imagePlacements.isEmpty,
              let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin

        for placement in imagePlacements {
            guard placement.size.width > 0, placement.size.height > 0,
                  NSMaxRange(placement.lineRange) <= (textStorage?.length ?? 0) else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: placement.lineRange,
                                                      actualCharacterRange: nil)
            var box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            box.origin.x += origin.x
            box.origin.y += origin.y

            // 비워 둔 줄 안에 왼쪽 맞춤으로 놓는다.
            let frame = NSRect(
                x: box.minX + textContainer.lineFragmentPadding,
                y: box.minY,
                width: placement.size.width,
                height: min(placement.size.height, box.height)
            )
            guard frame.intersects(rect) else { continue }
            placement.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                                 respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }
}
