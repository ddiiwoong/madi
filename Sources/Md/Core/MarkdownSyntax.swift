import Foundation

/// Block-level kind of a single source line.
public enum BlockKind: Equatable, Sendable {
    case heading(level: Int)
    case quote(depth: Int)
    case listItem(ordered: Bool, checked: Bool?)
    case codeFence
    case codeBody
    case thematicBreak
    case tableRow
    case tableDelimiter
    case paragraph
    case blank
}

/// One scanned source line. Ranges are UTF-16 offsets into the whole document,
/// so they can be handed straight to an `NSTextStorage`.
public struct LineToken: Equatable, Sendable {
    public let lineNumber: Int        // 1-based
    public let range: NSRange         // the line, without its newline
    public let kind: BlockKind
    /// Syntax punctuation (`#`, `>`, `-`, fence backticks). These are the parts
    /// a live-preview editor dims or hides.
    public let markerRanges: [NSRange]
    /// What is left after the markers — the text the reader cares about.
    public let contentRange: NSRange
}

public enum InlineKind: Equatable, Sendable {
    case strong
    case emphasis
    case strikethrough
    case code
    case link(url: String)
    case image(url: String)
    case autolink(url: String)
}

public struct InlineToken: Equatable, Sendable {
    public let kind: InlineKind
    public let range: NSRange          // the whole construct, markers included
    public let contentRange: NSRange   // the visible text
    public let markerRanges: [NSRange]
}

/// Scans markdown source into block and inline tokens. Pure: no AppKit, no
/// shared state, so the styler and the tests see identical results.
public struct MarkdownSyntax: Sendable {

    public init() {}

    // MARK: Blocks

    public func scanLines(in text: NSString) -> [LineToken] {
        var tokens: [LineToken] = []
        var inFence = false
        var lineNumber = 0
        var cursor = 0
        let length = text.length

        while cursor <= length {
            let lineRange = text.lineRange(for: NSRange(location: min(cursor, length), length: 0))
            // `lineRange` includes the terminator; style only the content.
            let contentOnly = text.rangeOfLine(excludingTerminatorIn: lineRange)
            lineNumber += 1

            let line = text.substring(with: contentOnly)
            let token = scanLine(line, at: contentOnly, lineNumber: lineNumber, inFence: &inFence)
            tokens.append(token)

            if NSMaxRange(lineRange) <= cursor { break }
            cursor = NSMaxRange(lineRange)
            if cursor == length {
                // A trailing newline means one more (empty) line exists.
                if length > 0, text.character(at: length - 1) == 10 {
                    lineNumber += 1
                    let empty = NSRange(location: length, length: 0)
                    tokens.append(LineToken(lineNumber: lineNumber, range: empty, kind: .blank,
                                            markerRanges: [], contentRange: empty))
                }
                break
            }
        }
        return tokens
    }

