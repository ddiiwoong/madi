import Foundation

/// 블록을 넘는 선택 — `docs/block-editor-design.md` §5.1.
///
/// 블록마다 자기 `NSTextView`를 가지면 first responder가 하나뿐이라서 "문단 중간에서
/// 시작해 표 칸에서 끝나는 선택"이 뷰 하나로 표현되지 않는다. 그래서 선택은 **뷰가
/// 아니라 여기**에 있고, 각 블록 뷰는 자기 몫(`Coverage`)만 받아 그린다.
///
/// 자리는 `(블록 번호, 그 블록 원문 조각 안의 UTF-16 오프셋)`이다. UTF-16인 이유는
/// `NSTextView`가 주고받는 단위가 그것이고, 중간에 다른 단위로 바꾸면 한글·이모지가
/// 든 문서에서 한 칸씩 밀린다.
public struct BlockPosition: Equatable, Comparable, Sendable {

    public let blockIndex: Int
    /// 그 블록의 `sourceSlice` 안쪽 UTF-16 오프셋.
    public let offset: Int

    public init(blockIndex: Int, offset: Int) {
        self.blockIndex = blockIndex
        self.offset = offset
    }

    public static func < (lhs: BlockPosition, rhs: BlockPosition) -> Bool {
        lhs.blockIndex == rhs.blockIndex
            ? lhs.offset < rhs.offset
            : lhs.blockIndex < rhs.blockIndex
    }
}

public struct BlockSelection: Equatable, Sendable {

    /// 드래그를 시작한 자리. 뒤로 끌면 `head`보다 뒤에 있을 수 있다.
    public var anchor: BlockPosition
    /// 캐럿이 지금 있는 자리.
    public var head: BlockPosition

    public init(anchor: BlockPosition, head: BlockPosition) {
        self.anchor = anchor
        self.head = head
    }

    public init(caretAt position: BlockPosition) {
        self.init(anchor: position, head: position)
    }

    public var start: BlockPosition { min(anchor, head) }
    public var end: BlockPosition { max(anchor, head) }
    public var isCollapsed: Bool { anchor == head }
    public var isWithinOneBlock: Bool { start.blockIndex == end.blockIndex }

    /// 한 블록이 이 선택에서 받는 몫.
    public enum Coverage: Equatable, Sendable {
        /// 선택에 걸리지 않는다.
        case outside
        /// 블록 전체가 선택됐다. 가운데 블록들이 이 상태다 — 길이를 모르고도
        /// 표현할 수 있어야 해서 범위가 아닌 별도 경우로 둔다.
        case whole
        /// 일부만. 범위는 그 블록 조각 안쪽 오프셋이다.
        case partial(NSRange)
    }

    /// `blockIndex` 블록이 받는 몫. 블록의 길이를 모르는 채로 답한다 —
    /// 끝까지라는 사실은 `.whole`과 `.partial`의 구분으로 표현된다.
    public func coverage(ofBlockAt blockIndex: Int) -> Coverage {
        let from = start
        let to = end
        guard blockIndex >= from.blockIndex, blockIndex <= to.blockIndex else { return .outside }

        if from.blockIndex == to.blockIndex {
            return .partial(NSRange(location: from.offset, length: max(0, to.offset - from.offset)))
        }
        if blockIndex == from.blockIndex {
            // 시작 블록은 "오프셋부터 끝까지"다. 길이를 모르므로 길이는 뷰가 가둔다.
            return .partial(NSRange(location: from.offset, length: NSNotFound))
        }
        if blockIndex == to.blockIndex {
            return .partial(NSRange(location: 0, length: to.offset))
        }
        return .whole
    }

    /// 선택된 마크다운을 조립한다 — 복사가 하는 일(설계 §5.1).
    ///
    /// 블록의 원문 조각을 그대로 잇는다. 블록마다 줄바꿈이 조각에 들어 있으므로
    /// 이어붙이기만으로 원문과 같은 글이 나온다 — 구분자를 끼워 넣으면 안 된다.
    public func markdown(in blocks: [Block]) -> String {
        guard !isCollapsed, !blocks.isEmpty else { return "" }
        var out = ""
        let lower = max(0, start.blockIndex)
        let upper = min(blocks.count - 1, end.blockIndex)
        guard lower <= upper else { return "" }

        for index in lower ... upper {
            let slice = blocks[index].sourceSlice as NSString
            switch coverage(ofBlockAt: index) {
            case .outside:
                continue
            case .whole:
                out += slice as String
            case .partial(let range):
                let location = min(max(0, range.location), slice.length)
                let length = range.length == NSNotFound
                    ? slice.length - location
                    : min(range.length, slice.length - location)
                guard length > 0 else { continue }
                out += slice.substring(with: NSRange(location: location, length: length))
            }
        }
        return out
    }
}
