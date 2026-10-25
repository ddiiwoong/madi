import Foundation

/// 블록 문서를 다시 마크다운으로 쓴다 — `docs/block-editor-design.md` §6의 오른쪽 절반.
///
/// 규칙은 하나다: **고치지 않은 블록은 원문 조각을 그대로 내보낸다.** 그래서
/// 열지만 하고 저장한 문서는 바이트가 같다. 이것이 취향이 아니라 요구사항인 이유는
/// git을 쓰는 사람에게 "열었더니 diff가 생겼다"가 곧 신뢰를 잃는 일이기 때문이다.
/// `| --- |`의 하이픈 개수처럼 의미 없는 차이까지 보존 대상이다.
public struct BlockSerializer: Sendable {

    public init() {}

    public func serialize(_ document: BlockDocument) -> String {
        let body = document.blocks.map(render).joined()
        guard let frontMatter = document.frontMatter else { return body }
        return frontMatter.joined(withBody: body)
    }

    public func render(_ block: Block) -> String {
        guard block.isModified else { return block.sourceSlice }
        switch block.kind {
        case .table(let model):
            return render(model, endsWithNewline: block.sourceSlice.hasSuffix("\n"))
        case .paragraph, .heading, .quote, .list, .codeBlock, .thematicBreak, .blankLines:
            // 표 말고는 모델을 고치는 길이 아직 없다(설계의 단계 3이 표다). 그래서
            // 여기 오는 일이 없고, 와도 원문을 내보내는 쪽이 안전하다 — 모델이 아직
            // 표현하지 못하는 구문을 멋대로 다시 쓰는 것보다 낫다.
            return block.sourceSlice
        }
    }

    // MARK: 표 그리기

    /// 고친 표를 다시 쓴다. 칸 사이는 `| `와 ` |`로 띄우고, 구분 행은 열 정렬에서
    /// 만든다. 원문의 칸 너비 맞춤(하이픈 개수, 덧댄 공백)은 **여기서 잃는다** —
    /// 고친 표에 한정된 일이고, 설계가 받아들인 대가다.
    func render(_ model: TableModel, endsWithNewline: Bool) -> String {
        var lines: [String] = []
        let header = min(model.headerRowCount, model.rows.count)

        for row in model.rows[0..<header] { lines.append(Self.rowLine(row)) }
        lines.append(Self.delimiterLine(model))
        if header < model.rows.count {
            for row in model.rows[header...] { lines.append(Self.rowLine(row)) }
        }

        return lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }

    private static func rowLine(_ cells: [String]) -> String {
        guard !cells.isEmpty else { return "|  |" }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    private static func delimiterLine(_ model: TableModel) -> String {
        let width = max(model.columnCount, 1)
        let specs = (0..<width).map { column -> String in
            switch model.alignment(forColumn: column) {
            case .none: return "---"
            case .left: return ":---"
            case .center: return ":---:"
            case .right: return "---:"
            }
        }
        return "| " + specs.joined(separator: " | ") + " |"
    }
}
