import Foundation

/// 강조 구분자(`*` · `_` · `~~`)를 **CommonMark의 짝 찾기**로 푼다 — 정규식으로 맞추면 겹친 강조가 깨진다.
///
/// 왜(앱에서 처음 본 것, Notion에서 내보낸 마크다운): 정규식은 굵게와 기울임을 따로 맞춰서 겹친 꼴을 못 읽었다.
/// `***굵고 기울임***`이 `*굵고 기울임*` 둘레에 별표를 남기고 굵게만 됐고, `*바깥 **안** 바깥*`은 기울임이 아예
/// 없었다. Notion은 굵고 기울인 조각과 기울인 조각을 잇대어 `***A****: B*`처럼 내보낸다.
///
/// 짝 찾기는 CommonMark 0.31의 "process emphasis"다(구분자 줄 · 열고 닫을 수 있는가 · 셋의 규칙 · 안쪽부터). 두 가지를
/// 바꿨다:
///
/// 1. **한중일 글자 옆의 구분자.** CommonMark는 닫는 `**` 앞이 문장 부호이고 뒤가 글자면 닫지 않는다 —
///    `**"값"**은`, `**내용(괄호)**을`이 굵어지지 않는다. 한국어는 조사가 바로 붙으므로 늘 걸린다. 그래서 반대편이
///    한중일 글자면 공백이나 문장 부호처럼 본다(markdown-cjk-friendly 제안과 같은 쪽). `_`는 그대로 둔다 —
///    `snake_case`가 기울면 안 된다.
/// 2. **짝을 못 찾은 `****`.** Notion은 굵은 조각 둘을 잇대어 `**A (****`코드`**)`로 내보낸다. CommonMark에서는 셋의
///    규칙 때문에 `****`가 어느 쪽과도 짝이 안 돼 별표 넷이 그대로 보인다. 양쪽으로 열고 닫을 수 있는 `****`가
///    한 번도 쓰이지 않았으면 닫는 `**`와 여는 `**`로 나눠 한 번 더 푼다.
public enum EmphasisDelimiters {

