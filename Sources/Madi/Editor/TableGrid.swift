import AppKit

/// 캐럿이 없는 표를 **격자로** 그린다 — 칸 안에서 줄을 바꾸고, 막대(`|`)와 구분 행(`| --- |`)은 그리지
/// 않으며, 머리 행은 굵게 바탕을 깐다.
///
/// 왜 원문 위에 맞추지 않고 따로 그리는가(실측, 860pt 창의 세 열 한국어 표): 원문의 한 행은 한 줄이라
/// 행이 글 넓이보다 길면 **행 자체가 다음 줄로 넘어간다.** 맞춰 둔 막대가 다음 줄 첫머리로 떨어져
/// 격자가 무너지고, 여덟 행 표의 모든 행이 그렇게 꺾였다. 칸 안에서 줄을 바꾸려면 칸이 제 폭을 가진
/// 상자여야 하는데, 원문을 고치지 않고는(`NSTextTable`은 칸마다 문단이 따로 있어야 한다) 글자 속성으로
/// 그 상자를 만들 수 없다. 그래서 다이어그램처럼 표 자리를 비우고 그 자리에 그린다
/// (`MarkdownStyler.placeTables`). 캐럿이 표에 들어오면 원문을 보인다 — 고치려면 원문이 보여야 한다.
///
/// 열 너비는 칸의 글을 한 줄로 쓴 폭을 따르고, 다 합쳐 글 넓이를 넘으면 좁은 열은 제 폭을 갖고 넓은
/// 열이 나머지를 나눈다(`columnWidths`). 칸은 위에서부터 채운다.
struct TableGrid {

    struct Row {
        var cells: [NSAttributedString]
        var isHeader: Bool
    }

    let rows: [Row]
    let columnWidths: [CGFloat]
    let rowHeights: [CGFloat]
    let size: CGSize

    /// 칸 안의 여백.
    static let padding = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    static let cornerRadius: CGFloat = 6

