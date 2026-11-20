import Foundation

/// 문서 레벨 되돌리기의 등록 단위 — `docs/block-editor-design.md` §5.2.
///
/// 블록 뷰마다 `NSUndoManager`를 두면 ⌘Z가 **방금 고친 블록이 아니라 first responder가
/// 마지막으로 머문 블록**을 되돌린다. 그래서 블록 뷰들의 undo를 모두 끄고 모든 편집을
/// 이 연산으로 바꿔 문서 하나의 undo 스택에 넣는다.
///
/// ## 왜 연산이 하나뿐인가
///
/// 설계는 "블록 N의 텍스트가 A→B", "블록 삽입/삭제", "표 M의 칸 (r,c)가 A→B"를 따로
/// 적었지만, 셋 다 **블록 구간을 다른 블록들로 바꾸는 것**이다. 하나로 두면 뒤집기가
/// 자명해지고(새 것과 옛 것을 맞바꾼다) 되돌리기가 깨질 자리가 없다. 특히 텍스트 편집은
/// 블록 **개수를 바꿀 수 있어서**(아래) "텍스트 A→B"라는 모양으로는 뒤집을 수 없다.
///
/// ## 텍스트 편집이 블록 구조를 바꾼다
///
/// 설계가 적지 않은 경우다. 문단 앞에 `# `을 치면 그 블록은 제목이 되고, 가운데서
/// 두 번 Enter를 치면 블록 **셋**(문단·빈 줄·문단)이 된다. 그래서 텍스트 편집은
/// 고친 조각을 `BlockParser`로 **다시 읽어** 나온 블록들로 갈아 끼운다. 두 번째
/// 판정기를 두지 않는 단계 0의 규칙을 그대로 지키는 것이고, 재파싱 결과가 원문 조각을
/// 그대로 들고 있으므로 바이트 동일 불변식도 유지된다.
public struct BlockEdit: Equatable {

    /// 갈아 끼울 블록 구간(옛 문서의 번호).
    public let range: Range<Int>
    /// 그 자리에 있던 블록들. 뒤집을 때 쓴다.
    public let old: [Block]
    /// 그 자리에 들어갈 블록들.
    public let new: [Block]
    /// 되돌리기 메뉴에 보일 이름.
    public let name: String

    public init(range: Range<Int>, old: [Block], new: [Block], name: String) {
        self.range = range
        self.old = old
        self.new = new
        self.name = name
    }

    /// 뒤집은 연산. 바뀐 뒤의 번호 구간에 옛 블록들을 되돌려 놓는다.
    public func inverted() -> BlockEdit {
        BlockEdit(range: range.lowerBound ..< (range.lowerBound + new.count),
                  old: new, new: old, name: name)
    }

    @discardableResult
    public func apply(to document: inout BlockDocument) -> Bool {
        guard range.lowerBound >= 0, range.upperBound <= document.blocks.count else { return false }
        document.blocks.replaceSubrange(range, with: new)
        return true
    }

    /// 아무것도 바꾸지 않는 연산인가. undo 스택에 넣을 가치가 없는 것을 가린다.
    public var isNoop: Bool { old == new }

    /// 블록이 쪼개진 뒤 캐럿이 갈 자리.
    ///
    /// 빈 줄을 쳐서 문단이 셋으로 갈리면 옛 블록의 뷰는 사라지고 새 뷰 셋이 생긴다.
    /// 그때 캐럿을 다시 놓지 않으면 **문서 앞으로 튄다** — Enter를 칠 때마다 일어나는
    /// 일이라 이것이 틀리면 편집기를 쓸 수 없다.
    ///
    /// `offset`은 갈리기 전 조각 안의 UTF-16 오프셋이고, 돌려주는 자리는 새 블록들
    /// 중 그 오프셋을 품은 블록이다. 경계에 정확히 걸리면 **뒤 블록의 처음**을 고른다 —
    /// 빈 줄을 쳐서 갈렸을 때 캐럿은 새로 생긴 아래 문단에 있어야 한다.
    public static func position(forOffset offset: Int, within blocks: [Block],
                                firstBlockIndex: Int) -> BlockPosition {
        guard !blocks.isEmpty else {
            return BlockPosition(blockIndex: max(0, firstBlockIndex), offset: 0)
        }
        var remaining = max(0, offset)
        for (step, block) in blocks.enumerated() {
            let length = (block.sourceSlice as NSString).length
            if remaining < length || step == blocks.count - 1 {
                return BlockPosition(blockIndex: firstBlockIndex + step,
                                     offset: min(remaining, length))
            }
            remaining -= length
        }
        let last = blocks.count - 1
        return BlockPosition(blockIndex: firstBlockIndex + last,
                             offset: (blocks[last].sourceSlice as NSString).length)
    }
}

