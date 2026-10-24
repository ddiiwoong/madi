import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class ImageEmbedderTests: XCTestCase {

    private let document = URL(fileURLWithPath: "/doc/문서.md")
    /// "PNG"라는 세 바이트. base64로 "UE5H".
    private let bytes = Data("PNG".utf8)

    private func embed(_ markdown: String, loader: ((URL) -> Data?)? = nil,
                       maxBytes: Int = ImageEmbedder.defaultMaxBytes) -> ImageEmbedder.Outcome {
        ImageEmbedder.embed(in: markdown, documentURL: document, maxBytes: maxBytes,
                            loader: loader ?? { _ in self.bytes })
    }

    // MARK: 기본 변환

    func testALocalImageBecomesADataURL() {
        let out = embed("![그림](a.png)\n")
        XCTAssertEqual(out.embedded, 1)
        XCTAssertEqual(out.markdown, "![그림](data:image/png;base64,UE5H)\n")
        XCTAssertTrue(out.skipped.isEmpty)
    }

    func testAltTextAndTitleSurvive() {
        // 주소만 바꿔야 한다 — 대체 글과 제목은 사용자가 쓴 것이다.
        let out = embed("![대체 글](a.png \"제목\")\n")
        XCTAssertEqual(out.embedded, 1)
        XCTAssertTrue(out.markdown.contains("![대체 글]("), out.markdown)
        XCTAssertTrue(out.markdown.contains("\"제목\")"), out.markdown)
    }

    func testSeveralImagesAreAllEmbeddedWithCorrectOffsets() {
        // 앞에서부터 바꾸면 뒤쪽 범위가 어긋난다. 셋을 한꺼번에 걸어 확인한다.
        let out = embed("![가](a.png) 글 ![나](b.png)\n\n![다](c.png)\n")
        XCTAssertEqual(out.embedded, 3)
        XCTAssertEqual(out.markdown.components(separatedBy: "data:image/png;base64,UE5H").count - 1, 3)
        XCTAssertTrue(out.markdown.contains("![가]("), out.markdown)
        XCTAssertTrue(out.markdown.contains("![나]("), out.markdown)
        XCTAssertTrue(out.markdown.contains("![다]("), out.markdown)
    }

    // MARK: 건드리면 안 되는 것

    func testImagesInsideFencedCodeAreLeftAlone() {
        // 코드 블록은 보여 주기 위한 예시다. 그 안의 그림 문법을 바꾸면 사용자가
        // 적어 둔 예시가 망가진다.
        let markdown = """
        ```markdown
        ![예시](a.png)
        ```

        ![진짜](a.png)
        """
        let out = embed(markdown)
        XCTAssertEqual(out.embedded, 1, "코드 블록 안의 그림까지 바꿨다")
        XCTAssertTrue(out.markdown.contains("![예시](a.png)"), "코드 블록 안이 바뀌었다")
        XCTAssertTrue(out.markdown.contains("![진짜](data:image/png;base64,"), out.markdown)
    }

    func testRemoteAddressesAreSkipped() {
        let out = embed("![원격](https://example.com/a.png)\n")
        XCTAssertEqual(out.embedded, 0)
        XCTAssertEqual(out.skipped.first?.reason, .remote)
        XCTAssertEqual(out.markdown, "![원격](https://example.com/a.png)\n", "원문이 바뀌었다")
    }

    func testAlreadyEmbeddedIsSkipped() {
        let markdown = "![박힌](data:image/png;base64,UE5H)\n"
        let out = embed(markdown)
        XCTAssertEqual(out.embedded, 0)
        XCTAssertEqual(out.skipped.first?.reason, .alreadyEmbedded)
        XCTAssertEqual(out.markdown, markdown, "두 번 감싸였다")
    }

    func testUnknownExtensionIsSkipped() {
        // 엉뚱한 MIME을 붙이면 어떤 뷰어에서도 열리지 않는다.
        let out = embed("![무엇](a.xyz)\n")
        XCTAssertEqual(out.embedded, 0)
        XCTAssertEqual(out.skipped.first?.reason, .unknownType)
        XCTAssertEqual(out.markdown, "![무엇](a.xyz)\n")
    }

    func testUnreadableFileIsSkipped() {
        let out = embed("![없음](a.png)\n", loader: { _ in nil })
        XCTAssertEqual(out.embedded, 0)
        XCTAssertEqual(out.skipped.first?.reason, .unreadable)
        XCTAssertEqual(out.markdown, "![없음](a.png)\n")
    }

    func testTooLargeIsSkipped() {
        let out = embed("![큰](a.png)\n", loader: { _ in Data(count: 100) }, maxBytes: 10)
        XCTAssertEqual(out.embedded, 0)
        XCTAssertEqual(out.skipped.first?.reason, .tooLarge)
    }

    func testRelativePathWithoutADocumentIsSkipped() {
        let out = ImageEmbedder.embed(in: "![가](a.png)\n", documentURL: nil,
                                      loader: { _ in self.bytes })
        XCTAssertEqual(out.embedded, 0)
        XCTAssertEqual(out.skipped.first?.reason, .unresolved)
    }

    func testPlainLinksAreNotTouched() {
        // 링크는 그림이 아니다.
        let markdown = "[링크](a.png) 그리고 [문서](b.md)\n"
        XCTAssertEqual(embed(markdown).markdown, markdown)
        XCTAssertEqual(embed(markdown).embedded, 0)
    }

    func testInlineCodeImageSyntaxIsNotTouched() {
        let markdown = "`![코드](a.png)` 입니다\n"
        XCTAssertEqual(embed(markdown).markdown, markdown)
    }

    // MARK: MIME

    func testKnownExtensionsMapToMimeTypes() {
        XCTAssertEqual(ImageEmbedder.mimeType(forExtension: "PNG"), "image/png")
        XCTAssertEqual(ImageEmbedder.mimeType(forExtension: "jpg"), "image/jpeg")
        XCTAssertEqual(ImageEmbedder.mimeType(forExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(ImageEmbedder.mimeType(forExtension: "svg"), "image/svg+xml")
        XCTAssertNil(ImageEmbedder.mimeType(forExtension: "txt"))
        XCTAssertNil(ImageEmbedder.mimeType(forExtension: ""))
    }

    // MARK: 한글 경로와 빈 문서

    func testKoreanFileNameIsEmbedded() {
        let out = embed("![그림](그림/사진.png)\n")
        XCTAssertEqual(out.embedded, 1)
        XCTAssertTrue(out.markdown.contains("data:image/png;base64,UE5H"))
    }

    func testDocumentWithoutImagesIsUnchanged() {
        let markdown = "# 제목\n\n보통 글입니다.\n"
        let out = embed(markdown)
        XCTAssertEqual(out.markdown, markdown)
        XCTAssertEqual(out.embedded, 0)
        XCTAssertTrue(out.skipped.isEmpty)
    }

    func testEmptyDocumentIsSafe() {
        let out = embed("")
        XCTAssertEqual(out.markdown, "")
        XCTAssertEqual(out.embedded, 0)
    }
}
