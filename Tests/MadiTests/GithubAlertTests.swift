import XCTest
// Core 소스는 이 번들에 직접 컴파일된다 — import가 필요 없다.

/// `> [!NOTE]` 알림 판정 — MarkText(Muya)의 규칙을 그대로 따른다.
final class GithubAlertTests: XCTestCase {

    private let syntax = MarkdownSyntax()

    func testEveryTypeIsRecognised() {
        for alert in GithubAlert.allCases {
            XCTAssertEqual(GithubAlert.marker(inQuoteContent: "[!\(alert.rawValue)]"), alert)
        }
        XCTAssertEqual(GithubAlert.allCases.count, 5, "GitHub가 정한 다섯 종류")
    }

    func testCaseAndWhitespaceAreIgnored() {
        XCTAssertEqual(GithubAlert.marker(inQuoteContent: "[!note]"), .note)
        XCTAssertEqual(GithubAlert.marker(inQuoteContent: "  [!Warning]  "), .warning)
        XCTAssertEqual(GithubAlert.marker(inQuoteContent: "[!tIp]"), .tip)
    }

    func testEscapedBracketsStillCount() {
        // 사용자가 `\[!NOTE\]`로 escape해 두어도 GitHub는 알림으로 읽는다.
        XCTAssertEqual(GithubAlert.marker(inQuoteContent: "\\[!NOTE\\]"), .note)
    }

    func testNonMarkersAreRejected() {
        for content in ["[!UNKNOWN]", "[NOTE]", "[!NOTE] 뒤에 글", "노트", "[!]", ""] {
            XCTAssertNil(GithubAlert.marker(inQuoteContent: content),
                         "`\(content)`을 알림으로 읽으면 보통 인용이 색칠된다")
        }
    }

    func testTitleIsHumanReadable() {
        XCTAssertEqual(GithubAlert.note.title, "Note")
        XCTAssertEqual(GithubAlert.important.title, "Important")
    }

    // MARK: 덩이 단위

    func testWholeQuoteRunInheritsTheAlert() {
        let text = "> [!WARNING]\n> 첫 줄.\n> 둘째 줄.\n" as NSString
        let lines = syntax.scanLines(in: text)
        let map = GithubAlert.map(lines: lines, in: text)
        XCTAssertEqual(map.count, 3, "표식 줄과 뒤따르는 인용 줄 모두가 알림이다")
        for index in 0 ..< 3 {
            XCTAssertEqual(map[index], .warning)
        }
    }

    func testAPlainQuoteAfterAnAlertDoesNotInheritTheColour() {
        let text = "> [!NOTE]\n> 알림.\n\n> 보통 인용.\n" as NSString
        let lines = syntax.scanLines(in: text)
        let map = GithubAlert.map(lines: lines, in: text)
        XCTAssertEqual(map[0], .note)
        XCTAssertEqual(map[1], .note)
        XCTAssertNil(map[2], "빈 줄은 덩이를 끝낸다")
        XCTAssertNil(map[3], "빈 줄 뒤의 인용은 다른 덩이다 — 색을 물려받으면 안 된다")
    }

    func testAMarkerThatIsNotFirstDoesNotMakeAnAlert() {
        let text = "> 먼저 글.\n> [!NOTE]\n" as NSString
        let lines = syntax.scanLines(in: text)
        XCTAssertTrue(GithubAlert.map(lines: lines, in: text).isEmpty,
                      "표식은 인용의 첫 줄에만 뜻이 있다")
    }

    func testPlainDocumentHasNoAlerts() {
        let text = "# 제목\n\n보통 글.\n" as NSString
        XCTAssertTrue(GithubAlert.map(lines: syntax.scanLines(in: text), in: text).isEmpty)
    }
}
