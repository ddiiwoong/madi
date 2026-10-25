import Foundation

/// 보이는 범위만 뷰를 만들기 위한 셈 — `docs/block-editor-design.md` §4.
///
/// 설계가 `NSStackView`를 쓰지 말라고 적은 이유가 여기 있다. 블록마다
/// `NSTextView`를 만드는 비용은 작지 않고(각자 text storage·layout manager·container를
/// 가진다), 500블록 문서에서 전부 만들면 여는 순간이 체감된다. 그래서 **보이는 블록만**
/// 뷰를 갖고 나머지는 높이만 기억한다.
///
/// 이 파일은 AppKit을 쓰지 않는다 — 셈이 맞는지는 창을 띄우지 않고 확인할 수 있어야
/// 한다(`make core-only`가 지킨다).
public struct BlockViewportLayout: Equatable, Sendable {

    /// 블록 하나의 자리.
    public struct Placement: Equatable, Sendable {
        public let blockIndex: Int
        /// 문서 좌표에서 위에서부터의 거리.
        public let y: Double
        public let height: Double
        public init(blockIndex: Int, y: Double, height: Double) {
            self.blockIndex = blockIndex
            self.y = y
            self.height = height
        }
        public var maxY: Double { y + height }
    }

    /// 블록 사이 간격.
    public let spacing: Double
    /// 보이는 범위 위아래로 더 만들어 둘 길이. 굴릴 때마다 뷰를 새로 만들면
    /// 끊겨 보이므로 한 화면의 일부를 미리 둔다.
    public let overscan: Double

    public init(spacing: Double = 0, overscan: Double = 200) {
        self.spacing = max(0, spacing)
        self.overscan = max(0, overscan)
    }

    /// 모든 블록의 자리. 높이는 호출하는 쪽이 재서 넘긴다 — 글자를 재는 일은
    /// AppKit의 몫이고, 여기서는 쌓기만 한다.
    public func placements(heights: [Double]) -> [Placement] {
        var out: [Placement] = []
        out.reserveCapacity(heights.count)
        var y = 0.0
        for (index, rawHeight) in heights.enumerated() {
            let height = max(0, rawHeight)
            out.append(Placement(blockIndex: index, y: y, height: height))
            y += height + spacing
        }
        return out
    }

    /// 문서 전체 높이. 마지막 블록 뒤의 간격은 더하지 않는다 — 더하면 문서 끝에
    /// 빈 띠가 남는다.
    public func totalHeight(heights: [Double]) -> Double {
        guard !heights.isEmpty else { return 0 }
        let sum = heights.reduce(0) { $0 + max(0, $1) }
        return sum + spacing * Double(heights.count - 1)
    }

    /// 뷰를 가져야 하는 블록들. `visibleOrigin`은 문서 좌표에서 보이는 범위의 위쪽
    /// 거리, `visibleHeight`는 그 높이다.
    public func visible(placements: [Placement], visibleOrigin: Double,
                        visibleHeight: Double) -> [Placement] {
        guard !placements.isEmpty, visibleHeight > 0 else { return [] }
        let lower = visibleOrigin - overscan
        let upper = visibleOrigin + visibleHeight + overscan
        return placements.filter { placement in
            // 높이 0인 블록도 경계에 걸리면 뷰를 가진다 — 빈 줄 블록이 그렇고,
            // 뷰가 없으면 그 자리에 캐럿을 놓을 수 없다.
            placement.height > 0
                ? placement.y < upper && placement.maxY > lower
                : placement.y <= upper && placement.y >= lower
        }
    }

    /// 어느 블록의 자리인가. 클릭한 지점이 어느 블록인지 가리는 데 쓴다.
    public func blockIndex(at y: Double, placements: [Placement]) -> Int? {
        for placement in placements where y >= placement.y && y < placement.maxY + spacing {
            return placement.blockIndex
        }
        guard let last = placements.last, y >= last.maxY else { return placements.first?.blockIndex }
        return last.blockIndex
    }
}
