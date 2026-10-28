import Foundation

/// 원문과 번역본의 블록을 짝짓고, 한쪽의 스크롤 위치를 다른 쪽 위치로 옮긴다.
///
/// **위치는 픽셀이 아니라 블록 좌표다.** `3.4`는 네 번째 블록(0부터 센다)의 40% 지점이다.
/// 번역하면 문장 길이가 달라져 같은 블록이 두 창에서 높이가 다르다 — 그래서 문서 전체의
/// 비율로 맞추면 갈수록 어긋나고, 블록 번호로 맞춰야 한다. 픽셀로 바꾸는 일은 각 창의
/// 레이아웃을 아는 Editor 층이 한다.
///
/// **짝짓기**는 종류 배열의 최장 공통 부분열(LCS)이다. 번역은 블록 구조를 지키므로
/// 보통 두 배열이 같고, 그때는 앞뒤를 깎는 것만으로 끝난다(O(n)). 사용자가 한쪽을 고치면
/// 고친 자리 근처만 다르므로 LCS는 그 가운데 구간에만 돈다.
///
/// **옮기기**는 짝마다 꼭짓점 두 개((i, j), (i+1, j+1))를 찍은 **단조 구간 선형 사상**이다.
/// 짝지어진 블록 안에서는 비율이 그대로 옮겨지고, 짝이 없는 블록이 낀 구간은 둘레의
/// 짝 사이에서 고르게 늘어나거나 줄어든다. 번역본에만 있는 블록은 원문 쪽에서 보면 폭이
/// 0인 구간이라, 번역본을 굴려 그 블록을 지나는 동안 원문은 제자리에 서 있다.
public struct BlockAlignment: Equatable, Sendable {

    /// 짝을 지을 때 보는 블록의 꼴. 내용은 보지 않는다 — 번역하면 내용은 전부 다르다.
    ///
    /// 표의 행·열 수와 코드 블록의 언어는 **일부러 뺐다.** 한쪽 창에서 행을 하나 더하거나
    /// 언어 이름을 고쳐도 같은 블록이다. 제목 수준은 남겼다 — 번역이 바꾸지 않고,
    /// 남겨야 `## 가`와 `### 나`가 엇갈려 짝지어지지 않는다.
    public enum Key: Hashable, Sendable {
        case paragraph
        case heading(level: Int)
        case quote
        case list(ordered: Bool)
        case codeBlock
        case table
        case thematicBreak
        case blankLines

        public init(_ kind: Block.Kind) {
            switch kind {
            case .paragraph: self = .paragraph
            case .heading(let level): self = .heading(level: level)
            case .quote: self = .quote
            case .list(let ordered): self = .list(ordered: ordered)
            case .codeBlock: self = .codeBlock
            case .table: self = .table
            case .thematicBreak: self = .thematicBreak
            case .blankLines: self = .blankLines
            }
        }
    }

    public struct Pair: Equatable, Sendable {
        public let source: Int
        public let target: Int
        public init(source: Int, target: Int) {
            self.source = source
            self.target = target
        }
    }

    /// 짝지어진 블록. 원문 번호와 번역본 번호가 **둘 다** 엄격히 늘어난다.
    public let pairs: [Pair]
    public let sourceCount: Int
    public let targetCount: Int

    /// LCS 표의 칸 수 상한. 넘으면 그 가운데 구간은 짝을 짓지 않고 비율로 옮긴다.
    ///
    /// 앞뒤를 깎은 뒤의 구간이 이만큼 크다는 것은 두 문서가 블록 수천 개에 걸쳐
    /// 다르다는 뜻이다 — 짝이 무엇이든 그 구간의 스크롤 맞추기는 근사일 수밖에 없고,
    /// 수천만 칸의 표를 스크롤 중에 만드는 비용을 치를 이유가 없다.
    public static let cellLimit = 2_000_000

    public init(pairs: [Pair], sourceCount: Int, targetCount: Int) {
        self.pairs = pairs
        self.sourceCount = sourceCount
        self.targetCount = targetCount
        let anchors = BlockAlignment.anchors(pairs: pairs, sourceCount: sourceCount,
                                             targetCount: targetCount)
        forward = anchors
        backward = anchors.map { Anchor(x: $0.y, y: $0.x) }
    }

    public static func align(source: [Block], target: [Block]) -> BlockAlignment {
        align(source: source.map { Key($0.kind) }, target: target.map { Key($0.kind) })
    }

