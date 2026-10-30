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

    // MARK: 번역

    /// 사람이 읽는 글이라 번역할 값의 키. `slug`·`date`·`layout`·`tags` 같은 값은 기계가
    /// 읽으므로 번역하면 사이트가 깨진다 — 그래서 고르는 쪽(허용 목록)으로 둔다.
    public static let translatableKeys: Set<String> = ["title", "description"]

    /// 번역할 값 하나. `line`은 `raw`를 `\n`으로 나눈 줄 번호다.
    public struct TranslatableValue: Equatable, Sendable {
        public let line: Int
        public let key: String
        /// 따옴표를 벗긴 값 — 번역기에 넘길 글.
        public let text: String
        let quote: Quote
    }

    enum Quote: Equatable, Sendable { case plain, single, double }

    /// 번역할 값들. **한 줄에 다 있는 값만** 고른다.
    ///
    /// 블록 스칼라(`|`·`>`), 다음 줄로 이어지는 값, 흐름 표기(`[`·`{`), 앵커·태그
    /// (`&`·`*`·`!`), 이스케이프가 든 따옴표 값, 주석이 붙은 값은 건너뛴다 — 그 줄에서
    /// 글자만 바꾸는 방식으로는 원래 뜻을 지킨다고 장담할 수 없다. 건너뛴 값은 원문 그대로
    /// 남는다(지금까지와 같다).
    public var translatableValues: [TranslatableValue] {
        let lines = raw.components(separatedBy: "\n")
        var out: [TranslatableValue] = []
        // 첫 줄과 닫는 줄(`---`/`...`) 사이만 본다. `raw`는 줄바꿈으로 끝나 마지막 조각이 빈다.
        guard lines.count >= 3 else { return out }
        let closing = lines.count - 2
        for index in 1 ..< closing {
            let line = lines[index]
            guard let colon = line.firstIndex(of: ":"), line.first?.isWhitespace == false else { continue }
            let key = String(line[..<colon])
            guard Self.translatableKeys.contains(key) else { continue }
            // 다음 줄이 들여쓴 이어짐이면 여러 줄 값이다.
            if index + 1 < closing, Self.isIndentedContinuation(lines[index + 1]) { continue }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard let parsed = Self.singleLineValue(value) else { continue }
            out.append(TranslatableValue(line: index, key: key, text: parsed.text, quote: parsed.quote))
        }
        return out
    }

    /// 한 줄 값의 글과 따옴표 꼴. 이 방식으로 다룰 수 없는 값이면 nil.
    static func singleLineValue(_ value: String) -> (text: String, quote: Quote)? {
        guard !value.isEmpty else { return nil }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            let inner = String(value.dropFirst().dropLast())
            guard !inner.contains("\\"), !inner.contains("\"") else { return nil }
            return inner.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (inner, .double)
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            let inner = String(value.dropFirst().dropLast())
            guard !inner.contains("'") else { return nil }
            return inner.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (inner, .single)
        }
        guard let first = value.first, !"|>[{&*!'\"%@`#".contains(first),
              !value.contains(" #") else { return nil }
        return (value, .plain)
    }

    /// 번역한 값을 넣은 문서. 고른 줄에서 **값 부분만** 바꾸고 나머지 줄은 바이트 그대로 둔다.
    /// `translations`는 `TranslatableValue.line` → 번역문이다.
    public func joined(withBody newBody: String, translatedValues translations: [Int: String]) -> String {
        guard !translations.isEmpty else { return joined(withBody: newBody) }
        var lines = raw.components(separatedBy: "\n")
        for value in translatableValues {
            guard let translated = translations[value.line], value.line < lines.count else { continue }
            let line = lines[value.line]
            guard let colon = line.firstIndex(of: ":") else { continue }
            // 콜론 뒤의 공백은 그대로 둔다 — `title:  값`의 두 칸도 사용자가 쓴 것이다.
            let afterColon = line[line.index(after: colon)...]
            let spacing = afterColon.prefix(while: { $0 == " " || $0 == "\t" })
            lines[value.line] = String(line[...colon]) + spacing
                + Self.encoded(translated, like: value.quote)
        }
        let block = lines.joined(separator: "\n")
        return block + (hadBlankSeparator ? "\n" : "") + newBody
    }

    /// 번역문을 원래 따옴표 꼴로 적는다. 따옴표 없던 값이라도 번역문이 YAML에서 다른 뜻이
    /// 되면(`: `가 들어감, `#`·`-`로 시작, `yes`·`null`·숫자처럼 읽힘) 큰따옴표로 감싼다.
    static func encoded(_ translated: String, like quote: Quote) -> String {
        // 한 줄 값이다. 번역기가 줄을 나눠 내놓아도 한 줄로 붙인다.
        let text = translated.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        func doubleQuoted() -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        switch quote {
        case .double:
            return doubleQuoted()
        case .single:
            return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        case .plain:
            return isPlainSafe(text) ? text : doubleQuoted()
        }
    }

    /// 따옴표 없이 적어도 YAML이 같은 문자열로 읽는가. 확실하지 않으면 false.
    static func isPlainSafe(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last,
              !first.isWhitespace, !last.isWhitespace, last != ":",
              !"-?:,[]{}#&*!|>'\"%@`".contains(first),
              !text.contains(": "), !text.contains(" #") else { return false }
        let lowered = text.lowercased()
        let reserved: Set<String> = ["yes", "no", "true", "false", "on", "off", "y", "n",
                                     "null", "~", ".nan", ".inf", "-.inf"]
        if reserved.contains(lowered) { return false }
        if Double(text) != nil || Int(text) != nil { return false }
        return true
    }
}
