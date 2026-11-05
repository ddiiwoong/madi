import Foundation

/// 줄 단위 편집 — 옮기기, 복제, 지우기.
///
/// 코드 편집기의 관례(Xcode, VS Code, Sublime)를 따른다. 선택이 걸친 **줄 전체**가 단위다.
/// 다음 줄의 맨 앞에서 끝나는 선택은 그 줄을 포함하지 않는다 — 줄을 끌어 고르면 선택이
/// 다음 줄의 맨 앞에서 끝나는데, 그 줄까지 움직이면 사용자가 고른 것보다 한 줄 많다.
public enum LineEditing {

    /// 선택이 걸친 줄들 — 첫 줄의 시작부터 마지막 줄의 끝(줄바꿈 포함)까지.
    public static func lineBlock(in text: NSString, selection: NSRange) -> NSRange {
        let start = text.lineRange(for: NSRange(location: min(selection.location, text.length), length: 0))
        var lastProbe = selection.location
        if selection.length > 0 { lastProbe = max(selection.location, NSMaxRange(selection) - 1) }
        let last = text.lineRange(for: NSRange(location: min(lastProbe, text.length), length: 0))
        return NSRange(location: start.location, length: NSMaxRange(last) - start.location)
    }

    /// 줄을 한 줄 위로. 맨 윗줄이면 nil.
    public static func moveUp(in text: NSString, selection: NSRange) -> TextEdit? {
        let block = lineBlock(in: text, selection: selection)
        guard block.location > 0 else { return nil }
        let previous = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
        let blockText = text.substring(with: block)
        let previousText = text.substring(with: previous)
        let replacement: String
        if terminator(of: blockText).isEmpty {
            // 마지막 줄(줄바꿈 없음)을 올린다 — 줄바꿈이 위 줄에서 옮겨 온다.
            let ending = terminator(of: previousText)
            replacement = blockText + ending + dropTerminator(previousText)
        } else {
            replacement = blockText + previousText
        }
        let offset = selection.location - block.location
        return TextEdit(range: NSRange(location: previous.location, length: NSMaxRange(block) - previous.location),
                        replacement: replacement,
                        selection: NSRange(location: previous.location + offset, length: selection.length))
    }

    /// 줄을 한 줄 아래로. 맨 아랫줄이면 nil.
    public static func moveDown(in text: NSString, selection: NSRange) -> TextEdit? {
        let block = lineBlock(in: text, selection: selection)
        let end = NSMaxRange(block)
        guard end < text.length else { return nil }
        let next = text.lineRange(for: NSRange(location: end, length: 0))
        let blockText = text.substring(with: block)
        let nextText = text.substring(with: next)
        let replacement: String
        let newStart: Int
        if terminator(of: nextText).isEmpty {
            // 마지막 줄 아래로 내린다 — 내린 줄이 마지막이 되어 줄바꿈을 내준다.
            let ending = terminator(of: blockText)
            replacement = nextText + ending + dropTerminator(blockText)
            newStart = block.location + (nextText as NSString).length + (ending as NSString).length
        } else {
            replacement = nextText + blockText
            newStart = block.location + next.length
        }
        let offset = selection.location - block.location
        return TextEdit(range: NSRange(location: block.location, length: NSMaxRange(next) - block.location),
                        replacement: replacement,
                        selection: NSRange(location: newStart + offset, length: selection.length))
    }

    /// 줄을 아래에 한 벌 더 놓는다. 선택은 새로 놓인 쪽으로 간다 — 이어서 누르면 계속 쌓인다.
    public static func duplicate(in text: NSString, selection: NSRange) -> TextEdit? {
        let block = lineBlock(in: text, selection: selection)
        let blockText = text.substring(with: block)
        guard text.length > 0 else { return nil }
        let end = NSMaxRange(block)
        let ending = terminator(of: blockText)
        // 마지막 줄이면 사이에 줄바꿈을 넣는다.
        let inserted = ending.isEmpty ? newline(near: block, in: text) + blockText : blockText
        let shift = (inserted as NSString).length
        return TextEdit(range: NSRange(location: end, length: 0),
                        replacement: inserted,
                        selection: NSRange(location: selection.location + shift, length: selection.length))
    }

    /// 줄을 지운다. 캐럿은 그 자리에 올라온 줄의 맨 앞으로 간다.
    public static func delete(in text: NSString, selection: NSRange) -> TextEdit? {
        guard text.length > 0 else { return nil }
        let block = lineBlock(in: text, selection: selection)
        let blockText = text.substring(with: block)
        if terminator(of: blockText).isEmpty, block.location > 0 {
            // 마지막 줄 — 위 줄의 줄바꿈까지 지운다. 안 그러면 빈 줄이 남는다.
            let previous = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let ending = (terminator(of: text.substring(with: previous)) as NSString).length
            let range = NSRange(location: block.location - ending, length: block.length + ending)
            return TextEdit(range: range, replacement: "",
                            selection: NSRange(location: previous.location, length: 0))
        }
        return TextEdit(range: block, replacement: "", selection: NSRange(location: block.location, length: 0))
    }

    // MARK: 줄바꿈

    /// 줄 끝의 줄바꿈(`\n`, `\r\n`, `\r`). 없으면 빈 문자열.
    static func terminator(of line: String) -> String {
        if line.hasSuffix("\r\n") { return "\r\n" }
        if line.hasSuffix("\n") { return "\n" }
        if line.hasSuffix("\r") { return "\r" }
        return ""
    }

    static func dropTerminator(_ line: String) -> String {
        String(line.dropLast(terminator(of: line) == "" ? 0 : 1))
    }

    /// 문서가 쓰는 줄바꿈. 바로 위 줄의 것을 따르고, 없으면 `\n`.
    private static func newline(near block: NSRange, in text: NSString) -> String {
        guard block.location > 0 else { return "\n" }
        let previous = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
        let ending = terminator(of: text.substring(with: previous))
        return ending.isEmpty ? "\n" : ending
    }
}
