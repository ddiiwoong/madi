import Foundation

/// 서식 명령(메뉴의 서식) — 글자 꾸밈(굵게 · 기울임 · 취소선 · 인라인 코드), 제목, 목록 · 인용, 링크, 코드 블록 ·
/// 표 · 구분선.
///
/// 모두 마크다운 **원문을 고치는** 순수 계산이고 `TextEdit`을 돌려준다(편집기가 `perform`으로 적용해 실행 취소에
/// 하나씩 실린다). 고칠 것이 없으면 nil — 편집기가 경고음을 낸다.
///
/// 규칙은 마크다운 편집기들의 관례를 따른다(Typora · Bear · Obsidian). 다시 누르면 풀린다 — 굵게를 다시 누르면
/// `**`가 빠지고, 같은 단계의 제목을 다시 누르면 본문이 된다. 여러 줄을 고르면 줄마다 한다.
public enum MarkdownFormatting {

    // MARK: 글자 꾸밈

    public enum Inline: Sendable, CaseIterable {
        case bold, italic, strikethrough, code

        /// 감싸는 표식.
        var marker: String {
            switch self {
            case .bold: "**"
            case .italic: "*"
            case .strikethrough: "~~"
            case .code: "`"
            }
        }

        /// 이 꾸밈이 걸렸다고 볼 표식 글자의 연속 개수. `*` 셋(`***`)은 굵게이자 기울임이다.
        var runs: Set<Int> {
            switch self {
            case .bold: [2, 3]
            case .italic: [1, 3]
            case .strikethrough: [2]
            case .code: [1]
            }
        }
    }

    /// 고른 글을 꾸미거나 푼다.
    ///
    /// - 고른 것이 없으면 표식 한 쌍을 넣고 캐럿을 가운데 둔다(`**|**`). 빈 쌍 가운데서 다시 누르면 쌍을 지운다.
    /// - 고른 글이 이미 꾸며져 있으면(표식이 고른 글 바로 밖에 있든, 고른 글의 양 끝이든) 푼다.
    /// - 아니면 감싼다. 고른 글 앞뒤의 공백과 줄 앞의 블록 표식(`#`, `-`, `1.`, `>`)은 감싸지 않는다 —
    ///   `** 글 **`나 `**# 제목**`은 마크다운이 꾸밈으로 읽지 않는다.
    /// - 여러 줄이면 줄마다. 모든 줄이 꾸며져 있으면 모두 풀고, 아니면 안 꾸민 줄만 감싼다.
    public static func toggle(_ style: Inline, in text: NSString, selection: NSRange) -> TextEdit? {
        let marker = style.marker
        let width = (marker as NSString).length
        guard let symbol = marker.utf16.first else { return nil }

        if selection.length == 0 {
            let caret = selection.location
            if run(of: symbol, endingAt: caret, in: text) == width, run(of: symbol, startingAt: caret, in: text) == width {
                return TextEdit(range: NSRange(location: caret - width, length: width * 2), replacement: "",
                                selection: NSRange(location: caret - width, length: 0))
            }
            return TextEdit(range: NSRange(location: caret, length: 0), replacement: marker + marker,
                            selection: NSRange(location: caret + width, length: 0))
        }

        let segments = inlineSegments(in: text, selection: selection)
        guard !segments.isEmpty else { return nil }
        // 조각마다 여는 표식과 닫는 표식이 각각 조각 **밖**(바로 앞 · 뒤)에 있는지 **안**(양 끝)에 있는지 본다. 두 끝이
        // 다를 수 있다 — 여러 줄을 감싼 뒤의 선택은 첫 줄의 여는 표식 뒤에서 시작해 끝 줄의 닫는 표식 앞에서 끝나므로,
        // 첫 줄 조각은 여는 표식이 밖, 닫는 표식이 안이다.
        struct Wrap { var openInside: Bool; var closeInside: Bool }
        let wraps: [Wrap?] = segments.map { segment in
            let start = segment.location, end = NSMaxRange(segment)
            let openOutside = style.runs.contains(run(of: symbol, endingAt: start, in: text))
            let openInside = style.runs.contains(min(run(of: symbol, startingAt: start, in: text), segment.length))
            let closeOutside = style.runs.contains(run(of: symbol, startingAt: end, in: text))
            let closeInside = style.runs.contains(min(run(of: symbol, endingAt: end, in: text), segment.length))
            guard openOutside || openInside, closeOutside || closeInside else { return nil }
            let wrap = Wrap(openInside: !openOutside, closeInside: !closeOutside)
            let markersInside = (wrap.openInside ? width : 0) + (wrap.closeInside ? width : 0)
            return segment.length > markersInside ? wrap : nil              // 표식만 고른 것은 꾸민 글이 아니다
        }
        let unwrap = wraps.allSatisfy { $0 != nil }

        var changes: [Change] = []
        var contents: [(start: Int, end: Int)] = []
        for (segment, wrap) in zip(segments, wraps) {
            let start = segment.location, end = NSMaxRange(segment)
            guard let wrap else {
                // 안 꾸민 조각 — 감싼다(unwrap이면 여기에 오지 않는다).
                changes.append(Change(range: NSRange(location: start, length: 0), replacement: marker))
                changes.append(Change(range: NSRange(location: end, length: 0), replacement: marker))
                contents.append((start, end))
                continue
            }
            let open = wrap.openInside ? NSRange(location: start, length: width)
                                       : NSRange(location: start - width, length: width)
            let close = wrap.closeInside ? NSRange(location: end - width, length: width)
                                         : NSRange(location: end, length: width)
            if unwrap {
                changes.append(Change(range: open, replacement: ""))
                changes.append(Change(range: close, replacement: ""))
            }
            contents.append((wrap.openInside ? start + width : start, wrap.closeInside ? end - width : end))
        }
        guard let first = contents.first, let last = contents.last else { return nil }
        return edit(applying: changes, in: text, selectFrom: (first.start, true), to: (last.end, false))
    }

