import Foundation

/// Block-level kind of a single source line.
public enum BlockKind: Equatable, Sendable {
    case heading(level: Int)
    /// setext 제목의 밑줄(`===` · `---`). 제목 글자가 아니라 **표시**라서 제목과
    /// 다른 종류다 — 제목 글꼴로 그리면 숨겨도 그 줄만큼 큰 빈 자리가 남고,
    /// 목차에 `=====`라는 항목이 생긴다.
    case setextUnderline(level: Int)
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
    /// 코드 펜스의 정보 문자열(```` ```swift ````의 `swift`). 펜스 줄과 그 안의 본문 줄이
    /// 모두 들고 있어서, 구문 강조가 "이 줄이 무슨 언어인지"를 따로 추적하지 않아도 된다.
    /// 코드가 아닌 줄에서는 nil이다.
    public let language: String?

    /// 명시적 이니셜라이저다. `language`에 기본값을 주려면 필요하다 — 멤버와이즈
    /// 이니셜라이저는 기본값을 붙일 수 없어서, 없으면 기존 생성 지점이 전부 깨진다.
    public init(lineNumber: Int, range: NSRange, kind: BlockKind,
                markerRanges: [NSRange], contentRange: NSRange, language: String? = nil) {
        self.lineNumber = lineNumber
        self.range = range
        self.kind = kind
        self.markerRanges = markerRanges
        self.contentRange = contentRange
        self.language = language
    }
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
        var fenceLanguage: String?
        var lineNumber = 0
        var cursor = 0
        let length = text.length

        while cursor <= length {
            let lineRange = text.lineRange(for: NSRange(location: min(cursor, length), length: 0))
            // `lineRange` includes the terminator; style only the content.
            let contentOnly = text.rangeOfLine(excludingTerminatorIn: lineRange)
            lineNumber += 1

            let line = text.substring(with: contentOnly)
            let token = scanLine(line, at: contentOnly, lineNumber: lineNumber,
                                 inFence: &inFence, fenceLanguage: &fenceLanguage)
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
        return Self.applySetextHeadings(tokens, in: text)
    }

    /// setext 제목을 뒤에서 판정한다 — `제목` 다음 줄이 `===`면 제목 1, `---`면 제목 2.
    ///
    /// 왜 후처리인가: 줄을 하나씩 읽는 동안에는 **다음 줄을 모른다.** 밑줄을 보고
    /// 나서야 앞 줄이 제목이었다는 것을 알 수 있어서, 읽기가 끝난 뒤 앞으로 거슬러
    /// 고친다.
    ///
    /// 이것을 안 하면 `제목` 다음의 `---`가 **수평선**이 된다 — 문서에 없는 선을
    /// 그리고, 제목은 목차에도 안 올라간다. CommonMark의 제목 두 꼴 가운데 하나라
    /// 틀리게 그리는 쪽이 모르는 쪽보다 나쁘다.
    ///
    /// 밑줄 위의 **문단 전체**가 제목이다(CommonMark). 여러 줄 문단 뒤에 `===`가
    /// 오면 그 문단의 모든 줄이 제목이 된다.
    static func applySetextHeadings(_ tokens: [LineToken], in text: NSString) -> [LineToken] {
        var out = tokens
        var index = 1
        while index < out.count {
            let token = out[index]
            // 밑줄 후보: `=` 또는 `-`만 있는 줄. `***`·`___`는 setext가 아니다.
            guard token.kind == .paragraph || token.kind == .thematicBreak,
                  token.range.length > 0,
                  let level = setextLevel(of: text.substring(with: token.range)) else {
                index += 1
                continue
            }
            // 바로 위가 문단이어야 한다. 빈 줄·목록·인용 뒤의 `---`는 수평선이다.
            guard out[index - 1].kind == .paragraph else {
                index += 1
                continue
            }
            // 문단 전체를 거슬러 올라가 제목으로 바꾼다.
            var first = index - 1
            while first > 0, out[first - 1].kind == .paragraph { first -= 1 }
            for line in first ..< index {
                let old = out[line]
                out[line] = LineToken(lineNumber: old.lineNumber, range: old.range,
                                      kind: .heading(level: level),
                                      markerRanges: [], contentRange: old.range)
            }
            // 밑줄은 표시다. 내용 범위를 비워 두어 목차에 `=====`가 올라가지 않게 한다.
            out[index] = LineToken(lineNumber: token.lineNumber, range: token.range,
                                   kind: .setextUnderline(level: level),
                                   markerRanges: [token.range],
                                   contentRange: NSRange(location: token.range.location, length: 0))
            index += 1
        }
        return out
    }