    public struct Span: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case strong, emphasis, strikethrough }
        public let kind: Kind
        /// 여는 표시와 닫는 표시. 줄 안의 오프셋(UTF-16)이다.
        public let opener: NSRange
        public let closer: NSRange

        public var range: NSRange {
            NSRange(location: opener.location, length: NSMaxRange(closer) - opener.location)
        }

        public var content: NSRange {
            NSRange(location: NSMaxRange(opener), length: closer.location - NSMaxRange(opener))
        }
    }

    /// `line` 안의 강조.
    ///
    /// - `opaque`: 구분자를 찾지 않는 자리 — 인라인 코드, 자동 링크, 그림, 링크의 대괄호와 주소. 그 안의 `*`는 글자다.
    /// - `groups`: 따로 짝을 찾는 자리 — 링크의 글. 링크 안과 밖의 구분자는 짝이 되지 않는다(CommonMark와 같다).
    public static func spans(in line: NSString, opaque: IndexSet = IndexSet(), groups: [NSRange] = []) -> [Span] {
        let runs = delimiterRuns(in: line, opaque: opaque, groups: groups)
        guard !runs.isEmpty else { return [] }
        var result: [Span] = []
        let groupIDs = Set(runs.map(\.group)).sorted()
        for group in groupIDs {
            let own = runs.filter { $0.group == group }
            var resolved = process(own)
            // 짝을 못 찾은 `****`가 있으면 나눠서 한 번 더.
            let unusedQuadruples = resolved.unusedRuns.filter { index in
                let run = own[index]
                return run.character == star && run.originalLength == 4 && run.canOpen && run.canClose
            }
            if !unusedQuadruples.isEmpty {
                var split: [Run] = []
                for (index, run) in own.enumerated() {
                    if unusedQuadruples.contains(index) {
                        split.append(Run(character: star, start: run.start, length: 2, originalLength: 2,
                                         canOpen: false, canClose: true, group: group))
                        split.append(Run(character: star, start: run.start + 2, length: 2, originalLength: 2,
                                         canOpen: true, canClose: false, group: group))
                    } else {
                        split.append(run)
                    }
                }
                resolved = process(split)
            }
            result += resolved.spans
        }
        return result.sorted { $0.opener.location < $1.opener.location }
    }

    // MARK: 구분자 줄

    static let star: UInt16 = 0x2A        // *
    static let underscore: UInt16 = 0x5F  // _
    static let tilde: UInt16 = 0x7E       // ~

    struct Run {
        let character: UInt16
        /// 남은 구분자의 시작과 길이. 짝을 지으면 여는 쪽은 끝에서, 닫는 쪽은 앞에서 줄어든다.
        var start: Int
        var length: Int
        /// 처음 길이 — 셋의 규칙이 본다.
        let originalLength: Int
        let canOpen: Bool
        let canClose: Bool
        let group: Int
    }

    static func delimiterRuns(in line: NSString, opaque: IndexSet, groups: [NSRange]) -> [Run] {
        var runs: [Run] = []
        let length = line.length
        var index = 0
        while index < length {
            let unit = line.character(at: index)
            guard unit == star || unit == underscore || unit == tilde, !opaque.contains(index) else {
                index += 1
                continue
            }
            if isEscaped(index, in: line) {
                index += 1
                continue
            }
            var end = index + 1
            while end < length, line.character(at: end) == unit, !opaque.contains(end) { end += 1 }
            let count = end - index
            defer { index = end }
            // `~~`만 취소선이다(GFM). 하나 · 셋 이상은 글자다.
            if unit == tilde, count != 2 { continue }

            let before = scalar(before: index, in: line)
            let after = scalar(at: end, in: line)
            let left = isLeftFlanking(before: before, after: after)
            let right = isRightFlanking(before: before, after: after)
            let canOpen: Bool
            let canClose: Bool
            if unit == underscore {
                // 낱말 안의 `_`는 강조가 아니다(CommonMark). 한중일 예외도 주지 않는다.
                let strictLeft = isLeftFlanking(before: before, after: after, cjkFriendly: false)
                let strictRight = isRightFlanking(before: before, after: after, cjkFriendly: false)
                canOpen = strictLeft && (!strictRight || isPunctuation(before))
                canClose = strictRight && (!strictLeft || isPunctuation(after))
            } else {
                canOpen = left
                canClose = right
            }
            guard canOpen || canClose else { continue }
            let group = (groups.firstIndex { NSLocationInRange(index, $0) }).map { $0 + 1 } ?? 0
            runs.append(Run(character: unit, start: index, length: count, originalLength: count,
                            canOpen: canOpen, canClose: canClose, group: group))
        }
        return runs
    }

    /// 앞의 역슬래시가 홀수 개면 이 글자는 `\*`처럼 이스케이프된 글자다.
    static func isEscaped(_ index: Int, in line: NSString) -> Bool {
        var count = 0
        var cursor = index - 1
        while cursor >= 0, line.character(at: cursor) == 0x5C {
            count += 1
            cursor -= 1
        }
        return count % 2 == 1
    }

    // MARK: 짝 찾기

    struct Resolution {
        var spans: [Span] = []
        /// 한 번도 쓰이지 않은 구분자 줄(번호).
        var unusedRuns: Set<Int> = []
    }

    /// CommonMark의 "process emphasis". 닫는 구분자마다 가장 가까운 여는 구분자를 찾고, 그 사이의 구분자는 버린다.
    static func process(_ input: [Run]) -> Resolution {
        var runs = input
        var active = [Bool](repeating: true, count: runs.count)
        var used = Set<Int>()
        var resolution = Resolution()

        for closer in runs.indices {
            guard active[closer], runs[closer].canClose else { continue }
            while runs[closer].length > 0 {
                guard let opener = findOpener(for: closer, in: runs, active: active) else { break }
                let character = runs[closer].character
                let use = character == tilde ? 2 : (runs[opener].length >= 2 && runs[closer].length >= 2 ? 2 : 1)
                let openerMarker = NSRange(location: runs[opener].start + runs[opener].length - use, length: use)
                let closerMarker = NSRange(location: runs[closer].start, length: use)
                let kind: Span.Kind = character == tilde ? .strikethrough : (use == 2 ? .strong : .emphasis)
                resolution.spans.append(Span(kind: kind, opener: openerMarker, closer: closerMarker))
                used.insert(opener)
                used.insert(closer)
                // 사이의 구분자는 글자가 된다 — 짝이 엇갈리지 않게.
                for between in (opener + 1) ..< closer { active[between] = false }
                runs[opener].length -= use
                runs[closer].start += use
                runs[closer].length -= use
                if runs[opener].length == 0 { active[opener] = false }
            }
            if runs[closer].length == 0 || !runs[closer].canOpen { active[closer] = false }
        }
        resolution.unusedRuns = Set(runs.indices).subtracting(used)
        return resolution
    }

    static func findOpener(for closer: Int, in runs: [Run], active: [Bool]) -> Int? {
        let close = runs[closer]
        var index = closer - 1
        while index >= 0 {
            let open = runs[index]
            if active[index], open.length > 0, open.canOpen, open.character == close.character,
               !(close.character == tilde && open.length != close.length),
               !breaksRuleOfThree(open, close) {
                return index
            }
            index -= 1
        }
        return nil
    }

    /// 셋의 규칙 — 한쪽이 열고 닫기를 다 할 수 있으면, 두 줄의 길이 합이 3의 배수일 때 짝이 아니다(둘 다 3의
    /// 배수면 된다). `*foo**bar**baz*`가 기울임 안의 굵게로 읽히는 까닭이다.
    static func breaksRuleOfThree(_ open: Run, _ close: Run) -> Bool {
        guard open.character != tilde, open.canClose || close.canOpen else { return false }
        let sum = open.originalLength + close.originalLength
        return sum % 3 == 0 && !(open.originalLength % 3 == 0 && close.originalLength % 3 == 0)
    }

    // MARK: 글자 갈래

    /// 줄 끝은 공백으로 본다(CommonMark).
    static func scalar(before index: Int, in line: NSString) -> Unicode.Scalar? {
        guard index > 0 else { return nil }
        let unit = line.character(at: index - 1)
        if UTF16.isTrailSurrogate(unit), index >= 2 {
            let lead = line.character(at: index - 2)
            if UTF16.isLeadSurrogate(lead) {
                return Unicode.Scalar(UInt32(0x10000) + (UInt32(lead - 0xD800) << 10) + UInt32(unit - 0xDC00))
            }
        }
        return Unicode.Scalar(unit)
    }

    static func scalar(at index: Int, in line: NSString) -> Unicode.Scalar? {
        guard index < line.length else { return nil }
        let unit = line.character(at: index)
        if UTF16.isLeadSurrogate(unit), index + 1 < line.length {
            let trail = line.character(at: index + 1)
            if UTF16.isTrailSurrogate(trail) {
                return Unicode.Scalar(UInt32(0x10000) + (UInt32(unit - 0xD800) << 10) + UInt32(trail - 0xDC00))
            }
        }
        return Unicode.Scalar(unit)
    }

    static func isLeftFlanking(before: Unicode.Scalar?, after: Unicode.Scalar?, cjkFriendly: Bool = true) -> Bool {
        guard !isWhitespace(after) else { return false }
        return !isPunctuation(after) || isWhitespace(before) || isPunctuation(before)
            || (cjkFriendly && isCJK(before))
    }

    static func isRightFlanking(before: Unicode.Scalar?, after: Unicode.Scalar?, cjkFriendly: Bool = true) -> Bool {
        guard !isWhitespace(before) else { return false }
        return !isPunctuation(before) || isWhitespace(after) || isPunctuation(after)
            || (cjkFriendly && isCJK(after))
    }

    static func isWhitespace(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return true }
        switch scalar.value {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x20: return true
        default: return scalar.properties.generalCategory == .spaceSeparator
        }
    }

    /// CommonMark 0.31의 문장 부호 — 유니코드 P(문장 부호)와 S(기호) 갈래.
    static func isPunctuation(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    /// 한글 · 한자 · 가나 · 한중일 기호와 전각 꼴.
    static func isCJK(_ scalar: Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        switch value {
        case 0x1100 ... 0x11FF, 0x3130 ... 0x318F, 0xA960 ... 0xA97F, 0xAC00 ... 0xD7AF, 0xD7B0 ... 0xD7FF,  // 한글
             0x2E80 ... 0x2FDF, 0x3000 ... 0x303F, 0x3040 ... 0x30FF, 0x3100 ... 0x312F, 0x31A0 ... 0x31FF,
             0x3200 ... 0x32FF, 0x3300 ... 0x33FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF,
             0xFE30 ... 0xFE4F, 0xFF00 ... 0xFFEF, 0x20000 ... 0x3134F:
            return true
        default:
            return false
        }
    }
}
