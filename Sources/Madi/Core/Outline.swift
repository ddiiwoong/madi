import Foundation

public struct OutlineEntry: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let level: Int
    public let title: String
    public let lineNumber: Int
    public let range: NSRange

    public static func == (lhs: OutlineEntry, rhs: OutlineEntry) -> Bool {
        lhs.level == rhs.level && lhs.title == rhs.title
            && lhs.lineNumber == rhs.lineNumber && NSEqualRanges(lhs.range, rhs.range)
    }
}

public struct Outline: Sendable {
    public init() {}

    /// Headings in document order. Headings inside a fenced code block are not
    /// headings, so the scanner's fence tracking decides, not a bare regex.
    public static func entries(in text: NSString, syntax: MarkdownSyntax = MarkdownSyntax()) -> [OutlineEntry] {
        entries(lines: syntax.scanLines(in: text), in: text)
    }

    /// 이미 훑은 줄로 만든다. 편집기는 타이핑마다 목차를 갱신하므로 줄 스캔을 다시 하지
    /// 않고 자기가 가진 것을 넘긴다. `lines`는 `text`의 것이어야 한다.
    public static func entries(lines: [LineToken], in text: NSString) -> [OutlineEntry] {
        lines.compactMap { token in
            guard case let .heading(level) = token.kind else { return nil }
            let title = token.contentRange.length > 0
                ? text.substring(with: token.contentRange).trimmingCharacters(in: .whitespaces)
                : ""
            guard !title.isEmpty else { return nil }
            return OutlineEntry(level: level, title: title,
                                lineNumber: token.lineNumber, range: token.range)
        }
    }
}
