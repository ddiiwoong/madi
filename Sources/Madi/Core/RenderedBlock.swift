import Foundation

/// 글 대신 **그림으로** 보여 줄 블록 — Mermaid 다이어그램과 KaTeX 수식.
///
/// 이것은 블록을 **찾기만** 한다. 그리는 일은 Editor의 `DiagramRenderer`가 숨은 웹뷰로 한다
/// (Core는 Foundation만 쓴다 — `make core-only`).
///
/// 찾는 모양:
/// - ```` ```mermaid ```` 펜스 블록
/// - ```` ```math ```` 펜스 블록(GitHub과 같은 모양). `katex`도 받는다
/// - `$$`만 있는 줄로 열고 닫는 블록, 그리고 한 줄짜리 `$$ … $$`
///
/// **닫히지 않은 블록은 그리지 않는다.** 치는 중인 블록이고, 닫는 펜스가 생길 때까지는
/// 아래 글 전체가 그 블록으로 읽힌다 — 그것을 그림으로 바꾸면 문서가 통째로 사라져 보인다.
///
/// 글 안의 `$…$`(인라인 수식)는 찾지 않는다. 글줄 사이에 그림을 끼우는 것은 줄 높이로
/// 자리를 만드는 지금 방식으로는 할 수 없다(`MarkdownStyler.placeImages`의 한계와 같다).
public struct RenderedBlock: Equatable, Sendable {

    public enum Kind: String, Sendable {
        case mermaid
        case math
    }

    /// `$$` 블록인가, 펜스 블록인가. `$$` 블록의 줄은 문단으로 읽히므로 원문을 보일 때
    /// 스타일러가 코드처럼 다시 칠해야 한다(`x_1`의 `_`가 기울임 표시로 숨지 않게).
    public enum Delimiter: Sendable {
        case fence
        case dollars
    }

    public let kind: Kind
    public let delimiter: Delimiter
    /// 그릴 원문 — 펜스나 `$$`를 뺀 안쪽.
    public let source: String
    /// 블록 전체(여는 줄의 처음부터 닫는 줄의 끝까지, 마지막 줄바꿈은 빼고).
    public let range: NSRange
    /// 여는 줄과 닫는 줄의 번호(1부터). 한 줄짜리 `$$ … $$`면 둘이 같다.
    public let firstLine: Int
    public let lastLine: Int

    public func contains(line: Int) -> Bool { (firstLine ... lastLine).contains(line) }

    /// 펜스의 정보 문자열을 종류로. 첫 낱말만 본다(```` ```mermaid title ````).
    public static func kind(forFenceInfo info: String?) -> Kind? {
        guard let word = info?.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first
        else { return nil }
        switch word.lowercased() {
        case "mermaid": return .mermaid
        case "math", "katex": return .math
        default: return nil
        }
    }

    /// 글의 블록을 위에서부터 찾는다. 줄 판정(`lines`)은 `MarkdownSyntax.scanLines`의 것이다.
    public static func blocks(in text: NSString, lines: [LineToken]) -> [RenderedBlock] {
        var found: [RenderedBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.kind == .codeFence {
                // 여는 펜스. 닫는 펜스까지가 한 블록이다 — 펜스 줄은 열고 닫기를 번갈아 하므로
                // 여기서 만나는 펜스는 늘 여는 쪽이다.
                var close = index + 1
                while close < lines.count, lines[close].kind == .codeBody { close += 1 }
                guard close < lines.count, lines[close].kind == .codeFence else { break }  // 안 닫혔다
                if let kind = kind(forFenceInfo: line.language) {
                    let body = lines[(index + 1) ..< close]
                    found.append(make(kind, .fence, body: Array(body), open: line,
                                      close: lines[close], in: text))
                }
                index = close + 1
                continue
            }
            if line.kind == .paragraph, let block = dollarBlock(startingAt: index, lines: lines, in: text) {
                found.append(block)
                index = block.lastLine            // 다음 줄의 인덱스(번호는 1부터)
                continue
            }
            index += 1
        }
        return found
    }

    private static func make(_ kind: Kind, _ delimiter: Delimiter, body: [LineToken],
                             open: LineToken, close: LineToken, in text: NSString) -> RenderedBlock {
        let source = body.map { text.substring(with: $0.range) }.joined(separator: "\n")
        return RenderedBlock(
            kind: kind, delimiter: delimiter, source: source,
            range: NSRange(location: open.range.location,
                           length: NSMaxRange(close.range) - open.range.location),
            firstLine: open.lineNumber, lastLine: close.lineNumber)
    }

    /// `$$` 블록. 여는 줄은 다듬은 내용이 `$$`로 **시작하는** 문단이다.
    ///
    /// - `$$ x $$` — 한 줄로 끝난다
    /// - `$$`만 있는 줄 — 다음 `$$`만 있는 줄까지. **빈 줄을 만나면 블록이 아니다**: 문단이
    ///   거기서 끝나므로, 짝 없는 `$$` 하나가 문서 끝까지를 수식으로 삼키지 않는다.
    ///   코드 펜스를 만나도 아니다.
    private static func dollarBlock(startingAt index: Int, lines: [LineToken],
                                    in text: NSString) -> RenderedBlock? {
        let open = lines[index]
        // 문단 줄은 문서의 거의 전부다. 타이핑마다 도는 패스이므로 **문자열을 만들기 전에**
        // 첫 글자가 `$`인지만 본다(22만 자 문서에서 줄마다 문자열을 만들면 그것이 비용이다).
        var lead = open.range.location
        while lead < NSMaxRange(open.range), text.character(at: lead) == 0x20 || text.character(at: lead) == 0x09 {
            lead += 1
        }
        guard lead < NSMaxRange(open.range), text.character(at: lead) == 0x24 else { return nil }
        let trimmed = text.substring(with: open.range).trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("$$") else { return nil }

        if trimmed != "$$" {
            // 한 줄짜리. `$$`로 끝나야 하고 안이 비어 있으면 안 된다.
            guard trimmed.count > 4, trimmed.hasSuffix("$$") else { return nil }
            let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            guard !inner.isEmpty else { return nil }
            return RenderedBlock(kind: .math, delimiter: .dollars, source: inner, range: open.range,
                                 firstLine: open.lineNumber, lastLine: open.lineNumber)
        }

        var close = index + 1
        while close < lines.count {
            let line = lines[close]
            if line.kind == .blank || line.kind == .codeFence || line.kind == .codeBody { return nil }
            if text.substring(with: line.range).trimmingCharacters(in: .whitespaces) == "$$" { break }
            close += 1
        }
        guard close < lines.count, close > index + 1 else { return nil }
        return make(.math, .dollars, body: Array(lines[(index + 1) ..< close]), open: open,
                    close: lines[close], in: text)
    }
}
