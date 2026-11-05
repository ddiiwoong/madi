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
/// 구간만 자리표로 바꾼다.** 자리표는 번호를 감싼 짧은 표시다(`TokenForm`, 기본 `{{0}}`).
///
/// 번역기는 자리표를 **가끔 잃는다** — 꼴이 무엇이든 그렇다(실측, `TokenForm`). 그래서 번역 뒤에
/// 자리표가 온전한지 보고(`Unit.isIntact`), 아니면 다른 꼴로 다시 번역하고, 그래도 안 되면 자리표
/// 없이 글 조각마다 따로 번역한다(`Unit.runTexts`). 마지막 길은 문맥을 잃지만 **링크와 각주가
/// 깨지지 않는다** — 깨진 문장보다 어색한 문장이 낫다.
///
/// 자리표로 바꾸는 것: 인라인 코드, 자동 링크, 각주 참조, 링크·이미지의 `[`와 `](URL)` 부분,
/// 굵게·기울임·취소선의 마커.
/// 번역에서 아예 빼는 것(단위 밖의 리터럴): 펜스 코드 블록, 제목의 `#`, 인용의 `>`,
/// 목록 불릿·번호·체크박스, 수평선, 표 구분선, 표의 `|`와 칸 정렬 공백.
///
/// 불변식: **모든 조각을 이으면 원문과 글자 하나까지 같다**(`source`). 번역을 하나도 하지
/// 않아도 문서가 그대로 복원된다.
public struct MarkdownTranslationPlan: Equatable {

    /// 자리표의 꼴. 번호를 감싸는 표시가 다르다.
    ///
    /// 실측(Apple 번역, 이 Mac, macOS 27.0.1, 2026-11-05). 링크·강조·각주가 든 문장마다 자리표가
    /// **모두 정확히 한 번, 여는 것이 닫는 것보다 앞에** 돌아왔는지 셌다:
    ///
    ///     꼴            ko→en   ko→ja   en→ko
    ///     {{0}}         13/14   14/14   6/6
    ///     ⟦0⟧           13/14   14/14   6/6
    ///     §0§           13/14   14/14   6/6
    ///     U+E000 0 U+E001  11/14   14/14   6/6   ← 전에 쓰던 꼴. 감싼 문자를 버리고 숫자만 남긴다
    ///     <g0>…</g0>     9/14   10/14   3/6
    ///
    /// 전에 쓰던 사용자 영역 문자(U+E000)는 2026-10-25에는 통과했지만 지금은 **감싼 문자를 버리고
    /// 숫자만** 돌려준다 — `본문에 각주[^1]가 있고 [링크](…)도 있다.`가 `There are footnotes 0 and 1
    /// in the text and a link 2.`가 됐다. 어느 꼴도 늘 통과하지는 않고, **잃는 문장이 꼴마다 다르다**
    /// (`{{0}}`가 잃은 문장을 `⟦0⟧`가 지키고 그 반대도 있었다). 그래서 다시 번역할 때 꼴을 바꾼다.
    ///
    /// 끝 표시가 있어야 한다 — `X1` 같은 꼴은 뒤에 숫자가 오면(`X12026년`) 어디까지가 자리표인지
    /// 알 수 없다.
    public enum TokenForm: CaseIterable, Sendable {
        case braces     // {{0}}
        case brackets   // ⟦0⟧
        case section    // §0§

        /// 써 볼 순서.
        public static let preference: [TokenForm] = [.braces, .brackets, .section]

        public func token(_ index: Int) -> String {
            switch self {
            case .braces: "{{\(index)}}"
            case .brackets: "⟦\(index)⟧"
            case .section: "§\(index)§"
            }
        }

        /// 이 꼴의 표시. 단위의 글에 이것이 있으면 그 꼴은 쓰지 않는다 — 문서에 원래 있던 `{{0}}`를
        /// 자리표로 잘못 되돌리게 된다.
        var markers: [String] {
            switch self {
            case .braces: ["{{", "}}"]
            case .brackets: ["⟦", "⟧"]
            case .section: ["§"]
            }
        }

