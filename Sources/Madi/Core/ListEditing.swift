import Foundation

/// 목록과 인용의 키보드 규칙 — Enter로 이어 쓰기, 빈 항목에서 끝내기, Tab·⇧Tab 들여쓰기.
///
/// 마크다운 편집기 대부분(Typora, Obsidian, Bear, VS Code의 마크다운 확장)이 같은 규칙을
/// 쓴다. 이것이 없으면 목록을 쓸 때마다 `- `를 손으로 쳐야 하고, 목록을 끝내려면 표지를
/// 지워야 한다.
///
/// 어느 줄이 목록인지는 **줄 판정(`LineToken`)이 정한다.** 줄의 글만 보고 정하면 코드 블록
/// 안의 `- x`에서도 이어 쓰기가 일어난다 — 펜스 안인지는 그 앞의 모든 줄에 달려 있다.
public enum ListEditing {

    /// 줄 앞머리 — 인용 막대, 들여쓰기, 목록 표지, 체크박스.
    struct Prefix: Equatable {
        /// 인용 막대를 쓴 그대로(`> `, `>> `, `> > `).
        var quote: String
        /// 목록 표지 앞의 공백. 인용 안이면 막대 뒤의 공백이다.
        var indent: String
        /// `-` `*` `+` 또는 `3.` `3)`. 목록이 아니면 nil.
        var bullet: String?
        /// 표지 뒤의 공백.
        var gap: String
        /// `[ ]` · `[x]`. 없으면 nil.
        var task: String?
        /// 체크박스 뒤의 공백.
        var taskGap: String

        /// 앞머리 전체의 길이(UTF-16).
        var length: Int {
            (quote + indent + (bullet ?? "") + gap + (task ?? "") + taskGap as NSString).length
        }

        /// 표지와 그 뒤 공백의 폭 — 이 항목의 글이 표지에서 몇 칸 뒤에 시작하는가.
        /// 하위 항목은 이만큼 들여써야 이 항목에 속한다(CommonMark).
        var markerWidth: Int { ((bullet ?? "") + gap as NSString).length }
    }

    /// 줄 앞머리를 가른다. 목록 판정 규칙은 `MarkdownSyntax`의 목록 패턴과 같다(표지 뒤에
    /// 공백이 하나 이상, 체크박스 뒤 공백은 없어도 된다).
    static func prefix(of line: String) -> Prefix {
        let ns = line as NSString
        guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return Prefix(quote: "", indent: "", bullet: nil, gap: "", task: nil, taskGap: "")
        }
        func group(_ index: Int) -> String? {
            let range = m.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        let bullet = group(3)
        return Prefix(quote: group(1) ?? "",
                      // 목록이 아니면 앞 공백은 글의 일부다 — 앞머리로 세지 않는다.
                      indent: bullet == nil ? "" : (group(2) ?? ""),
                      bullet: bullet,
                      gap: group(4) ?? "",
                      task: group(5),
                      taskGap: group(6) ?? "")
    }

    /// 다음 항목의 표지. 번호는 하나 올리고 구분자(`.` `)`)는 그대로 둔다.
    static func nextBullet(after bullet: String) -> String {
        guard let delimiter = bullet.last, delimiter == "." || delimiter == ")",
              let number = Int(bullet.dropLast()) else { return bullet }
        return "\(number + 1)\(delimiter)"
    }

    // MARK: Enter

    /// Enter를 눌렀을 때의 편집. nil이면 평소대로 줄을 바꾼다.
    ///
    /// - 내용이 있는 항목: 캐럿 자리에서 줄을 나누고 새 줄에 같은 표지를 붙인다(번호는 하나
    ///   올린다, 체크박스는 빈 칸으로).
    /// - 내용이 없는 항목: 목록을 끝낸다. 들여쓴 항목이면 한 단계 내어 쓴다 — 하위 목록을
    ///   끝내고 위 목록으로 돌아가는 것이다.
    /// - 캐럿이 표지 앞이나 안에 있으면 평소대로 바꾼다(항목을 통째로 아래로 미는 동작).
    public static func newline(in text: NSString, selection: NSRange,
                               lines: [LineToken]) -> TextEdit? {
        guard let index = lineIndex(containing: selection.location, in: lines) else { return nil }
        let line = lines[index]
        guard isContinuable(line.kind),
              NSMaxRange(selection) <= NSMaxRange(line.range) else { return nil }
        let string = text.substring(with: line.range)
        let parts = prefix(of: string)
        guard parts.bullet != nil || !parts.quote.isEmpty else { return nil }
        let column = selection.location - line.range.location
        guard column >= parts.length else { return nil }

        let rest = (string as NSString).substring(from: parts.length)
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            return endList(line: line, parts: parts, text: text, lines: lines, index: index)
        }

