import AppKit

/// 줄을 바꾸지 않고 그린 코드 블록 한 덩이 — 글 넓이보다 긴 줄이 있는 블록을 읽을 때 쓴다(사용자 — "코드 줄바꿈되는
/// 건 어떻게 하는 게 좋을까", 고른 것: 읽을 때는 가로로 굴리고 고칠 때는 줄을 바꾼 원문).
///
/// 왜: `kubectl get … -owide`처럼 칸을 맞춘 출력은 줄이 바뀌면 칸이 어긋나 읽을 수 없다(받은 Notion 문서에서 봄).
/// 텍스트 뷰는 문단마다 줄 바꿈을 끌 수 없으므로(`NSTextView` 하나에 글 넓이 하나), 표처럼 블록 자리를 비우고
/// 그 자리에 이 그림을 놓는다(`MarkdownStyler.placeWideCode`). 그림이 글 넓이보다 넓으므로 텍스트 뷰가 가로로 굴리는
/// 보기(`WidePlacementView`)에 담는다. 캐럿이 블록에 들어오면 원문(줄을 바꾼 글)이 된다.
///
/// 그리기는 자기 TextKit으로 한다 — 글꼴 · 색 · 줄 간격이 편집기의 코드 줄과 같아 높이가 같고, 누른 자리의 글자를
/// 같은 레이아웃으로 찾는다(`documentIndex(at:)`).
@MainActor
final class CodeBlockRendering {

    let size: CGSize
    let image: NSImage
    private let storage: NSTextStorage
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                         height: CGFloat.greatestFiniteMagnitude))
    /// 그린 글의 UTF-16 자리마다 문서의 자리.
    private let documentIndices: [Int]
    private let documentEnd: Int

    /// 끝의 여백 — 가장 긴 줄의 끝까지 굴렸을 때 마지막 글자가 칸 가장자리에 붙지 않게.
    static let trailingPadding: CGFloat = 16

    /// - Parameters:
    ///   - text: 그릴 글(줄을 `\n`으로 이은 것, 숨긴 표시는 뺀 것).
    ///   - documentIndices: `text`의 UTF-16 자리마다 문서의 자리.
    ///   - documentEnd: 블록 끝의 문서 자리 — 마지막 글자 뒤를 누르면 여기.
    init(text: NSAttributedString, documentIndices: [Int], documentEnd: Int) {
        storage = NSTextStorage(attributedString: text)
        self.documentIndices = documentIndices
        self.documentEnd = documentEnd
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        var width: CGFloat = 0
        var height: CGFloat = 0
        let glyphs = NSRange(location: 0, length: layout.numberOfGlyphs)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in
            width = max(width, used.maxX)
            height = max(height, rect.maxY)
        }
        // 끝 줄이 비면(닫는 펜스) 그 줄은 남는 줄 조각이다 — 그 높이도 센다.
        let extra = layout.extraLineFragmentRect
        if extra.height > 0 { height = max(height, extra.maxY) }
        size = CGSize(width: ceil(width) + Self.trailingPadding, height: ceil(height))

        let layout = self.layout
        let image = NSImage(size: size, flipped: true) { _ in
            layout.drawGlyphs(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs), at: .zero)
            return true
        }
        // 그때마다 그린다 — 글자가 화면 배율대로 또렷하고, 외관을 바꿔도 낡은 색이 남지 않는다(표 격자와 같다).
        image.cacheMode = .never
        self.image = image
    }

    /// 점(그림 좌표, 위가 0) 아래에 캐럿을 놓을 문서 자리.
    func documentIndex(at point: NSPoint) -> Int {
        var fraction: CGFloat = 0
        let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < documentIndices.count else { return documentEnd }
        // 글자의 오른쪽 반을 눌렀으면 그 뒤에.
        if fraction > 0.5, index + 1 < documentIndices.count { return documentIndices[index + 1] }
        if fraction > 0.5 { return documentIndices[index] + 1 }
        return documentIndices[index]
    }

    /// 줄의 수(그린 줄). 시험이 쓴다.
    var lineCount: Int {
        var count = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in
            count += 1
        }
        return count + (layout.extraLineFragmentRect.height > 0 ? 1 : 0)
    }
}
