import Foundation

/// 마크다운 표 하나를 칸 단위로 읽는다.
///
/// 왜 필요한가: 표를 **읽기 좋게 그리려면** 칸의 경계와 열의 정렬을 알아야 한다.
/// 중요한 제약이 하나 있다 — **문서를 고쳐서 맞추면 안 된다.** 공백을 끼워 넣어
/// 열을 맞추는 흔한 방법은 저장할 때 원문이 달라지므로 쓸 수 없다. 그래서 이 조각은
/// **위치만** 알려 주고, 맞추는 일은 그리는 쪽이 글자 간격으로 한다.
public struct MarkdownTable: Equatable {

    public enum Alignment: Equatable, Sendable {
        case none
        case left
        case center
        case right

        /// 구분 행의 한 칸(`:---`, `:--:`, `---:`)을 읽는다.
        static func read(_ spec: String) -> Alignment {
            let trimmed = spec.trimmingCharacters(in: .whitespaces)
            let leading = trimmed.hasPrefix(":")
            let trailing = trimmed.hasSuffix(":")
            switch (leading, trailing) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            case (false, false): return .none
            }
        }
    }

    public enum RowKind: Equatable, Sendable {
        case header
        case delimiter
        case body
    }

    public struct Row: Equatable, Sendable {
        public let lineNumber: Int
        /// 줄 전체(줄바꿈 제외).
        public let range: NSRange
        /// 칸의 **내용** 범위. 앞뒤 공백을 뺀 자리다. 빈 칸은 길이 0이다.
        public let cells: [NSRange]
        /// 칸 구분자 `|`의 범위. 줄 맨 앞·맨 끝의 것도 들어간다.
        public let separators: [NSRange]
        public let kind: RowKind
    }

    public let rows: [Row]
    /// 열별 정렬. 구분 행이 말해 준다. 구분 행이 없으면 빈 배열이다.
    public let alignments: [Alignment]

    /// 열 수. 가장 칸이 많은 행을 따른다 — 행마다 칸 수가 다른 표가 현실에 있다.
    public var columnCount: Int {
        rows.map(\.cells.count).max() ?? 0
    }

    public func alignment(forColumn column: Int) -> Alignment {
        column < alignments.count ? alignments[column] : .none
    }

    // MARK: 묶어 읽기

    /// 스캔된 줄에서 이어진 표 블록들을 뽑는다.
    ///
    /// 구분 행이 **없는** 연속 행은 표로 보지 않는다. `| 뭐 |` 한 줄만 있는 문단이
    /// 표로 둔갑하면 평범한 글이 격자로 그려진다.
    public static func blocks(in text: NSString, lines: [LineToken]) -> [MarkdownTable] {
        var tables: [MarkdownTable] = []
        var run: [LineToken] = []

        func flush() {
            defer { run = [] }
            guard run.count >= 2,
                  let delimiterIndex = run.firstIndex(where: { $0.kind == .tableDelimiter }),
                  delimiterIndex > 0
            else { return }

            var rows: [Row] = []
            var alignments: [Alignment] = []

            for (offset, line) in run.enumerated() {
                let parsed = parseRow(line, in: text)
                let kind: RowKind
                if line.kind == .tableDelimiter {
                    kind = .delimiter
                    alignments = parsed.cells.map { Alignment.read(text.substring(with: $0)) }
                } else {
                    kind = offset < delimiterIndex ? .header : .body
                }
                rows.append(Row(lineNumber: line.lineNumber, range: line.range,
                                cells: parsed.cells, separators: parsed.separators, kind: kind))
            }
            tables.append(MarkdownTable(rows: rows, alignments: alignments))
        }

        for line in lines {
            if line.kind == .tableRow || line.kind == .tableDelimiter {
                run.append(line)
            } else {
                flush()
            }
        }
        flush()
        return tables
    }

    // MARK: 한 행 쪼개기

    /// 한 줄을 칸과 구분자로 나눈다.
    ///
    /// 두 가지를 피해 간다 — `\|`는 칸을 나누지 않는 글자 그대로의 막대이고,
    /// 인라인 코드(`` `a|b` ``) 안의 막대도 칸을 나누지 않는다. 둘을 무시하면
    /// 한 칸이 둘로 쪼개져 열이 어긋난다.
    static func parseRow(_ line: LineToken, in text: NSString) -> (cells: [NSRange],
                                                                   separators: [NSRange]) {
        let start = line.range.location
        let end = NSMaxRange(line.range)
        guard end > start else { return ([], []) }

        var separators: [NSRange] = []
        var inCode = false
        var index = start

        while index < end {
            let character = text.character(at: index)
            if character == 92, index + 1 < end {        // 역슬래시 — 다음 글자를 건너뛴다
                index += 2
                continue
            }
            if character == 96 {                          // 백틱 — 코드 구간 토글
                inCode.toggle()
                index += 1
                continue
            }
            if character == 124, !inCode {                // 막대
                separators.append(NSRange(location: index, length: 1))
                index += 1
                continue
            }
            index += 1
        }

        // 구분자 사이가 칸이다. 맨 앞·맨 끝의 막대 밖은 칸으로 세지 않는다
        // (`| a | b |`는 두 칸이고, 공백뿐인 양 끝은 버린다).
        var bounds: [(Int, Int)] = []
        var cursor = start
        for separator in separators {
            bounds.append((cursor, separator.location))
            cursor = NSMaxRange(separator)
        }
        bounds.append((cursor, end))

        var cells: [NSRange] = []
        for (index, bound) in bounds.enumerated() {
            let isEdge = index == 0 || index == bounds.count - 1
            let raw = NSRange(location: bound.0, length: max(0, bound.1 - bound.0))
            let trimmed = trim(raw, in: text)
            // 양 끝의 막대 바깥이 비어 있으면 칸이 아니다.
            if isEdge, trimmed.length == 0, !separators.isEmpty { continue }
            cells.append(trimmed)
        }
        return (cells, separators)
    }

    /// 앞뒤 공백을 뺀 범위. 내용이 없으면 길이 0으로, 시작 자리는 유지한다.
    private static func trim(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        func isSpace(_ index: Int) -> Bool {
            let scalar = text.character(at: index)
            return scalar == 32 || scalar == 9
        }
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }
}
