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
        syntax.scanLines(in: text).compactMap { token in
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