    // MARK: 제목

    /// 줄을 제목 `level`(1~6)로, 0이면 본문으로. 고른 줄이 모두 이미 그 단계면 본문으로 되돌린다.
    /// 빈 줄은 건드리지 않는다.
    public static func heading(_ level: Int, in text: NSString, selection: NSRange) -> TextEdit? {
        guard (0...6).contains(level) else { return nil }
        return rewriteLines(in: text, selection: selection) { lines in
            if lines.count == 1, lines[0].isBlank {
                // 빈 줄 하나 — 그 줄을 제목으로 시작한다(이어서 쓰면 제목이 된다).
                return [level == 0 ? nil : (lines[0].text.utf16.count, String(repeating: "#", count: level) + " ")]
            }
            let levels = lines.filter { !$0.isBlank }.map { headingLevel(of: $0.text) }
            let target = level > 0 && !levels.isEmpty && levels.allSatisfy { $0 == level } ? 0 : level
            let prefix = target == 0 ? "" : String(repeating: "#", count: target) + " "
            return lines.map { line -> (Int, String)? in
                line.isBlank ? nil : (headingPrefixLength(of: line.text), prefix)
            }
        }
    }

    /// 줄의 제목 단계. 제목이 아니면 0. `#글`(띄어 쓰지 않음)은 제목이 아니다.
    static func headingLevel(of line: String) -> Int {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return 0 }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " || rest.first == "\t" ? hashes : 0
    }

    private static func headingPrefixLength(of line: String) -> Int {
        let level = headingLevel(of: line)
        guard level > 0 else { return 0 }
        let spaces = line.dropFirst(level).prefix { $0 == " " || $0 == "\t" }.count
        return level + spaces
    }

    // MARK: 목록 · 인용

    public enum Block: Sendable, CaseIterable {
        case bullet, numbered, task, quote
    }

    /// 줄을 목록(글머리 · 번호 · 할 일)이나 인용으로, 모두 이미 그것이면 푼다. 다른 목록이면 바꾼다(글머리 → 번호).
    /// 들여쓰기는 그대로 두고, 번호는 같은 들여쓰기마다 1부터 다시 센다.
    public static func toggle(_ block: Block, in text: NSString, selection: NSRange) -> TextEdit? {
        if block == .quote { return toggleQuote(in: text, selection: selection) }
        return rewriteLines(in: text, selection: selection) { lines in
            if lines.count == 1, lines[0].isBlank {
                // 빈 줄 하나 — 목록을 시작한다.
                let marker = switch block {
                case .bullet: "- "
                case .numbered: "1. "
                case .task: "- [ ] "
                case .quote: "> "
                }
                return [(lines[0].text.utf16.count, marker)]
            }
            let items = lines.filter { !$0.isBlank }.map { listItem(in: $0.text) }
            let all = !items.isEmpty && items.allSatisfy { $0.kind == block }
            var counters: [Int: Int] = [:]                                  // 들여쓰기 폭 → 다음 번호
            return lines.map { line -> (Int, String)? in
                guard !line.isBlank else { return nil }
                let item = listItem(in: line.text)
                let oldPrefix = item.indent.utf16.count + item.marker.utf16.count
                if all { return (oldPrefix, item.indent) }
                switch block {
                case .bullet:
                    return (oldPrefix, item.indent + "- ")
                case .task:
                    // 이미 할 일이면 체크 상태를 그대로 둔다.
                    return item.kind == .task ? nil : (oldPrefix, item.indent + "- [ ] ")
                case .numbered:
                    let depth = item.indent.utf16.count
                    counters = counters.filter { $0.key <= depth }
                    let number = counters[depth, default: 1]
                    counters[depth] = number + 1
                    return (oldPrefix, item.indent + "\(number). ")
                case .quote:
                    return nil
                }
            }
        }
    }

    private struct ListItem {
        var indent: String
        var marker: String
        var kind: Block?
    }

    private static let listPattern = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+][ \t]+\[[ xX]\][ \t]+)|([-*+][ \t]+)|(\d{1,9}[.)][ \t]+))?"#)

    private static func listItem(in line: String) -> ListItem {
        let ns = line as NSString
        guard let match = listPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return ListItem(indent: "", marker: "", kind: nil)
        }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        let indent = group(1) ?? ""
        if let task = group(2) { return ListItem(indent: indent, marker: task, kind: .task) }
        if let bullet = group(3) { return ListItem(indent: indent, marker: bullet, kind: .bullet) }
        if let number = group(4) { return ListItem(indent: indent, marker: number, kind: .numbered) }
        return ListItem(indent: indent, marker: "", kind: nil)
    }

    /// 인용 — 모든 글 줄이 `>`로 시작하면 한 겹 벗기고, 아니면 `> `를 붙인다. 글 줄 **사이**의 빈 줄은 `>`가 되어
    /// 한 덩이로 남는다(빈 줄이 덩이를 끊으면 인용이 둘로 갈린다).
    private static func toggleQuote(in text: NSString, selection: NSRange) -> TextEdit? {
        rewriteLines(in: text, selection: selection) { lines in
            if lines.count == 1, lines[0].isBlank { return [(lines[0].text.utf16.count, "> ")] }  // 빈 줄 — 인용을 시작
            let filled = lines.indices.filter { !lines[$0].isBlank }
            guard let firstFilled = filled.first, let lastFilled = filled.last else {
                return lines.map { _ -> (Int, String)? in nil }
            }
            let quoted = filled.allSatisfy { lines[$0].text.hasPrefix(">") }
            return lines.indices.map { index -> (Int, String)? in
                let line = lines[index].text
                if quoted {
                    guard line.hasPrefix(">") else { return nil }
                    return (line.hasPrefix("> ") ? 2 : 1, "")
                }
                if lines[index].isBlank {
                    return index > firstFilled && index < lastFilled ? (line.utf16.count, ">") : nil
                }
                return line.hasPrefix(">") ? nil : (0, "> ")
            }
        }
    }

    // MARK: 링크

    /// 링크. 고른 것이 없으면 `[]()`를 넣고 캐럿을 `[]` 안에 둔다. 고른 글이 주소면 `[](주소)`(캐럿은 `[]` 안),
    /// 아니면 `[글]()`(캐럿은 `()` 안). 여러 줄에 걸친 선택은 링크가 될 수 없다.
    public static func link(in text: NSString, selection: NSRange) -> TextEdit? {
        let selected = text.substring(with: selection)
        guard !selected.contains(where: \.isNewline) else { return nil }
        let start = selection.location
        if selected.isEmpty || isAddress(selected) {
            return TextEdit(range: selection, replacement: "[](\(selected))",
                            selection: NSRange(location: start + 1, length: 0))
        }
        let length = (selected as NSString).length
        return TextEdit(range: selection, replacement: "[\(selected)]()",
                        selection: NSRange(location: start + length + 3, length: 0))
    }

    static func isAddress(_ string: String) -> Bool {
        guard !string.contains(where: \.isWhitespace) else { return false }
        let lower = string.lowercased()
        return ["http://", "https://", "mailto:", "www."].contains { lower.hasPrefix($0) && lower.count > $0.count }
    }

    // MARK: 코드 블록 · 표 · 구분선

    /// 코드 블록. 고른 줄을 ```` ``` ```` 울타리로 감싸고 캐럿을 여는 울타리 뒤에 둔다(언어 이름을 바로 쓴다).
    /// 빈 줄에서는 빈 블록을 넣고 캐럿을 그 안에 둔다. 이미 울타리로 감싼 줄들을 고르고 누르면 울타리를 뺀다.
    public static func codeBlock(in text: NSString, selection: NSRange) -> TextEdit? {
        let block = LineEditing.lineBlock(in: text, selection: selection)
        let blockText = text.substring(with: block)
        let ending = LineEditing.terminator(of: blockText)
        let body = String(blockText.dropLast(ending.isEmpty ? 0 : 1))
        let lines = body.components(separatedBy: "\n")

        if lines.count >= 2, let first = lines.first, let last = lines.last,
           first.trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           last.trimmingCharacters(in: .whitespaces) == "```" {
            let inner = lines.dropFirst().dropLast().joined(separator: "\n")
            let replacement = inner.isEmpty ? ending : inner + ending
            return TextEdit(range: block, replacement: replacement,
                            selection: NSRange(location: block.location, length: (inner as NSString).length))
        }
        if body.trimmingCharacters(in: .whitespaces).isEmpty, !body.contains("\n") {
            return TextEdit(range: block, replacement: "```\n\n```" + ending,
                            selection: NSRange(location: block.location + 4, length: 0))
        }
        return TextEdit(range: block, replacement: "```\n" + body + "\n```" + ending,
                        selection: NSRange(location: block.location + 3, length: 0))
    }

    /// 표 — 열 둘, 머리와 빈 행 하나. 첫 머리 칸의 글을 골라 두어 바로 덮어 쓴다.
    public static func table(in text: NSString, selection: NSRange,
                             columnTitle: (Int) -> String = { "열 \($0)" }) -> TextEdit {
        let first = columnTitle(1), second = columnTitle(2)
        let body = "| \(first) | \(second) |\n| --- | --- |\n|  |  |"
        return insertBlock(body, in: text, at: selection,
                           select: NSRange(location: 2, length: (first as NSString).length))
    }

    /// 구분선(`---`). 앞 줄이 글이면 빈 줄을 하나 둔다 — 글 바로 아래의 `---`는 구분선이 아니라 제목 2다.
    public static func rule(in text: NSString, selection: NSRange) -> TextEdit {
        insertBlock("---", in: text, at: selection, select: NSRange(location: 3, length: 0))
    }

    /// 블록(여러 줄)을 캐럿 줄에 넣는다. 캐럿 줄이 비어 있으면 그 자리에, 글이 있으면 그 아래에. 위아래의 글 줄과는
    /// 빈 줄 하나로 띄운다. `select`는 블록 안의 위치다.
    private static func insertBlock(_ body: String, in text: NSString, at selection: NSRange,
                                    select: NSRange) -> TextEdit {
        let location = min(selection.location, text.length)
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let lineText = text.substring(with: line)
        let ending = LineEditing.terminator(of: lineText)
        let content = NSRange(location: line.location, length: line.length - (ending as NSString).length)
        let isBlank = text.substring(with: content).trimmingCharacters(in: .whitespaces).isEmpty

        func lineIsFilled(at start: Int) -> Bool {
            guard start >= 0, start < text.length else { return false }
            let other = text.lineRange(for: NSRange(location: start, length: 0))
            return !text.substring(with: other).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let range: NSRange
        var lead = ""
        var trail = ""
        if isBlank {
            range = content
            if lineIsFilled(at: line.location - 1) { lead = "\n" }
            if !ending.isEmpty, lineIsFilled(at: NSMaxRange(line)) { trail = "\n" }
        } else if ending.isEmpty {
            range = NSRange(location: NSMaxRange(line), length: 0)            // 마지막 줄 — 줄바꿈이 없다
            lead = "\n\n"
        } else {
            range = NSRange(location: NSMaxRange(line), length: 0)
            lead = "\n"
            trail = lineIsFilled(at: NSMaxRange(line)) ? "\n\n" : "\n"
        }
        let start = range.location + (lead as NSString).length
        return TextEdit(range: range, replacement: lead + body + trail,
                        selection: NSRange(location: start + select.location, length: select.length))
    }

    // MARK: 줄 고쳐 쓰기

    struct Line {
        /// 줄의 글(줄바꿈 빼고).
        var text: String
        var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 고른 줄마다 **줄 앞부분**만 바꾼다. `transform`은 줄마다 (앞에서 지울 글자 수, 그 자리에 넣을 글)을, 그대로
    /// 둘 줄에는 nil을 돌려준다. 캐럿과 선택은 글과 함께 움직인다 — 지운 앞부분 안에 있던 자리는 새 앞부분 뒤로.
    private static func rewriteLines(in text: NSString, selection: NSRange,
                                     transform: ([Line]) -> [(Int, String)?]) -> TextEdit? {
        let block = LineEditing.lineBlock(in: text, selection: selection)
        var ranges: [NSRange] = []
        text.enumerateSubstrings(in: block, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        if ranges.isEmpty { ranges = [NSRange(location: block.location, length: 0)] }   // 빈 문서 · 끝의 빈 줄
        let lines = ranges.map { Line(text: text.substring(with: $0)) }
        let plan = transform(lines)

        var changes: [Change] = []
        for (range, step) in zip(ranges, plan) {
            guard let (remove, insert) = step else { continue }
            let old = text.substring(with: NSRange(location: range.location, length: remove))
            guard old != insert else { continue }
            changes.append(Change(range: NSRange(location: range.location, length: remove), replacement: insert))
        }
        guard !changes.isEmpty else { return nil }
        let end = NSMaxRange(selection)
        return edit(applying: changes, in: text, selectFrom: (selection.location, true), to: (end, selection.length == 0))
    }

    // MARK: 바꾸기 모으기

    private struct Change {
        var range: NSRange
        var replacement: String
    }

    /// 겹치지 않는 바꾸기들을 편집 하나로 묶는다. 선택의 양 끝은 편집 전 위치로 받아 옮겨 놓는다.
    /// `(위치, true)`는 그 자리에 끼워 넣은 글의 **뒤**로, `false`는 **앞**으로 간다. 바꾼 범위 안에 있던 위치는
    /// 그 범위가 바뀐 글의 끝으로 간다.
    private static func edit(applying changes: [Change], in text: NSString,
                             selectFrom start: (Int, Bool), to end: (Int, Bool)) -> TextEdit? {
        let sorted = changes.sorted { $0.range.location < $1.range.location }
        guard let low = sorted.first?.range.location, let high = sorted.map({ NSMaxRange($0.range) }).max() else {
            return nil
        }
        var replacement = ""
        var cursor = low
        for change in sorted {
            replacement += text.substring(with: NSRange(location: cursor, length: change.range.location - cursor))
            replacement += change.replacement
            cursor = NSMaxRange(change.range)
        }
        func moved(_ point: Int, afterInsertion: Bool) -> Int {
            var shift = 0
            for change in sorted {
                let delta = (change.replacement as NSString).length - change.range.length
                let changeEnd = NSMaxRange(change.range)
                if changeEnd < point || (changeEnd == point && (change.range.length > 0 || afterInsertion)) {
                    shift += delta
                } else if change.range.location < point, point < changeEnd {
                    return change.range.location + shift + (change.replacement as NSString).length
                }
            }
            return point + shift
        }
        let from = moved(start.0, afterInsertion: start.1)
        let to = max(from, moved(end.0, afterInsertion: end.1))
        return TextEdit(range: NSRange(location: low, length: high - low), replacement: replacement,
                        selection: NSRange(location: from, length: to - from))
    }

    // MARK: 글자 꾸밈 — 도움

    /// `point` 바로 앞에서 끝나는 `symbol` 글자의 연속 개수.
    private static func run(of symbol: unichar, endingAt point: Int, in text: NSString) -> Int {
        var count = 0
        var index = point - 1
        while index >= 0, text.character(at: index) == symbol {
            count += 1
            index -= 1
        }
        return count
    }

    /// `point`에서 시작하는 `symbol` 글자의 연속 개수.
    private static func run(of symbol: unichar, startingAt point: Int, in text: NSString) -> Int {
        var count = 0
        var index = point
        while index < text.length, text.character(at: index) == symbol {
            count += 1
            index += 1
        }
        return count
    }

    private static let blockPrefixPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d{1,9}[.)][ \t]+)*"#)

    /// 고른 범위를 줄마다 자른 조각. 줄 앞의 블록 표식과 앞뒤 공백은 뺀다. 빈 조각은 버린다.
    static func inlineSegments(in text: NSString, selection: NSRange) -> [NSRange] {
        let block = LineEditing.lineBlock(in: text, selection: selection)
        var segments: [NSRange] = []
        text.enumerateSubstrings(in: block, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            guard let cut = line.intersection(selection), cut.length > 0 else { return }
            var start = cut.location
            var end = NSMaxRange(cut)
            if start == line.location {
                let lineText = text.substring(with: line)
                let prefix = blockPrefixPattern.firstMatch(
                    in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length))?.range.length ?? 0
                start += prefix
            }
            while start < end, isSpace(text.character(at: start)) { start += 1 }
            while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
            if end > start { segments.append(NSRange(location: start, length: end - start)) }
        }
        return segments
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x3000
    }
}
