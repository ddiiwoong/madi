import AppKit
import XCTest

/// **치는 사람의 글자는 절대 사라지지 않는다** — 라이브 프리뷰 편집기의 가장 중요한 약속.
///
/// 마커 숨김은 글자를 폭 0으로 만드는 일이라, 숨길 범위를 한 글자라도 넓게 잡으면
/// 사용자가 친 글이 **흔적도 없이** 없어진다. 되돌릴 수도 없고(글은 저장소에 그대로
/// 있으니 지워지지도 않는다) 무엇이 잘못됐는지 알 수도 없다.
///
/// 실제로 겪었다: 코드 펜스 줄을 **통째로** 마커로 두어서, ``` ``` import ``` 처럼
/// 언어 이름을 적으면 그 줄이 빈 줄로 보였다. 사용자 신고는 "코드블록 글자가 투명하게
/// 잘 안 보여"였고, 테스트는 286개가 전부 초록이었다.
final class MarkerVisibilityTests: XCTestCase {

    private let syntax = MarkdownSyntax()

    // MARK: 펜스의 언어 이름

    func testFenceInfoStringIsNotPartOfTheHiddenMarker() {
        let text = "``` import \n코드\n```\n" as NSString
        let lines = syntax.scanLines(in: text)
        XCTAssertEqual(lines.first?.kind, .codeFence, "전제: 첫 줄이 펜스")

        guard let fence = lines.first else { return XCTFail("줄이 없다") }
        let infoRange = text.range(of: "import")
        XCTAssertNotEqual(infoRange.location, NSNotFound, "전제: 언어 이름이 있다")

        for marker in fence.markerRanges {
            XCTAssertFalse(NSIntersectionRange(marker, infoRange).length > 0,
                           "언어 이름이 마커에 들어가면 그 글자가 화면에서 사라진다")
        }
        // 백틱은 숨어야 한다.
        let backticks = text.range(of: "```")
        XCTAssertTrue(fence.markerRanges.contains { NSIntersectionRange($0, backticks).length == 3 },
                      "백틱은 마커여야 한다")
    }

    func testFenceWithLanguageKeepsTheLanguageVisible() {
        let text = "```swift\nlet x = 1\n```\n" as NSString
        guard let fence = syntax.scanLines(in: text).first else { return XCTFail("줄이 없다") }
        let language = text.range(of: "swift")
        for marker in fence.markerRanges {
            XCTAssertEqual(NSIntersectionRange(marker, language).length, 0,
                           "`swift`가 숨으면 블록의 언어를 알 길이 없다")
        }
    }

    func testBareFenceHidesTheWholeLine() {
        let text = "```\n코드\n```\n" as NSString
        guard let fence = syntax.scanLines(in: text).first else { return XCTFail("줄이 없다") }
        let hidden = fence.markerRanges.reduce(0) { $0 + $1.length }
        XCTAssertEqual(hidden, 3, "언어 이름이 없으면 백틱 세 개가 전부 마커다")
    }

    // MARK: 스타일러까지 — 실제로 숨는 글자

    /// 스타일을 입힌 뒤 `.mdHiddenMarker`가 붙은 글자를 모은다.
    @MainActor
    private func hiddenCharacters(in markdown: String) -> String {
        let storage = NSTextStorage(string: markdown)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 700, height: 1_000_000))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        MarkdownStyler().style(storage, caretLine: nil, search: MarkdownStyler.SearchState())

        var hidden = ""
        let ns = storage.string as NSString
        for index in 0 ..< ns.length
        where storage.attribute(.mdHiddenMarker, at: index, effectiveRange: nil) != nil {
            hidden.append(contentsOf: ns.substring(with: NSRange(location: index, length: 1)))
        }
        return hidden
    }

    @MainActor
    func testCodeFenceInfoStringSurvivesStyling() {
        let hidden = hiddenCharacters(in: "``` import \n내용\n```swift\n")
        XCTAssertFalse(hidden.contains("import"), "사용자가 친 `import`가 숨었다")
        XCTAssertFalse(hidden.contains("swift"), "언어 이름 `swift`가 숨었다")
        XCTAssertTrue(hidden.contains("```"), "백틱은 숨어야 한다")
    }

    @MainActor
    func testCodeBodyIsNeverHidden() {
        let hidden = hiddenCharacters(in: "```swift\nlet 값 = 1  // 주석\n```\n")
        for fragment in ["let", "값", "주석"] {
            XCTAssertFalse(hidden.contains(fragment), "코드 본문의 `\(fragment)`이 숨었다")
        }
    }

    /// **한글은 어떤 경우에도 숨지 않는다.**
    ///
    /// 한글은 마크다운 구문에 쓰이는 글자가 아니다(`#` · `*` · 백틱 · 괄호뿐). 그래서
    /// 한글이 숨었다면 그것은 구문이 아니라 **사람이 쓴 글**이고, 화면에서 사라진 것이다.
    /// 링크 주소처럼 일부러 숨기는 구간에도 이 코퍼스에는 한글이 없다.
    @MainActor
    func testNoHangulIsEverHidden() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MadiTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
        let documents = ["README.md", "TODO.md", "docs/block-editor-design.md"]
        var checked = 0
        for name in documents {
            let url = repo.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            let hidden = hiddenCharacters(in: text)
            let hangul = hidden.unicodeScalars.filter {
                (0xAC00 ... 0xD7A3).contains($0.value)        // 완성형 음절
                    || (0x1100 ... 0x11FF).contains($0.value) // 자모
                    || (0x3130 ... 0x318F).contains($0.value) // 호환 자모
            }
            XCTAssertTrue(hangul.isEmpty,
                          "\(name)에서 한글 \(hangul.count)자가 숨었다: "
                          + String(String.UnicodeScalarView(hangul.prefix(20))))
        }
        XCTAssertGreaterThan(checked, 0, "코퍼스를 하나도 읽지 못했다 — 테스트가 아무것도 보지 않았다")
    }
}
