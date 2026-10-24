import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class ImageReferenceTests: XCTestCase {

    private let document = URL(fileURLWithPath: "/Users/someone/notes/글/문서.md")

    // MARK: 원격 주소는 풀지 않는다

    func testRemoteAddressesAreRefused() {
        // 문서를 열었을 뿐인데 바깥으로 요청이 나가면 안 된다.
        for raw in ["http://example.com/a.png", "HTTPS://example.com/a.png",
                    "//example.com/a.png", "data:image/png;base64,AAAA",
                    "ftp://example.com/a.png", "javascript:alert(1)"] {
            XCTAssertTrue(ImageReference.isRemote(raw), raw)
            XCTAssertNil(ImageReference.localURL(for: raw, relativeTo: document), raw)
        }
    }

    func testLocalPathsAreNotTreatedAsRemote() {
        for raw in ["a.png", "./a.png", "../그림/a.png", "/tmp/a.png", "~/a.png"] {
            XCTAssertFalse(ImageReference.isRemote(raw), raw)
        }
    }

    // MARK: 경로 풀기

    func testRelativePathResolvesAgainstTheDocumentFolder() {
        let url = ImageReference.localURL(for: "그림/a.png", relativeTo: document)
        XCTAssertEqual(url?.path, "/Users/someone/notes/글/그림/a.png")
    }

    func testDotSegmentsAreResolved() {
        XCTAssertEqual(ImageReference.localURL(for: "./a.png", relativeTo: document)?.path,
                       "/Users/someone/notes/글/a.png")
        XCTAssertEqual(ImageReference.localURL(for: "../a.png", relativeTo: document)?.path,
                       "/Users/someone/notes/a.png")
    }

    func testAbsolutePathIsUsedAsIs() {
        XCTAssertEqual(ImageReference.localURL(for: "/tmp/a.png", relativeTo: document)?.path,
                       "/tmp/a.png")
    }

    func testTildeIsExpanded() {
        let url = ImageReference.localURL(for: "~/a.png", relativeTo: document)
        XCTAssertNotNil(url)
        XCTAssertFalse(url!.path.contains("~"), "틸데가 그대로 남았다: \(url!.path)")
        XCTAssertTrue(url!.path.hasSuffix("/a.png"))
    }

    func testRelativePathWithoutADocumentCannotBeResolved() {
        // 저장하지 않은 문서는 기준이 없다.
        XCTAssertNil(ImageReference.localURL(for: "a.png", relativeTo: nil))
        // 절대 경로는 기준이 없어도 된다.
        XCTAssertEqual(ImageReference.localURL(for: "/tmp/a.png", relativeTo: nil)?.path,
                       "/tmp/a.png")
    }

    // MARK: 마크다운이 쓰는 모양들

    func testPercentEncodingIsDecoded() {
        XCTAssertEqual(ImageReference.localURL(for: "my%20image.png", relativeTo: document)?.path,
                       "/Users/someone/notes/글/my image.png")
    }

    func testKoreanFileNameSurvives() {
        XCTAssertEqual(ImageReference.localURL(for: "그림%20하나.png", relativeTo: document)?.path,
                       "/Users/someone/notes/글/그림 하나.png")
        XCTAssertEqual(ImageReference.localURL(for: "사진.png", relativeTo: document)?.path,
                       "/Users/someone/notes/글/사진.png")
    }

    func testAngleBracketsAreStripped() {
        XCTAssertEqual(ImageReference.localURL(for: "<a.png>", relativeTo: document)?.path,
                       "/Users/someone/notes/글/a.png")
    }

    func testFragmentAndQueryAreDropped() {
        XCTAssertEqual(ImageReference.localURL(for: "a.png#frag", relativeTo: document)?.path,
                       "/Users/someone/notes/글/a.png")
        XCTAssertEqual(ImageReference.localURL(for: "a.png?v=2", relativeTo: document)?.path,
                       "/Users/someone/notes/글/a.png")
    }

    func testEmptyAndWhitespaceOnlyAreRefused() {
        XCTAssertNil(ImageReference.localURL(for: "", relativeTo: document))
        XCTAssertNil(ImageReference.localURL(for: "   ", relativeTo: document))
        XCTAssertNil(ImageReference.localURL(for: "#only-fragment", relativeTo: document))
    }

    // MARK: 보여 줄 크기

    func testOversizedImageIsScaledDownKeepingAspect() {
        let size = ImageReference.displaySize(for: CGSize(width: 2000, height: 1000),
                                              maxWidth: 800)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 400, "비율이 깨졌다")
    }

    func testSmallImageIsNotEnlarged() {
        // 작은 그림을 늘리면 뭉개진다.
        let size = ImageReference.displaySize(for: CGSize(width: 40, height: 20), maxWidth: 800)
        XCTAssertEqual(size.width, 40)
        XCTAssertEqual(size.height, 20)
    }

    func testTallImageIsBoundedByHeightToo() {
        let size = ImageReference.displaySize(for: CGSize(width: 100, height: 4000),
                                              maxWidth: 800, maxHeight: 400)
        XCTAssertEqual(size.height, 400)
        XCTAssertEqual(size.width, 10)
    }

    func testDegenerateSizesAreZero() {
        XCTAssertEqual(ImageReference.displaySize(for: .zero, maxWidth: 800), .zero)
        XCTAssertEqual(ImageReference.displaySize(for: CGSize(width: 10, height: 10),
                                                  maxWidth: 0), .zero)
    }
}
