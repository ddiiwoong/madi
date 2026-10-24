import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

/// 기울임 구분자 규칙. `*`와 `_`는 CommonMark에서 규칙이 다르고, 그 차이가
/// 한국어에서 특히 크게 드러난다.
final class EmphasisRuleTests: XCTestCase {

    private func emphasised(_ line: String) -> [String] {
        let text = line as NSString
        let whole = NSRange(location: 0, length: text.length)
        return MarkdownSyntax().scanInline(in: text, range: whole)
            .filter { $0.kind == .emphasis }
            .map { text.substring(with: $0.contentRange) }
    }

    // MARK: 한국어 — 조사가 바로 붙는다

    func testKoreanParticleRightAfterTheClosingStar() {
        // 실측된 결함: `은`이 낱말 글자라 강조가 아예 인식되지 않았다. 한국어에서
        // 조사는 공백 없이 붙으므로 이것이 막히면 기울임을 거의 쓸 수 없다.
        XCTAssertEqual(emphasised("*기울임*은 서로 달라야 합니다."), ["기울임"])
        XCTAssertEqual(emphasised("보통 글과 *기울인 한글*을 나란히 둡니다."), ["기울인 한글"])
        XCTAssertEqual(emphasised("*강조*와 *다른 강조*가 모두 됩니다."), ["강조", "다른 강조"])
    }

    func testStarEmphasisStillWorksWithSurroundingSpaces() {
        XCTAssertEqual(emphasised("보통 글과 *italic latin* 도 봅니다."), ["italic latin"])
        XCTAssertEqual(emphasised("*斜体* 와 *かたむき* 도"), ["斜体", "かたむき"])
    }

    // MARK: 밑줄은 낱말 안에서 강조하지 않는다

    func testUnderscoreInsideAWordIsNotEmphasis() {
        // `snake_case_name`이 기울어지면 코드 이름이 망가져 보인다. CommonMark도 금지한다.
        XCTAssertTrue(emphasised("snake_case_name 입니다").isEmpty)
        XCTAssertTrue(emphasised("a_b_c").isEmpty)
    }

    func testUnderscoreEmphasisWorksAtWordBoundaries() {
        XCTAssertEqual(emphasised("보통 _기울임_ 보통"), ["기울임"])
    }

    // MARK: 굵게와 섞이지 않는다

    func testStrongIsNotReadAsEmphasis() {
        XCTAssertTrue(emphasised("**굵게**와 보통").isEmpty,
                      "굵게가 기울임으로 읽혔다")
    }

    func testStrongAndEmphasisTogether() {
        let line = "**굵게**와 *기울임*은 다르다"
        XCTAssertEqual(emphasised(line), ["기울임"])
        let text = line as NSString
        let strong = MarkdownSyntax()
            .scanInline(in: text, range: NSRange(location: 0, length: text.length))
            .filter { $0.kind == .strong }
            .map { text.substring(with: $0.contentRange) }
        XCTAssertEqual(strong, ["굵게"])
    }

    // MARK: 내용 안의 다른 구분자

    func testStarEmphasisMayContainUnderscores() {
        XCTAssertEqual(emphasised("*파일 이름은 a_b 입니다*"), ["파일 이름은 a_b 입니다"])
    }

    func testCodeSpanWinsOverEmphasis() {
        // 코드 안의 별표는 강조가 아니다.
        XCTAssertTrue(emphasised("`*코드 속 별표*`").isEmpty)
    }

    func testEmptyEmphasisIsNotMatched() {
        XCTAssertTrue(emphasised("** 와 __ 는 내용이 없다").isEmpty)
    }
}
