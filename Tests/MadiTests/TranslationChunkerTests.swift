import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class TranslationChunkerTests: XCTestCase {

    /// 자리표의 기본 꼴(`TokenForm.braces`) — `{{0}}`.
    private let open = "{{"
    private let close = "}}"

    private func occurrences(_ marker: String, in text: String) -> Int {
        text.components(separatedBy: marker).count - 1
    }

    // MARK: 불변식 1 — 글자를 잃거나 더하지 않는다

    func testBaselineShortTextIsOneChunk() {
        XCTAssertEqual(TranslationChunker.split("짧은 글입니다."), ["짧은 글입니다."])
        XCTAssertEqual(TranslationChunker.split(""), [])
    }

    func testJoinedChunksEqualTheInput() {
        let sentence = "이것은 문장 하나입니다. "
        let long = String(repeating: sentence, count: 200)   // 약 4,000자
        let chunks = TranslationChunker.split(long, limit: 800)
        XCTAssertGreaterThan(chunks.count, 1, "쪼개지지 않았다")
        XCTAssertEqual(chunks.joined(), long)
    }

    func testEachChunkStaysUnderTheLimitWhenBoundariesAllow() {
        let long = String(repeating: "문장. ", count: 500)
        for chunk in TranslationChunker.split(long, limit: 200) {
            XCTAssertLessThanOrEqual(chunk.count, 200, "조각이 한계를 넘었다: \(chunk.count)자")
        }
    }

    func testAWordLongerThanTheLimitIsSplitByCharacters() {
        // 공백 없는 긴 글(URL·base64)은 글자 경계까지 내려간다.
        let url = String(repeating: "a", count: 300)
        let chunks = TranslationChunker.split(url, limit: 100)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.joined(), url)
    }

    // MARK: 불변식 2 — 자리표를 가르지 않는다

    func testPlaceholdersAreNeverSplit() {
        // 자리표가 쪼개지면 복원이 불가능해진다. 글자 경계까지 내려가는 경우로 몰아 본다.
        let token = "\(open)12\(close)"
        let text = String(repeating: "x", count: 95) + token + String(repeating: "y", count: 95)
        let chunks = TranslationChunker.split(text, limit: 100)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            let opens = occurrences(open, in: chunk)
            let closes = occurrences(close, in: chunk)
            XCTAssertEqual(opens, closes, "자리표가 조각 경계에서 갈렸다: \(chunk.debugDescription)")
        }
    }

    func testPlaceholderHeavyTextStaysRestorable() {
        // 자리표 여러 개가 연달아 있어도 각 조각 안에서 짝이 맞아야 한다.
        var text = ""
        for index in 0 ..< 40 {
            text += "본문 조각 \(index) \(open)\(index)\(close) 이어지는 글. "
        }
        let chunks = TranslationChunker.split(text, limit: 150)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertEqual(occurrences(open, in: chunk), occurrences(close, in: chunk))
        }
    }

    // MARK: 경계 조건

    func testSentenceBoundariesArePreferredOverWordBoundaries() {
        let text = "첫 번째 문장입니다. 두 번째 문장입니다. 세 번째 문장입니다."
        let chunks = TranslationChunker.split(text, limit: 20)
        XCTAssertEqual(chunks.joined(), text)
        // 문장 경계로 갈렸으면 조각 대부분이 마침표로 끝난다.
        let endingWithPeriod = chunks.filter { $0.trimmingCharacters(in: .whitespaces).hasSuffix(".") }
        XCTAssertGreaterThanOrEqual(endingWithPeriod.count, 2, "문장 경계를 쓰지 않았다: \(chunks)")
    }

    func testZeroOrNegativeLimitDoesNotLoopOrLoseText() {
        let text = "짧은 글"
        XCTAssertEqual(TranslationChunker.split(text, limit: 0).joined(), text)
        XCTAssertEqual(TranslationChunker.split(text, limit: -5).joined(), text)
    }

    func testTheLimitConstantIsTheOneWeDesignedFor() {
        XCTAssertEqual(TranslationChunker.characterLimit, 800)
    }
}
