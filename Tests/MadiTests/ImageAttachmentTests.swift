import AppKit
import XCTest

/// 그림 넣기의 규칙(`ImageAttachment`) — 자리, 이름, 경로, 넣는 줄.
final class ImageAttachmentTests: XCTestCase {

    func testAssetsFolderSitsNextToTheDocument() {
        let document = URL(fileURLWithPath: "/글/회의 메모.md")
        XCTAssertEqual(ImageAttachment.assetsFolder(for: document).path, "/글/회의 메모.assets")
    }

    func testUniqueURLCountsUpPastTakenNames() {
        let folder = URL(fileURLWithPath: "/a")
        let taken: Set<String> = ["/a/사진.png", "/a/사진-2.png"]
        let url = ImageAttachment.uniqueURL(for: "사진.png", in: folder) { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "사진-3.png")
        XCTAssertEqual(ImageAttachment.uniqueURL(for: "새.png", in: folder) { _ in false }.lastPathComponent, "새.png")
    }

    func testRelativePathOnlyInsideTheDocumentFolder() {
        let document = URL(fileURLWithPath: "/글/노트.md")
        XCTAssertEqual(ImageAttachment.relativePath(of: URL(fileURLWithPath: "/글/그림/a.png"), fromDocument: document),
                       "그림/a.png")
        XCTAssertNil(ImageAttachment.relativePath(of: URL(fileURLWithPath: "/다른/a.png"), fromDocument: document))
        XCTAssertNil(ImageAttachment.relativePath(of: URL(fileURLWithPath: "/글자/a.png"), fromDocument: document),
                     "이름이 같은 말로 시작하는 옆 폴더는 안이 아니다")
    }

    func testEncodedPathEscapesOnlyWhatBreaksALink() {
        XCTAssertEqual(ImageAttachment.encodedPath("회의 메모.assets/사진 (1).png"),
                       "회의%20메모.assets/사진%20%281%29.png", "한글은 그대로, 공백과 괄호만")
        XCTAssertEqual(ImageAttachment.encodedPath("100%.png"), "100%25.png")
    }

    func testEncodedPathRoundTripsThroughTheImageResolver() {
        let document = URL(fileURLWithPath: "/글/회의 메모.md")
        let path = ImageAttachment.encodedPath("회의 메모.assets/사진 (1) 100%.png")
        XCTAssertEqual(ImageReference.localURL(for: path, relativeTo: document)?.path,
                       "/글/회의 메모.assets/사진 (1) 100%.png", "마디가 적은 경로를 마디가 다시 푼다")
    }

    func testMarkdownLineUsesTheFileNameAsAltText() {
        XCTAssertEqual(ImageAttachment.markdown(fileName: "[초안] 표.png", path: "a.assets/[초안] 표.png"),
                       "![초안 표](a.assets/[초안]%20표.png)")
    }

    func testPastedImageNameIsATimestamp() {
        let date = Date(timeIntervalSince1970: 1_793_000_000)      // 2026-10-26 07:33:20 UTC
        XCTAssertEqual(ImageAttachment.pastedImageName(date: date, timeZone: TimeZone(identifier: "UTC")!),
                       "image-20261026-073320.png")
    }

    func testInsertionPutsEachImageOnItsOwnLine() {
        let text = "앞글뒤글" as NSString
        let edit = ImageAttachment.insertion(["![a](a.png)", "![b](b.png)"],
                                             replacing: NSRange(location: 2, length: 0), in: text)
        XCTAssertEqual(edit.applied(to: text as String), "앞글\n![a](a.png)\n![b](b.png)\n뒤글",
                       "글 사이에 끼인 그림은 그려지지 않는다 — 줄을 바꿔 준다")
        XCTAssertEqual(edit.selection.location, ("앞글\n![a](a.png)\n![b](b.png)" as NSString).length)
    }

    func testInsertionOnAnEmptyLineAddsNoBreaks() {
        let text = "위\n\n아래" as NSString
        let edit = ImageAttachment.insertion(["![a](a.png)"], replacing: NSRange(location: 2, length: 0), in: text)
        XCTAssertEqual(edit.applied(to: text as String), "위\n![a](a.png)\n아래")
    }
}

