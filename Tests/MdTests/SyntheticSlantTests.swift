import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class SyntheticSlantTests: XCTestCase {

    private func slanted(_ string: String) -> [String] {
        let text = string as NSString
        return SyntheticSlant.ranges(in: text, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0) }
    }

    // MARK: 어떤 글자가 강제 기울임을 받는가

    func testKoreanNeedsSlant() {
        XCTAssertEqual(slanted("기울임"), ["기울임"])
    }

    func testLatinAndDigitsDoNotNeedSlant() {
        // 이들은 진짜 기울임꼴을 받는다. 거기에 강제 기울임까지 주면 두 번 기운다.
        XCTAssertTrue(slanted("italic").isEmpty)
        XCTAssertTrue(slanted("12345").isEmpty)
        XCTAssertTrue(slanted("a1-b2_c3").isEmpty)
    }

    func testOtherCjkScriptsNeedSlantToo() {
        // 실측에서 일본어·중국어도 italic 글꼴이 먹지 않았다.
        XCTAssertEqual(slanted("斜体"), ["斜体"])
        XCTAssertEqual(slanted("かたむき"), ["かたむき"])
        XCTAssertEqual(slanted("カタカナ"), ["カタカナ"])
    }

    func testEmojiIsNotSlanted() {
        // 기울인 이모지는 어색하다.
        XCTAssertTrue(slanted("🎉🙂").isEmpty)
    }

    // MARK: 섞인 글

    func testMixedTextYieldsOnlyTheCjkRuns() {
        XCTAssertEqual(slanted("hello 기울임 world"), ["기울임"])
    }

    func testSeveralRunsAreReportedSeparately() {
        XCTAssertEqual(slanted("가 a 나 b 다"), ["가", "나", "다"])
    }

    func testAdjacentCjkCharactersAreOneRun() {
        // 이어진 글자를 한 범위로 묶어야 속성 쓰기 횟수가 글자 수만큼 늘지 않는다.
        let text = "한국어문장입니다" as NSString
        let ranges = SyntheticSlant.ranges(in: text,
                                           range: NSRange(location: 0, length: text.length))
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.length, text.length)
    }

    // MARK: 경계

    func testRangesStayInsideTheGivenRange() {
        let text = "가나다라마" as NSString
        let window = NSRange(location: 1, length: 2)
        let ranges = SyntheticSlant.ranges(in: text, range: window)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first, window)
    }

    func testEmptyAndOutOfBoundsRangesAreSafe() {
        let text = "가" as NSString
        XCTAssertTrue(SyntheticSlant.ranges(in: text, range: NSRange(location: 0, length: 0)).isEmpty)
        XCTAssertTrue(SyntheticSlant.ranges(in: text, range: NSRange(location: 0, length: 99)).isEmpty)
    }

    func testSurrogatePairIsReadAsOneCharacter() {
        // 확장 한자는 UTF-16 두 단위다. 앞 단위만 보면 엉뚱한 글자로 읽힌다.
        let extended = "\u{20000}"      // 한자 확장 B
        XCTAssertEqual(slanted(extended), [extended])
        let mixed = "a\u{20000}b"
        XCTAssertEqual(slanted(mixed), [extended])
    }

    func testTheObliquenessValueIsTheOneWeMeasured() {
        XCTAssertEqual(SyntheticSlant.obliqueness, 0.2, accuracy: 0.0001)
    }
}
