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
    init(rows: [Row], columnCount: Int, lineHeight: CGFloat, maxWidth: CGFloat, minimumColumnWidth: CGFloat) {
        self.rows = rows
        let horizontal = Self.padding.left + Self.padding.right
        let vertical = Self.padding.top + Self.padding.bottom

        var natural = [CGFloat](repeating: horizontal, count: columnCount)
        for row in rows {
            for (column, cell) in row.cells.enumerated() where column < columnCount {
                natural[column] = max(natural[column], ceil(cell.size().width) + horizontal)
            }
        }
        let widths = Self.columnWidths(natural: natural, available: maxWidth,
                                       minimum: min(minimumColumnWidth, maxWidth / CGFloat(max(1, columnCount))))
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
                let frame = frames[rowIndex][column]
                let text = NSRect(x: frame.minX + Self.padding.left, y: frame.minY + Self.padding.top,
                                  width: frame.width - Self.padding.left - Self.padding.right,
                                  height: frame.height - Self.padding.top - Self.padding.bottom)
                cell.draw(with: text, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
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
