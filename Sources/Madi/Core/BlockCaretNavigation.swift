import Foundation

/// 캐럿이 블록 경계를 넘는 규칙과 입력기 보호 — `docs/block-editor-design.md` §5.3·§5.4.
///
/// 뷰에서 떼어 둔 이유는 이것이 **판단**이고 그리기가 아니기 때문이다. 한글 조합 중에
/// 경계를 넘지 않는다는 규칙은 테스트로 지킬 수 있어야 한다 — 설계가 "한국어 사용자에게
/// 가장 먼저 티가 나는 결함"이라고 적은 것이고, 손으로 눌러 보는 것만으로는 회귀를
/// 막을 수 없다.
public enum BlockCaretNavigation {

    public enum Direction: Equatable, Sendable {
        case up
        case down
    }

    /// 들어갈 블록의 어느 쪽 끝에 캐럿을 놓는가.
    public enum Edge: Equatable, Sendable {
        case top
        case bottom
    }

    public struct Target: Equatable, Sendable {
        public let blockIndex: Int
        public let edge: Edge
        public init(blockIndex: Int, edge: Edge) {
            self.blockIndex = blockIndex
            self.edge = edge
        }
    }

    /// 경계를 넘은 캐럿이 갈 자리. 문서 끝이면 `nil`이고, 그때 뷰는 아무것도 하지
    /// 않는다 — 마지막 블록의 끝에서 ↓는 제자리에 머무는 것이 맞다.
    ///
    /// 단계 1에서는 모든 블록이 글 뷰라서 건너뛸 블록이 없다. 단계 2에서 표가 격자가
    /// 되고 `thematicBreak`이 선 하나가 되면, 캐럿을 받을 수 없는 블록을 건너뛰는
    /// 규칙이 여기에 들어온다.
    public static func target(from blockIndex: Int, direction: Direction,
                              blockCount: Int) -> Target? {
        guard blockCount > 0, blockIndex >= 0, blockIndex < blockCount else { return nil }
        switch direction {
        case .up:
            guard blockIndex > 0 else { return nil }
            return Target(blockIndex: blockIndex - 1, edge: .bottom)
        case .down:
            guard blockIndex + 1 < blockCount else { return nil }
            return Target(blockIndex: blockIndex + 1, edge: .top)
        }
    }
}

/// 입력기(IME) 보호막 — 설계 §5.4.
///
/// 한글은 조합이 끝나기 전까지 글자가 확정되지 않는다(`ㄱ` → `가` → `각`). 그 동안
/// `NSTextView`는 **마크된 글자**를 들고 있고, 그 뷰가 다시 만들어지거나 first responder가
/// 옮겨 가면 조합이 깨져 사용자가 치던 글자가 사라진다.
///
/// 그래서 조합 중에 막아야 하는 것이 둘이다:
///
/// - **블록 경계 이동.** 조합 중의 ↓는 다음 블록으로 가지 않는다.
/// - **구조 변경(재파싱·뷰 재사용).** 조합 중에 `# `이 들어와 블록이 제목으로 바뀌면
///   뷰를 갈아야 하는데, 그 순간 마크된 글자가 날아간다. 조합이 끝날 때까지 **미룬다.**
///
/// 미룬 일을 잃지 않는 것이 이 구조의 요점이다. 조합이 끝나면 `takePending()`이
/// 미뤄 둔 것을 한 번에 내놓는다.
public struct BlockInputGuard: Equatable, Sendable {

    /// 조합 중인가. `NSTextInputClient.hasMarkedText`가 말해 주는 것을 그대로 담는다.
    public private(set) var isComposing = false
    /// 조합 때문에 미뤄 둔 구조 변경이 있는가.
    public private(set) var hasPendingStructureChange = false

    public init() {}

    public mutating func setComposing(_ composing: Bool) {
        if isComposing, !composing {
            isComposing = false
            return
        }
        isComposing = composing
    }

    /// 캐럿이 블록 경계를 넘어도 되는가.
    public var allowsBoundaryMove: Bool { !isComposing }

    /// 구조 변경을 지금 해도 되는가. 안 되면 미뤄 둔다 — **떨어뜨리지 않는다.**
    public mutating func requestStructureChange() -> Bool {
        guard isComposing else { return true }
        hasPendingStructureChange = true
        return false
    }

    /// 미뤄 둔 구조 변경을 가져간다. 두 번 가져가지지 않는다.
    public mutating func takePendingStructureChange() -> Bool {
        guard hasPendingStructureChange, !isComposing else { return false }
        hasPendingStructureChange = false
        return true
    }
}
