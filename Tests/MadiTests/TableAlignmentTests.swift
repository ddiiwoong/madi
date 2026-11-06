import AppKit
import XCTest

/// 표 열 맞추기 — **그려진 막대의 자리**가 모든 행에서 같은지.
///
/// 전에는 이 기능을 그림으로 확인할 시험이 없었다(표 파서만 `MarkdownTableTests`가 본다).
/// README 그림을 찍다가 구분 행 `|:---|:---:|---:|`의 막대가 다른 행보다 왼쪽에 서 있는 것을
/// 보고서야 알았다 — 칸의 글만 재고 둘레의 공백을 재지 않아서였다.
@MainActor
final class TableAlignmentTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    /// 행마다 막대의 x. 캐럿은 **표 안**(첫 행의 처음)에 둔다 — 표 밖에 캐럿이 있으면 표는 원문이
    /// 아니라 격자로 그려진다(`TableGridTests`). 열 맞추기는 표를 고치는 동안 보이는 원문의 일이다.
    /// 시험 표의 칸에는 인라인 마크업이 없어, 캐럿이 있는 행도 마커 때문에 넓어지지 않는다.
    private func barPositions(_ markdown: String) -> [[CGFloat]] {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 720, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 720, height: 400))
        window.contentView = editor
        window.orderBack(nil)
        windows.append(window)
        editor.markdown = markdown
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.drawnTableCount, 0, "전제: 캐럿이 든 표는 원문이다")
        let layout = editor.textView.layoutManager!
        layout.ensureLayout(for: editor.textView.textContainer!)

        let text = editor.textView.string as NSString
        var rows: [[CGFloat]] = []
        var start = 0
        while start < text.length {
            let line = text.lineRange(for: NSRange(location: start, length: 0))
            var bars: [CGFloat] = []
            for index in line.location ..< NSMaxRange(line) where text.character(at: index) == 0x7C {
                bars.append(layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: index)).x)
            }
            if !bars.isEmpty { rows.append(bars) }
            start = NSMaxRange(line)
        }
        return rows
    }

    private func assertAligned(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) {
        let rows = barPositions(markdown)
        XCTAssertGreaterThanOrEqual(rows.count, 3, "전제: 표 행이 셋 이상", file: file, line: line)
        guard let first = rows.first else { return }
        // 전제: 막대 사이가 실제로 벌어져 있다 — 다 0이면 아래 비교가 아무것도 보지 않는다.
        XCTAssertGreaterThan(first.last ?? 0, 50, file: file, line: line)
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(row.count, first.count, "행 \(index)의 막대 수", file: file, line: line)
            for (column, x) in row.enumerated() where column < first.count {
                XCTAssertEqual(x, first[column], accuracy: 0.6,
                               "행 \(index)의 막대 \(column): \(row) / 첫 행 \(first)", file: file, line: line)
            }
        }
    }

    /// 구분 행을 공백 없이 쓴 표 — 흔한 꼴이고, 고치기 전에 어긋났던 꼴이다.
    func testDelimiterRowWithoutSpacesLinesUp() {
        assertAligned("""
        | 기능 | 단축키 | 상태 |
        |:---|:---:|---:|
        | 원본 보기 | ⌘E | 있음 |
        | 번역 | ⌘⇧T | 있음 |

        """)
    }

    /// 행마다 공백이 제각각인 표.
    func testIrregularSpacingLinesUp() {
        assertAligned("""
        |a|bb|ccc|
        | --- | --- | --- |
        |   길게 쓴 칸   | x |y|
        | 가 |나|   다 |

        """)
    }

    /// 공백을 넣어 가지런히 쓴 표는 전부터 맞았다 — 고치면서 깨지지 않았는지.
    func testWellSpacedTableStillLinesUp() {
        assertAligned("""
        | 이름 | 값 |
        | --- | --- |
        | 하나 | 1 |
        | 아주 긴 이름 | 1234 |

        """)
    }

    /// 빈 칸이 있는 표.
    func testEmptyCellsLineUp() {
        assertAligned("""
        | 가 | 나 | 다 |
        |---|---|---|
        |  | 값 |  |
        | 긴 글 |  | 끝 |

        """)
    }
}