    /// `===`면 1, `---`면 2, 아니면 nil. 들여쓰기는 세 칸까지 허용한다(CommonMark).
    static func setextLevel(of line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 1,
              line.prefix(while: { $0 == " " }).count <= 3 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private func scanLine(_ line: String, at range: NSRange, lineNumber: Int,
                          inFence: inout Bool, fenceLanguage: inout String?) -> LineToken {
        func token(_ kind: BlockKind, markers: [NSRange] = [], content: NSRange? = nil,
                   language: String? = nil) -> LineToken {
            LineToken(lineNumber: lineNumber, range: range, kind: kind,
                      markerRanges: markers, contentRange: content ?? range, language: language)
        }

        let ns = line as NSString

        if let m = Self.fence.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let opening = !inFence
            inFence.toggle()
            let info = m.range(at: 2)
            if opening {
                // 정보 문자열은 여는 펜스에만 있다. 닫는 펜스는 여는 쪽의 언어를 물려받아
                // 블록 전체가 같은 언어로 보이게 한다.
                fenceLanguage = (info.location != NSNotFound && info.length > 0)
                    ? ns.substring(with: info) : nil
            }
            // 숨길 것은 **백틱까지**다. 정보 문자열은 남겨 둔다.
            //
            // 전에는 줄 전체를 마커로 두어 통째로 숨겼다. 그러면 ``` ``` import ```
            // 처럼 치는 사람의 글자가 흔적도 없이 사라진다 — 사용자가 "코드블록 글자가
            // 투명하게 안 보인다"고 신고한 것이 이것이었다. 정보 문자열은 코드의
            // 내용이 아니라 **언어 이름**이라 렌더러가 그리지 않는 것이 맞지만,
            // 편집기에서는 자기가 친 글자가 어디로 갔는지 보여야 하고 블록의 언어도
            // 그렇게 알 수 있다. 그래서 흐린 라벨로 남긴다(색은 스타일러가 준다).
            let fenceRun = m.range(at: 1)
            let hideUpTo = (info.location != NSNotFound && info.length > 0)
                ? info.location                      // 백틱과 사이 공백까지
                : NSMaxRange(fenceRun)               // 정보 문자열이 없으면 백틱까지
            let marker = NSRange(location: 0, length: max(hideUpTo, NSMaxRange(fenceRun)))
            let result = token(.codeFence, markers: [shift(marker, by: range.location)],
                               content: shift(m.range, by: range.location),
                               language: fenceLanguage)
            if !opening { fenceLanguage = nil }
            return result
        }
        if inFence {
            return token(.codeBody, language: fenceLanguage)
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
        // 기울임은 구분자에 따라 규칙이 다르다. CommonMark에서 `*`는 낱말 안 강조를
        // 허용하고 `_`는 금지한다. 둘을 한 정규식으로 묶어 낱말 경계를 요구하면
        // **한국어에서 거의 쓸 수 없게 된다** — 조사가 바로 붙기 때문이다
        // (`*기울임*은`에서 `은`이 낱말 글자라 강조가 깨졌다. 실측).
        for m in Self.emphasisStar.matches(in: line, range: whole) {
            add(.emphasis, m, content: 1, markers: markerPair(m, contentIndex: 1))
        }
        for m in Self.emphasisUnderscore.matches(in: line, range: whole) {
            add(.emphasis, m, content: 1, markers: markerPair(m, contentIndex: 1))
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
    /// `*`로 감싼 기울임. **낱말 경계를 요구하지 않는다** — CommonMark가 `*`의 낱말 안
    /// 강조를 허용하고, 한국어는 조사가 바로 붙어(`*기울임*은`) 경계를 요구하면 못 쓴다.
    /// 내용에 `_`는 허용한다(`*a_b*`).
    private static let emphasisStar = regex(#"(?<!\*)\*(?=\S)([^*\n]+?)(?<=\S)\*(?!\*)"#)
    /// `_`로 감싼 기울임. CommonMark대로 낱말 안 강조를 **금지한다**(`snake_case_name`이
    /// 기울어지면 안 된다). 내용에 `*`는 허용한다.
    private static let emphasisUnderscore = regex(#"(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])"#)
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