        /// 번역기가 자리표 안에 넣은 공백을 걷는다(`{{ 0 }}` → `{{0}}`).
        func normalized(_ text: String) -> String {
            guard let pattern = loosePattern else { return text }
            let range = NSRange(location: 0, length: (text as NSString).length)
            return pattern.stringByReplacingMatches(in: text, options: [], range: range,
                                                    withTemplate: token(0).replacingOccurrences(of: "0", with: "$1"))
        }

        private var loosePattern: NSRegularExpression? {
            let source: String = switch self {
            case .braces: #"\{\{\s*(\d+)\s*\}\}"#
            case .brackets: #"⟦\s*(\d+)\s*⟧"#
            case .section: #"§\s*(\d+)\s*§"#
            }
            return try? NSRegularExpression(pattern: source)
        }

        /// 어느 꼴이든 자리표 하나에 맞는 정규식. 조각기가 이 안에서 자르지 않는다.
        static let anyToken: NSRegularExpression = {
            guard let expression = try? NSRegularExpression(pattern: #"\{\{\d+\}\}|⟦\d+⟧|§\d+§"#) else {
                preconditionFailure("invalid built-in pattern")
            }
            return expression
        }()
    }

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
        /// 표의 칸 구분자 `|`인가. 이것이 옮겨지면 칸 수가 바뀐다(`Unit.keepsStructure`).
        public let isCellSeparator: Bool