/// 편집기에서 실제로 그림이 들어가는지 — 파일이 문서 옆에 복사되고 그림 줄이 생긴다.
@MainActor
final class ImageInsertTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var folder: URL!
    /// 이름 붙인 대지는 로그아웃할 때까지 남는다 — 테스트가 만든 것은 끝나면 놓는다.
    private var boards: [NSPasteboard] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("madi-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for window in windows {
            window.attachedSheet.map { window.endSheet($0) }
            window.orderOut(nil)
        }
        windows = []
        for board in boards { board.releaseGlobally() }
        boards = []
        try? FileManager.default.removeItem(at: folder)
    }

    private func editor(_ markdown: String, document: URL?) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = editor
        window.orderBack(nil)
        windows.append(window)
        editor.markdown = markdown
        editor.documentURL = document
        return editor
    }

    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("madi-test-\(UUID().uuidString)"))
        board.clearContents()
        fill(board)
        boards.append(board)
        return board
    }

    func testDroppedFileIsCopiedNextToTheDocument() throws {
        let outside = folder.appendingPathComponent("밖", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let picture = outside.appendingPathComponent("사진 1.png")
        try png().write(to: picture)
        let documentFolder = folder.appendingPathComponent("글", isDirectory: true)
        try FileManager.default.createDirectory(at: documentFolder, withIntermediateDirectories: true)
        let document = documentFolder.appendingPathComponent("노트.md")

        let view = editor("위\n", document: document)
        let board = pasteboard { $0.writeObjects([picture as NSURL]) }
        XCTAssertTrue(view.insertImages(from: board, replacing: NSRange(location: 2, length: 0)))
        XCTAssertEqual(view.markdown, "위\n![사진 1](노트.assets/사진%201.png)")
        let copied = documentFolder.appendingPathComponent("노트.assets/사진 1.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))

        // 같은 그림을 또 넣으면 같은 파일을 쓴다.
        XCTAssertTrue(view.insertImages(from: board, replacing: NSRange(location: (view.markdown as NSString).length,
                                                                        length: 0)))
        let names = try FileManager.default.contentsOfDirectory(atPath: copied.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["사진 1.png"], "같은 내용이면 사진-2를 만들지 않는다")
    }

    func testFileInsideTheDocumentFolderIsNotCopied() throws {
        let document = folder.appendingPathComponent("노트.md")
        let picture = folder.appendingPathComponent("그림/a.png")
        try FileManager.default.createDirectory(at: picture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png().write(to: picture)
        let view = editor("", document: document)
        XCTAssertTrue(view.insertImages(from: pasteboard { $0.writeObjects([picture as NSURL]) }, replacing: nil))
        XCTAssertEqual(view.markdown, "![a](그림/a.png)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("노트.assets").path))
    }

    func testPastedImageDataIsWrittenAsPNG() throws {
        let document = folder.appendingPathComponent("노트.md")
        let view = editor("", document: document)
        let data = try png()
        let board = pasteboard { $0.setData(data, forType: .png) }
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertTrue(view.insertImages(from: board, replacing: nil, date: date))
        let name = ImageAttachment.pastedImageName(date: date)
        XCTAssertEqual(view.markdown, "![\((name as NSString).deletingPathExtension)](노트.assets/\(name))")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("노트.assets/\(name)")), data)
    }

    func testTextAheadOfTheImageIsLeftToTheNormalPaste() throws {
        let view = editor("", document: folder.appendingPathComponent("노트.md"))
        let data = try png()
        let board = pasteboard { board in
            board.declareTypes([.string, .png], owner: nil)
            board.setString("글", forType: .string)
            board.setData(data, forType: .png)
        }
        XCTAssertFalse(view.insertImages(from: board, replacing: nil), "글이 먼저면 글을 붙여 넣는다")
    }

    func testAFinderCopyOfANonImageDoesNotPasteItsIcon() throws {
        let file = folder.appendingPathComponent("문서.pdf")
        try Data("x".utf8).write(to: file)
        let data = try png()
        let board = pasteboard { board in
            board.writeObjects([file as NSURL])
            board.setData(data, forType: .tiff)
        }
        let view = editor("", document: folder.appendingPathComponent("노트.md"))
        XCTAssertFalse(view.insertImages(from: board, replacing: nil), "아이콘이 그림으로 들어가면 안 된다")
    }

    func testUnsavedDocumentAsksToSaveFirstAndChangesNothing() throws {
        let picture = folder.appendingPathComponent("a.png")
        try png().write(to: picture)
        let view = editor("글", document: nil)
        XCTAssertTrue(view.insertImages(from: pasteboard { $0.writeObjects([picture as NSURL]) }, replacing: nil),
                      "그림이 있었다 — 경로를 글로 붙여 넣지 않는다")
        XCTAssertEqual(view.markdown, "글")
        XCTAssertNotNil(view.window?.attachedSheet, "저장하라고 알린다")
    }
}
