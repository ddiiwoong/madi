import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class DocumentSearchTests: XCTestCase {

    func testThresholdsAreTheOnesWeDesignedFor() {
        XCTAssertEqual(DocumentSearch.largeDocumentChars, 180_000)
        XCTAssertEqual(DocumentSearch.bailoutDocumentChars, 250_000)
        XCTAssertEqual(DocumentSearch.debounce, 0.080, accuracy: 0.0001)
        XCTAssertEqual(DocumentSearch.debounceLarge, 0.180, accuracy: 0.0001)
    }

    func testBaselineFindsEveryOccurrence() {
        let ranges = DocumentSearch.matches(in: "ab ab ab" as NSString, query: "ab")
        XCTAssertEqual(ranges.map(\.location), [0, 3, 6])
        XCTAssertEqual(ranges.map(\.length), [2, 2, 2])
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(DocumentSearch.matches(in: "Hello HELLO hello" as NSString, query: "hello").count, 3)
        XCTAssertEqual(DocumentSearch.matches(in: "hello" as NSString, query: "HeLLo").count, 1)
    }

    func testQueryIsTrimmed() {
        XCTAssertEqual(DocumentSearch.normalize("  find  "), "find")
        XCTAssertEqual(DocumentSearch.matches(in: "find me" as NSString, query: "  find  ").count, 1)
    }

    func testMatchesDoNotOverlap() {
        let ranges = DocumentSearch.matches(in: "aaaa" as NSString, query: "aa")
        XCTAssertEqual(ranges.map(\.location), [0, 2])
    }

    func testEmptyQueryMatchesNothing() {
        XCTAssertTrue(DocumentSearch.matches(in: "anything" as NSString, query: "").isEmpty)
        XCTAssertTrue(DocumentSearch.matches(in: "anything" as NSString, query: "   ").isEmpty)
    }

    func testSearchIsLiteralNotRegex() {
        XCTAssertEqual(DocumentSearch.matches(in: "a.c abc" as NSString, query: ".").count, 1)
        XCTAssertTrue(DocumentSearch.matches(in: "abc" as NSString, query: "a.c").isEmpty)
    }

    func testHugeDocumentIgnoresOneCharacterQuery() {
        let huge = DocumentSearch.bailoutDocumentChars + 1
        XCTAssertFalse(DocumentSearch.shouldSearch(documentLength: huge, query: "a"))
        XCTAssertTrue(DocumentSearch.shouldSearch(documentLength: huge, query: "ab"))
        XCTAssertTrue(DocumentSearch.shouldSearch(documentLength: DocumentSearch.bailoutDocumentChars,
                                                  query: "a"))
    }

    func testDebounceRelaxesOnlyAboveTheThreshold() {
        XCTAssertEqual(DocumentSearch.debounce(forDocumentLength: 0), DocumentSearch.debounce)
        XCTAssertEqual(DocumentSearch.debounce(forDocumentLength: DocumentSearch.largeDocumentChars),
                       DocumentSearch.debounce)
        XCTAssertEqual(DocumentSearch.debounce(forDocumentLength: DocumentSearch.largeDocumentChars + 1),
                       DocumentSearch.debounceLarge)
    }

    func testKoreanMatchingWorksOnUTF16Offsets() {
        let text = "검색 기능 검색" as NSString
        let ranges = DocumentSearch.matches(in: text, query: "검색")
        XCTAssertEqual(ranges.count, 2)
        for range in ranges {
            XCTAssertEqual(text.substring(with: range), "검색")
        }
    }

    func testMutationGuardAdvanceByLengthIsWhatPreventsOverlap() {
        // Proof the non-overlap assertion is not vacuous: advancing by one
        // instead of the query length yields three matches for "aaaa"/"aa".
        let text = "aaaa" as NSString
        var overlapping = 0
        var start = 0
        while start < text.length {
            let found = text.range(of: "aa", options: [],
                                   range: NSRange(location: start, length: text.length - start))
            guard found.location != NSNotFound else { break }
            overlapping += 1
            start = found.location + 1
        }
        XCTAssertEqual(overlapping, 3)
        XCTAssertEqual(DocumentSearch.matches(in: text, query: "aa").count, 2)
    }
}
