import Foundation
import XCTest

/// `madi://` 주소 읽기(`MadiURL`) — 명령 셋(open · new · append), 값, 경로, 거절.
final class MadiURLTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/someone")

    private func parse(_ string: String, file: StaticString = #filePath, line: UInt = #line)
        -> Result<MadiURL.Command, MadiURL.Failure>? {
        guard let url = MadiURL.url(from: string) else {
            XCTFail("시험의 전제 — URL로 읽힌다: \(string)", file: file, line: line)
            return nil
        }
        return MadiURL.parse(url, home: home)
    }

    // MARK: open

    func testOpenTakesAbsoluteHomeAndFileURLPaths() {
        XCTAssertEqual(parse("madi://open?path=/Users/someone/글/메모.md"),
                       .success(.open(file: URL(fileURLWithPath: "/Users/someone/글/메모.md"), line: nil, search: nil)))
        XCTAssertEqual(parse("madi://open?path=~/글/메모.md"),
                       .success(.open(file: URL(fileURLWithPath: "/Users/someone/글/메모.md"), line: nil, search: nil)),
                       "~/는 집 폴더")
        XCTAssertEqual(parse("madi://open?path=file:///tmp/a.markdown"),
                       .success(.open(file: URL(fileURLWithPath: "/tmp/a.markdown"), line: nil, search: nil)))
        XCTAssertEqual(parse("madi://open?path=%2FUsers%2Fsomeone%2F%EB%A9%94%EB%AA%A8%20%EB%91%98.md"),
                       .success(.open(file: URL(fileURLWithPath: "/Users/someone/메모 둘.md"), line: nil, search: nil)),
                       "퍼센트 부호를 푼다")
    }

    func testOpenReadsLineAndSearch() {
        XCTAssertEqual(parse("madi://open?path=/a/b.md&line=42&search=%EB%A7%88%EB%94%94"),
                       .success(.open(file: URL(fileURLWithPath: "/a/b.md"), line: 42, search: "마디")))
        XCTAssertEqual(parse("madi://open?path=/a/b.md&line=0"), .failure(.badLine("0")))
        XCTAssertEqual(parse("madi://open?path=/a/b.md&line=셋"), .failure(.badLine("셋")))
        XCTAssertEqual(parse("madi://open?path=/a/b.md&search="),
                       .success(.open(file: URL(fileURLWithPath: "/a/b.md"), line: nil, search: nil)), "빈 낱말은 없는 것")
    }

    /// 명령은 `madi://open`, `madi:open`, `madi:///open` 어느 꼴로 적어도 같다. 대소문자도 가리지 않는다.
    func testActionCanBeHostOrPath() {
        let expected = MadiURL.Command.open(file: URL(fileURLWithPath: "/a/b.md"), line: nil, search: nil)
        XCTAssertEqual(parse("madi:open?path=/a/b.md"), .success(expected))
        XCTAssertEqual(parse("madi:///open?path=/a/b.md"), .success(expected))
        XCTAssertEqual(parse("MADI://OPEN?path=/a/b.md"), .success(expected))
    }

    // MARK: new · append

    func testNewTakesTextAndTitle() {
        XCTAssertEqual(parse("madi://new?text=%EC%B2%AB%20%EC%A4%84%0A%EB%91%98%EC%A7%B8&title=%ED%9A%8C%EC%9D%98"),
                       .success(.new(text: "첫 줄\n둘째", title: "회의")))
        XCTAssertEqual(parse("madi://new"), .success(.new(text: "", title: nil)), "글 없이 — 빈 새 문서")
        XCTAssertEqual(parse("madi://new?text=a+b"), .success(.new(text: "a+b", title: nil)),
                       "+는 공백이 아니다(웹 폼의 약속이고 URL의 약속이 아니다)")
    }

    /// `path`를 주면 그 자리의 새 파일 — 경로 규칙은 open · append와 같다.
    func testNewWithPathNamesTheFileToCreate() {
        XCTAssertEqual(parse("madi://new?path=~/글/새 글.md&title=제목"),
                       .success(.new(text: "", title: "제목", file: URL(fileURLWithPath: "/Users/someone/글/새 글.md"))))
        XCTAssertEqual(parse("madi://new?path=~/.zshrc&text=x"), .failure(.unsupportedFile("/Users/someone/.zshrc")))
        XCTAssertEqual(parse("madi://new?path=글/새.md"), .failure(.relativePath("글/새.md")))
        XCTAssertEqual(parse("madi://new?path="), .failure(.missing("path")), "적었으면 비우지 않는다")
    }

    func testNewDocumentText() {
        XCTAssertEqual(MadiURL.newDocumentText("본문", title: "제목", asFile: false), "# 제목\n\n본문")
        XCTAssertEqual(MadiURL.newDocumentText("본문", title: "제목", asFile: true), "# 제목\n\n본문\n", "파일은 줄바꿈으로 맺는다")
        XCTAssertEqual(MadiURL.newDocumentText("", title: "제목", asFile: true), "# 제목\n\n", "제목만 — 그 아래 빈 줄에서 쓴다")
        XCTAssertEqual(MadiURL.newDocumentText("본문\n", title: nil, asFile: true), "본문\n")
        XCTAssertEqual(MadiURL.newDocumentText("", title: nil, asFile: true), "", "빈 파일은 비운다")
    }

    func testAppendNeedsAFileAndText() {
        XCTAssertEqual(parse("madi://append?path=~/할일.md&text=-%20%5B%20%5D%20%EC%9A%B0%EC%9C%A0"),
                       .success(.append(file: URL(fileURLWithPath: "/Users/someone/할일.md"), text: "- [ ] 우유")))
        XCTAssertEqual(parse("madi://append?path=~/할일.md"), .failure(.missing("text")))
        XCTAssertEqual(parse("madi://append?text=a"), .failure(.missing("path")))
    }

    /// 셸에 적은 그대로 — 한글 · 공백 · `#` · `[ ]`가 날것으로 섞이고 `%XX`도 섞인 주소. `URL(string:)`은 이런 글에서 이미
    /// 적힌 `%`까지 다시 싸서 값에 `%20` 글자가 남는다(이 시험이 처음 잡은 것).
    func testHandTypedAddressesKeepTheirEscapes() {
        XCTAssertEqual(parse("madi://new?text=회의%20메모"), .success(.new(text: "회의 메모", title: nil)))
        XCTAssertEqual(parse("madi://new?text=회의 메모&title=오늘"), .success(.new(text: "회의 메모", title: "오늘")))
        XCTAssertEqual(parse("madi://new?text=# 제목\n- [ ] 우유"), .success(.new(text: "# 제목\n- [ ] 우유", title: nil)),
                       "#은 조각이 아니라 글이다")
        XCTAssertEqual(parse("madi://new?text=100%"), .success(.new(text: "100%", title: nil)), "짝 없는 %는 글자")
        XCTAssertEqual(parse("madi://new?text=a%2Bb%26c"), .success(.new(text: "a+b&c", title: nil)),
                       "싼 &는 값을 가르지 않는다")
        XCTAssertEqual(MadiURL.url(from: "madi://open?path=/a/b.md")?.absoluteString, "madi://open?path=/a/b.md",
                       "ASCII 주소는 손대지 않는다")
    }

    // MARK: 거절

    /// 링크는 웹 페이지도 누를 수 있다 — 마크다운 · 글 파일이 아닌 것, 상대 경로는 받지 않는다. 확장자는 `..`를 푼 뒤의
    /// 경로로 따진다.
    func testRejectsNonMarkdownRelativeAndTraversingPaths() {
        XCTAssertEqual(parse("madi://append?path=~/.ssh/authorized_keys&text=x"),
                       .failure(.unsupportedFile("/Users/someone/.ssh/authorized_keys")))
        XCTAssertEqual(parse("madi://open?path=/etc/hosts"), .failure(.unsupportedFile("/etc/hosts")))
        XCTAssertEqual(parse("madi://open?path=글/메모.md"), .failure(.relativePath("글/메모.md")))
        XCTAssertEqual(parse("madi://open?path=/a/b.md/../../etc/passwd"), .failure(.unsupportedFile("/etc/passwd")))
        XCTAssertEqual(parse("madi://open?path=/a/./b/../c.md"),
                       .success(.open(file: URL(fileURLWithPath: "/a/c.md"), line: nil, search: nil)))
    }

    func testRejectsOtherSchemesAndUnknownActions() {
        XCTAssertEqual(parse("https://example.com/open?path=/a.md"), .failure(.notMadi))
        XCTAssertEqual(parse("madi://delete?path=/a.md"), .failure(.unknownAction("delete")))
        XCTAssertEqual(parse("madi://"), .failure(.noAction))
        XCTAssertFalse(MadiURL.Failure.unknownAction("delete").message.isEmpty)
    }

    // MARK: 끝에 더하기

    private func appended(_ text: String, to body: String) -> String {
        let edit = MadiURL.appendEdit(text, to: body)
        return (body as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    func testAppendSeparatesParagraphsWithOneBlankLine() {
        XCTAssertEqual(appended("둘째", to: "첫 문단"), "첫 문단\n\n둘째\n")
        XCTAssertEqual(appended("둘째", to: "첫 문단\n"), "첫 문단\n\n둘째\n")
        XCTAssertEqual(appended("둘째\n", to: "첫 문단\n\n"), "첫 문단\n\n둘째\n", "이미 빈 줄이면 더 띄우지 않는다")
        XCTAssertEqual(appended("첫 글", to: ""), "첫 글\n")
        let edit = MadiURL.appendEdit("둘째", to: "첫 문단")
        XCTAssertEqual(edit.selection, NSRange(location: ("첫 문단\n\n둘째\n" as NSString).length, length: 0), "캐럿은 더한 글 뒤")
    }

    /// 할 일 목록에 할 일을 더하면 같은 목록의 다음 항목 — 빈 줄을 두지 않는다(앱에서 처음 본 것: 빈 줄이 끼어 목록이
    /// 느슨해졌다).
    func testAppendContinuesAListWithoutABlankLine() {
        XCTAssertEqual(appended("- [ ] 우유\n- [ ] 달걀", to: "# 할 일\n\n- [ ] 빵\n"),
                       "# 할 일\n\n- [ ] 빵\n- [ ] 우유\n- [ ] 달걀\n")
        XCTAssertEqual(appended("2. 둘", to: "1. 하나"), "1. 하나\n2. 둘\n")
        XCTAssertEqual(appended("문단", to: "- 항목\n"), "- 항목\n\n문단\n", "목록 뒤의 문단은 띄운다")
        XCTAssertEqual(appended("- 항목", to: "문단\n"), "문단\n\n- 항목\n", "문단 뒤의 목록도 띄운다")
        XCTAssertEqual(appended("- 둘", to: "- 하나\n\n"), "- 하나\n\n- 둘\n", "적어 둔 빈 줄은 그대로 둔다")
    }

    // MARK: 줄 번호

    func testLineLocations() {
        let text = "가\n나다\n라" as NSString
        XCTAssertEqual(MadiURL.location(ofLine: 1, in: text), 0)
        XCTAssertEqual(MadiURL.location(ofLine: 2, in: text), 2)
        XCTAssertEqual(MadiURL.location(ofLine: 3, in: text), 5)
        XCTAssertEqual(MadiURL.location(ofLine: 9, in: text), 5, "줄이 모자라면 마지막 줄")
        XCTAssertEqual(MadiURL.location(ofLine: 3, in: "가\n나\n" as NSString), 4, "끝 줄바꿈 뒤의 빈 줄")
        XCTAssertEqual(MadiURL.location(ofLine: 4, in: "" as NSString), 0)
        XCTAssertEqual(MadiURL.bodyLine(forFileLine: 6, frontMatterLines: 4), 2)
        XCTAssertEqual(MadiURL.bodyLine(forFileLine: 2, frontMatterLines: 4), 1, "front matter 안이면 본문 첫 줄")
    }
}