    public static func align(source: [Key], target: [Key]) -> BlockAlignment {
        let n = source.count, m = target.count
        var pairs: [Pair] = []

        // 앞을 깎는다.
        var head = 0
        while head < n, head < m, source[head] == target[head] {
            pairs.append(Pair(source: head, target: head))
            head += 1
        }
        // 뒤를 깎는다. 앞에서 짝지은 것과 겹치지 않게 head에서 멈춘다.
        var tail = 0
        while tail < n - head, tail < m - head, source[n - 1 - tail] == target[m - 1 - tail] {
            tail += 1
        }

        let a = Array(source[head..<(n - tail)])
        let b = Array(target[head..<(m - tail)])
        if !a.isEmpty, !b.isEmpty, (a.count + 1) * (b.count + 1) <= cellLimit {
            for pair in lcs(a, b) {
                pairs.append(Pair(source: head + pair.source, target: head + pair.target))
            }
        }

        for k in 0..<tail {
            pairs.append(Pair(source: n - tail + k, target: m - tail + k))
        }
        return BlockAlignment(pairs: pairs, sourceCount: n, targetCount: m)
    }

    /// 원문 위치 → 번역본 위치.
    public func targetPosition(forSource position: Double) -> Double {
        BlockAlignment.interpolate(forward, at: position, upper: Double(sourceCount))
    }

    /// 번역본 위치 → 원문 위치.
    public func sourcePosition(forTarget position: Double) -> Double {
        BlockAlignment.interpolate(backward, at: position, upper: Double(targetCount))
    }

    // MARK: - 내부

    private struct Anchor: Equatable, Sendable {
        let x: Double
        let y: Double
    }

    private let forward: [Anchor]
    private let backward: [Anchor]

    public static func == (lhs: BlockAlignment, rhs: BlockAlignment) -> Bool {
        lhs.pairs == rhs.pairs && lhs.sourceCount == rhs.sourceCount
            && lhs.targetCount == rhs.targetCount
    }

    /// 꼭짓점: 문서 처음(0, 0), 짝마다 블록의 처음과 끝, 문서 끝(n, m).
    /// 짝이 두 좌표 모두에서 엄격히 늘어나므로 꼭짓점도 두 좌표 모두에서 줄지 않는다 —
    /// 그래서 (x, y) 순으로 정렬한 배열과 (y, x) 순으로 정렬한 배열이 같은 순서다.
    private static func anchors(pairs: [Pair], sourceCount: Int, targetCount: Int) -> [Anchor] {
        var out: [Anchor] = [Anchor(x: 0, y: 0)]
        for pair in pairs {
            for point in [Anchor(x: Double(pair.source), y: Double(pair.target)),
                          Anchor(x: Double(pair.source + 1), y: Double(pair.target + 1))]
            where point != out.last {
                out.append(point)
            }
        }
        let end = Anchor(x: Double(sourceCount), y: Double(targetCount))
        if end != out.last { out.append(end) }
        return out
    }

    /// 단조 구간 선형 보간. x가 같은 꼭짓점이 여럿이면(상대 쪽에만 있는 블록) **가장 뒤의
    /// 것**을 쓴다 — 짝지어진 블록의 처음에 서 있으면 상대도 그 블록의 처음에 서야 하고,
    /// 상대 쪽에만 있는 블록 앞에 서면 안 된다.
    private static func interpolate(_ anchors: [Anchor], at raw: Double, upper: Double) -> Double {
        guard let first = anchors.first else { return 0 }
        let x = min(max(raw.isFinite ? raw : 0, 0), upper)
        // x 이하인 마지막 꼭짓점을 찾는다.
        var lo = 0, hi = anchors.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if anchors[mid].x <= x { lo = mid } else { hi = mid - 1 }
        }
        let left = anchors[lo]
        guard left.x <= x else { return first.y }
        guard lo + 1 < anchors.count else { return left.y }
        let right = anchors[lo + 1]
        let width = right.x - left.x
        guard width > 0 else { return left.y }
        return left.y + (x - left.x) / width * (right.y - left.y)
    }

    /// 고전적인 LCS. 짝을 앞에서부터 돌려준다.
    private static func lcs(_ a: [Key], _ b: [Key]) -> [Pair] {
        let n = a.count, m = b.count
        let width = m + 1
        // table[i][j] = a[i...]와 b[j...]의 LCS 길이. 뒤에서부터 채워야 앞에서부터 짝을 뽑는다.
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var out: [Pair] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                out.append(Pair(source: i, target: j))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return out
    }
}
