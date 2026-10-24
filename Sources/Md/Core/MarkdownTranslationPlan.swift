import Foundation

/// 마크다운을 **번역할 단위**와 **건드리지 않을 조각**으로 가른다.
///
/// Sogon은 받아쓴 말을 통째로 넘기므로 이 문제가 없다. 마크다운은 둘을 동시에 만족해야 한다 —
/// 마크업이 번역기를 통과하면 안 되고(코드가 번역되거나 링크 URL이 깨진다), 그렇다고 마커마다
/// 잘라 넘기면 **문장의 문맥이 사라진다.**
///
/// 처음에는 마커마다 잘라 넘겼고 결과가 이렇게 나왔다(실측, Apple 번역 ko→en):
///
///     본문은 **굵게**와 `인라인 코드`, [문서 링크](…)를 포함합니다.
///     → The main text is**Boldly**Wow`인라인 코드`,[Document link](…)Includes.
///
/// 13조각이 각각 문맥 없이 번역돼 말이 되지 않았다. 그래서 **문장을 통째로 넘기고 보호할
/// 구간만 자리표로 바꾼다.** 자리표는 사용자 영역 문자(`U+E000`/`U+E001`)로 감싼 번호다 —
/// 문서 내용과 충돌하지 않고, Apple 번역이 그대로 통과시키는 것을 실측했다(대괄호·중괄호·
/// 태그 모양도 통과했지만 그것들은 문서에 실제로 나타날 수 있다).
///
/// 자리표로 바꾸는 것: 인라인 코드, 자동 링크, 링크·이미지의 `[`와 `](URL)` 부분,
/// 굵게·기울임·취소선의 마커.
/// 번역에서 아예 빼는 것(단위 밖의 리터럴): 펜스 코드 블록, 제목의 `#`, 인용의 `>`,
/// 목록 불릿·번호·체크박스, 수평선, 표 구분선, 표의 `|`와 칸 정렬 공백.
///
/// 불변식: **모든 조각을 이으면 원문과 글자 하나까지 같다**(`source`). 번역을 하나도 하지
/// 않아도 문서가 그대로 복원된다.
public struct MarkdownTranslationPlan: Equatable {

    /// 자리표를 감싸는 문자. 사용자 영역이라 실제 문서에 나타나지 않는다.
    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"

    /// 번역기에 넘기는 단위 하나. 보통 한 줄의 본문 또는 표의 한 칸이다.
    public struct Unit: Equatable {
        /// 번역기에 넘기는 글. 보호 구간은 자리표로 바뀌어 있다.
        public let text: String
        /// 자리표 번호 순서대로의 원문 조각.
        public let protected: [String]

        /// 번역문의 자리표를 원문 조각으로 되돌린다.
        ///
        /// 번역기가 자리표를 잃었으면 그 조각은 되살릴 자리가 없다 — 끝에 붙인다.
        /// 잃는 쪽이 지우는 쪽보다 낫다(코드나 링크가 조용히 사라지지 않는다).
        public func restored(from translated: String) -> String {
            var out = translated
            var missing: [String] = []
            for (index, original) in protected.enumerated() {
                let token = "\(MarkdownTranslationPlan.open)\(index)\(MarkdownTranslationPlan.close)"
                if out.contains(token) {
                    out = out.replacingOccurrences(of: token, with: original)
                } else {
                    missing.append(original)
                }
            }
            return missing.isEmpty ? out : out + missing.joined()
        }
    }

    public enum Segment: Equatable {
        case literal(String)
        case unit(Unit)
    }

    public let segments: [Segment]

    public var units: [Unit] {
        segments.compactMap { if case let .unit(unit) = $0 { unit } else { nil } }
    }

    /// 번역기에 넘길 글들. `assembled(with:)`에 같은 개수·순서로 돌려준다.
    public var translatableTexts: [String] { units.map(\.text) }

    /// 조각을 모두 이은 원문. 불변식 검사의 대상이다.
    public var source: String {
        segments.map { segment in
            switch segment {
            case let .literal(value): value
            case let .unit(unit): unit.restored(from: unit.text)
            }
        }.joined()
    }

    public var translatableCharacterCount: Int {
        units.reduce(0) { $0 + $1.text.count }
    }

    // MARK: Build

    public static func make(_ text: String, syntax: MarkdownSyntax = MarkdownSyntax()) -> MarkdownTranslationPlan {
        let ns = text as NSString
        guard ns.length > 0 else { return MarkdownTranslationPlan(segments: []) }

        var builder = Builder(text: ns)
        var cursor = 0
        for line in syntax.scanLines(in: ns) {
            if line.range.location > cursor {
                builder.literal(NSRange(location: cursor, length: line.range.location - cursor))
            }
            append(line: line, to: &builder, text: ns, syntax: syntax)
            cursor = max(cursor, NSMaxRange(line.range))
        }
        if cursor < ns.length {
            builder.literal(NSRange(location: cursor, length: ns.length - cursor))
        }
        return MarkdownTranslationPlan(segments: builder.finish())
    }

