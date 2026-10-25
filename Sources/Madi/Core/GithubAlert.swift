import Foundation

/// GitHub 알림 — `> [!NOTE]`로 시작하는 인용은 색이 있는 안내 상자다.
///
/// GitHub·GitLab·Obsidian이 모두 이 꼴을 쓰고, MarkText(Muya)도
/// `src/utils/githubAlerts.ts`에 같은 다섯 종류를 둔다. 마디는 지금 이것을 **그냥
/// 인용**으로 그려서, 문서를 GitHub에서 보면 색 상자인데 편집기에서는 회색 막대만
/// 보인다.
///
/// 판정 규칙은 Muya의 것을 그대로 따른다(그쪽이 GitHub의 동작에 맞춰 둔 것이다):
/// 인용의 **첫 줄**이 `[!TYPE]` 하나뿐이어야 하고, 대소문자는 가리지 않으며,
/// escape된 `\[`·`\!`·`\]`는 먼저 되돌린다.
public enum GithubAlert: String, CaseIterable, Sendable {
    case note = "NOTE"
    case tip = "TIP"
    case important = "IMPORTANT"
    case warning = "WARNING"
    case caution = "CAUTION"

    /// 사람이 읽는 제목. GitHub는 `Note`·`Warning`처럼 첫 글자만 크게 쓴다.
    public var title: String {
        rawValue.prefix(1) + rawValue.dropFirst().lowercased()
    }

    /// 인용 줄의 **내용**(`>` 뒤)이 알림 표식인가.
    ///
    /// 표식인 줄은 그 자체가 내용이 아니라 상자의 종류를 말하는 표시다.
    public static func marker(inQuoteContent content: String) -> GithubAlert? {
        let unescaped = content
            .replacingOccurrences(of: "\\[", with: "[")
            .replacingOccurrences(of: "\\!", with: "!")
            .replacingOccurrences(of: "\\]", with: "]")
        let trimmed = unescaped.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]") else { return nil }
        let inner = trimmed.dropFirst(2).dropLast()
        guard !inner.isEmpty else { return nil }
        return GithubAlert(rawValue: inner.uppercased())
    }

    /// 인용 줄들을 훑어 **각 줄이 어느 알림에 속하는지** 알려 준다.
    ///
    /// 한 인용 덩이의 첫 줄이 표식이면 그 덩이 전체가 그 알림이다. 빈 줄이나
    /// 인용이 아닌 줄을 만나면 덩이가 끝난다 — 그래야 알림 다음의 보통 인용이
    /// 색을 물려받지 않는다.
    public static func map(lines: [LineToken], in text: NSString) -> [Int: GithubAlert] {
        var result: [Int: GithubAlert] = [:]
        var current: GithubAlert?
        var runStarted = false

        for (index, line) in lines.enumerated() {
            guard case .quote = line.kind else {
                current = nil
                runStarted = false
                continue
            }
            if !runStarted {
                runStarted = true
                let content = line.contentRange.length > 0
                    ? text.substring(with: line.contentRange) : ""
                current = marker(inQuoteContent: content)
            }
            if let current { result[index] = current }
        }
        return result
    }
}
