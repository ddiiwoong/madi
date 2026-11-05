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
    /// 링크 정의 줄(`[참조]: https://example.com "제목"`). 렌더러는 이 줄을 통째로
    /// 삼켜 아무것도 그리지 않지만, 편집기는 **보여야 한다** — 숨기면 빈 줄이 남고
    /// 사용자가 친 글자가 어디로 갔는지 알 수 없다(펜스의 언어 이름에서 겪은 일이다).
    case linkDefinition
    /// 각주 정의 줄(`[^1]: 각주 글`). 라벨의 괄호와 콜론은 마커이고 라벨과 글은 보인다.
    /// 링크 정의보다 먼저 판정한다 — `[^1]: https://…`는 링크 정의 꼴이기도 하지만 GFM에서는
    /// 각주다.
    case footnoteDefinition
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
    /// 각주 참조 `[^라벨]`. 정의가 있을 때만 나온다(GFM) — 없으면 평범한 대괄호 글이다.
    case footnoteReference(label: String)
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
        scan(text).lines
    }

    /// 줄을 읽기 **전의** 펜스 상태. 한 줄의 판정은 그 줄의 글과 이 상태만으로 정해진다.
    public struct FenceState: Equatable, Sendable {
        public var inFence = false
        public var language: String?
    }

    /// 한 번 훑은 결과. 다음 편집에서 **고친 자리부터** 다시 훑는 데 쓴다(`rescan`).
    public struct LineScan: Sendable {
        /// setext 제목까지 판정한 줄들 — 바깥이 쓰는 것.
        public let lines: [LineToken]
        /// setext를 적용하기 전의 줄들. setext는 **위쪽** 문단을 바꾸므로, 다시 훑을 때는 적용
        /// 전의 판정이 있어야 한다.
        let raw: [LineToken]
        /// `states[i]`는 `raw[i]`를 읽기 전의 상태다.
        let states: [FenceState]
        /// 훑은 글의 길이(UTF-16).
        let length: Int
    }

    /// 문서 전체를 훑는다.
    public func scan(_ text: NSString) -> LineScan {
        var raw: [LineToken] = []
        var states: [FenceState] = []
        _ = scanRaw(text, from: 0, state: FenceState(), into: &raw, states: &states, resync: nil)
        return LineScan(lines: Self.applySetextHeadings(raw, in: text), raw: raw, states: states,
                        length: text.length)
    }

    /// 한 번의 편집 뒤에 **고친 자리부터** 다시 훑는다. 결과는 `scan(text)`와 같다.
    ///
    /// 왜(실측, 22만 자 문서): 전체를 훑는 데 12~16ms가 들고 글자 하나를 칠 때마다 돌았다.
    /// 한 줄의 판정은 그 줄의 글과 그 앞의 펜스 상태만으로 정해지므로, 고친 줄의 한 줄 위부터
    /// 다시 훑다가 **고친 구간을 지난 줄의 시작이 옛 판정의 어느 줄 시작과 같고 상태도 같으면**
    /// 거기서 멈추고 나머지는 위치만 민다. 한 줄 위부터인 이유: `\r` 뒤에 `\n`을 넣으면 두
    /// 줄바꿈이 하나로 합쳐져 앞 줄의 끝이 바뀐다.
    ///
    /// setext 제목은 다시 훑은 뒤 **전체에** 다시 적용한다 — 밑줄 하나가 위쪽 문단 전체를
    /// 제목으로 바꾸므로 고친 자리의 위로도 번진다. 문지기 덕에 싸다.
    ///
    /// - Parameters:
    ///   - editedRange: 편집 **뒤** 글에서 바뀐 범위(`NSTextStorage`의 `editedRange`).
    ///   - delta: 길이 변화(`changeInLength`).
    /// - Returns: 앞뒤가 맞지 않으면(길이가 다름, 범위가 글 밖) nil — 부르는 쪽이 `scan`으로
    ///   전체를 훑는다. 여기서 몰래 전체를 훑지 않는 이유: 그러면 결과는 맞아도 **편집기가 늘
    ///   전체를 훑는 결함**이 보이지 않는다(배선이 틀린 값을 넘겨도 테스트가 통과한다).
    public func rescan(_ text: NSString, after previous: LineScan,
                       editedRange: NSRange, changeInLength delta: Int) -> LineScan? {
        let length = text.length
        guard length == previous.length + delta,
              editedRange.location >= 0, NSMaxRange(editedRange) <= length,
              editedRange.length - delta >= 0,
              !previous.raw.isEmpty else { return nil }

        let editStart = editedRange.location
        let newEditEnd = NSMaxRange(editedRange)
        // 고친 자리가 든 옛 줄, 그 한 줄 위부터.
        let edited = Self.lastIndex(in: previous.raw, startingAtOrBefore: editStart)
        let start = max(0, edited - 1)

        var raw = Array(previous.raw[..<start])
        var states = Array(previous.states[..<start])
        let from = previous.raw[start].range.location

        var resumeAt: Int?
        let stopped = scanRaw(text, from: from, state: previous.states[start],
                              into: &raw, states: &states) { lineStart, state in
            // 고친 구간을 **넘어선** 줄의 시작만 맞춰 본다. 같은 자리이면 그 줄의 판정이 앞
            // 글자(문서 끝의 빈 줄은 마지막 글자가 `\n`인지)에 기댈 수 있다.
            guard lineStart > newEditEnd else { return false }
            let old = lineStart - delta
            let index = Self.lastIndex(in: previous.raw, startingAtOrBefore: old)
            guard previous.raw[index].range.location == old,
                  previous.states[index] == state else { return false }
            resumeAt = index
            return true
        }
        if stopped, let resume = resumeAt {
            let offset = raw.count - resume
            for index in resume ..< previous.raw.count {
                raw.append(Self.shifted(previous.raw[index], by: delta, lineNumber: index + offset + 1))
            }
            states.append(contentsOf: previous.states[resume...])
        }
        return LineScan(lines: Self.applySetextHeadings(raw, in: text), raw: raw, states: states,
                        length: length)
    }

    /// 시작이 `location` 이하인 마지막 줄의 번호(배열 안 위치). 줄이 비어 있지 않아야 한다.
    static func lastIndex(in tokens: [LineToken], startingAtOrBefore location: Int) -> Int {
        var lo = 0, hi = tokens.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tokens[mid].range.location <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// 위치를 민 줄. 판정은 글과 상태만으로 정해지므로 위치만 다르다.
    static func shifted(_ token: LineToken, by delta: Int, lineNumber: Int) -> LineToken {
        func move(_ range: NSRange) -> NSRange { NSRange(location: range.location + delta, length: range.length) }
        return LineToken(lineNumber: lineNumber, range: move(token.range), kind: token.kind,
                         markerRanges: delta == 0 ? token.markerRanges : token.markerRanges.map(move),
                         contentRange: move(token.contentRange), language: token.language)
    }

    /// `from`(줄의 시작)부터 줄을 판정해 덧붙인다. `resync`가 줄의 시작과 그 앞 상태를 보고
    /// true를 돌려주면 그 줄을 읽지 않고 멈추고 true를 돌려준다. 끝까지 읽으면 false.
    private func scanRaw(_ text: NSString, from start: Int, state initial: FenceState,
                         into tokens: inout [LineToken], states: inout [FenceState],
                         resync: ((Int, FenceState) -> Bool)?) -> Bool {
        var inFence = initial.inFence
        var fenceLanguage = initial.language
        var lineNumber = tokens.count
        var cursor = start
        let length = text.length

        while cursor <= length {
            let state = FenceState(inFence: inFence, language: fenceLanguage)
            if cursor > start, let resync, resync(cursor, state) { return true }
            let lineRange = text.lineRange(for: NSRange(location: min(cursor, length), length: 0))
            // `lineRange` includes the terminator; style only the content.
            let contentOnly = text.rangeOfLine(excludingTerminatorIn: lineRange)
            lineNumber += 1

            let token: LineToken
            if let fast = Self.fastToken(in: text, range: contentOnly, lineNumber: lineNumber,
                                         inFence: inFence, fenceLanguage: fenceLanguage) {
                token = fast
            } else {
                let line = text.substring(with: contentOnly)
                token = scanLine(line, at: contentOnly, lineNumber: lineNumber,
                                 inFence: &inFence, fenceLanguage: &fenceLanguage)
            }
            tokens.append(token)
            states.append(state)

            if NSMaxRange(lineRange) <= cursor { break }
            cursor = NSMaxRange(lineRange)
            if cursor == length {
                // A trailing newline means one more (empty) line exists.
                if length > 0, text.character(at: length - 1) == 10 {
                    let trailing = FenceState(inFence: inFence, language: fenceLanguage)
                    if let resync, resync(length, trailing) { return true }
                    lineNumber += 1
                    let empty = NSRange(location: length, length: 0)
                    tokens.append(LineToken(lineNumber: lineNumber, range: empty, kind: .blank,
                                            markerRanges: [], contentRange: empty))
                    states.append(trailing)
                }
                break
            }
        }
        return false
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
                  mayBeSetextUnderline(text, token.range),
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

    /// 밑줄일 **수 있는** 줄인가. 첫 글자가 `=`나 `-`가 아니면 `setextLevel`이 nil을 낼 것이
    /// 확실하므로 문자열을 만들지 않고 건너뛴다. 확실하지 않으면 true(정식 판정에 넘긴다).
    ///
    /// 왜(실측, 22만 자 문서): 거의 모든 줄이 문단이라 이 판정이 줄마다 돌았고, 줄을 Swift
    /// 문자열로 만들어 다듬는 데 줄 스캔 시간의 40%가 들었다.
    static func mayBeSetextUnderline(_ text: NSString, _ range: NSRange) -> Bool {
        switch lead(in: text, range: range) {
        case let .unit(unit): return unit == 0x3D || unit == 0x2D   // = -
        case .blank: return false       // 공백뿐인 줄은 다듬으면 비어 nil이다
        case .unknown: return true
        }
    }

    // MARK: 빠른 길

    /// 줄의 첫 글자 — 앞의 공백을 건너뛰고.
    enum LineLead: Equatable {
        /// 비었거나 스페이스·탭뿐이다.
        case blank
        /// 공백이 아닌 첫 UTF-16 단위.
        case unit(UInt16)
        /// 빠른 판정을 할 수 없다(서로게이트, 스페이스·탭 아닌 공백뿐인 줄). 정식 길로 간다.
        case unknown
    }

    /// 건너뛰는 공백은 정규식의 `\s`(ICU: `[\t\n\f\r\p{Z}]`)를 **모두 포함하는** 집합이다.
    /// 빠른 길은 "이 첫 글자로는 이 패턴이 맞을 수 없다"를 말할 때만 쓰이므로, `\s`보다
    /// 적게 건너뛰면 맞을 줄을 놓치고 더 많이 건너뛰면 정식 판정에 넘길 뿐이다.
    static func lead(in text: NSString, range: NSRange) -> LineLead {
        var onlySpaceOrTab = true
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let unit = text.character(at: index)
            index += 1
            if unit == 0x20 || unit == 0x09 { continue }
            if unit < 0x80 {
                if unit >= 0x0A, unit <= 0x0D { onlySpaceOrTab = false; continue }
                return .unit(unit)
            }
            if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) { return .unknown }
            if let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                onlySpaceOrTab = false
                continue
            }
            return .unit(unit)
        }
        return onlySpaceOrTab ? .blank : .unknown
    }

    /// 줄 패턴 가운데 하나라도 이 글자로 시작할 수 있는가.
    ///
    /// 각 패턴이 앞 공백 뒤에 요구하는 첫 글자: 펜스 `` ` `` `~`, 수평선 `*` `-` `_`,
    /// 제목 `#`, 인용 `>`, 목록 `-` `+` `*` 숫자(`\d`는 유니코드 숫자 전부), 링크 정의 `[`,
    /// 표 구분줄 `|` `:` `-`.
    static func patternsMayMatch(lead unit: UInt16) -> Bool {
        switch unit {
        case 0x60, 0x7E, 0x2A, 0x2D, 0x5F, 0x23, 0x3E, 0x2B, 0x5B, 0x7C, 0x3A, 0x30 ... 0x39:
            return true
        default:
            guard unit >= 0x80, let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.decimalDigits.contains(scalar)
        }
    }

    /// 정규식이 하나도 맞을 수 없는 줄은 **문자열을 만들지 않고** 판정한다. 확실하지 않으면
    /// nil — 그때는 `scanLine`이 판정한다. 결과는 `scanLine`과 같아야 한다(그 판정 순서를
    /// 그대로 따른다: 펜스 → 코드 본문 → 빈 줄 → … → 표 행 → 문단).
    ///
    /// 왜(실측, 22만 자 문서): 줄 스캔이 26ms였고 타이핑마다 몇 번씩 돌았다. 대부분의 줄은
    /// 한글로 시작하는 문단인데, 줄마다 Swift 문자열을 만들고 정규식을 일곱 개까지 돌렸다.
    static func fastToken(in text: NSString, range: NSRange, lineNumber: Int,
                          inFence: Bool, fenceLanguage: String?) -> LineToken? {
        switch lead(in: text, range: range) {
        case .unknown:
            return nil
        case .blank:
            // 공백뿐인 줄에는 펜스가 맞을 수 없다. 펜스 안이면 코드 본문, 밖이면 빈 줄.
            return LineToken(lineNumber: lineNumber, range: range,
                             kind: inFence ? .codeBody : .blank,
                             markerRanges: [], contentRange: range,
                             language: inFence ? fenceLanguage : nil)
        case let .unit(unit):
            if inFence {
                if unit == 0x60 || unit == 0x7E { return nil }      // 닫는 펜스일 수 있다
                return LineToken(lineNumber: lineNumber, range: range, kind: .codeBody,
                                 markerRanges: [], contentRange: range, language: fenceLanguage)
            }
            if patternsMayMatch(lead: unit) { return nil }
            // 남은 갈림길은 표 행(`|`가 있다)과 문단이다. `|`가 있으면 정식 판정에 넘긴다.
            if text.range(of: "|", options: .literal, range: range).location != NSNotFound {
                return nil
            }
            return LineToken(lineNumber: lineNumber, range: range, kind: .paragraph,
                             markerRanges: [], contentRange: range)
        }
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

    /// 링크 정의 줄을 가른다 — `[참조]: https://example.com "제목"`.
    ///
    /// **정규식이 한 곳에만 있어야 한다.** 세 곳이 이것을 쓴다: 줄 스캐너가 종류를
    /// 정하고, `LinkDefinitions`가 표를 모으고, 스타일러가 주소에 색을 준다. 각자
    /// 따로 쓰면 세 곳의 판정이 조용히 갈린다.
    ///
    /// 범위는 **그 줄 안의** 오프셋이다(문서 전체가 아니다) — 부르는 쪽이 줄의 시작을
    /// 더한다.
    /// 각주 정의 줄의 라벨(`[^1]: …`의 `1`)과 그 범위. 줄 판정이 남긴 두 마커 사이다 —
    /// 정규식을 다시 돌리지 않는다.
    public static func footnoteLabelRange(ofDefinition line: LineToken) -> NSRange? {
        guard line.kind == .footnoteDefinition, line.markerRanges.count == 2 else { return nil }
        let start = NSMaxRange(line.markerRanges[0])
        let end = line.markerRanges[1].location
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    public static func footnoteLabel(ofDefinition line: LineToken, in text: NSString) -> String? {
        guard let range = footnoteLabelRange(ofDefinition: line), NSMaxRange(range) <= text.length else {
            return nil
        }
        return text.substring(with: range)
    }

    public static func linkDefinition(in line: String) -> (label: NSRange, url: NSRange)? {
        let ns = line as NSString
        guard let m = linkDefinitionPattern.firstMatch(in: line,
                                                       range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let label = m.range(at: 1)
        let url = m.range(at: 2)
        guard label.location != NSNotFound, url.location != NSNotFound, url.length > 0 else {
            return nil
        }
        return (label: label, url: url)
    }

    /// 정식 판정 — 정규식으로 한 줄을 가른다. 빠른 길(`fastToken`)이 답할 때는 이것과 같은
    /// 답이어야 하고, 테스트가 둘을 줄마다 견준다(그래서 `private`이 아니다).
    func scanLine(_ line: String, at range: NSRange, lineNumber: Int,
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
        if let m = Self.footnoteDefinition.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            // 라벨은 남긴다 — 어느 각주인지가 이 줄의 머리다. 감싼 `[^`와 `]:`만 접힌다.
            let label = m.range(at: 1)
            let content = m.range(at: 2)
            return token(.footnoteDefinition,
                         markers: [shift(NSRange(location: 0, length: label.location), by: range.location),
                                   shift(NSRange(location: NSMaxRange(label),
                                                 length: content.location - NSMaxRange(label)),
                                         by: range.location)],
                         content: shift(content, by: range.location))
        }
        if let parts = Self.linkDefinition(in: line) {
            // 라벨과 콜론은 마커다(캐럿이 없는 줄에서는 접힌다). 주소는 남겨 둔다 —
            // 어디로 가는 링크인지가 이 줄의 내용이다.
            return token(.linkDefinition,
                         markers: [shift(NSRange(location: 0, length: parts.url.location),
                                         by: range.location)],
                         content: shift(parts.url, by: range.location))
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
    ///
    /// `definitions`는 문서 전체에서 모은 링크 정의다. 참조 링크(`[글][참조]`)의 주소는
    /// 이 줄에 없으므로, 표가 없으면 참조 링크를 **평범한 글자로 둔다** — 그것이 정의가
    /// 아직 없는 참조의 올바른 모습이기도 하다.
    public func scanInline(in text: NSString, range: NSRange,
                           definitions: LinkDefinitions = .empty) -> [InlineToken] {
        guard range.length > 0 else { return [] }
        let line = text.substring(with: range)
        let whole = NSRange(location: 0, length: (line as NSString).length)
        var tokens: [InlineToken] = []
        var claimed = IndexSet()
        /// 인라인 코드가 차지한 자리. 강조·링크의 **내용**에는 코드가 들어갈 수 있다 —
        /// `**문서 레벨 `NSUndoManager` 하나**`, `[`설정` 열기](…)`. 코드가 먼저 자리를 차지하므로
        /// 전에는 그런 강조와 링크가 통째로 빠져, 편집기에서 굵게 보이지 않았고 번역에서는 `**`가
        /// 보호받지 못해 번역기가 지웠다(실측, 저장소 설계 문서).
        var codeClaimed = IndexSet()

        func add(_ kind: InlineKind, _ m: NSTextCheckingResult, content: Int, markers: [NSRange]) {
            let full = m.range
            let fullRange = full.location ..< NSMaxRange(full)
            let inner = m.range(at: content)
            let containsCode: Bool
            switch kind {
            case .strong, .emphasis, .strikethrough, .link, .image:
                containsCode = inner.location != NSNotFound
            default:
                containsCode = false
            }
            if containsCode {
                // 내용 밖(표시)은 비어 있어야 하고, 내용 안에서 차지된 자리는 코드뿐이어야 한다.
                var outside = IndexSet(integersIn: fullRange)
                outside.remove(integersIn: inner.location ..< NSMaxRange(inner))
                guard claimed.intersection(outside).isEmpty else { return }
                var insideClaimed = claimed
                insideClaimed.formIntersection(IndexSet(integersIn: inner.location ..< NSMaxRange(inner)))
                guard insideClaimed.isSubset(of: codeClaimed) else { return }
            } else {
                guard !claimed.intersects(integersIn: fullRange) else { return }
            }
            claimed.insert(integersIn: fullRange)
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
            codeClaimed.insert(integersIn: full.location ..< NSMaxRange(full))
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

        // 각주 참조. 참조 링크의 축약 꼴(`[참조]`)보다 먼저 — 그쪽 패턴도 `[^1]`에 맞는다.
        for m in Self.footnoteReference.matches(in: line, range: whole) {
            let label = (line as NSString).substring(with: m.range(at: 1))
            guard definitions.hasFootnote(label) else { continue }
            add(.footnoteReference(label: label), m, content: 1, markers: markerPair(m, contentIndex: 1))
        }

        // 참조 꼴. **인라인 꼴 다음이어야 한다** — `[a](b)`를 먼저 잡게 두지 않으면
        // 축약 참조 패턴 `[a]`가 그 앞부분을 먼저 집어간다.
        //
        // 세 꼴을 다룬다: 온전한 꼴 `[글][참조]`, 줄인 꼴 `[참조][]`, 축약 꼴 `[참조]`.
        // 줄인 꼴과 축약 꼴은 보이는 글자가 곧 라벨이다.
        //
        // **해결되는 것만** 토큰으로 만든다. 정의가 없으면 아무 토큰도 내지 않아 그 글은
        // 평범한 대괄호 글로 남는다 — 그래서 `[보류]`처럼 링크가 아닌 대괄호 글이
        // 밑줄 친 링크로 보이지 않는다.
        //
        // 종류는 인라인 링크와 **같은** `.link`/`.image`를 쓴다. 해결된 참조는 그리는
        // 쪽에서 인라인 링크와 다를 이유가 없고(그림은 그대로 그림으로 놓여야 한다),
        // 종류를 새로 만들면 받는 쪽마다 두 경우를 쓰게 된다.
        for (pattern, isImage, labelGroup) in [
            (Self.referenceImageFull, true, 2),
            (Self.referenceLinkFull, false, 2),
            (Self.referenceImageShortcut, true, 1),
            (Self.referenceLinkShortcut, false, 1),
        ] as [(NSRegularExpression, Bool, Int)] {
            for m in pattern.matches(in: line, range: whole) {
                let ns = line as NSString
                let explicit = m.numberOfRanges > labelGroup ? m.range(at: labelGroup) : NSRange()
                // 줄인 꼴 `[글][]`은 라벨 자리가 비어 있다 — 보이는 글자를 라벨로 쓴다.
                let labelRange = (explicit.location != NSNotFound && explicit.length > 0)
                    ? explicit : m.range(at: 1)
                guard labelRange.location != NSNotFound, labelRange.length > 0,
                      let url = definitions.url(for: ns.substring(with: labelRange))
                else { continue }
                add(isImage ? .image(url: url) : .link(url: url), m, content: 1,
                    markers: markerPair(m, contentIndex: 1))
            }
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
    /// 링크 정의 줄. 주소는 꺾쇠로 감쌀 수 있고(`<a b.html>`), 제목은 따옴표 세 꼴
    /// 모두 받는다(CommonMark). 들여쓰기는 세 칸까지.
    private static let linkDefinitionPattern =
        regex(#"^\s{0,3}\[([^\]\n]+)\]:[ \t]*(<[^>\n]*>|[^\s\n]+)(?:[ \t]+("[^"\n]*"|'[^'\n]*'|\([^)\n]*\)))?[ \t]*$"#)

    /// 각주 정의 줄. 라벨에는 공백과 `]`가 올 수 없다(GFM). 들여쓰기는 세 칸까지.
    private static let footnoteDefinition = regex(#"^\s{0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$"#)
    /// 각주 참조. 뒤에 `:`가 오면 정의의 머리이고, `(`가 오면 인라인 링크다.
    private static let footnoteReference = regex(#"\[\^([^\]\s]+)\](?![:(])"#)

    private static let code = regex(#"`([^`\n]+)`"#)
    private static let image = regex(#"!\[([^\]\n]*)\]\(([^)\s]+)[^)]*\)"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\s]+)[^)]*\)"#)
    private static let autolink = regex(#"<((?:https?|mailto):[^>\s]+)>"#)
    /// 참조 꼴. 온전한 꼴은 두 번째 대괄호가 라벨이고, 비어 있으면(`[글][]`) 줄인
    /// 꼴이라 첫 대괄호가 라벨을 겸한다.
    private static let referenceImageFull = regex(#"!\[([^\]\n]*)\]\[([^\]\n]*)\]"#)
    private static let referenceLinkFull = regex(#"\[([^\]\n]+)\]\[([^\]\n]*)\]"#)
    /// 축약 꼴 `[참조]`. 뒤에 `(`나 `[`가 오면 인라인 꼴이나 온전한 꼴이므로 제외한다 —
    /// 그 둘은 이미 앞에서 잡혔지만, 여기서도 막아 **반쪽만** 집어가지 않게 한다.
    private static let referenceImageShortcut = regex(#"!\[([^\]\n]+)\](?![\[(])"#)
    private static let referenceLinkShortcut = regex(#"(?<!!)\[([^\]\n]+)\](?![\[(:])"#)
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
