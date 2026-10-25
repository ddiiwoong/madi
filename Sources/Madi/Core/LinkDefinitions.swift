import Foundation

/// 문서에 흩어져 있는 링크 정의(`[참조]: https://example.com`)를 모아 둔다.
///
/// 왜 따로 있는가: 참조 링크는 **줄 하나만 보고 풀 수 없다.** `[글][참조]`가 가리키는
/// 주소는 문서의 다른 줄에, 보통 문서 맨 끝에 있다. 인라인 스캔은 한 줄의 범위만
/// 받으므로, 문서 전체를 한 번 훑어 만든 이 표를 받아야 한다.
///
/// 정의가 **없는** 참조는 링크가 아니다. CommonMark가 그렇게 정하고, 편집기에서는 그게
/// 더 중요하다 — 정의를 아직 안 쓴 참조를 링크처럼 그리면 주소가 빈 링크가 생기고,
/// `[각주]` 같은 평범한 대괄호 글이 전부 링크로 보인다.
public struct LinkDefinitions: Equatable, Sendable {

    /// 열쇠는 **정규화한** 라벨이다(아래 `normalize`).
    private var table: [String: String]

    public static let empty = LinkDefinitions(table: [:])

    private init(table: [String: String]) {
        self.table = table
    }

    /// 문서를 훑어 정의를 모은다. 코드 블록 안의 `[a]: b`는 코드이므로 세지 않는다 —
    /// 줄 종류를 이미 가려 둔 `lines`를 받는 이유가 그것이다.
    public init(scanning text: NSString, lines: [LineToken]) {
        var table: [String: String] = [:]
        for line in lines where line.kind == .linkDefinition {
            guard line.range.length > 0,
                  let parts = MarkdownSyntax.linkDefinition(in: text.substring(with: line.range))
            else { continue }
            let label = Self.normalize((text.substring(with: line.range) as NSString)
                .substring(with: parts.label))
            let url = (text.substring(with: line.range) as NSString).substring(with: parts.url)
            guard !label.isEmpty, !url.isEmpty else { continue }
            // 같은 라벨이 두 번 정의되면 **먼저 나온 것**이 이긴다(CommonMark).
            if table[label] == nil { table[label] = url }
        }
        self.table = table
    }

    public var isEmpty: Bool { table.isEmpty }
    public var count: Int { table.count }

    /// 라벨이 가리키는 주소. 정의가 없으면 nil.
    public func url(for label: String) -> String? {
        table[Self.normalize(label)]
    }

    /// 라벨 정규화 — CommonMark의 규칙이다. 대소문자를 무시하고, 앞뒤 공백을 떼고,
    /// 가운데 이어진 공백을 한 칸으로 줄인다. 그래서 `[Foo  Bar]`와 `[foo bar]`가
    /// 같은 정의를 가리킨다.
    ///
    /// 줄바꿈도 공백으로 센다. 여러 줄에 걸친 라벨은 이 편집기가 다루지 않지만,
    /// 정규화 규칙 자체는 그렇게 두는 것이 맞다.
    static func normalize(_ label: String) -> String {
        label
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