    /// - Parameters:
    ///   - lineHeight: 빈 칸 하나의 높이(본문 한 줄).
    ///   - maxWidth: 표가 쓸 수 있는 폭(글 넓이).
    ///   - minimumColumnWidth: 열이 이보다 좁아지지 않는다 — 아주 좁으면 글자마다 줄이 바뀐다.
    ///   - readableWidth: 주면 열이 **읽을 만한 폭**보다 좁아지지 않는다 — 이 폭과 열의 가장 긴 낱말 중 넓은 쪽(제 폭보다
    ///     넓지는 않다). 그래서 표가 `maxWidth`보다 넓어질 수 있고, 편집기는 넓은 표를 가로로 굴린다(사용자 — "표도
    ///     마찬가지", 고른 것: 열이 너무 좁아지지 않게 두고 넘치는 표만 가로로). nil이면 전처럼 `maxWidth`에 맞춘다
    ///     (내보내기 — 종이는 굴릴 수 없다).
    init(rows: [Row], columnCount: Int, lineHeight: CGFloat, maxWidth: CGFloat, minimumColumnWidth: CGFloat,
         readableWidth: CGFloat? = nil) {
        self.rows = rows
        let horizontal = Self.padding.left + Self.padding.right
        let vertical = Self.padding.top + Self.padding.bottom

        var natural = [CGFloat](repeating: horizontal, count: columnCount)
        var longestWord = [CGFloat](repeating: 0, count: columnCount)
        for row in rows {
            for (column, cell) in row.cells.enumerated() where column < columnCount {
                natural[column] = max(natural[column], ceil(cell.size().width) + horizontal)
                if readableWidth != nil {
                    longestWord[column] = max(longestWord[column], Self.longestWordWidth(in: cell))
                }
            }
        }
        let widths: [CGFloat]
        if let readableWidth {
            let minimums = natural.indices.map { column in
                min(natural[column], max(readableWidth, min(longestWord[column], Self.longestWordCap)) + horizontal)
            }
            widths = Self.columnWidths(natural: natural, available: maxWidth, minimums: minimums)
        } else {
            widths = Self.columnWidths(natural: natural, available: maxWidth,
                                       minimum: min(minimumColumnWidth, maxWidth / CGFloat(max(1, columnCount))))
        }
        columnWidths = widths

        rowHeights = rows.map { row in
            var height = lineHeight
            for (column, cell) in row.cells.enumerated() where column < widths.count && cell.length > 0 {
                let bounds = cell.boundingRect(with: NSSize(width: widths[column] - horizontal,
                                                            height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
                height = max(height, ceil(bounds.height))
            }
            return height + vertical
        }
        size = CGSize(width: widths.reduce(0, +), height: rowHeights.reduce(0, +))
    }

    /// 열 너비. 다 합쳐 `available` 안이면 제 폭 그대로다.
    ///
    /// 넘으면 **좁은 열부터** 제 폭을 준다 — 남은 폭을 남은 열 수로 나눈 몫보다 좁은 열이다. 그런 열이
    /// 더 없으면 남은 폭을 남은 열의 제 폭에 비례해 나눈다. `구성요소 | 설명 | 경계`처럼 이름 열이
    /// 짧고 설명 열이 긴 표에서, 이름은 한 줄로 남고 긴 열만 줄이 바뀐다. 모든 열을 비례로 줄이면
    /// 짧은 이름까지 꺾인다.
    static func columnWidths(natural: [CGFloat], available: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard natural.reduce(0, +) > available, !natural.isEmpty else { return natural }
        var widths = natural
        var open = Array(natural.indices)
        var remaining = available
        while !open.isEmpty {
            let share = remaining / CGFloat(open.count)
            let fits = open.filter { natural[$0] <= share }
            guard !fits.isEmpty else { break }
            for column in fits { remaining -= natural[column] }
            open.removeAll { fits.contains($0) }
        }
        let openTotal = open.reduce(CGFloat(0)) { $0 + natural[$1] }
        for column in open where openTotal > 0 {
            widths[column] = max(minimum, (remaining * natural[column] / openTotal).rounded(.down))
        }
        return widths
    }

    /// 열마다 최소 폭이 있는 열 너비. 다 합쳐 `available` 안이면 제 폭 그대로, 최소들만으로도 넘치면 최소들(표가
    /// 넓어진다 — 편집기가 가로로 굴린다). 그 사이면 위의 규칙(좁은 열부터 제 폭)으로 나눈 뒤 최소를 지키고, 그만큼
    /// 넘친 몫을 최소보다 넓은 열에서 남는 폭에 비례해 뺀다 — 넓은 설명 열이 덜고 이름 열은 그대로다.
    static func columnWidths(natural: [CGFloat], available: CGFloat, minimums: [CGFloat]) -> [CGFloat] {
        guard natural.reduce(0, +) > available, !natural.isEmpty else { return natural }
        let floors = zip(natural, minimums).map { min($0, $1) }
        guard floors.reduce(0, +) < available else { return floors.map { $0.rounded(.up) } }
        var widths = zip(columnWidths(natural: natural, available: available, minimum: 0), floors).map { max($0, $1) }
        let excess = widths.reduce(0, +) - available
        if excess > 0.5 {
            let slack = widths.indices.map { widths[$0] - floors[$0] }
            let total = slack.reduce(0, +)
            if total > 0 {
                for column in widths.indices {
                    widths[column] = (widths[column] - excess * slack[column] / total).rounded(.down)
                }
            }
        }
        return widths
    }

    /// 칸의 가장 긴 낱말(공백으로 나눈 조각)의 폭. 주소처럼 아주 긴 것은 `longestWordCap`에서 자른다 — 그보다 긴 낱말은
    /// 칸 안에서 글자 단위로 꺾인다.
    static func longestWordWidth(in cell: NSAttributedString) -> CGFloat {
        let text = cell.string as NSString
        var widest: CGFloat = 0
        var start: Int?
        func measure(upTo end: Int) {
            guard let begin = start, end > begin else { return }
            widest = max(widest, ceil(cell.attributedSubstring(from: NSRange(location: begin, length: end - begin))
                .size().width))
        }
        for index in 0 ..< text.length {
            let unit = text.character(at: index)
            if unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x3000 {
                measure(upTo: index)
                start = nil
            } else if start == nil {
                start = index
            }
        }
        measure(upTo: text.length)
        return widest
    }

    static let longestWordCap: CGFloat = 320

    /// 칸들의 사각형(그리는 좌표, 위가 0). 테스트와 그리기가 함께 쓴다.
    func cellFrames() -> [[NSRect]] {
        var frames: [[NSRect]] = []
        var y: CGFloat = 0
        for (index, _) in rows.enumerated() {
            var x: CGFloat = 0
            var row: [NSRect] = []
            for width in columnWidths {
                row.append(NSRect(x: x, y: y, width: width, height: rowHeights[index]))
                x += width
            }
            frames.append(row)
            y += rowHeights[index]
        }
        return frames
    }

    /// 칸 안에서 글이 놓이는 사각형 — 칸에서 여백을 뺀 자리. 그리기와 링크 찾기가 같은 자리를 쓴다.
    static func textFrame(in cell: NSRect) -> NSRect {
        NSRect(x: cell.minX + padding.left, y: cell.minY + padding.top,
               width: cell.width - padding.left - padding.right,
               height: cell.height - padding.top - padding.bottom)
    }

    /// 점(격자 좌표, 위가 0) 아래 글자의 링크 주소. 글자 위가 아니면(칸의 빈 자리, 여백) nil이다.
    ///
    /// 격자는 그림이라 텍스트 뷰가 그 안의 글자를 모른다. 그래서 그 칸의 글을 그릴 때와 같은 폭으로
    /// 다시 놓아 보고 점 아래의 글자를 찾는다. ⌘클릭을 받을 때만 부른다.
    func link(at point: NSPoint) -> String? {
        let frames = cellFrames()
        for (rowIndex, row) in frames.enumerated() {
            for (column, frame) in row.enumerated() where frame.contains(point) {
                guard column < rows[rowIndex].cells.count else { return nil }
                let cell = rows[rowIndex].cells[column]
                guard cell.length > 0 else { return nil }
                let text = Self.textFrame(in: frame)
                let local = NSPoint(x: point.x - text.minX, y: point.y - text.minY)

                let storage = NSTextStorage(attributedString: cell)
                let layout = NSLayoutManager()
                let container = NSTextContainer(size: NSSize(width: text.width, height: .greatestFiniteMagnitude))
                // 문자열 그리기(`draw(with:options:)`)는 줄 조각 여백 없이 놓는다 — 같게 맞춘다.
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                storage.addLayoutManager(layout)
                layout.ensureLayout(for: container)
                let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
                guard glyph < layout.numberOfGlyphs else { return nil }
                let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                guard box.contains(local) else { return nil }
                let index = layout.characterIndexForGlyph(at: glyph)
                guard index < storage.length else { return nil }
                return storage.attribute(.mdLinkTarget, at: index, effectiveRange: nil) as? String
            }
        }
        return nil
    }

    /// 뒤집힌 좌표(위가 0)에 그린다. 색은 그리는 때의 외관으로 풀린다 — 다크로 바꿔도 다시 만들지 않는다.
    func draw(line: NSColor, headerBackground: NSColor) {
        let bounds = NSRect(origin: .zero, size: size)
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        let frames = cellFrames()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        headerBackground.setFill()
        for (index, row) in rows.enumerated() where row.isHeader {
            if let first = frames[index].first {
                NSRect(x: 0, y: first.minY, width: size.width, height: first.height).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        line.setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for row in frames.dropFirst() {
            guard let first = row.first else { continue }
            grid.move(to: NSPoint(x: 0, y: first.minY + 0.5))
            grid.line(to: NSPoint(x: size.width, y: first.minY + 0.5))
        }
        if let row = frames.first {
            for cell in row.dropFirst() {
                grid.move(to: NSPoint(x: cell.minX + 0.5, y: 0))
                grid.line(to: NSPoint(x: cell.minX + 0.5, y: size.height))
            }
        }
        grid.stroke()
        outline.lineWidth = 1
        outline.stroke()

        for (rowIndex, row) in rows.enumerated() {
            for (column, cell) in row.cells.enumerated() where column < columnWidths.count && cell.length > 0 {
                cell.draw(with: Self.textFrame(in: frames[rowIndex][column]),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
        }
    }

    /// 그리는 그림. 그때마다 그린다(`cacheMode = .never`) — 글자가 화면 배율대로 또렷하고, 외관이
    /// 바뀌어도 낡은 색이 남지 않는다.
    func image(line: NSColor, headerBackground: NSColor) -> NSImage {
        let grid = self
        let image = NSImage(size: size, flipped: true) { _ in
            grid.draw(line: line, headerBackground: headerBackground)
            return true
        }
        image.cacheMode = .never
        return image
    }
}