    private func scanLine(_ line: String, at range: NSRange, lineNumber: Int,
                          inFence: inout Bool) -> LineToken {
        func token(_ kind: BlockKind, markers: [NSRange] = [], content: NSRange? = nil) -> LineToken {
            LineToken(lineNumber: lineNumber, range: range, kind: kind,
                      markerRanges: markers, contentRange: content ?? range)
        }

        let ns = line as NSString

        if let m = Self.fence.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            inFence.toggle()
            return token(.codeFence, markers: [range], content: shift(m.range, by: range.location))
        }
        if inFence {
            return token(.codeBody)
        }
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            return token(.blank)
        }
        if Self.thematicBreak.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
            return token(.thematicBreak, markers: [range])
        }
        if let m = Self.heading.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let hashes = m.range(at: 2)
            let level = hashes.length
            let body = m.range(at: 3)
            // Marker spans the leading indent, the hashes and the space after.
            let markerEnd = body.location == NSNotFound ? ns.length : body.location
            let marker = NSRange(location: 0, length: markerEnd)
            return token(.heading(level: level),
                         markers: [shift(marker, by: range.location)],
                         content: shift(body.location == NSNotFound ? NSRange(location: ns.length, length: 0) : body,
                                        by: range.location))
        }
        if let m = Self.quote.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let marker = m.range(at: 1)
            let depth = ns.substring(with: marker).filter { $0 == ">" }.count
            return token(.quote(depth: depth),
                         markers: [shift(marker, by: range.location)],
                         content: shift(m.range(at: 2), by: range.location))
        }
        if let m = Self.listItem.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let bullet = m.range(at: 2)
            let ordered = ns.substring(with: bullet).contains(where: \.isNumber)
            let task = m.range(at: 3)
            var checked: Bool? = nil
            var markers = [shift(NSRange(location: 0, length: NSMaxRange(bullet)), by: range.location)]
            if task.location != NSNotFound {
                let box = ns.substring(with: task)
                checked = box.lowercased().contains("x")
                markers.append(shift(task, by: range.location))
            }
            return token(.listItem(ordered: ordered, checked: checked),
                         markers: markers,
                         content: shift(m.range(at: 4), by: range.location))
        }
        if Self.tableDelimiter.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
            return token(.tableDelimiter, markers: [range])
        }
        if line.contains("|") {
            return token(.tableRow)
        }
        return token(.paragraph)
    }

    // MARK: Inlines

    /// Inline constructs inside one line's content range.
    public func scanInline(in text: NSString, range: NSRange) -> [InlineToken] {
        guard range.length > 0 else { return [] }
        let line = text.substring(with: range)
        let whole = NSRange(location: 0, length: (line as NSString).length)
        var tokens: [InlineToken] = []
        var claimed = IndexSet()

        func add(_ kind: InlineKind, _ m: NSTextCheckingResult, content: Int, markers: [NSRange]) {
            let full = m.range
            guard !claimed.intersects(integersIn: full.location ..< NSMaxRange(full)) else { return }
            claimed.insert(integersIn: full.location ..< NSMaxRange(full))
            tokens.append(InlineToken(kind: kind,
                                      range: shift(full, by: range.location),
                                      contentRange: shift(m.range(at: content), by: range.location),
                                      markerRanges: markers.map { shift($0, by: range.location) }))
        }

        // Code first: its content must not be parsed further.
        for m in Self.code.matches(in: line, range: whole) {
            let full = m.range
            let inner = m.range(at: 1)
            add(.code, m, content: 1, markers: [
                NSRange(location: full.location, length: inner.location - full.location),
                NSRange(location: NSMaxRange(inner), length: NSMaxRange(full) - NSMaxRange(inner)),
            ])
        }
        for m in Self.image.matches(in: line, range: whole) {
            let url = (line as NSString).substring(with: m.range(at: 2))
            add(.image(url: url), m, content: 1, markers: markerPair(m, contentIndex: 1))
        }
        for m in Self.link.matches(in: line, range: whole) {
            let url = (line as NSString).substring(with: m.range(at: 2))
            add(.link(url: url), m, content: 1, markers: markerPair(m, contentIndex: 1))
        }
        for m in Self.autolink.matches(in: line, range: whole) {
            let url = (line as NSString).substring(with: m.range(at: 1))
            add(.autolink(url: url), m, content: 1, markers: markerPair(m, contentIndex: 1))
        }
        for m in Self.strong.matches(in: line, range: whole) {
            add(.strong, m, content: 2, markers: markerPair(m, contentIndex: 2))
        }
        for m in Self.strikethrough.matches(in: line, range: whole) {
            add(.strikethrough, m, content: 1, markers: markerPair(m, contentIndex: 1))
        }
        for m in Self.emphasis.matches(in: line, range: whole) {
            add(.emphasis, m, content: 2, markers: markerPair(m, contentIndex: 2))
        }

        return tokens.sorted { $0.range.location < $1.range.location }
    }

    private func markerPair(_ m: NSTextCheckingResult, contentIndex: Int) -> [NSRange] {
        let full = m.range
        let inner = m.range(at: contentIndex)
        guard inner.location != NSNotFound else { return [full] }
        return [
            NSRange(location: full.location, length: inner.location - full.location),
            NSRange(location: NSMaxRange(inner), length: NSMaxRange(full) - NSMaxRange(inner)),
        ].filter { $0.length > 0 }
    }

    private func shift(_ range: NSRange, by offset: Int) -> NSRange {
        guard range.location != NSNotFound else { return range }
        return NSRange(location: range.location + offset, length: range.length)
    }

    // MARK: Patterns

    private static let heading = regex(#"^(\s{0,3})(#{1,6})(?:[ \t]+(.*?))?[ \t]*#*[ \t]*$"#)
    private static let quote = regex(#"^(\s{0,3}>+[ \t]?)(.*)$"#)
    private static let listItem = regex(#"^(\s*)([-+*]|\d+[.)])[ \t]+(\[[ xX]\])?[ \t]*(.*)$"#)
    private static let fence = regex(#"^\s*(```|~~~)\s*([\w+#-]*)\s*$"#)
    private static let thematicBreak = regex(#"^\s{0,3}((\*[ \t]*){3,}|(-[ \t]*){3,}|(_[ \t]*){3,})$"#)
    private static let tableDelimiter = regex(#"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)

    private static let code = regex(#"`([^`\n]+)`"#)
    private static let image = regex(#"!\[([^\]\n]*)\]\(([^)\s]+)[^)]*\)"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\s]+)[^)]*\)"#)
    private static let autolink = regex(#"<((?:https?|mailto):[^>\s]+)>"#)
    private static let strong = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let emphasis = regex(#"(?<![*\w])(\*|_)(?=\S)([^*_\n]+?)(?<=\S)\1(?![*\w])"#)
    private static let strikethrough = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // These patterns are compile-time constants; a failure is a programming
        // error, not a runtime condition.
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("invalid built-in pattern: \(pattern)")
        }
        return expression
    }
}

extension NSRegularExpression {
    func matches(in string: String, range: NSRange) -> [NSTextCheckingResult] {
        matches(in: string, options: [], range: range)
    }

    func firstMatch(in string: String, range: NSRange) -> NSTextCheckingResult? {
        firstMatch(in: string, options: [], range: range)
    }
}

extension NSString {
    /// `lineRange(for:)` includes the line terminator; styling wants it gone.
    func rangeOfLine(excludingTerminatorIn range: NSRange) -> NSRange {
        var end = NSMaxRange(range)
        while end > range.location {
            let c = character(at: end - 1)
            if c == 10 || c == 13 { end -= 1 } else { break }
        }
        return NSRange(location: range.location, length: end - range.location)
    }
}
