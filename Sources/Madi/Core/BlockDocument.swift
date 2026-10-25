import Foundation

/// 블록 편집기의 문서 모델 — `docs/block-editor-design.md` §3.
///
/// 표를 격자로 편집하려면 문서가 선형 텍스트가 아니라 **블록의 배열**이어야 한다.
/// 이 파일은 그 모델만 둔다. UI는 없고 Foundation만 쓴다(`make core-only`가 지킨다).
///
/// ## 설계 문서와 다른 점
///
/// 설계는 최상위 `BlockKind`를 쓰라고 적었지만 그 이름은 이미
/// `MarkdownSyntax`에서 **줄 하나의 종류**로 쓰이고 있다(`.codeBody`, `.tableDelimiter` …).
/// 둘은 다른 층위다 — 줄 종류는 스타일러가 한 줄을 칠할 때 쓰고, 여기 있는 것은
/// 문서를 이루는 덩어리다. 같은 이름을 두면 어느 쪽인지 읽는 사람이 매번 확인해야
/// 하므로 `Block.Kind`로 중첩했다.
///
/// ## 바이트 동일 왕복이 성립하는 이유
///
/// 모든 블록은 자기를 만든 **원문 조각을 줄바꿈까지 그대로** 들고 있고, 문서는 그
/// 조각들의 단순 이어붙이기다. 그래서 고치지 않은 문서는 재직렬화해도 바이트가
/// 같다 — 파서가 이해하지 못한 구문(HTML 덩어리, 각주, 낯선 확장)도 마찬가지다.
/// 모델에서 **고친 블록만** 다시 그린다. front matter에서 이미 택한 원칙과 같다.
public struct BlockDocument: Equatable {

    /// front matter는 이미 구현된 것을 그대로 쓴다. 없으면 nil이다.
    public var frontMatter: FrontMatter?
    public var blocks: [Block]

    public init(frontMatter: FrontMatter?, blocks: [Block]) {
        self.frontMatter = frontMatter
        self.blocks = blocks
    }

    /// 고친 블록이 하나라도 있는가. 저장이 원문을 다시 쓸지 가리는 데 쓴다.
    public var hasModifiedBlocks: Bool { blocks.contains(where: \.isModified) }

    public subscript(id: Block.ID) -> Block? {
        get { blocks.first { $0.id == id } }
        set {
            guard let newValue, let index = blocks.firstIndex(where: { $0.id == id })
            else { return }
            blocks[index] = newValue
        }
    }
}

// MARK: - 블록

public struct Block: Identifiable, Equatable {

    public struct ID: Hashable, Sendable {
        public let raw: UUID
        public init(raw: UUID = UUID()) { self.raw = raw }
    }

    /// 문서를 이루는 덩어리의 종류.
    ///
    /// 설계 §3의 목록에서 `.image`와 `.html`은 **아직 없다.** 이미지는 설계가 단계 4로
    /// 미뤘고, HTML 덩어리는 따로 종류를 만들 필요가 없다 — 어떤 블록이든 원문 조각을
    /// 그대로 들고 있어서 `.paragraph`로 분류돼도 저장될 때 글자 하나까지 복원된다.
    /// 종류를 더하는 것은 **그것을 다르게 그릴 뷰가 생길 때**다.
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        case quote
        case list(ordered: Bool)
        case codeBlock(language: String?)
        case table(TableModel)
        case thematicBreak
        /// 빈 줄의 연속. 블록 사이의 간격도 문서의 일부라서 모델에 있어야 한다 —
        /// 없으면 이어붙이기가 원문과 달라진다(설계가 적지 않았던 종류다).
        case blankLines
    }

    public let id: ID
    public private(set) var kind: Kind
    /// 이 블록을 만든 원문. **줄바꿈과 뒤따르는 빈 줄까지 그대로** 들어 있다.
    public private(set) var sourceSlice: String
    /// 모델이 원문과 갈라졌는가. 직렬화는 이 값이 참인 블록만 다시 그린다.
    public private(set) var isModified: Bool

    public init(id: ID = ID(), kind: Kind, sourceSlice: String, isModified: Bool = false) {
        self.id = id
        self.kind = kind
        self.sourceSlice = sourceSlice
        self.isModified = isModified
    }

    /// 같은 문서를 두 번 파싱하면 `id`는 매번 새로 생긴다. 그래서 동등성에서 빼야
    /// 왕복 테스트가 모델을 비교할 수 있다 — `id`는 뷰가 블록을 다시 찾는 열쇠이고
    /// 내용의 일부가 아니다.
    public static func == (lhs: Block, rhs: Block) -> Bool {
        lhs.kind == rhs.kind
            && lhs.sourceSlice == rhs.sourceSlice
            && lhs.isModified == rhs.isModified
    }

    /// 표를 고친다. 표가 아닌 블록에서는 아무 일도 하지 않고 거짓을 돌려준다.
    @discardableResult
    public mutating func mutateTable(_ body: (inout TableModel) -> Void) -> Bool {
        guard case .table(var model) = kind else { return false }
        let before = model
        body(&model)
        guard model != before else { return false }
        kind = .table(model)
        isModified = true
        return true
    }
}

