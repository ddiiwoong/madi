import Foundation

/// 마크다운 원문을 블록의 배열로 읽는다 — `docs/block-editor-design.md` §6의 왼쪽 절반.
///
/// 줄 종류는 **다시 판정하지 않는다.** `MarkdownSyntax.scanLines`가 이미 하고 있고,
/// 두 번째 판정기를 두면 스타일러가 칠하는 것과 블록 편집기가 보는 것이 언젠가
/// 갈라진다. 이 파일이 하는 일은 그 줄들을 **덩어리로 묶는 것**뿐이다.
///
/// ## 조각 경계
///
/// 블록의 원문 조각은 `[이 블록 첫 줄의 시작, 다음 블록 첫 줄의 시작)`이다.
/// 줄 토큰의 범위는 줄바꿈을 빼고 있으므로, 다음 줄의 시작까지를 가져와야 줄바꿈이
/// 조각 안에 들어온다. 그래서 조각들을 그냥 이어붙이면 원문이 된다.
public struct BlockParser: Sendable {

    public init() {}

    public func parse(_ text: String) -> BlockDocument {
        let frontMatter = FrontMatter.parse(text)
        let body = frontMatter?.body ?? text
        return BlockDocument(frontMatter: frontMatter, blocks: parseBlocks(body))
    }

    public func parseBlocks(_ body: String) -> [Block] {
        let ns = body as NSString
        let lines = MarkdownSyntax().scanLines(in: ns)
        guard !lines.isEmpty else { return [] }

        /// `[from, to)` 줄들의 원문 조각. `to`가 끝이면 문서 끝까지.
        func slice(_ from: Int, _ to: Int) -> String {
            let start = lines[from].range.location
            let end = to < lines.count ? lines[to].range.location : ns.length
            guard end > start else { return "" }
            return ns.substring(with: NSRange(location: start, length: end - start))
        }

        var blocks: [Block] = []
        func append(_ kind: Block.Kind, _ from: Int, _ to: Int) {
            let text = slice(from, to)
            // 길이 0 조각은 블록이 아니다. 문서가 줄바꿈으로 끝나면 `scanLines`가
            // 그 뒤의 빈 줄을 토큰 하나로 더 내놓는데, 그 줄에는 바이트가 없다 —
            // 줄바꿈은 이미 앞 줄의 조각에 들어 있다.
            guard !text.isEmpty else { return }
            blocks.append(Block(kind: kind, sourceSlice: text))
        }

        var index = 0
        while index < lines.count {
            switch lines[index].kind {

            case .blank:
                let end = run(from: index, in: lines) { $0.kind == .blank }
                append(.blankLines, index, end)
                index = end

            case .codeFence:
                // 여는 펜스부터 **닫는 펜스까지 포함**해 한 블록이다. 닫히지 않은
                // 펜스는 문서 끝까지 — 그것이 마크다운의 동작이고, 그렇게 묶지 않으면
                // 코드 안의 `#`나 `|`가 제목·표로 둔갑한다.
                let language = lines[index].language
                var end = index + 1
                while end < lines.count {
                    let isFence = lines[end].kind == .codeFence
                    end += 1
                    if isFence { break }
                }
                append(.codeBlock(language: language), index, end)
                index = end

            case .thematicBreak:
                append(.thematicBreak, index, index + 1)
                index += 1

            case .heading(let level):
                append(.heading(level: level), index, index + 1)
                index += 1

            case .quote:
                let end = run(from: index, in: lines) { if case .quote = $0.kind { return true } else { return false } }
                append(.quote, index, end)
                index = end

            case .listItem(let ordered, _):
                var end = index + 1
                while end < lines.count {
                    if case .listItem = lines[end].kind { end += 1; continue }
                    // 들여쓴 글줄은 앞 항목이 이어지는 것이다(`- 항목` 다음 줄의 `  계속`).
                    if lines[end].kind == .paragraph, isIndented(lines[end], in: ns) { end += 1; continue }
                    break
                }
                append(.list(ordered: ordered), index, end)
                index = end

            case .tableRow, .tableDelimiter:
                let end = run(from: index, in: lines) {
                    $0.kind == .tableRow || $0.kind == .tableDelimiter
                }
                let kind = tableKind(Array(lines[index..<end]), in: ns)
                append(kind, index, end)
                index = end

            case .paragraph, .codeBody:
                // `.codeBody`는 펜스 안에서만 나오고 위에서 이미 먹혔다. 여기 오는 것은
                // 있을 수 없는 경우이므로 글줄로 다룬다 — 떨어뜨리면 그 줄이 사라진다.
                let end = run(from: index, in: lines) {
                    $0.kind == .paragraph || $0.kind == .codeBody
                }
                append(.paragraph, index, end)
                index = end
            }
        }
        return blocks
    }

    // MARK: 묶기 도우미

    private func run(from start: Int, in lines: [LineToken],
                     while predicate: (LineToken) -> Bool) -> Int {
        var end = start
        while end < lines.count, predicate(lines[end]) { end += 1 }
        return max(end, start + 1)
    }

    private func isIndented(_ line: LineToken, in text: NSString) -> Bool {
        guard line.range.length > 0, line.range.location < text.length else { return false }
        let first = text.character(at: line.range.location)
        return first == 32 || first == 9
    }

    /// 표로 볼지 가린다. 구분 행이 없는 연속 행은 표가 아니다 — `| 뭐 |` 한 줄짜리
    /// 글이 격자로 둔갑하면 안 된다. 그 판정은 `MarkdownTable`이 이미 하고 있다.
    private func tableKind(_ run: [LineToken], in text: NSString) -> Block.Kind {
        guard let table = MarkdownTable.blocks(in: text, lines: run).first else {
            return .paragraph
        }
        var rows: [[String]] = []
        var headerRowCount = 0
        var seenDelimiter = false
        for row in table.rows {
            if row.kind == .delimiter {
                seenDelimiter = true
                continue
            }
            if !seenDelimiter { headerRowCount += 1 }
            rows.append(row.cells.map { text.substring(with: $0) })
        }
        return .table(TableModel(alignments: table.alignments,
                                 rows: rows,
                                 headerRowCount: headerRowCount))
    }
}