    private static func append(line: LineToken, to builder: inout Builder,
                               text: NSString, syntax: MarkdownSyntax) {
        guard line.range.length > 0 else { return }

        switch line.kind {
        case .codeFence, .codeBody, .thematicBreak, .tableDelimiter, .blank:
            builder.literal(line.range)

        case .tableRow:
            appendTableRow(line.range, to: &builder, text: text, syntax: syntax)

        case .heading, .quote, .listItem, .paragraph:
            let content = line.contentRange
            let hasContent = content.location != NSNotFound && content.length > 0
            let contentStart = hasContent ? content.location : NSMaxRange(line.range)
            if contentStart > line.range.location {
                builder.literal(NSRange(location: line.range.location,
                                        length: contentStart - line.range.location))
            }
            guard hasContent else { return }
            builder.unit(content, syntax: syntax)
            let contentEnd = NSMaxRange(content)
            if contentEnd < NSMaxRange(line.range) {
                builder.literal(NSRange(location: contentEnd,
                                        length: NSMaxRange(line.range) - contentEnd))
            }
        }
    }

    /// 표의 한 행. `|`와 칸 정렬 공백은 리터럴이고, 칸 내용은 각각 **독립된 단위**다 —
    /// 칸은 서로 문맥을 공유하지 않으므로 함께 넘길 이유가 없다.
    private static func appendTableRow(_ range: NSRange, to builder: inout Builder,
                                       text: NSString, syntax: MarkdownSyntax) {
        var cursor = range.location
        let end = NSMaxRange(range)
        while cursor < end {
            let pipe = text.range(of: "|", options: [],
                                  range: NSRange(location: cursor, length: end - cursor))
            let cellEnd = pipe.location == NSNotFound ? end : pipe.location
            if cellEnd > cursor {
                appendCell(NSRange(location: cursor, length: cellEnd - cursor),
                           to: &builder, text: text, syntax: syntax)
            }
            if pipe.location == NSNotFound { return }
            builder.literal(pipe)
            cursor = NSMaxRange(pipe)
        }
    }

    private static func appendCell(_ range: NSRange, to builder: inout Builder,
                                   text: NSString, syntax: MarkdownSyntax) {
        let raw = text.substring(with: range)
        let leading = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
        let trailing = raw.reversed().prefix(while: { $0 == " " || $0 == "\t" }).count
        guard leading + trailing < (raw as NSString).length else {
            builder.literal(range)
            return
        }
        if leading > 0 { builder.literal(NSRange(location: range.location, length: leading)) }
        builder.unit(NSRange(location: range.location + leading,
                             length: range.length - leading - trailing), syntax: syntax)
        if trailing > 0 {
            builder.literal(NSRange(location: NSMaxRange(range) - trailing, length: trailing))
        }
    }

    // MARK: Assemble

    public enum AssemblyError: Error, Equatable {
        case countMismatch(expected: Int, got: Int)
    }

    public func assembled(with translations: [String]) throws -> String {
        let expected = units.count
        guard translations.count == expected else {
            throw AssemblyError.countMismatch(expected: expected, got: translations.count)
        }
        var index = 0
        var out = ""
        for segment in segments {
            switch segment {
            case let .literal(value):
                out += value
            case let .unit(unit):
                out += unit.restored(from: translations[index])
                index += 1
            }
        }
        return out
    }

    // MARK: Builder

    private struct Builder {
        let text: NSString
        private var segments: [Segment] = []

        init(text: NSString) { self.text = text }

        mutating func literal(_ range: NSRange) { addLiteral(text.substring(with: range)) }

        /// 한 줄의 본문(또는 표의 한 칸)을 단위 하나로 만든다. 보호 구간은 자리표가 된다.
        mutating func unit(_ range: NSRange, syntax: MarkdownSyntax) {
            guard range.length > 0 else { return }
            var body = ""
            var protected: [String] = []

            func protect(_ protectedRange: NSRange) {
                guard protectedRange.length > 0 else { return }
                body += "\(MarkdownTranslationPlan.open)\(protected.count)\(MarkdownTranslationPlan.close)"
                protected.append(text.substring(with: protectedRange))
            }

            var cursor = range.location
            let end = NSMaxRange(range)
            for token in syntax.scanInline(in: text, range: range) {
                guard token.range.location >= cursor, NSMaxRange(token.range) <= end else { continue }
                if token.range.location > cursor {
                    body += text.substring(with: NSRange(location: cursor,
                                                         length: token.range.location - cursor))
                }
                switch token.kind {
                case .code, .autolink:
                    protect(token.range)
                case .link, .image, .strong, .emphasis, .strikethrough:
                    let content = token.contentRange
                    if content.location != NSNotFound, content.length > 0,
                       content.location >= token.range.location,
                       NSMaxRange(content) <= NSMaxRange(token.range) {
                        protect(NSRange(location: token.range.location,
                                        length: content.location - token.range.location))
                        body += text.substring(with: content)
                        protect(NSRange(location: NSMaxRange(content),
                                        length: NSMaxRange(token.range) - NSMaxRange(content)))
                    } else {
                        protect(token.range)
                    }
                }
                cursor = NSMaxRange(token.range)
            }
            if cursor < end {
                body += text.substring(with: NSRange(location: cursor, length: end - cursor))
            }

            // 번역할 글자가 하나도 없으면(자리표와 공백뿐) 번역기를 부르지 않는다.
            let bare = body.filter { $0 != MarkdownTranslationPlan.open && $0 != MarkdownTranslationPlan.close }
                .filter { !$0.isNumber }
            if bare.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addLiteral(text.substring(with: range))
                return
            }
            segments.append(.unit(Unit(text: body, protected: protected)))
        }

        private mutating func addLiteral(_ value: String) {
            guard !value.isEmpty else { return }
            if case let .literal(previous) = segments.last {
                segments[segments.count - 1] = .literal(previous + value)
            } else {
                segments.append(.literal(value))
            }
        }

        func finish() -> [Segment] { segments }
    }
}