// MARK: - 표

/// 표 하나를 **칸의 글자**로 들고 있는 모델.
///
/// `MarkdownTable`과 역할이 다르다. 그쪽은 원문 안의 **위치**(NSRange)를 알려 줘서
/// 스타일러가 열을 맞추는 데 쓰고, 이쪽은 격자 편집이 고칠 **값**을 들고 있다.
/// 둘을 합치지 않은 이유는 수명이 다르기 때문이다 — 위치는 한 글자만 쳐도 전부 밀리고,
/// 값은 사용자가 고칠 때만 바뀐다.
public struct TableModel: Equatable, Sendable {

    public typealias Alignment = MarkdownTable.Alignment

    /// 열별 정렬. 구분 행이 말해 준다.
    public var alignments: [Alignment]
    /// 칸의 글자를 **원문 그대로** 담는다(`\|`처럼 escape된 상태 그대로).
    /// 사람이 읽는 글자는 `plainText(row:column:)`가 준다.
    public var rows: [[String]]
    /// 구분 행 **앞**에 있는 행의 수. 보통 1이지만 머리글을 두 줄 쓴 표가 현실에 있고,
    /// 그런 표를 고쳤을 때 머리글이 본문으로 떨어지지 않게 하려면 기억해야 한다.
    public var headerRowCount: Int

    public init(alignments: [Alignment], rows: [[String]], headerRowCount: Int = 1) {
        self.alignments = alignments
        self.rows = rows
        self.headerRowCount = headerRowCount
    }

    public var columnCount: Int { rows.map(\.count).max() ?? alignments.count }

    public func alignment(forColumn column: Int) -> Alignment {
        column < alignments.count ? alignments[column] : .none
    }

    // MARK: 읽기

    /// 사람이 읽는 칸의 글자. `\|`를 막대로, `\\`를 역슬래시로 되돌린다.
    public func plainText(row: Int, column: Int) -> String? {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
        return Self.unescape(rows[row][column])
    }

    // MARK: 고치기

    /// 칸의 글자를 바꾼다. 막대와 줄바꿈은 표를 깨뜨리므로 여기서 막는다 —
    /// 막대는 escape하고 줄바꿈은 공백으로 바꾼다. 호출하는 쪽이 기억해야 하는 규칙을
    /// 두지 않으려는 것이다.
    @discardableResult
    public mutating func setCell(row: Int, column: Int, plainText: String) -> Bool {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return false }
        rows[row][column] = Self.escape(plainText)
        return true
    }

    /// 행을 넣는다. 칸 수는 현재 열 수에 맞춘다.
    @discardableResult
    public mutating func insertRow(at index: Int) -> Bool {
        guard index >= 0, index <= rows.count, index >= headerRowCount else { return false }
        rows.insert(Array(repeating: "", count: max(1, columnCount)), at: index)
        return true
    }

    /// 행을 뺀다. 머리글 행은 뺄 수 없다 — 머리글이 없는 마크다운 표는 없다.
    @discardableResult
    public mutating func removeRow(at index: Int) -> Bool {
        guard rows.indices.contains(index), index >= headerRowCount else { return false }
        rows.remove(at: index)
        return true
    }

    /// 열을 넣는다. 모든 행과 정렬 목록에 같은 자리로 들어가야 한다 — 한쪽만 넣으면
    /// 정렬이 옆 열로 밀린다.
    @discardableResult
    public mutating func insertColumn(at index: Int) -> Bool {
        let width = columnCount
        guard index >= 0, index <= width else { return false }
        for row in rows.indices {
            let clamped = min(index, rows[row].count)
            rows[row].insert("", at: clamped)
        }
        let alignmentIndex = min(index, alignments.count)
        alignments.insert(.none, at: alignmentIndex)
        return true
    }

    @discardableResult
    public mutating func removeColumn(at index: Int) -> Bool {
        guard index >= 0, index < columnCount, columnCount > 1 else { return false }
        for row in rows.indices where rows[row].indices.contains(index) {
            rows[row].remove(at: index)
        }
        if alignments.indices.contains(index) { alignments.remove(at: index) }
        return true
    }

    // MARK: escape

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "|": out += "\\|"
            case "\n", "\r": out += " "
            default: out.append(character)
            }
        }
        return out
    }

    static func unescape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var escaped = false
        for character in text {
            if escaped {
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        if escaped { out.append("\\") }
        return out
    }
}