        var next = parts.quote
        if let bullet = parts.bullet {
            next += parts.indent + nextBullet(after: bullet) + parts.gap
            if parts.task != nil { next += "[ ]" + (parts.taskGap.isEmpty ? " " : parts.taskGap) }
        }
        let inserted = "\n" + next
        return TextEdit(range: selection, replacement: inserted,
                        selection: NSRange(location: selection.location + (inserted as NSString).length,
                                           length: 0))
    }

    /// 빈 항목에서의 Enter — 목록(또는 인용)을 끝낸다.
    private static func endList(line: LineToken, parts: Prefix, text: NSString,
                                lines: [LineToken], index: Int) -> TextEdit? {
        // 하위 항목이면 한 단계 내어 쓴다.
        if parts.bullet != nil, !parts.indent.isEmpty,
           let edit = outdent(lineAt: index, in: text, lines: lines) {
            return edit
        }
        // 인용 안의 목록이면 표지만 떼고 인용은 남긴다.
        let keep = (parts.bullet != nil) ? parts.quote : ""
        let replaced = NSRange(location: line.range.location, length: line.range.length)
        return TextEdit(range: replaced, replacement: keep,
                        selection: NSRange(location: line.range.location + (keep as NSString).length,
                                           length: 0))
    }

    // MARK: Tab · ⇧Tab

    /// Tab(`outdent == false`) · ⇧Tab의 편집.
    ///
    /// - Returns: `handled`가 false면 이 규칙의 일이 아니다(목록이 아닌 줄) — 평소의 Tab에
    ///   맡긴다. true인데 `edit`이 nil이면 목록 줄이지만 바꿀 것이 없다(맨 앞 항목의 ⇧Tab).
    ///   그때 평소의 Tab을 부르면 선택이 탭 문자로 바뀌므로, 아무것도 하지 않는다.
    public static func indentation(in text: NSString, selection: NSRange, lines: [LineToken],
                                   outdent isOutdent: Bool) -> (handled: Bool, edit: TextEdit?) {
        guard let first = lineIndex(containing: selection.location, in: lines) else { return (false, nil) }
        var lastLocation = NSMaxRange(selection)
        // 다음 줄의 맨 앞에서 끝나는 선택은 그 줄을 포함하지 않는다(편집기 관례).
        if selection.length > 0, lastLocation > selection.location,
           lastLocation <= text.length, isLineBreak(text.character(at: lastLocation - 1)) {
            lastLocation -= 1
        }
        guard let last = lineIndex(containing: lastLocation, in: lines) else { return (false, nil) }
        let targets = (first ... last).filter { if case .listItem = lines[$0].kind { return true }; return false }
        guard !targets.isEmpty else { return (false, nil) }

        // 줄마다 새 들여쓰기를 **편집 전 글**로 정한다. 여러 항목을 함께 들여써도 서로의
        // 결과에 기대지 않으므로 같은 만큼 움직인다.
        var changes: [(line: LineToken, oldIndent: Int, newIndent: String)] = []
        for index in targets {
            let line = lines[index]
            let parts = prefix(of: text.substring(with: line.range))
            let target = isOutdent
                ? outdentedIndent(for: index, parts: parts, text: text, lines: lines)
                : indentedIndent(for: index, parts: parts, text: text, lines: lines)
            guard let target, target != parts.indent else { continue }
            changes.append((line, (parts.quote + parts.indent as NSString).length,
                            parts.quote + target))
        }
        guard !changes.isEmpty else { return (true, nil) }
        return (true, rewrite(changes, in: text, selection: selection))
    }

    /// 들여쓴 뒤의 공백. 바로 위의 같은 깊이 항목의 표지 폭만큼 더한다 — 그래야 위 항목의
    /// 하위가 된다(`1. ` 아래는 세 칸, `- ` 아래는 두 칸). 위에 없으면 자기 표지 폭.
    /// 탭으로 들여쓴 문서는 탭을 하나 더한다.
    private static func indentedIndent(for index: Int, parts: Prefix, text: NSString,
                                       lines: [LineToken]) -> String? {
        if parts.indent.contains("\t") { return parts.indent + "\t" }
        var width = parts.markerWidth
        if let sibling = previousItem(before: index, text: text, lines: lines, where: {
            $0.quote == parts.quote && $0.indent == parts.indent
        }) {
            width = sibling.markerWidth
        }
        return parts.indent + String(repeating: " ", count: max(1, width))
    }

    /// 내어 쓴 뒤의 공백 — 위 항목(이것보다 덜 들여쓴 가장 가까운 항목)과 같은 깊이.
    /// 위 항목이 없으면 맨 앞으로. 이미 맨 앞이면 nil.
    private static func outdentedIndent(for index: Int, parts: Prefix, text: NSString,
                                        lines: [LineToken]) -> String? {
        guard !parts.indent.isEmpty else { return nil }
        let depth = (parts.indent as NSString).length
        if let parent = previousItem(before: index, text: text, lines: lines, where: {
            $0.quote == parts.quote && ($0.indent as NSString).length < depth
        }) {
            return parent.indent
        }
        return ""
    }

    /// 빈 하위 항목의 Enter가 쓰는 내어 쓰기 — 캐럿은 줄의 끝으로.
    private static func outdent(lineAt index: Int, in text: NSString, lines: [LineToken]) -> TextEdit? {
        let line = lines[index]
        let parts = prefix(of: text.substring(with: line.range))
        guard let target = outdentedIndent(for: index, parts: parts, text: text, lines: lines) else {
            return nil
        }
        return rewrite([(line, (parts.quote + parts.indent as NSString).length, parts.quote + target)],
                       in: text, selection: NSRange(location: NSMaxRange(line.range), length: 0))
    }

    /// 바로 위의 목록 항목 가운데 `matches`를 만족하는 가장 가까운 것. 목록 덩이를 벗어나면
    /// (목록도 들여쓴 글줄도 빈 줄도 아닌 줄) 멈춘다.
    private static func previousItem(before index: Int, text: NSString, lines: [LineToken],
                                     where matches: (Prefix) -> Bool) -> Prefix? {
        var cursor = index - 1
        while cursor >= 0 {
            let line = lines[cursor]
            switch line.kind {
            case .listItem:
                let parts = prefix(of: text.substring(with: line.range))
                if matches(parts) { return parts }
            case .blank:
                break
            case .paragraph where line.range.length > 0
                && isIndent(text.character(at: line.range.location)):
                break
            default:
                return nil
            }
            cursor -= 1
        }
        return nil
    }

    /// 줄들의 들여쓰기를 바꾸는 편집 하나. 첫 줄의 시작부터 마지막 줄의 끝까지를 통째로
    /// 바꾸고, 선택은 같은 글자를 가리키도록 옮긴다.
    private static func rewrite(_ changes: [(line: LineToken, oldIndent: Int, newIndent: String)],
                                in text: NSString, selection: NSRange) -> TextEdit {
        let start = changes[0].line.range.location
        let end = NSMaxRange(changes[changes.count - 1].line.range)
        var replacement = ""
        var cursor = start
        // (줄 시작, 옛 앞머리 길이, 새 앞머리 길이)
        var shifts: [(Int, Int, Int)] = []
        for change in changes {
            let lineStart = change.line.range.location
            replacement += text.substring(with: NSRange(location: cursor, length: lineStart - cursor))
            replacement += change.newIndent
            let newLength = (change.newIndent as NSString).length
            shifts.append((lineStart, change.oldIndent, newLength))
            cursor = lineStart + change.oldIndent
        }
        replacement += text.substring(with: NSRange(location: cursor, length: end - cursor))

        func map(_ position: Int) -> Int {
            var delta = 0
            for (lineStart, old, new) in shifts {
                if position >= lineStart + old {
                    delta += new - old
                } else if position > lineStart {
                    // 옛 앞머리 안이었다 — 새 앞머리 안의 같은 칸(넘으면 끝).
                    return position + delta - (position - lineStart) + min(position - lineStart, new)
                } else {
                    break
                }
            }
            return position + delta
        }
        let newStart = map(selection.location)
        let newEnd = map(NSMaxRange(selection))
        return TextEdit(range: NSRange(location: start, length: end - start),
                        replacement: replacement,
                        selection: NSRange(location: newStart, length: max(0, newEnd - newStart)))
    }

    // MARK: 체크박스

    /// `[ ]` ↔ `[x]`. `box`는 여는 대괄호의 위치다. 그 자리가 체크박스가 아니면 nil.
    /// 바꾸는 것은 가운데 한 글자뿐이라 선택은 그대로 둔다.
    public static func toggleTask(in text: NSString, box: Int, selection: NSRange) -> TextEdit? {
        guard box >= 0, box + 3 <= text.length,
              text.character(at: box) == 0x5B, text.character(at: box + 2) == 0x5D else { return nil }
        let mark = text.character(at: box + 1)
        let replacement: String
        switch mark {
        case 0x20: replacement = "x"
        case 0x78, 0x58: replacement = " "      // x X
        default: return nil
        }
        return TextEdit(range: NSRange(location: box + 1, length: 1), replacement: replacement,
                        selection: selection)
    }

    // MARK: 도우미

    private static func isContinuable(_ kind: BlockKind) -> Bool {
        switch kind {
        case .listItem, .quote: return true
        default: return false
        }
    }

    /// `location`이 든 줄의 배열 위치.
    static func lineIndex(containing location: Int, in lines: [LineToken]) -> Int? {
        guard !lines.isEmpty, location >= 0 else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].range.location <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private static func isLineBreak(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }
    private static func isIndent(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }

    /// 인용 막대들 · 들여쓰기 · 표지 · 표지 뒤 공백 · 체크박스 · 그 뒤 공백.
    /// 인용 막대는 `MarkdownSyntax`처럼 세 칸까지 들여쓸 수 있다.
    private static let pattern: NSRegularExpression = {
        let source = #"^((?:[ ]{0,3}>[ \t]?)*)([ \t]*)(?:([-+*]|\d{1,9}[.)])([ \t]+)(?:(\[[ xX]\])([ \t]*))?)?"#
        guard let expression = try? NSRegularExpression(pattern: source) else {
            preconditionFailure("invalid built-in pattern")
        }
        return expression
    }()
}