        public init(text: String, role: Role, hadAdjacentSpace: Bool, isCellSeparator: Bool = false) {
            self.text = text
            self.role = role
            self.hadAdjacentSpace = hadAdjacentSpace
            self.isCellSeparator = isCellSeparator
        }
    }

    /// 번역기에 넘기는 단위 하나. 보통 한 줄의 본문 또는 표의 한 행이다.
    public struct Unit: Equatable {
        /// 단위를 이루는 조각 — 글, 또는 보호 구간 번호.
        public enum Piece: Equatable {
            case text(String)
            case token(Int)
        }

        public let pieces: [Piece]
        /// 자리표 번호 순서대로의 보호 구간.
        public let protected: [ProtectedSpan]
        /// 표의 행일 때만: 같은 행을 **칸마다** 나눈 계획. 행 번역이 칸 구조를 지키지
        /// 못했을 때(`keepsStructure`가 거짓) 그 행만 이것으로 다시 번역한다.
        public let cellFallback: MarkdownTranslationPlan?
        /// 처음 쓸 자리표 꼴 — 이 단위의 글과 부딪히지 않는 첫 꼴.
        public let form: TokenForm

        public init(pieces: [Piece], protected: [ProtectedSpan],
                    cellFallback: MarkdownTranslationPlan? = nil) {
            self.pieces = pieces
            self.protected = protected
            self.cellFallback = cellFallback
            let usable = Self.usableForms(pieces)
            self.form = usable.first ?? .braces
        }

        /// 글에 표시가 나오지 않는 꼴들(선호 순).
        private static func usableForms(_ pieces: [Piece]) -> [TokenForm] {
            let text = pieces.map { if case let .text(value) = $0 { value } else { "" } }.joined()
            return TokenForm.preference.filter { form in !form.markers.contains { text.contains($0) } }
        }

        /// 다시 번역할 때 써 볼 다른 꼴들.
        public var alternateForms: [TokenForm] {
            Self.usableForms(pieces).filter { $0 != form }
        }

        /// 번역기에 넘기는 글. 보호 구간은 자리표로 바뀌어 있다.
        public var text: String { text(in: form) }

        public func text(in form: TokenForm) -> String {
            pieces.map { piece in
                switch piece {
                case let .text(value): value
                case let .token(index): form.token(index)
                }
            }.joined()
        }

        /// 여는 구간 → 그것을 닫는 구간(번호). 인라인 토큰은 서로 겹치지 않으므로(`scanInline`이
        /// 차지한 자리를 다시 내주지 않는다) 짝은 스택으로 찾으면 된다.
        var pairs: [(open: Int, close: Int)] {
            var stack: [Int] = []
            var out: [(Int, Int)] = []
            for (index, span) in protected.enumerated() {
                switch span.role {
                case .opening: stack.append(index)
                case .closing: if let open = stack.popLast() { out.append((open, index)) }
                case .standalone: break
                }
            }
            return out
        }

        /// 번역문의 자리표가 온전한가 — 자리표마다 **정확히 한 번** 나오고, 여는 것이 닫는 것보다
        /// 앞이다. 거짓이면 그대로 되돌리면 링크·강조·각주가 깨진다(잃은 구간은 단위 끝에 붙는다).
        public func isIntact(_ translated: String, form: TokenForm? = nil) -> Bool {
            guard !protected.isEmpty else { return true }
            let form = form ?? self.form
            let text = form.normalized(translated)
            var positions: [String.Index] = []
            for index in protected.indices {
                let token = form.token(index)
                guard let found = text.range(of: token),
                      text.range(of: token, range: found.upperBound ..< text.endIndex) == nil
                else { return false }
                positions.append(found.lowerBound)
            }
            for pair in pairs {
                guard positions[pair.open] < positions[pair.close] else { return false }
                // 감싼 글이 있었으면 번역문에도 있어야 한다. 번역기가 글을 밖으로 빼고 표시만 남기면
                // `with ****`가 된다(실측).
                guard hasContent(between: pair) else { continue }
                let from = text.range(of: form.token(pair.open))!.upperBound
                let to = text.range(of: form.token(pair.close))!.lowerBound
                var inner = String(text[from ..< to])
                for index in protected.indices { inner = inner.replacingOccurrences(of: form.token(index), with: "") }
                if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            }
            return true
        }

        /// 원문에서 이 짝이 감싼 글에 글자가 있는가.
        private func hasContent(between pair: (open: Int, close: Int)) -> Bool {
            var inside = false
            for piece in pieces {
                switch piece {
                case let .token(index):
                    if index == pair.open { inside = true } else if index == pair.close { return false }
                case let .text(value):
                    if inside, Self.isTranslatable(value) { return true }
                }
            }
            return false
        }

        /// 번역문이 표의 칸 구조를 지키는가. 칸 구분자가 없는 단위는 늘 참이다.
        ///
        /// 왜 있는가(실측): 행을 통째로 넘기면 문맥이 살아 번역이 나아지지만, 번역기가
        /// 자리표를 **옮기거나 복제한다.** 저장소 문서 다섯을 번역했더니 표 두 개의 열
        /// 수가 바뀌었다 — 닫는 `**`가 마지막 `|` 뒤로 가 칸이 하나 늘었고, 다른 행에서는
        /// 구분자 하나가 두 번 나와 `|`가 다섯 개가 됐다.
        ///
        /// 검사하는 것: 자리표가 **각각 정확히 한 번** 나온다, 구분자가 **순서대로** 나온다,
        /// 인라인 자리표가 원문과 **같은 칸**에 있다, 원문에서 구분자 앞뒤에 글이 없었으면
        /// 번역문에도 없다(있으면 칸이 생긴다).
        public func keepsStructure(_ translated: String) -> Bool {
            let separators = protected.indices.filter { protected[$0].isCellSeparator }
            guard !separators.isEmpty else { return true }
            let source = text
            let translated = form.normalized(translated)

            var positions: [String.Index] = []
            for index in protected.indices {
                let token = form.token(index)
                guard let found = translated.range(of: token),
                      translated.range(of: token, range: found.upperBound..<translated.endIndex) == nil
                else { return false }
                positions.append(found.lowerBound)
            }

            let separatorPositions = separators.map { positions[$0] }
            for (a, b) in zip(separatorPositions, separatorPositions.dropFirst()) where a >= b {
                return false
            }
            for index in protected.indices where !protected[index].isCellSeparator {
                let sourceCell = separators.filter { $0 < index }.count
                let translatedCell = separatorPositions.filter { $0 < positions[index] }.count
                guard sourceCell == translatedCell else { return false }
            }

            func isBlank(_ text: Substring) -> Bool {
                text.allSatisfy { $0 == " " || $0 == "\t" }
            }
            let firstToken = form.token(separators[0])
            let lastToken = form.token(separators[separators.count - 1])
            if let sourceFirst = source.range(of: firstToken), isBlank(source[..<sourceFirst.lowerBound]),
               let translatedFirst = translated.range(of: firstToken),
               !isBlank(translated[..<translatedFirst.lowerBound]) {
                return false
            }
            if let sourceLast = source.range(of: lastToken), isBlank(source[sourceLast.upperBound...]),
               let translatedLast = translated.range(of: lastToken),
               !isBlank(translated[translatedLast.upperBound...]) {
                return false
            }
            return true
        }

        /// 번역문의 자리표를 원문 조각으로 되돌린다.
        ///
        /// 번역기가 자리표를 잃었으면 그 조각은 되살릴 자리가 없다 — 끝에 붙인다.
        /// 잃는 쪽이 지우는 쪽보다 낫다(코드나 링크가 조용히 사라지지 않는다). 번역기에서 온 글은
        /// `isIntact`로 먼저 걸러 이 길에 거의 오지 않는다(`AppleTranslator.repairs`).
        public func restored(from translated: String, form: TokenForm? = nil) -> String {
            let form = form ?? self.form
            var out = form.normalized(translated)
            var missing: [String] = []

            for (index, span) in protected.enumerated() {
                let token = form.token(index)
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

        // MARK: 마지막 길 — 글 조각마다 따로

        /// 자리표 없이 따로 번역할 글 조각들(글자가 있는 것만, 앞뒤 공백을 뗀 것). 꼴을 바꿔도
        /// 자리표가 온전하지 않을 때 쓴다 — 문맥을 잃지만 보호 구간은 번역기를 거치지 않으므로
        /// **깨질 수가 없다.**
        public var runTexts: [String] {
            pieces.compactMap { piece in
                guard case let .text(value) = piece else { return nil }
                let core = Self.core(of: value)
                return Self.isTranslatable(core) ? core : nil
            }
        }

        /// `runTexts`를 번역한 것으로 단위를 다시 짓는다. 원문의 공백은 그대로 둔다.
        ///
        /// - Parameter wordSpacing: 대상 언어가 낱말 사이를 띄우는가. 한국어는 조사가 붙어
        ///   `**굵게**와`처럼 공백이 없지만, 따로 번역한 `and`는 `**bold** and`로 띄워야 한다 —
        ///   닫는 구간 뒤, 여는 구간 앞에서 글자끼리 붙으면 띄운다. 일본어·중국어는 띄우지 않는다.
        public func reassembled(runs translations: [String], wordSpacing: Bool) -> String {
            var out = ""
            var next = translations.makeIterator()
            /// 바로 앞에 놓은 것이 닫는(또는 독립) 구간인가.
            var afterClosing = false
            for piece in pieces {
                switch piece {
                case let .token(index):
                    let span = protected[index]
                    if wordSpacing, span.role == .opening, !span.hadAdjacentSpace,
                       let last = out.last, last.isLetter || last.isNumber {
                        out += " "
                    }
                    out += span.text
                    afterClosing = span.role != .opening
                case let .text(value):
                    let core = Self.core(of: value)
                    let leading = String(value.prefix { $0 == " " || $0 == "\t" })
                    let trailing = String(value.dropFirst(leading.count).reversed()
                        .prefix { $0 == " " || $0 == "\t" }.reversed())
                    var body = core
                    if Self.isTranslatable(core) {
                        body = (next.next() ?? core).trimmingCharacters(in: .whitespaces)
                    }
                    if wordSpacing, afterClosing, leading.isEmpty,
                       let first = body.first, first.isLetter || first.isNumber {
                        out += " "
                    }
                    out += leading + body + trailing
                    afterClosing = false
                }
            }
            return out
        }

        private static func core(of value: String) -> String {
            value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }

        /// 글자가 하나라도 있는가. 문장부호·공백·숫자뿐인 조각은 번역기에 넘기지 않는다.
        static func isTranslatable(_ text: String) -> Bool {
            text.contains { $0.isLetter }
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
        let lines = syntax.scanLines(in: ns)
        // 정의를 알아야 참조 링크(`[글][참조]`)와 각주 참조(`[^1]`)를 인라인 토큰으로 받는다.
        // 모르면 둘 다 평범한 글로 번역기에 넘어가 라벨이 번역되고, 정의 줄은 번역하지 않으므로
        // (아래 `.linkDefinition`) 참조가 끊어진다.
        builder.definitions = LinkDefinitions(scanning: ns, lines: lines)
        // `$$` 수식 블록의 줄은 줄 판정으로는 **문단**이다(펜스가 아니므로). 그대로 두면
        // 번역기가 `\int_0^1`을 글로 받아 옮기고, `_`·`*`를 기울임 표시로 보호하면서 수식을
        // 망가뜨린다. 펜스 수식(```` ```math ````)은 코드 줄이라 이미 건너뛴다 — 같은 수식이
        // 쓰는 꼴에 따라 번역되고 안 되면 안 된다. 블록을 찾는 규칙은 그리기와 같은 것을 쓴다.
        let mathLines = Set(RenderedBlock.blocks(in: ns, lines: lines)
            .filter { $0.delimiter == .dollars }
            .flatMap { $0.firstLine ... $0.lastLine })
        for line in lines {
            if line.range.location > cursor {
                builder.literal(NSRange(location: cursor, length: line.range.location - cursor))
            }
            if mathLines.contains(line.lineNumber) {
                if line.range.length > 0 { builder.literal(line.range) }
            } else {
                append(line: line, to: &builder, text: ns, syntax: syntax)
            }
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

        case .heading, .quote, .listItem, .paragraph, .footnoteDefinition:
            // 각주 정의는 머리(`[^1]: `)가 앞머리로 남고 각주 글만 번역된다 — 목록 표지와 같다.
            // 내용 앞뒤의 공백은 번역기에 넘기지 않는다(실측). 목록 항목의 이어지는 줄
            // `   링크는 파란 밑줄.`은 문단 줄이라 내용이 줄 전체인데, 앞 공백까지 넘기면
            // 번역기가 버리고 그 줄이 **목록 밖으로 떨어진다** — 저장소 문서 다섯 중 셋이
            // 그렇게 블록 구조가 바뀌었다. 뒤 공백 둘(하드 줄바꿈)도 같은 이유로 지킨다.
            let content = trimmingSpaces(line.contentRange, in: text)
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

    /// 범위 앞뒤의 공백·탭을 깎는다. 다 깎이면 길이 0인 범위를 돌려준다.
    static func trimmingSpaces(_ range: NSRange, in text: NSString) -> NSRange {
        guard range.location != NSNotFound, range.length > 0 else { return range }
        func isBlank(_ index: Int) -> Bool {
            let c = text.character(at: index)
            return c == 32 || c == 9
        }
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isBlank(start) { start += 1 }
        while end > start, isBlank(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// 표의 한 행. **행 전체를 한 단위로** 넘기고 `|`만 자리표로 지킨다.
    ///
    /// 왜 바꿨는가(실측): 전에는 칸마다 독립된 단위였다. 번역기에 `검색` 한 낱말만
    /// 넘어가니 문맥이 없어 `reference`가 나오고, `항목`은 `a head`가 됐다. 사람도
    /// 낱말 하나만 보면 그렇게 읽는다 — 정보가 없는 것이 문제였다.
    ///
    /// 행을 통째로 넘기면 같은 행의 다른 칸이 문맥이 된다. 칸 경계는 `|`를 자리표로
    /// 바꿔 지키지만, **번역기가 자리표를 옮기면 칸 수가 바뀐다**(실측, `Unit.keepsStructure`).
    /// 그래서 칸마다 나눈 옛 방식의 계획을 함께 들고 있다가, 행 번역이 구조를 지키지
    /// 못한 행만 그것으로 다시 번역한다. 문맥은 잃어도 표는 깨지지 않는다.
    private static func appendTableRow(_ range: NSRange, to builder: inout Builder,
                                       text: NSString, syntax: MarkdownSyntax) {
        let row = LineToken(lineNumber: 0, range: range, kind: .tableRow,
                            markerRanges: [], contentRange: range)
        // `MarkdownTable`이 이미 `\|`와 인라인 코드 안의 막대를 가려 준다.
        let parsed = MarkdownTable.parseRow(row, in: text)

        var cells = Builder(text: text)
        var cursor = range.location
        for cell in parsed.cells where cell.length > 0 {
            if cell.location > cursor {
                cells.literal(NSRange(location: cursor, length: cell.location - cursor))
            }
            cells.unit(cell, syntax: syntax)
            cursor = NSMaxRange(cell)
        }
        if cursor < NSMaxRange(range) {
            cells.literal(NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        }
        let fallback = MarkdownTranslationPlan(segments: cells.finish())

        builder.unit(range, syntax: syntax, protecting: parsed.separators,
                     cellFallback: fallback)
    }

    // MARK: Assemble

    public enum AssemblyError: Error, Equatable {
        case countMismatch(expected: Int, got: Int)
    }

    public func assembled(with translations: [String]) throws -> String {
        try assembled(with: translations, replacing: [:])
    }

    /// - Parameter replacing: 단위 번호 → **이미 복원된** 글. 칸 구조를 지키지 못한
    ///   표 행을 칸 단위로 다시 번역한 결과가 여기로 온다(`Unit.cellFallback`).
    public func assembled(with translations: [String], replacing: [Int: String]) throws -> String {
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
                out += replacing[index] ?? unit.restored(from: translations[index])
                index += 1
            }
        }
        return out
    }

    // MARK: Builder

    private struct Builder {
        let text: NSString
        var definitions = LinkDefinitions.empty
        private var segments: [Segment] = []

        init(text: NSString) { self.text = text }

        mutating func literal(_ range: NSRange) { addLiteral(text.substring(with: range)) }

        /// 한 줄의 본문(또는 표의 한 행)을 단위 하나로 만든다. 보호 구간은 자리표가 된다.
        ///
        /// - Parameter protecting: 인라인 마크업 **말고도** 지켜야 하는 구간. 표의 `|`가
        ///   여기로 온다 — 행을 한 단위로 넘기면서 칸 경계는 지켜야 하기 때문이다.
        mutating func unit(_ range: NSRange, syntax: MarkdownSyntax,
                           protecting extra: [NSRange] = [],
                           cellFallback: MarkdownTranslationPlan? = nil) {
            guard range.length > 0 else { return }
            var pieces: [Unit.Piece] = []
            var protected: [ProtectedSpan] = []

            func appendText(_ value: String) {
                guard !value.isEmpty else { return }
                if case let .text(previous) = pieces.last {
                    pieces[pieces.count - 1] = .text(previous + value)
                } else {
                    pieces.append(.text(value))
                }
            }

            /// 원문에서 `index` 위치의 글자가 공백인가. 줄 밖이면 true로 본다 —
            /// 경계에는 지울 공백이 없다.
            func isSpace(at index: Int) -> Bool {
                guard index >= 0, index < text.length else { return true }
                let scalar = text.character(at: index)
                return scalar == 32 || scalar == 9 || scalar == 10 || scalar == 13
            }

            func protect(_ protectedRange: NSRange, role: ProtectedSpan.Role, separator: Bool) {
                guard protectedRange.length > 0 else { return }
                pieces.append(.token(protected.count))
                // 지울 쪽의 공백만 본다 — 여는 구간은 뒤, 닫는 구간은 앞.
                let adjacent: Bool = switch role {
                case .opening: isSpace(at: NSMaxRange(protectedRange))
                case .closing: isSpace(at: protectedRange.location - 1)
                case .standalone: true
                }
                protected.append(ProtectedSpan(
                    text: text.substring(with: protectedRange),
                    role: role,
                    hadAdjacentSpace: adjacent,
                    isCellSeparator: separator
                ))
            }

            // 지킬 자리를 한 목록으로 모아 **위치 순으로** 적용한다. 인라인 토큰과
            // 바깥에서 들어온 구간(표의 `|`)을 따로 돌면 순서가 섞여 자리표 번호와
            // 실제 위치가 어긋난다.
            /// 지킬 구간 하나. 구간 사이의 글(강조의 내용 등)은 그대로 번역기에 넘어간다.
            struct Step {
                let range: NSRange
                let role: ProtectedSpan.Role
                var separator = false
                var location: Int { range.location }
            }

            var steps: [Step] = []
            let end = NSMaxRange(range)
            var tokenRanges: [NSRange] = []

            for token in syntax.scanInline(in: text, range: range, definitions: definitions) {
                guard token.range.location >= range.location,
                      NSMaxRange(token.range) <= end else { continue }
                tokenRanges.append(token.range)
                switch token.kind {
                case .code, .autolink, .footnoteReference:
                    steps.append(Step(range: token.range, role: .standalone))
                case .link, .image, .strong, .emphasis, .strikethrough:
                    let content = token.contentRange
                    if content.location != NSNotFound, content.length > 0,
                       content.location >= token.range.location,
                       NSMaxRange(content) <= NSMaxRange(token.range) {
                        // 내용은 따로 넣지 않는다 — 구간 사이의 글은 그대로 이어 붙는다. 그래야 내용 안의
                        // 인라인 코드(`**문서 `x` 하나**`)도 제 자리에서 지켜진다.
                        steps.append(Step(range: NSRange(location: token.range.location,
                                                         length: content.location - token.range.location),
                                          role: .opening))
                        steps.append(Step(range: NSRange(location: NSMaxRange(content),
                                                         length: NSMaxRange(token.range) - NSMaxRange(content)),
                                          role: .closing))
                    } else {
                        steps.append(Step(range: token.range, role: .standalone))
                    }
                }
            }

            for candidate in extra {
                guard candidate.length > 0, candidate.location >= range.location,
                      NSMaxRange(candidate) <= end else { continue }
                // 인라인 토큰과 겹치면 넘긴다 — 코드 구간 안의 `|`는 칸을 나누지 않는다.
                let overlaps = tokenRanges.contains { NSIntersectionRange($0, candidate).length > 0 }
                guard !overlaps else { continue }
                steps.append(Step(range: candidate, role: .standalone, separator: true))
            }

            steps.sort { $0.location < $1.location }

            var cursor = range.location
            for step in steps {
                guard step.location >= cursor else { continue }
                if step.location > cursor {
                    appendText(text.substring(with: NSRange(location: cursor, length: step.location - cursor)))
                }
                protect(step.range, role: step.role, separator: step.separator)
                cursor = NSMaxRange(step.range)
            }
            if cursor < end {
                appendText(text.substring(with: NSRange(location: cursor, length: end - cursor)))
            }

            // 번역할 글자가 하나도 없으면(보호 구간·공백·숫자·문장부호뿐) 번역기를 부르지 않는다.
            let bare = pieces.map { if case let .text(value) = $0 { value } else { "" } }.joined()
            guard Unit.isTranslatable(bare) else {
                addLiteral(text.substring(with: range))
                return
            }
            segments.append(.unit(Unit(pieces: pieces, protected: protected, cellFallback: cellFallback)))
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
