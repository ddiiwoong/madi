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
        XCTAssertEqual(edit.selection.location, ("앞글\n![a](a.png)\n![b](b.png)\n" as NSString).length,
                       "캐럿은 그림 다음 줄의 처음 — 그림 줄에 두면 원문으로 보여 그림이 안 보인다")
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
        XCTAssertEqual(view.markdown, "위\n![사진 1](노트.assets/사진%201.png)\n", "문서 끝이면 빈 줄을 하나 둔다")
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
        XCTAssertEqual(view.markdown, "![a](그림/a.png)\n")
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
        XCTAssertEqual(view.markdown, "![\((name as NSString).deletingPathExtension)](노트.assets/\(name))\n")
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

    // MARK: 브라우저의 '이미지 복사' — 그림 앞의 글이 그림 자신뿐이면 그림

    func testBrowserImageCopyWithHTMLOrAddressAheadIsAnImage() throws {
        let data = try png()
        let document = folder.appendingPathComponent("노트.md")
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        for (type, value) in [(NSPasteboard.PasteboardType.html,
                               "<meta charset='utf-8'><img src=\"https://example.com/a.png\" alt=\"\"/>"),
                              (.string, "https://example.com/images/a.png")] {
            let view = editor("", document: document)
            let board = pasteboard { board in
                board.declareTypes([type, .png], owner: nil)
                board.setString(value, forType: type)
                board.setData(data, forType: .png)
            }
            XCTAssertTrue(view.insertImages(from: board, replacing: nil, date: date), "\(type.rawValue) 앞")
            XCTAssertTrue(view.markdown.hasPrefix("![image-"), view.markdown)
            XCTAssertTrue(view.markdown.contains("](노트.assets/image-"), view.markdown)
        }
    }

    func testRealTextAheadOfTheImageStaysText() throws {
        let data = try png()
        let view = editor("", document: folder.appendingPathComponent("노트.md"))
        for (type, value) in [(NSPasteboard.PasteboardType.html, "<p>설명 <img src=\"a.png\"></p>"),
                              (.string, "그림 설명 https://example.com/a.png"),
                              (.rtf, "{\\rtf1 x}")] {
            let board = pasteboard { board in
                board.declareTypes([type, .png], owner: nil)
                board.setString(value, forType: type)
                board.setData(data, forType: .png)
            }
            XCTAssertFalse(view.insertImages(from: board, replacing: nil), "\(type.rawValue): 글이 있으면 글")
        }
        XCTAssertFalse(ImagePasteboard.htmlHasText("<meta charset='utf-8'><img src=\"x\">&nbsp;"))
        XCTAssertTrue(ImagePasteboard.isJustAnAddress(""))
        XCTAssertFalse(ImagePasteboard.isJustAnAddress("a.png"), "주소가 아닌 글은 글")
    }

    // MARK: 저장하지 않은 문서 — 잠시 두었다가 처음 저장할 때 문서 옆으로

    /// 저장하지 않은 문서에 붙여 넣은 그림은 잠시 두는 폴더에 들어가고, 절대 경로 링크로 바로 보인다.
    func testUnsavedDocumentStagesThePastedImage() throws {
        let staging = folder.appendingPathComponent("Pasted Images", isDirectory: true)
        let view = editor("글\n", document: nil)
        view.imageStagingFolder = staging
        let data = try png()
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertTrue(view.insertImages(from: pasteboard { $0.setData(data, forType: .png) },
                                        replacing: NSRange(location: 2, length: 0), date: date))
        let name = ImageAttachment.pastedImageName(date: date)
        let staged = staging.appendingPathComponent(name)
        XCTAssertEqual(try Data(contentsOf: staged), data)
        XCTAssertEqual(view.markdown, "글\n![\((name as NSString).deletingPathExtension)](\(ImageAttachment.encodedPath(staged.path)))\n")
        XCTAssertNil(view.window?.attachedSheet, "저장하라고 막지 않는다")
        let link = try XCTUnwrap(view.markdown.components(separatedBy: "](").last?.dropLast(2))
        XCTAssertEqual(ImageReference.localURL(for: String(link), relativeTo: nil)?.path, staged.standardizedFileURL.path,
                       "절대 경로라 저장하기 전에도 그림이 보인다")
    }

    /// 넣자마자 그림이 보인다 — 캐럿이 그림 다음 줄로 가서 그림 줄이 원문이 아니다. 글 가운데에 넣어도 같다.
    func testPastedImageShowsRightAway() throws {
        let staging = folder.appendingPathComponent("Pasted Images", isDirectory: true)
        for (source, location) in [("", 0), ("앞 문단\n뒤 문단\n", 5)] {
            let view = editor(source, document: nil)
            view.imageStagingFolder = staging
            let data = try png()
            XCTAssertTrue(view.insertImages(from: pasteboard { $0.setData(data, forType: .png) },
                                            replacing: NSRange(location: location, length: 0)))
            let text = view.markdown as NSString
            let imageLine = text.lineRange(for: text.range(of: "![image-"))
            XCTAssertFalse(NSLocationInRange(view.textView.selectedRange().location, imageLine),
                           "캐럿이 그림 줄에 있지 않다: \(view.markdown.debugDescription)")
            XCTAssertEqual(view.textView.imagePlacements.count, 1, "그림이 보인다: \(view.markdown.debugDescription)")
        }
    }

    /// 그림 줄 끝의 `\`(줄바꿈 표시)는 그림 줄로 본다 — 그 `\`도 숨긴다.
    func testImageLineWithATrailingBackslashStillShows() throws {
        let picture = folder.appendingPathComponent("a.png")
        try png().write(to: picture)
        let view = editor("![a](\(picture.path))\\\n\n끝\n", document: nil)
        view.textView.setSelectedRange(NSRange(location: (view.markdown as NSString).length, length: 0))
        view.markdown = view.markdown
        XCTAssertEqual(view.textView.imagePlacements.count, 1)
        let slash = (view.markdown as NSString).range(of: ")\\").location + 1
        XCTAssertNotNil(view.textView.textStorage?.attribute(.mdHiddenMarker, at: slash, effectiveRange: nil))
    }

    /// `⌘V`가 부르는 길 그대로(`paste(_:)`) — 저장하지 않은 문서에 화면 캡처를 붙여 넣으면 그림 줄이 들어간다.
    /// 앱에서는 확인용 사본에 보낸 `⌘V`가 닿지 않아(다른 단축키도 같았다) 이 길을 시험으로 본다.
    func testCommandVPathPastesAScreenshotIntoAnUnsavedDocument() throws {
        let staging = folder.appendingPathComponent("Pasted Images", isDirectory: true)
        let view = editor("", document: nil)
        view.imageStagingFolder = staging
        let data = try png()
        view.textView.pastePasteboard = pasteboard { $0.setData(data, forType: .png) }
        view.textView.paste(nil)
        XCTAssertTrue(view.markdown.hasPrefix("![image-"), view.markdown)
        XCTAssertTrue(view.markdown.contains(ImageAttachment.encodedPath(staging.path)), view.markdown)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path).count, 1)
    }

    /// 처음 저장하면 잠시 둔 그림을 문서 옆으로 복사하고 링크를 상대 경로로 고친다 — 실행 취소 한 번. 다른 링크와 코드
    /// 블록 안은 그대로.
    func testFirstSaveAdoptsStagedImagesNextToTheDocument() throws {
        let staging = folder.appendingPathComponent("Pasted Images", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("image-1.png")
        try png().write(to: staged)
        let other = folder.appendingPathComponent("다른 곳/b.png")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png().write(to: other)
        let stagedLink = ImageAttachment.encodedPath(staged.path)
        let source = "# 제목\n\n![image-1](\(stagedLink))\n\n![b](\(ImageAttachment.encodedPath(other.path)))\n\n"
            + "```\n![image-1](\(stagedLink))\n```\n끝"
        let view = editor(source, document: nil)
        view.imageStagingFolder = staging
        let undo = UndoManager()
        undo.groupsByEvent = false
        view.undoManagerOverride = undo

        let documentFolder = folder.appendingPathComponent("글", isDirectory: true)
        try FileManager.default.createDirectory(at: documentFolder, withIntermediateDirectories: true)
        view.documentURL = documentFolder.appendingPathComponent("새 노트.md")
        undo.beginUndoGrouping()
        XCTAssertTrue(view.adoptStagedImages())
        undo.endUndoGrouping()

        XCTAssertTrue(view.markdown.contains("![image-1](새%20노트.assets/image-1.png)"), view.markdown)
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentFolder.appendingPathComponent("새 노트.assets/image-1.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "옮기지 않고 복사 — 실행 취소해도 깨지지 않는다")
        XCTAssertTrue(view.markdown.contains("](\(ImageAttachment.encodedPath(other.path)))"), "임시 폴더 밖의 링크는 그대로")
        XCTAssertTrue(view.markdown.contains("```\n![image-1](\(stagedLink))\n```"), "코드 블록 안은 글이다")
        XCTAssertEqual(undo.undoActionName, "그림 옮기기")
        XCTAssertFalse(view.adoptStagedImages(), "다시 하면 고칠 것이 없다")
        undo.undo()
        XCTAssertEqual(view.markdown, source, "실행 취소 한 번에 돌아간다")
    }

    // MARK: 끌어놓기 — 텍스트 뷰의 끌어놓기 길

    /// Finder에서 끌어 온 것처럼 보이는 끌기. 텍스트 뷰가 묻는 것만 답한다.
    @MainActor
    private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingLocation: NSPoint
        let draggingSource: Any?
        weak var draggingDestinationWindow: NSWindow?
        @MainActor
        init(pasteboard: NSPasteboard, location: NSPoint, source: Any?, window: NSWindow?) {
            draggingPasteboard = pasteboard
            draggingLocation = location
            draggingSource = source
            draggingDestinationWindow = window
        }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [],
                                    for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    /// 창 좌표의 점 — 문서 끝 글자 뒤.
    private func pointAfterLastCharacter(_ view: MarkdownEditorView) throws -> NSPoint {
        let tv = view.textView
        tv.window?.displayIfNeeded()
        let layout = try XCTUnwrap(tv.layoutManager)
        let container = try XCTUnwrap(tv.textContainer)
        let used = layout.usedRect(for: container)
        let local = NSPoint(x: tv.textContainerOrigin.x + used.maxX - 1,
                            y: tv.textContainerOrigin.y + used.maxY - 2)
        return tv.convert(local, to: nil)
    }

    func testDroppingAFileOnTheEditorGoesThroughTheTextView() throws {
        let picture = folder.appendingPathComponent("밖에 있는 사진.png")
        try png().write(to: picture)
        let document = folder.appendingPathComponent("글/노트.md")
        try FileManager.default.createDirectory(at: document.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let view = editor("위 문단\n", document: document)
        let board = pasteboard { $0.writeObjects([picture as NSURL]) }
        let drag = FakeDrag(pasteboard: board, location: try pointAfterLastCharacter(view),
                            source: nil, window: view.window)

        XCTAssertTrue(view.textView.acceptableDragTypes.contains(.fileURL), "파일을 받겠다고 알린다")
        XCTAssertEqual(view.textView.dragOperation(for: drag, type: .fileURL), .copy, "끄는 동안 '복사' 표시")
        XCTAssertTrue(view.textView.performDragOperation(drag))
        XCTAssertEqual(view.markdown, "위 문단\n![밖에 있는 사진](노트.assets/밖에%20있는%20사진.png)\n")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("글/노트.assets/밖에 있는 사진.png").path))
    }

    func testDraggingWithinTheEditorIsNotAnImageDrop() throws {
        let picture = folder.appendingPathComponent("a.png")
        try png().write(to: picture)
        let view = editor("글\n", document: folder.appendingPathComponent("노트.md"))
        var asked = 0
        view.textView.imageInsertHandler = { _, _ in asked += 1; return true }
        let board = pasteboard { $0.writeObjects([picture as NSURL]) }
        let drag = FakeDrag(pasteboard: board, location: try pointAfterLastCharacter(view),
                            source: view.textView, window: view.window)
        _ = view.textView.dragOperation(for: drag, type: .fileURL)
        _ = view.textView.performDragOperation(drag)
        XCTAssertEqual(asked, 0, "이 뷰에서 시작한 끌기(글 옮기기)는 그림 넣기로 받지 않는다")
    }

    func testDroppingANonImageFileFallsBackToTheTextView() throws {
        let file = folder.appendingPathComponent("표.csv")
        try Data("a,b".utf8).write(to: file)
        let view = editor("글\n", document: folder.appendingPathComponent("노트.md"))
        let board = pasteboard { $0.writeObjects([file as NSURL]) }
        XCTAssertFalse(ImagePasteboard.holdsImages(board), "그림이 아닌 파일은 그림 넣기가 받지 않는다")
        XCTAssertFalse(view.insertImages(from: board, replacing: nil))
        XCTAssertEqual(view.markdown, "글\n")
    }
}
