import Foundation

/// A YAML front matter block at the top of a markdown document.
///
/// The parsed fields are for DISPLAY only. `raw` holds the original block
/// byte-for-byte and is what gets written back, so a document round-trips
/// unchanged even when this parser does not understand every YAML construct it
/// contains. Re-serialising from the parsed fields would quietly rewrite the
/// user's file; that is not a trade worth making for a metadata card.
public struct FrontMatter: Equatable, Sendable {

    public enum Value: Equatable, Sendable {
        case scalar(String)
        case list([String])
    }

    public struct Field: Equatable, Sendable, Identifiable {
        public let id: Int
        public let key: String
        public let value: Value
    }

    /// The whole block including the `---` fences and the trailing newline.
    public let raw: String
    public let fields: [Field]
    /// The document text with the block removed.
    public let body: String
    /// Whether a blank line separated the block from the body. Recorded because
    /// without it `joined(withBody:)` cannot tell "---\n\nbody" from
    /// "---\nbody" and silently inserts or drops a line on every save.
    public let hadBlankSeparator: Bool

    public var isEmpty: Bool { fields.isEmpty }

    // MARK: Parsing

    /// Splits `text` into its front matter and body.
    ///
    /// Returns nil when there is no front matter, which keeps "no block" and
    /// "an empty block" distinguishable — only the former may gain one.
    public static func parse(_ text: String) -> FrontMatter? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") || normalized == "---" else { return nil }

        var lines = normalized.components(separatedBy: "\n")
        guard lines.count > 1 else { return nil }

        // Find the closing fence. A document that opens a block and never
        // closes it has no front matter — it is just text starting with ---.
        var closing: Int? = nil
        for index in 1 ..< lines.count {
            let line = lines[index]
            if line == "---" || line == "..." {
                closing = index
                break
            }
        }
        guard let end = closing else { return nil }

        let blockLines = Array(lines[0 ... end])
        let bodyLines = Array(lines[(end + 1)...])
        // Drop one blank separator line so the body does not start with a gap
        // that the user never typed — and remember that we did.
        var body = bodyLines
        var hadBlank = false
        if body.first?.isEmpty == true {
            body.removeFirst()
            hadBlank = true
        }

        let raw = blockLines.joined(separator: "\n") + "\n"
        let fields = parseFields(Array(lines[1 ..< end]))
        return FrontMatter(raw: raw, fields: fields, body: body.joined(separator: "\n"),
                           hadBlankSeparator: hadBlank)
    }

    private static func parseFields(_ lines: [String]) -> [Field] {
        var fields: [Field] = []
        var index = 0
        var nextID = 0

        func appendField(_ key: String, _ value: Value) {
            fields.append(Field(id: nextID, key: key, value: value))
            nextID += 1
        }

        while index < lines.count {
            let line = lines[index]
            index += 1

            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                  let colon = line.firstIndex(of: ":"),
                  line.first?.isWhitespace != true else { continue }

            let key = String(line[line.startIndex ..< colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            var rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            // Inline flow list: [a, b, c]
            if rest.hasPrefix("["), rest.hasSuffix("]") {
                let inner = String(rest.dropFirst().dropLast())
                let items = inner.split(separator: ",")
                    .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
                appendField(key, .list(items))
                continue
            }

            // Block list: following lines starting with "- "
            if rest.isEmpty, index < lines.count, isListItem(lines[index]) {
                var items: [String] = []
                while index < lines.count, isListItem(lines[index]) {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    items.append(unquote(String(item.dropFirst()).trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                appendField(key, .list(items))
                continue
            }

            // Block scalar (| or >) and folded continuations: indented lines
            // that follow belong to this value.
            if rest == "|" || rest == ">" || rest == "|-" || rest == ">-" {
                var parts: [String] = []
                while index < lines.count, isIndentedContinuation(lines[index]) {
                    parts.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                appendField(key, .scalar(parts.joined(separator: " ")))
                continue
            }

            var continuation: [String] = []
            while index < lines.count, isIndentedContinuation(lines[index]) {
                continuation.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            if !continuation.isEmpty {
                rest = ([rest] + continuation).filter { !$0.isEmpty }.joined(separator: " ")
            }

            appendField(key, .scalar(unquote(rest)))
        }

        return fields
    }

    private static func isListItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- ") || trimmed == "-"
    }

    private static func isIndentedContinuation(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        guard first == " " || first == "\t" else { return false }
        return !isListItem(line)
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2 {
            if value.hasPrefix("\"") && value.hasSuffix("\"") { return String(value.dropFirst().dropLast()) }
            if value.hasPrefix("'") && value.hasSuffix("'") { return String(value.dropFirst().dropLast()) }
        }
        return value
    }

    // MARK: Writing

    /// Re-joins the preserved block with a (possibly edited) body, restoring the
    /// original blank-separator shape so a save is a no-op when nothing changed.
    public func joined(withBody newBody: String) -> String {
        raw + (hadBlankSeparator ? "\n" : "") + newBody
    }
}
