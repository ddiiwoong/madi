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
/// 블록 편집기의 `BlockTextView`가 이 클래스를 물려받는다(코드 배경·그림 그리기를
/// 그대로 쓰고 블록 경계 처리만 더한다). 그래서 `final`이 아니다.
public class DecoratedTextView: NSTextView {

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
        guard let visible = visibleCharacterRange(in: rect) else { return }
        drawCodeBlocks(in: rect, visible: visible)
        drawImages(in: rect, visible: visible)
    }

    /// 그릴 사각형에 걸친 글자 범위. 블록과 그림은 **이 범위에 닿는 것만** 묻는다.
    ///
    /// 왜(실측, 22만 자 문서): 전에는 그릴 때마다 문서의 코드 블록 **전부**에
    /// `boundingRect`를 물었다. 문서 끝의 블록을 물으면 TextKit이 거기까지 레이아웃을
    /// 끝내야 하므로, 첫 화면 하나를 그리는 데 문서 전체를 놓았다 — 그것도 한 번에
    /// 놓는 것(`ensureLayout`, 0.41초)보다 열 배 느리게 조각조각(4.7초). 글 앞쪽에서
    /// 한 글자를 칠 때마다 그 뒤의 레이아웃이 무효가 되므로 **타이핑 한 번에 4.5초**가
    /// 들었다. 이 질의는 사각형까지만 레이아웃한다.
    ///
    /// 위아래로 블록 여백만큼 넓혀 묻는다 — 배경은 글자보다 여백만큼 크므로, 글자가
    /// 사각형 밖에 있어도 배경의 가장자리는 안에 들어올 수 있다.
    private func visibleCharacterRange(in rect: NSRect) -> NSRange? {
        guard let layoutManager, let textContainer else { return nil }
        let origin = textContainerOrigin
        let margin = max(codeBlockPadding.top, codeBlockPadding.bottom) + 1
        let query = NSRect(x: rect.minX - origin.x, y: rect.minY - origin.y - margin,
                           width: rect.width, height: rect.height + margin * 2)
        let glyphs = layoutManager.glyphRange(forBoundingRect: query, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// `ranges`(위치 순) 가운데 `visible`에 닿는 것. 블록이 수백 개라 이분 탐색으로
    /// 첫 후보를 찾는다.
    static func ranges(_ ranges: [NSRange], touching visible: NSRange) -> ArraySlice<NSRange> {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(ranges[mid]) < visible.location { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < ranges.count, ranges[end].location <= NSMaxRange(visible) { end += 1 }
        return ranges[lo ..< end]
    }

    private func drawCodeBlocks(in rect: NSRect, visible: NSRange) {
        guard !codeBlockRanges.isEmpty,
              let layoutManager, let textContainer else { return }

        let origin = textContainerOrigin
        codeBlockColor.setFill()

        for range in Self.ranges(codeBlockRanges, touching: visible) {
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
    private func drawImages(in rect: NSRect, visible: NSRange) {
        guard !imagePlacements.isEmpty,
              let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin

        for placement in imagePlacements
        where NSIntersectionRange(placement.lineRange, visible).length > 0
            || NSLocationInRange(placement.lineRange.location, visible) {
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
