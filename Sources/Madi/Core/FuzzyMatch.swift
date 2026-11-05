import Foundation

/// 빠른 열기·명령 팔레트의 걸러내기 — 친 글자가 **순서대로** 다 들어 있으면 맞는다.
///
/// VS Code·Sublime·Xcode의 'Open Quickly'와 같은 방식이다. `fmd`가 `features.md`에 맞고
/// `줄복`이 `줄 복제`에 맞는다. 점수는 사람이 기대하는 순서를 내기 위한 것이다:
/// 이어서 맞을수록, 낱말 첫 글자에 맞을수록, 앞에서 맞을수록 높다.
///
/// 대소문자·분음부호·전각/반각을 가리지 않는다. 친 글의 공백은 무시한다(`줄 복`과 `줄복`이 같다).
/// 한글은 **글자 단위**로 견준다 — 자모를 풀지 않으므로 `ㅈ`이 `줄`에 맞지는 않는다.
public enum FuzzyMatch {

    /// 맞으면 점수(클수록 잘 맞음), 아니면 nil. 빈 질의는 모두 0점으로 맞는다.
    ///
    /// 두 번 맞춰 보고 높은 쪽을 쓴다 — 앞에서부터 바로 맞추기, 그리고 가까운 **낱말 첫 글자**를
    /// 먼저 잡기. 뒤의 것이 `fm`을 `features.md`의 `f`와 `m`(md)에 맞춘다. 앞의 것만 쓰면
    /// `feature`의 안쪽 글자에 흩어지고, 뒤의 것만 쓰면 뒤로 건너뛰다 못 맞추는 경우가 생긴다.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(fold(query).filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(fold(candidate))
        guard needle.count <= haystack.count else { return nil }
        let plain = score(needle, haystack, preferWordStarts: false)
        let starts = score(needle, haystack, preferWordStarts: true)
        switch (plain, starts) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    private static func score(_ needle: [Character], _ haystack: [Character], preferWordStarts: Bool) -> Int? {
        var score = 0
        var index = 0
        var previous: Int?
        for wanted in needle {
            guard let found = nextMatch(of: wanted, in: haystack, from: index,
                                        preferWordStart: preferWordStarts) else { return nil }
            score += 1
            if let previous, found == previous + 1 {
                score += 6                              // 이어서 맞음
            } else if let previous {
                score -= min(found - previous - 1, 6)   // 건너뛴 만큼 조금 깎는다
            }
            if isWordStart(haystack, found) { score += 8 }
            if found == 0 { score += 6 }
            previous = found
            index = found + 1
        }
        if haystack.count == needle.count { score += 20 }     // 똑같다
        return score
    }

    /// `from`부터 `wanted`가 나오는 자리. `preferWordStart`면 처음 나온 자리에서 12글자 안에
    /// 낱말 첫 글자로 나오는 자리가 있을 때 그쪽을 고른다.
    private static func nextMatch(of wanted: Character, in haystack: [Character], from start: Int,
                                  preferWordStart: Bool) -> Int? {
        guard start < haystack.count,
              let first = haystack[start...].firstIndex(of: wanted) else { return nil }
        guard preferWordStart, !isWordStart(haystack, first) else { return first }
        let limit = min(haystack.count, first + 13)
        for position in (first + 1) ..< limit where haystack[position] == wanted && isWordStart(haystack, position) {
            return position
        }
        return first
    }

    private static func isWordStart(_ text: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let before = text[index - 1]
        return before == " " || before == "/" || before == "-" || before == "_" || before == "."
            || before == "▸" || before == "(" || before == "["
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// 점수 순으로 거른다. 점수가 같으면 원래 순서(최근 문서는 최근 순)를 지킨다.
    public static func rank<Item>(_ items: [Item], query: String,
                                  key: (Item) -> (primary: String, secondary: String?)) -> [Item] {
        var scored: [(offset: Int, score: Int, item: Item)] = []
        for (offset, item) in items.enumerated() {
            let keys = key(item)
            // 이름에 맞는 것을 경로에만 맞는 것보다 앞에 둔다.
            if let primary = score(query, in: keys.primary) {
                scored.append((offset, primary * 2 + 1000, item))
            } else if let secondaryText = keys.secondary, let secondary = score(query, in: secondaryText) {
                scored.append((offset, secondary, item))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
        return scored.map(\.item)
    }
}
