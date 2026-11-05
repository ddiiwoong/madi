import Foundation

/// 번역 단위 하나가 너무 길 때 **진행을 보일 수 있을 만큼** 잘게 나눈다.
///
/// 왜 필요한가: Apple 번역은 출력 상한이 없어 길이로 실패하지는 않지만, 시간이 글자 수에
/// 비례한다. Sogon의 실측 기록으로는 이 Mac에서 5,966자가 한 호출에 23~54초였고 그동안
/// 화면에 아무것도 나타나지 않았다. 마크업 없는 긴 문단은 단위 하나가 수천 자가 되므로
/// 그 문단이 끝날 때까지 앱이 멈춘 듯 보인다.
///
/// 나누는 규칙은 Sogon의 `TranslationChunker`를 따른다 — **문장 → 낱말 → 글자** 순으로
/// 내려가고, 윗단계로 둘 이상이 나오면 각 조각을 다시 같은 규칙으로 나눈다. 문장 경계에서
/// 자르는 것이 핵심이다: 문장 중간에서 자르면 번역 품질이 떨어진다(자리표 설계로 막은 바로
/// 그 문제가 다시 생긴다).
///
/// 불변식 둘:
/// 1. **글자를 잃거나 더하지 않는다** — 모든 조각을 이으면 입력과 같다.
/// 2. **자리표를 가르지 않는다** — `MarkdownTranslationPlan`의 자리표(`{{12}}`)는 쪼개지면 복원할
///    수 없으므로, 글자 경계까지 내려가도 자리표 안에서는 자르지 않는다.
public enum TranslationChunker {

    /// 한 조각의 목표 글자 수. 이 Mac에서 초당 110~260자이므로 800자면 조각 하나가 3~9초다.
    public static let characterLimit = 800

    /// 이보다 짧으면 더 가르지 않는다.
    public static let minimumSplittable = 40

    /// `text`를 본문이 `limit`자 이하인 조각들로 나눈다.
    public static func split(_ text: String, limit: Int = characterLimit) -> [String] {
        let bound = max(1, limit)
        guard text.count > bound else { return text.isEmpty ? [] : [text] }
        return merge(units(of: text, limit: bound), limit: bound)
    }

    // MARK: 단위 분해

    private static func units(of text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }

        let sentences = sentenceUnits(text)
        if sentences.count > 1 {
            return sentences.flatMap { units(of: $0, limit: limit) }
        }
        let words = wordUnits(text)
        if words.count > 1 {
            return words.flatMap { units(of: $0, limit: limit) }
        }
        return characterUnits(text, limit: limit)
    }

    /// 문장 단위. Foundation의 문장 경계를 쓰고, **이어 붙인 결과가 원문과 다르면 쪼개지
    /// 않은 것으로 돌아간다**(글자를 잃지 않는 쪽이 중요하다).
    static func sentenceUnits(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex,
                                 options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            result.append(String(text[enclosing]))
        }
        return result.joined() == text ? result : [text]
    }

    /// 낱말 단위. 단위 하나는 공백 아닌 글자 런과 그 뒤에 이어진 공백 런이다.
    static func wordUnits(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var units: [String] = []
        var current = ""
        var inSpaceRun = false
        for character in text {
            if character.isWhitespace {
                current.append(character)
                inSpaceRun = true
            } else {
                if inSpaceRun {
                    units.append(current)
                    current = ""
                    inSpaceRun = false
                }
                current.append(character)
            }
        }
        if !current.isEmpty { units.append(current) }
        return units
    }

    /// 낱말 하나가 한계를 넘을 때(URL·base64·공백 없는 긴 글)만 쓴다.
    ///
    /// **자리표 안에서는 자르지 않는다.** 자리표(`{{12}}` 등, `MarkdownTranslationPlan.TokenForm`)가
    /// 쪼개지면 되살릴 수 없다.
    static func characterUnits(_ text: String, limit: Int) -> [String] {
        let characters = Array(text)
        // 자리표의 **안쪽** 글자 위치(첫 글자 뒤부터 끝 글자까지) — 여기 앞에서는 자르지 않는다.
        var inside = Set<Int>()
        let ns = text as NSString
        for match in MarkdownTranslationPlan.TokenForm.anyToken.matches(
            in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text) else { continue }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let count = text.distance(from: range.lowerBound, to: range.upperBound)
            for offset in 1 ..< max(1, count) { inside.insert(start + offset) }
        }

        var pieces: [String] = []
        var current: [Character] = []
        for (index, character) in characters.enumerated() {
            if current.count >= limit, !inside.contains(index) {
                pieces.append(String(current))
                current = []
            }
            current.append(character)
        }
        if !current.isEmpty { pieces.append(String(current)) }
        return pieces.isEmpty ? [text] : pieces
    }

    /// 단위를 차례로 묶는다. 묶음이 `limit` 이하인 선까지다.
    private static func merge(_ units: [String], limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for unit in units {
            let candidate = current + unit
            if candidate.count <= limit {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current) }
                current = unit
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
