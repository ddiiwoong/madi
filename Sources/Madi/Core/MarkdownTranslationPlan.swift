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

    /// 보호 구간 하나.
    ///
    /// 번역기가 자리표 주변에 공백을 넣는 것을 실측했다 — `[문서 링크]`의 여는 `[`를
    /// 자리표로 바꿔 넘기면 `⟦3⟧ document links`로 돌아와 `[ document links]`가 됐다.
    ///
    /// 그런데 "원문에 공백이 없었으니 지운다"는 규칙만으로는 **틀린다.** 한국어는 조사가
    /// 붙어 `**굵게**와`처럼 공백이 없지만 영어는 `**bold** and`처럼 공백이 있어야 한다.
    /// 그 규칙으로 지웠더니 `**bold**and`가 나왔다(실측). 그래서 **구분자가 여는 쪽인지
    /// 닫는 쪽인지**를 함께 들고, 지우는 방향을 그것으로 정한다:
    ///
    /// - 여는 구분자(`[`, 여는 `**`): 자리표 **뒤**의 공백을 지운다 → `[document`
    /// - 닫는 구분자(`](url)`, 닫는 `**`): 자리표 **앞**의 공백을 지운다 → `links]`
    /// - 그 자체로 완결된 구간(인라인 코드, 자동 링크): 공백을 건드리지 않는다
    public struct ProtectedSpan: Equatable {
        public enum Role: Equatable {
            /// 뒤따르는 글을 감싸기 시작하는 구간.
            case opening
            /// 앞의 글을 닫는 구간.
            case closing
            /// 감싸는 것이 아니라 통째로 보호되는 구간.
            case standalone
        }

        public let text: String
        public let role: Role
        /// 원문에서 **지울 쪽**(opening이면 뒤, closing이면 앞)에 공백이 있었는가.
        /// 있었다면 번역기가 넣은 것이 아니므로 건드리지 않는다.
        public let hadAdjacentSpace: Bool
    }

    /// 번역기에 넘기는 단위 하나. 보통 한 줄의 본문 또는 표의 한 칸이다.
    public struct Unit: Equatable {
        /// 번역기에 넘기는 글. 보호 구간은 자리표로 바뀌어 있다.
        public let text: String
        /// 자리표 번호 순서대로의 보호 구간.
        public let protected: [ProtectedSpan]

        /// 번역문의 자리표를 원문 조각으로 되돌린다.
        ///
        /// 번역기가 자리표를 잃었으면 그 조각은 되살릴 자리가 없다 — 끝에 붙인다.
        /// 잃는 쪽이 지우는 쪽보다 낫다(코드나 링크가 조용히 사라지지 않는다).
        public func restored(from translated: String) -> String {
            var out = translated
            var missing: [String] = []

            for (index, span) in protected.enumerated() {
                let token = "\(MarkdownTranslationPlan.open)\(index)\(MarkdownTranslationPlan.close)"
                guard out.contains(token) else {
                    missing.append(span.text)
                    continue
                }
                if !span.hadAdjacentSpace {
                    switch span.role {
                    case .opening: out = removingSpace(after: token, in: out)
                    case .closing: out = removingSpace(before: token, in: out)
                    case .standalone: break
                    }
                }
                out = out.replacingOccurrences(of: token, with: span.text)
            }
            return missing.isEmpty ? out : out + missing.joined()
        }

        /// 자리표는 번호마다 유일하므로 첫 등장만 보면 된다.
        private func removingSpace(after token: String, in text: String) -> String {
            guard let range = text.range(of: token), range.upperBound < text.endIndex,
                  text[range.upperBound] == " " else { return text }
            var result = text
            result.remove(at: range.upperBound)
            return result
        }

        private func removingSpace(before token: String, in text: String) -> String {
            guard let range = text.range(of: token), range.lowerBound > text.startIndex else { return text }
            let beforeToken = text.index(before: range.lowerBound)
            guard text[beforeToken] == " " else { return text }
            var result = text
            result.remove(at: beforeToken)
            return result
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

        case .setextUnderline:
            // 밑줄은 번역할 글이 아니라 표시다. 번역기에 넘기면 `===`가 되돌아오지
            // 않아 제목이 문단으로 떨어진다.
            builder.literal(line.range)

        case .linkDefinition:
            // 라벨도 주소도 번역하지 않는다. 주소를 번역기에 넘기면 링크가 깨지고,
            // **라벨을 번역하면 그 라벨을 가리키던 본문의 참조가 전부 끊어진다** —
            // 본문 쪽은 인라인 단위로 번역되므로 둘이 따로 번역돼 서로 어긋난다.
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

    /// 표의 한 행. **행 전체를 한 단위로** 넘기고 `|`만 자리표로 지킨다.
    ///
    /// 왜 바꿨는가(실측): 전에는 칸마다 독립된 단위였다. 번역기에 `검색` 한 낱말만
    /// 넘어가니 문맥이 없어 `reference`가 나오고, `항목`은 `a head`가 됐다. 사람도
    /// 낱말 하나만 보면 그렇게 읽는다 — 정보가 없는 것이 문제였다.
    ///
    /// 행을 통째로 넘기면 같은 행의 다른 칸이 문맥이 된다. 칸 경계는 `|`를 자리표로
    /// 바꿔 지키므로, 번역기가 글을 옮겨도 칸의 개수와 자리는 보존된다. 번역기가
    /// 자리표를 잃으면 `restored(from:)`이 끝에 붙여 내용을 잃지 않는다.
    private static func appendTableRow(_ range: NSRange, to builder: inout Builder,
                                       text: NSString, syntax: MarkdownSyntax) {
        let row = LineToken(lineNumber: 0, range: range, kind: .tableRow,
                            markerRanges: [], contentRange: range)
        // `MarkdownTable`이 이미 `\|`와 인라인 코드 안의 막대를 가려 준다.
        let separators = MarkdownTable.parseRow(row, in: text).separators
        builder.unit(range, syntax: syntax, protecting: separators)
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

        /// 한 줄의 본문(또는 표의 한 행)을 단위 하나로 만든다. 보호 구간은 자리표가 된다.
        ///
        /// - Parameter protecting: 인라인 마크업 **말고도** 지켜야 하는 구간. 표의 `|`가
        ///   여기로 온다 — 행을 한 단위로 넘기면서 칸 경계는 지켜야 하기 때문이다.
        mutating func unit(_ range: NSRange, syntax: MarkdownSyntax,
                           protecting extra: [NSRange] = []) {
            guard range.length > 0 else { return }
            var body = ""
            var protected: [ProtectedSpan] = []

            /// 원문에서 `index` 위치의 글자가 공백인가. 줄 밖이면 true로 본다 —
            /// 경계에는 지울 공백이 없다.
            func isSpace(at index: Int) -> Bool {
                guard index >= 0, index < text.length else { return true }
                let scalar = text.character(at: index)
                return scalar == 32 || scalar == 9 || scalar == 10 || scalar == 13
            }

            func protect(_ protectedRange: NSRange, role: ProtectedSpan.Role) {
                guard protectedRange.length > 0 else { return }
                body += "\(MarkdownTranslationPlan.open)\(protected.count)\(MarkdownTranslationPlan.close)"
                // 지울 쪽의 공백만 본다 — 여는 구간은 뒤, 닫는 구간은 앞.
                let adjacent: Bool = switch role {
                case .opening: isSpace(at: NSMaxRange(protectedRange))
                case .closing: isSpace(at: protectedRange.location - 1)
                case .standalone: true
                }
                protected.append(ProtectedSpan(
                    text: text.substring(with: protectedRange),
                    role: role,
                    hadAdjacentSpace: adjacent
                ))
            }

            // 지킬 자리를 한 목록으로 모아 **위치 순으로** 적용한다. 인라인 토큰과
            // 바깥에서 들어온 구간(표의 `|`)을 따로 돌면 순서가 섞여 자리표 번호와
            // 실제 위치가 어긋난다.
            enum Step {
                case guard_(NSRange, ProtectedSpan.Role)
                /// 번역기에 그대로 넘어가는 조각(강조의 내용 등).
                case through(NSRange)

                var location: Int {
                    switch self {
                    case let .guard_(range, _): return range.location
                    case let .through(range): return range.location
                    }
                }
            }

            var steps: [Step] = []
            let end = NSMaxRange(range)
            var tokenRanges: [NSRange] = []

            for token in syntax.scanInline(in: text, range: range) {
                guard token.range.location >= range.location,
                      NSMaxRange(token.range) <= end else { continue }
                tokenRanges.append(token.range)
                switch token.kind {
                case .code, .autolink:
                    steps.append(.guard_(token.range, .standalone))
                case .link, .image, .strong, .emphasis, .strikethrough:
                    let content = token.contentRange
                    if content.location != NSNotFound, content.length > 0,
                       content.location >= token.range.location,
                       NSMaxRange(content) <= NSMaxRange(token.range) {
                        steps.append(.guard_(NSRange(location: token.range.location,
                                                     length: content.location - token.range.location),
                                             .opening))
                        steps.append(.through(content))
                        steps.append(.guard_(NSRange(location: NSMaxRange(content),
                                                     length: NSMaxRange(token.range) - NSMaxRange(content)),
                                             .closing))
                    } else {
                        steps.append(.guard_(token.range, .standalone))
                    }
                }
            }

            for candidate in extra {
                guard candidate.length > 0, candidate.location >= range.location,
                      NSMaxRange(candidate) <= end else { continue }
                // 인라인 토큰과 겹치면 넘긴다 — 코드 구간 안의 `|`는 칸을 나누지 않는다.
                let overlaps = tokenRanges.contains { NSIntersectionRange($0, candidate).length > 0 }
                guard !overlaps else { continue }
                steps.append(.guard_(candidate, .standalone))
            }

            steps.sort { $0.location < $1.location }

            var cursor = range.location
            for step in steps {
                switch step {
                case let .guard_(guarded, role):
                    guard guarded.location >= cursor else { continue }
                    if guarded.location > cursor {
                        body += text.substring(with: NSRange(location: cursor,
                                                             length: guarded.location - cursor))
                    }
                    protect(guarded, role: role)
                    cursor = NSMaxRange(guarded)
                case let .through(passed):
                    guard passed.location >= cursor else { continue }
                    if passed.location > cursor {
                        body += text.substring(with: NSRange(location: cursor,
                                                             length: passed.location - cursor))
                    }
                    body += text.substring(with: passed)
                    cursor = NSMaxRange(passed)
                }
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
