import Compression
import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

/// 손으로 만든 최소 EPUB으로 시험한다. 구조를 내가 정하므로 무엇을 확인하는지가 분명하다.
/// (실제 책으로도 확인했고 그 결과는 커밋 메시지에 적혀 있다 — 테스트가 사용자의
/// Downloads 폴더에 의존하면 다른 기계에서 돌지 않는다.)
final class EpubBookTests: XCTestCase {

    private var folder: URL!

    private func inflate(_ data: Data, _ size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written: Int = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw CocoaError(.fileReadCorruptFile) }
        return output
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        try super.tearDownWithError()
    }

    // MARK: 최소 EPUB 만들기

    /// EPUB 규격의 포장 순서를 따른다 — `mimetype`을 먼저 **무압축으로** 넣고 나머지를 넣는다.
    private func makeEpub(_ files: [String: String],
                          mimetype: String = "application/epub+zip") throws -> ZipArchive {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else {
            throw XCTSkip("/usr/bin/zip이 없습니다")
        }
        var all = files
        all["mimetype"] = mimetype
        for (name, contents) in all {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        func zip(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = folder
            process.arguments = ["-q"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try zip(["-X", "-0", "book.epub", "mimetype"])
        let rest = files.keys.sorted()
        if !rest.isEmpty { try zip(["-X", "book.epub"] + rest) }
        return try ZipArchive(data: try Data(contentsOf: folder.appendingPathComponent("book.epub")))
    }

    private let container = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf"
        media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    private func opf(version: String, extra: String = "", spineAttributes: String = "") -> String {
        """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="\(version)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>책 제목</dc:title>
            <dc:creator>지은이 하나</dc:creator>
            <dc:creator>지은이 둘</dc:creator>
            <dc:language>ko</dc:language>
            <dc:publisher>펴낸곳</dc:publisher>
            <dc:identifier>urn:isbn:1234567890</dc:identifier>
            <dc:date>2026-10-25</dc:date>
          </metadata>
          <manifest>
            <item id="c1" href="Text/1장.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="Text/2장.xhtml" media-type="application/xhtml+xml"/>
            \(extra)
          </manifest>
          <spine \(spineAttributes)>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """
    }

    // MARK: 구조 읽기

    func testReadsMetadataManifestAndSpine() throws {
        let archive = try makeEpub([
            "META-INF/container.xml": container,
            "OEBPS/content.opf": opf(version: "3.0"),
            "OEBPS/Text/1장.xhtml": "<html><body>하나</body></html>",
            "OEBPS/Text/2장.xhtml": "<html><body>둘</body></html>",
        ])
        let book = try EpubBook.open(archive, inflate: inflate)

        XCTAssertEqual(book.metadata.title, "책 제목")
        XCTAssertEqual(book.metadata.creators, ["지은이 하나", "지은이 둘"])
        XCTAssertEqual(book.metadata.language, "ko")
        XCTAssertEqual(book.metadata.publisher, "펴낸곳")
        XCTAssertEqual(book.metadata.identifier, "urn:isbn:1234567890")
        XCTAssertEqual(book.opfPath, "OEBPS/content.opf")
        XCTAssertEqual(book.spine.count, 2)
        // OPF 기준 상대 경로가 ZIP 안의 전체 경로로 풀려야 한다.
        XCTAssertEqual(book.spine.map(\.path), ["OEBPS/Text/1장.xhtml", "OEBPS/Text/2장.xhtml"])
        XCTAssertTrue(book.isSpecCompliant)
    }

    func testSpinePathsActuallyExistInTheArchive() throws {
        // 경로를 잘못 풀면 모든 챕터가 "없는 파일"이 된다. 가장 중요한 불변식이다.
        let archive = try makeEpub([
            "META-INF/container.xml": container,
            "OEBPS/content.opf": opf(version: "3.0"),
            "OEBPS/Text/1장.xhtml": "<html/>",
            "OEBPS/Text/2장.xhtml": "<html/>",
        ])
        let book = try EpubBook.open(archive, inflate: inflate)
        for item in book.spine {
            XCTAssertNotNil(archive.entry(named: item.path), "ZIP에 없다: \(item.path)")
        }
    }

    // MARK: DRM

    func testDrmProtectedBookIsRefusedHonestly() throws {
        // 암호화된 바이트를 억지로 그리면 깨진 글자가 나오고 사용자는 앱이 고장 난 줄 안다.
        let encryption = """
        <?xml version="1.0"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <EncryptedData><KeyInfo><resource xmlns="http://ns.adobe.com/adept"/></KeyInfo></EncryptedData>
        </encryption>
        """
        let archive = try makeEpub([
            "META-INF/container.xml": container,
            "META-INF/encryption.xml": encryption,
            "OEBPS/content.opf": opf(version: "3.0"),
        ])
        XCTAssertThrowsError(try EpubBook.open(archive, inflate: inflate)) { error in
            XCTAssertEqual(error as? EpubBook.Failure, .drmProtected(scheme: "Adobe ADEPT"))
        }
    }

    func testFontObfuscationIsNamedDistinctlyFromRealDrm() throws {
        // 글꼴 난독화는 본문을 읽을 수 있다. 같은 말로 거절하면 사용자가 포기한다.
        let encryption = """
        <?xml version="1.0"?>
        <encryption><EncryptedData><EncryptionMethod
          Algorithm="http://www.idpf.org/2008/embedding"/></EncryptedData></encryption>
        """
        let archive = try makeEpub([
            "META-INF/container.xml": container,
            "META-INF/encryption.xml": encryption,
            "OEBPS/content.opf": opf(version: "3.0"),
        ])
        XCTAssertThrowsError(try EpubBook.open(archive, inflate: inflate)) { error in
            XCTAssertEqual(error as? EpubBook.Failure,
                           .drmProtected(scheme: "글꼴 난독화(IDPF)"))
        }
    }

    // MARK: EPUB이 아닌 것

    func testWrongMimetypeIsRefused() throws {
        let archive = try makeEpub(["META-INF/container.xml": container],
                                   mimetype: "application/zip")
        XCTAssertThrowsError(try EpubBook.open(archive, inflate: inflate)) { error in
            guard case .notAnEpub = (error as? EpubBook.Failure) else {
                return XCTFail("다른 오류: \(error)")
            }
        }
    }

    func testMissingContainerIsRefused() throws {
        let archive = try makeEpub(["OEBPS/content.opf": opf(version: "3.0")])
        XCTAssertThrowsError(try EpubBook.open(archive, inflate: inflate)) { error in
            XCTAssertEqual(error as? EpubBook.Failure, .missingContainer)
        }
    }

    func testEmptySpineIsRefused() throws {
        let bare = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>빈 책</dc:title></metadata>
          <manifest/><spine/>
        </package>
        """
        let archive = try makeEpub([
            "META-INF/container.xml": container,
            "OEBPS/content.opf": bare,
        ])
        XCTAssertThrowsError(try EpubBook.open(archive, inflate: inflate)) { error in
            XCTAssertEqual(error as? EpubBook.Failure, .emptySpine)
        }
    }

    // MARK: 목차 — 두 방식 모두

    func testEpub3NavigationDocumentToc() throws {
        let nav = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body><nav epub:type="toc">
            <ol>
              <li><a href="Text/1장.xhtml">첫째 장</a>
                <ol><li><a href="Text/1장.xhtml#절">첫째 절</a></li></ol>
              </li>
              <li><a href="Text/2장.xhtml">둘째 장</a></li>
            </ol>
          </nav></body>
        </html>
        """
        let archive = try makeEpub([
            "META-INF/container.xml": container,
            "OEBPS/content.opf": opf(version: "3.0", extra:
                #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#),
            "OEBPS/nav.xhtml": nav,
            "OEBPS/Text/1장.xhtml": "<html/>",
            "OEBPS/Text/2장.xhtml": "<html/>",
        ])
        let book = try EpubBook.open(archive, inflate: inflate)

        XCTAssertEqual(book.toc.count, 2)
        XCTAssertEqual(book.toc[0].title, "첫째 장")
        XCTAssertEqual(book.toc[0].path, "OEBPS/Text/1장.xhtml")
        XCTAssertEqual(book.toc[0].children.count, 1, "중첩 목차가 평평해졌다")
        XCTAssertEqual(book.toc[0].children[0].fragment, "절")
        XCTAssertEqual(book.toc[1].title, "둘째 장")
    }

    func testEpub2NcxToc() throws {
        // 실제 책(2026년 발행)이 EPUB 2 + NCX였다. 한쪽만 다루면 목차를 못 읽는다.
        let ncx = """
        <?xml version="1.0"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="n1"><navLabel><text>첫째 장</text></navLabel>
              <content src="Text/1장.xhtml"/>
              <navPoint id="n1-1"><navLabel><text>첫째 절</text></navLabel>
                <content src="Text/1장.xhtml#절"/></navPoint>
            </navPoint>
            <navPoint id="n2"><navLabel><text>둘째 장</text></navLabel>
              <content src="Text/2장.xhtml"/></navPoint>
          </navMap>
        </ncx>
        """
        let archive = try makeEpub([
            "META-INF/container.xml": container,
            "OEBPS/content.opf": opf(version: "2.0", extra:
                #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#,
                spineAttributes: #"toc="ncx""#),
            "OEBPS/toc.ncx": ncx,
            "OEBPS/Text/1장.xhtml": "<html/>",
            "OEBPS/Text/2장.xhtml": "<html/>",
        ])
        let book = try EpubBook.open(archive, inflate: inflate)

        XCTAssertEqual(book.toc.count, 2)
        XCTAssertEqual(book.toc[0].title, "첫째 장")
        XCTAssertEqual(book.toc[0].path, "OEBPS/Text/1장.xhtml")
        XCTAssertEqual(book.toc[0].children.map(\.title), ["첫째 절"])
        XCTAssertEqual(book.toc[0].children[0].fragment, "절")
    }

    func testABookWithoutATocStillOpens() throws {
        // 목차는 없어도 된다. 없다고 책을 못 열면 안 된다.
        let archive = try makeEpub([
            "META-INF/container.xml": container,
            "OEBPS/content.opf": opf(version: "3.0"),
            "OEBPS/Text/1장.xhtml": "<html/>",
            "OEBPS/Text/2장.xhtml": "<html/>",
        ])
        let book = try EpubBook.open(archive, inflate: inflate)
        XCTAssertTrue(book.toc.isEmpty)
        XCTAssertEqual(book.spine.count, 2)
    }

    // MARK: 경로 풀기

    func testResolveHandlesDotDotAndAbsolute() {
        XCTAssertEqual(EpubBook.resolve("Text/a.xhtml", against: "OEBPS"), "OEBPS/Text/a.xhtml")
        XCTAssertEqual(EpubBook.resolve("../Images/a.png", against: "OEBPS/Text"),
                       "OEBPS/Images/a.png")
        XCTAssertEqual(EpubBook.resolve("./a.xhtml", against: "OEBPS"), "OEBPS/a.xhtml")
        XCTAssertEqual(EpubBook.resolve("/top.xhtml", against: "OEBPS"), "top.xhtml")
        XCTAssertEqual(EpubBook.resolve("a.xhtml", against: ""), "a.xhtml")
    }

    func testResolveDoesNotEscapeAboveTheRoot() {
        // `../../..`로 ZIP 바깥을 가리키려 해도 뿌리에서 멈춘다.
        XCTAssertEqual(EpubBook.resolve("../../../etc/passwd", against: "OEBPS"), "etc/passwd")
    }
}