// MARK: - 편집을 연산으로 바꾸기

public struct BlockEditFactory: Sendable {

    private let parser: BlockParser

    public init(parser: BlockParser = BlockParser()) {
        self.parser = parser
    }

    /// 블록 하나의 글이 `newSource`로 바뀌었다. 그 조각을 다시 읽어 나온 블록들로
    /// 갈아 끼우는 연산을 만든다.
    ///
    /// 재파싱 결과가 블록 하나이면 **식별자를 물려준다.** 블록 뷰는 식별자로 자기
    /// 블록을 다시 찾으므로, 한 글자 칠 때마다 식별자가 바뀌면 뷰가 매번 새로 만들어지고
    /// first responder와 조합 중인 한글이 날아간다.
    public func textEdit(in document: BlockDocument, blockIndex: Int,
                         newSource: String, name: String = String(localized: "입력")) -> BlockEdit? {
        guard document.blocks.indices.contains(blockIndex) else { return nil }
        let oldBlock = document.blocks[blockIndex]
        guard oldBlock.sourceSlice != newSource else { return nil }

        var replacement = parser.parseBlocks(newSource)

        if replacement.isEmpty {
            // 조각이 빈 글이 됐다. 블록을 없애는 것이 맞다 — 빈 블록을 남기면
            // 이어붙이기에 아무 바이트도 더하지 않는 유령 블록이 생긴다.
            return BlockEdit(range: blockIndex ..< (blockIndex + 1),
                             old: [oldBlock], new: [], name: name)
        }
        if replacement.count == 1 {
            let only = replacement[0]
            replacement = [Block(id: oldBlock.id, kind: only.kind,
                                 sourceSlice: only.sourceSlice, isModified: false)]
        }
        return BlockEdit(range: blockIndex ..< (blockIndex + 1),
                         old: [oldBlock], new: replacement, name: name)
    }

    /// 표의 칸을 고친다. 모델을 고치므로 직렬화가 그 블록만 다시 그린다.
    public func tableEdit(in document: BlockDocument, blockIndex: Int,
                          name: String = String(localized: "표 고치기"),
                          _ body: (inout TableModel) -> Void) -> BlockEdit? {
        guard document.blocks.indices.contains(blockIndex) else { return nil }
        let oldBlock = document.blocks[blockIndex]
        var newBlock = oldBlock
        guard newBlock.mutateTable(body) else { return nil }
        return BlockEdit(range: blockIndex ..< (blockIndex + 1),
                         old: [oldBlock], new: [newBlock], name: name)
    }

    /// 블록을 넘는 선택을 `replacement`로 바꾼다. 걸친 블록들을 **한 조각으로 합쳐**
    /// 다시 읽는다 — 양쪽 토막이 한 블록이 되는 경우(문단 둘의 가운데를 지우면 한 문단)가
    /// 흔하다.
    ///
    /// 지우기와 치기가 같은 연산인 이유: 블록마다 텍스트 뷰가 따로이므로
    /// `insertText`는 **자기 블록의 몫만** 지운다. 그대로 두면 블록을 넘는 선택 위에
    /// 글자를 쳤을 때 나머지 블록의 선택된 글이 남는다. 그래서 치기·붙이기도 이 길을
    /// 지나 하나의 되돌릴 수 있는 편집이 된다.
    public func replacement(in document: BlockDocument, selection: BlockSelection,
                            with replacement: String, name: String = String(localized: "삭제")) -> BlockEdit? {
        guard !selection.isCollapsed else { return nil }
        let from = selection.start
        let to = selection.end
        guard document.blocks.indices.contains(from.blockIndex),
              document.blocks.indices.contains(to.blockIndex) else { return nil }

        let firstSlice = document.blocks[from.blockIndex].sourceSlice as NSString
        let lastSlice = document.blocks[to.blockIndex].sourceSlice as NSString
        let head = firstSlice.substring(to: min(max(0, from.offset), firstSlice.length))
        let tail = lastSlice.substring(from: min(max(0, to.offset), lastSlice.length))

        let range = from.blockIndex ..< (to.blockIndex + 1)
        let old = Array(document.blocks[range])
        let merged = head + replacement + tail
        let new = merged.isEmpty ? [] : parser.parseBlocks(merged)
        return BlockEdit(range: range, old: old, new: new, name: name)
    }

    /// 블록을 넘는 선택을 지운다.
    public func deletion(in document: BlockDocument, selection: BlockSelection,
                         name: String = String(localized: "삭제")) -> BlockEdit? {
        replacement(in: document, selection: selection, with: "", name: name)
    }
}
