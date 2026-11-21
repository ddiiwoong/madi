import AppKit
import XCTest

/// 바깥에서 바뀐 파일 — 무엇이 바뀌었는지 가리기(`ExternalFileChange`), 가장 작은 갈아 끼우기(`TextSplice`).
final class ExternalFileChangeTests: XCTestCase {

    private func data(_ text: String) -> Data { Data(text.utf8) }

    /// 끝에 붙은 것은 붙은 바이트만 읽는다 — 앞은 끝 조각(4KB)만 다시 본다. 이어 센 지문은 전체를 센 것과 같다.
    func testAppendReadsOnlyTheNewBytes() throws {
        let head = String(repeating: "앞줄입니다 INFO 2026-11-21\n", count: 400)
        let old = data(head)
        let new = data(head + "새 줄 하나\n")
        let baseline = DiskBaseline(data: old, modificationDate: Date(timeIntervalSince1970: 1))
        var reads: [Range<Int>] = []
        let change = ExternalFileChange.detect(baseline: baseline, size: new.count,
                                               modificationDate: Date(timeIntervalSince1970: 2)) { range in
            reads.append(range)
            return new.subdata(in: range)
        }
        XCTAssertEqual(change, .appended(text: "새 줄 하나\n",
                                         baseline: DiskBaseline(data: new, modificationDate: Date(timeIntervalSince1970: 2))))
        XCTAssertEqual(reads, [(old.count - DiskBaseline.tailSize) ..< old.count, old.count ..< new.count],
                       "앞을 통째로 읽지 않는다")
    }

    /// 한 글자를 두 번에 나눠 쓴 사이에 읽으면 그 글자는 다음에 — 깨진 글자를 들이지 않는다.
    func testHalfWrittenCharacterWaitsForTheRest() throws {
        let old = data("로그\n")
        let baseline = DiskBaseline(data: old, modificationDate: nil)
        let han = Array("한".utf8)
        let half = old + data("abc") + Data(han.prefix(2))
        let first = ExternalFileChange.detect(baseline: baseline, size: half.count, modificationDate: nil) {
            half.subdata(in: $0)
        }
        guard case let .appended(text, next) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(text, "abc")
        XCTAssertEqual(next.length, old.count + 3, "덜 쓴 두 바이트는 들이지 않았다")

        let only = old + Data(han.prefix(2))
        XCTAssertEqual(ExternalFileChange.detect(baseline: baseline, size: only.count, modificationDate: nil) {
            only.subdata(in: $0)
        }, .unchanged(baseline), "덜 쓴 글자뿐이면 기준을 옮기지 않는다")

        let whole = half + Data(han.suffix(1))
        let second = ExternalFileChange.detect(baseline: next, size: whole.count, modificationDate: nil) {
            whole.subdata(in: $0)
        }
        XCTAssertEqual(second, .appended(text: "한", baseline: DiskBaseline(data: whole, modificationDate: nil)))
    }

    /// 줄어듦 · 가운데가 바뀜 · 같은 길이로 바꿔 씀은 통째로. 수정 시각만 바뀐 것(`touch`)은 그대로다. 길이와 수정 시각이 같으면 읽지도
    /// 않는다.
    func testOtherChangesAreReplacedAndTouchIsNot() throws {
        let old = data("하나\n둘\n셋\n")
        let date = Date(timeIntervalSince1970: 10)
        let baseline = DiskBaseline(data: old, modificationDate: date)
        func detect(_ new: Data, _ modified: Date?, _ base: DiskBaseline = baseline, utf8: Bool = true) -> DiskChange {
            ExternalFileChange.detect(baseline: base, size: new.count, modificationDate: modified, appendsAsUTF8: utf8) {
                new.subdata(in: $0.clamped(to: 0 ..< new.count))
            }
        }
        let shorter = data("하나\n")
        XCTAssertEqual(detect(shorter, date), .replaced(data: shorter, baseline: DiskBaseline(data: shorter, modificationDate: date)))
        let middle = data("하나\n이\n셋\n넷\n")
        if case .replaced = detect(middle, date) {} else { XCTFail("앞이 바뀌고 길어진 것은 붙은 것이 아니다") }
        let sameLength = data("하나\n둘\n넷\n")
        if case .replaced = detect(sameLength, Date(timeIntervalSince1970: 11)) {} else { XCTFail("같은 길이로 바꿔 씀") }
        XCTAssertEqual(detect(old, Date(timeIntervalSince1970: 12)),
                       .unchanged(baseline.with(modificationDate: Date(timeIntervalSince1970: 12))), "수정 시각만 바뀜")
        var reads = 0
        _ = ExternalFileChange.detect(baseline: baseline, size: old.count, modificationDate: date) { _ in
            reads += 1
            return Data()
        }
        XCTAssertEqual(reads, 0)
        let appended = old + data("넷\n")
        if case .replaced = detect(appended, nil, utf8: false) {} else {
            XCTFail("UTF-8이 아닌 문서는 붙은 바이트를 UTF-8로 읽지 않는다")
        }
    }

    func testCompleteUTF8Prefix() {
        let han = Data("한".utf8)
        XCTAssertEqual(ExternalFileChange.completeUTF8Prefix(of: Data()), 0)
        XCTAssertEqual(ExternalFileChange.completeUTF8Prefix(of: Data("abc".utf8)), 3)
        XCTAssertEqual(ExternalFileChange.completeUTF8Prefix(of: Data("a".utf8) + han), 4)
        XCTAssertEqual(ExternalFileChange.completeUTF8Prefix(of: Data("a".utf8) + han.prefix(1)), 1)
        XCTAssertEqual(ExternalFileChange.completeUTF8Prefix(of: Data("a".utf8) + han.prefix(2)), 1)
        let emoji = Data("😀".utf8)
        XCTAssertEqual(ExternalFileChange.completeUTF8Prefix(of: emoji.prefix(3)), 0)
        XCTAssertEqual(ExternalFileChange.completeUTF8Prefix(of: emoji), 4)
    }

    /// 앞뒤가 같은 부분은 두고 다른 가운데만. 이모지(UTF-16 둘)의 가운데를 자르지 않는다.
    func testSpliceIsTheChangedMiddle() throws {
        XCTAssertNil(TextSplice.between("같다", "같다"))
        let splice = try XCTUnwrap(TextSplice.between("하나\n둘\n셋\n", "하나\n이\n셋\n"))
        XCTAssertEqual(splice, TextSplice(range: NSRange(location: 3, length: 1), replacement: "이"))
        XCTAssertEqual(TextSplice.between("abc", "abcdef"), TextSplice(range: NSRange(location: 3, length: 0), replacement: "def"))
        XCTAssertTrue(TextSplice.between("abc", "abcdef")!.isAppend(toLength: 3))
        XCTAssertEqual(TextSplice.between("abcdef", "ab"), TextSplice(range: NSRange(location: 2, length: 4), replacement: ""))
        // 😀(D83D DE00)과 😃(D83D DE03)은 앞 반쪽이 같다 — 갈아 끼우는 곳은 두 반쪽을 다 덮는다.
        let emoji = try XCTUnwrap(TextSplice.between("a😀b", "a😃b"))
        XCTAssertEqual(emoji, TextSplice(range: NSRange(location: 1, length: 2), replacement: "😃"))
        // 뒤 반쪽이 같은 경우: U+1F642(D83D DE42)와 U+1FA42(D83E DE42) — 뒤 반쪽만 남기고 자르지 않는다.
        let trail = try XCTUnwrap(TextSplice.between("x\u{1F642}y", "x\u{1FA42}y"))
        XCTAssertEqual(trail, TextSplice(range: NSRange(location: 1, length: 2), replacement: "\u{1FA42}"))
    }

    /// 선택은 같은 글자에 남는다 — 앞은 그대로, 뒤는 길이 차만큼, 안쪽은 갈아 끼운 곳의 처음으로.
    func testSelectionFollowsTheSameText() {
        let splice = TextSplice(range: NSRange(location: 10, length: 5), replacement: "12345678")   // +3
        XCTAssertEqual(splice.adjusted(NSRange(location: 2, length: 3)), NSRange(location: 2, length: 3))
        XCTAssertEqual(splice.adjusted(NSRange(location: 20, length: 2)), NSRange(location: 23, length: 2))
        XCTAssertEqual(splice.adjusted(NSRange(location: 12, length: 0)), NSRange(location: 10, length: 0))
        XCTAssertEqual(splice.adjusted(NSRange(location: 5, length: 15)), NSRange(location: 5, length: 18), "걸친 선택은 넓어진다")
        let append = TextSplice(range: NSRange(location: 30, length: 0), replacement: "끝")
        XCTAssertEqual(append.adjusted(NSRange(location: 30, length: 0)), NSRange(location: 30, length: 0), "끝의 캐럿은 붙은 글 앞")
    }
}

/// 편집기가 바깥 글을 들인다 — 둘레만 칠하고, 읽던 자리를 지키고, 끝을 보고 있었으면 따라간다.
@MainActor
final class ExternalEditEditorTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func editor(lines: Int = 200) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.contentView = editor
        window.orderBack(nil)
        windows.append(window)
        editor.markdown = (1 ... lines).map { "- 2026-11-21 21:00:\($0 % 60) INFO 줄 \($0)" }.joined(separator: "\n") + "\n"
        editor.layoutSubtreeIfNeeded()
        return editor
    }

    private func append(_ text: String, to editor: MarkdownEditorView) {
        let end = (editor.markdown as NSString).length
        editor.applyExternalEdit(TextSplice(range: NSRange(location: end, length: 0), replacement: text), keepsUndo: true)
        editor.layoutSubtreeIfNeeded()
    }

    /// 끝을 보고 있었으면 새 끝을 따라간다 — 단추는 없다. 문서 전체를 다시 칠하지 않는다.
    func testAppendFollowsWhenShowingTheEnd() {
        let view = editor()
        view.scrollToEnd()
        XCTAssertTrue(view.isShowingEnd)
        let restyles = view.fullRestyleCount
        append((201 ... 230).map { "- 새 줄 \($0)" }.joined(separator: "\n") + "\n", to: view)
        XCTAssertTrue(view.isShowingEnd, "새 끝을 따라갔다")
        XCTAssertTrue(view.newLinesButton.isHidden)
        XCTAssertEqual(view.fullRestyleCount, restyles, "붙은 둘레만 칠했다")
        XCTAssertTrue(view.markdown.hasSuffix("- 새 줄 230\n"))
    }

    /// 위를 읽고 있었으면 그 자리에 두고 '새 줄 N개 ↓'. 누르면 끝으로 가고 단추는 걷힌다. 손으로 끝까지 굴려도 걷힌다.
    func testAppendWhileReadingAboveKeepsThePlaceAndOffersTheNewLines() throws {
        let view = editor()
        view.clipView.scroll(to: NSPoint(x: 0, y: 120))
        let origin = view.clipView.bounds.origin
        XCTAssertFalse(view.isShowingEnd)
        append("- 하나\n- 둘\n- 셋\n", to: view)
        XCTAssertEqual(view.clipView.bounds.origin, origin, "읽던 자리 그대로")
        XCTAssertFalse(view.newLinesButton.isHidden)
        XCTAssertEqual(view.newLinesButton.title, String(localized: "새 줄 \(3)개 ↓"))
        append("- 넷\n- 다섯\n", to: view)
        XCTAssertEqual(view.unseenNewLines, 5)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(view.newLinesButton.action), to: view.newLinesButton.target,
                                       from: view.newLinesButton))
        XCTAssertTrue(view.isShowingEnd)
        XCTAssertTrue(view.newLinesButton.isHidden)

        view.clipView.scroll(to: NSPoint(x: 0, y: 0))
        append("- 여섯\n", to: view)
        XCTAssertFalse(view.newLinesButton.isHidden)
        let bottom = view.textView.frame.height - view.clipView.bounds.height
        view.clipView.scroll(to: NSPoint(x: 0, y: bottom))
        XCTAssertTrue(view.newLinesButton.isHidden, "손으로 끝까지 굴리면 다 본 것")
        XCTAssertEqual(view.unseenNewLines, 0)
    }

    /// 가운데를 갈아 끼워도 캐럿과 고른 것은 같은 글자에 남고, 실행 취소 기록은 비운다(옛 자리가 틀린다).
    func testSpliceKeepsTheCaretOnTheSameTextAndClearsUndo() throws {
        let view = editor(lines: 20)
        let text = view.markdown as NSString
        let target = text.range(of: "줄 15")
        // 실행 취소할 것을 하나 만든다 — 고를 글(15번 줄) 뒤에 친다.
        view.textView.insertText("x", replacementRange: NSRange(location: text.range(of: "줄 18").location, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        view.textView.setSelectedRange(target)
        let undo = try XCTUnwrap(view.textView.undoManager)
        XCTAssertTrue(undo.canUndo, "전제: 실행 취소할 것이 있다")
        let line3 = (view.markdown as NSString).range(of: "줄 3\n")
        view.applyExternalEdit(TextSplice(range: line3, replacement: "줄 셋 — 바뀜\n"), keepsUndo: false)
        let selected = (view.markdown as NSString).substring(with: view.textView.selectedRange())
        XCTAssertEqual(selected, "줄 15")
        XCTAssertFalse(undo.canUndo, "가운데가 바뀌면 옛 기록을 버린다")
    }
}

/// 문서가 바깥 변경을 들인다 — 고친 것이 없으면 묻지 않고, 있으면 띠로 묻고 자동 저장을 멈춘다.
@MainActor
final class ExternalChangeDocumentTests: XCTestCase {

    private var folder: URL!
    private var documents: [MarkdownDocument] = []
    private var controllers: [DocumentWindowController] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("madi-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for controller in controllers { controller.window?.orderOut(nil) }
        for document in documents { document.close() }
        controllers = []
        documents = []
        MarkdownDocument.watchesFiles = false
        try? FileManager.default.removeItem(at: folder)
    }

    private func open(_ text: String, name: String = "로그.md") throws -> (MarkdownDocument, DocumentWindowController, URL) {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let document = try MarkdownDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
        let store = PreferenceStore(defaults: MemoryDefaults())
        store.save(.standard)
        let controller = DocumentWindowController(preferences: store, autosavesFrame: false)
        document.addWindowController(controller)
        controller.window?.setFrameOrigin(NSPoint(x: -20000, y: 0))
        controller.window?.orderBack(nil)
        controller.load(markdown: document.markdown)
        controller.editor.layoutSubtreeIfNeeded()
        documents.append(document)
        controllers.append(controller)
        return (document, controller, url)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func disk(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// 편집기에 친다. 치기의 실행 취소 묶음은 사건이 끝나야 닫히고, 닫힐 때 문서가 '편집됨'을 다시 센다 — 앱에서는 키 사건이
    /// 끝날 때다. 시험은 사건 없이 치므로 한 차례 돌려 닫는다(안 그러면 저장한 뒤에 닫혀 저장한 문서가 다시 '편집됨'이 된다).
    private func type(_ text: String, at location: Int, in controller: DocumentWindowController) {
        controller.editor.textView.insertText(text, replacementRange: NSRange(location: location, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func save(_ document: MarkdownDocument) {
        let done = expectation(description: "저장")
        document.save(to: document.fileURL!, ofType: document.fileType!, for: .saveOperation) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// 끝에 붙은 줄은 편집기 끝에 붙는다 — 문서와 디스크가 같고, '편집됨'이 아니고, 문서 전체를 다시 칠하지 않는다.
    func testAppendedLinesComeInWithoutMarkingTheDocumentEdited() throws {
        let (document, controller, url) = try open("# 로그\n\n- 줄 1\n- 줄 2\n")
        let restyles = controller.editor.fullRestyleCount
        try append("- 줄 3\n- 줄 4\n", to: url)
        document.reconcileWithDisk()
        XCTAssertEqual(document.markdown, try disk(url))
        XCTAssertEqual(controller.editor.markdown, try disk(url))
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertEqual(controller.editor.fullRestyleCount, restyles)
        XCTAssertEqual(document.fileModificationDate, MarkdownDocument.modificationDate(of: url), "다음 저장이 막히지 않는다")
        document.reconcileWithDisk()
        XCTAssertEqual(document.markdown, try disk(url), "두 번 들이지 않는다")
    }

    /// 마디가 저장한 것을 바깥 변경으로 읽지 않는다 — 끝에 치고 저장한 뒤 바깥에서 줄이 붙어도 친 글은 한 번만.
    func testOwnSaveIsNotReadBackAsAnAppend() throws {
        let (document, controller, url) = try open("- 줄 1\n")
        let editor = controller.editor
        type("- 내가 친 줄\n", at: (editor.markdown as NSString).length, in: controller)
        XCTAssertTrue(document.isDocumentEdited)
        save(document)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertEqual(try disk(url), "- 줄 1\n- 내가 친 줄\n")
        try append("- 바깥 줄\n", to: url)
        document.reconcileWithDisk()
        XCTAssertEqual(document.markdown, "- 줄 1\n- 내가 친 줄\n- 바깥 줄\n")
        XCTAssertEqual(editor.markdown, document.markdown)
        XCTAssertEqual(editor.textView.undoManager?.canUndo, true,
                       "끝에 붙은 것은 앞의 자리를 옮기지 않는다 — 친 것을 되돌릴 수 있다")
    }

    /// 가운데가 바뀌면 다른 가운데만 갈아 끼운다 — 캐럿은 같은 글자에 남고 문서는 '편집됨'이 아니다.
    func testReplacedFileSplicesTheMiddle() throws {
        let (document, controller, url) = try open("하나\n둘\n셋\n넷\n")
        let editor = controller.editor
        let caret = (editor.markdown as NSString).range(of: "넷").location
        editor.textView.setSelectedRange(NSRange(location: caret, length: 1))
        try Data("하나\n둘이 길어졌다\n셋\n넷\n".utf8).write(to: url)
        document.reconcileWithDisk()
        XCTAssertEqual(document.markdown, "하나\n둘이 길어졌다\n셋\n넷\n")
        XCTAssertEqual((editor.markdown as NSString).substring(with: editor.textView.selectedRange()), "넷")
        XCTAssertFalse(document.isDocumentEdited)

        try Data("하나\n".utf8).write(to: url)
        document.reconcileWithDisk()
        XCTAssertEqual(editor.markdown, "하나\n", "줄어든 것도(로그를 비움)")
    }

    /// 앞머리(front matter)가 있는 문서 — 끝에 붙은 것은 본문 끝에, 앞머리가 바뀌면 카드까지 통째로.
    func testFrontMatterDocuments() throws {
        let (document, controller, url) = try open("---\ntitle: 처음\n---\n\n본문\n")
        try append("더한 줄\n", to: url)
        document.reconcileWithDisk()
        XCTAssertEqual(controller.editor.markdown, "본문\n더한 줄\n")
        XCTAssertEqual(document.markdown, try disk(url))
        try Data("---\ntitle: 바뀐 제목\n---\n\n본문\n더한 줄\n".utf8).write(to: url)
        document.reconcileWithDisk()
        XCTAssertEqual(document.markdown, try disk(url))
        XCTAssertEqual(controller.editor.markdown, "본문\n더한 줄\n")
        XCTAssertFalse(document.isDocumentEdited)
    }

    /// 여기서 고친 것이 있으면 섞지 않는다 — 띠로 묻고 자동 저장을 멈춘다. '내 것 지키기'는 내 것을 저장한다.
    func testEditedDocumentAsksAndKeepMineSavesMine() throws {
        let (document, controller, url) = try open("- 줄 1\n")
        type("고친 ", at: 0, in: controller)
        try append("- 바깥 줄\n", to: url)
        document.reconcileWithDisk()
        XCTAssertTrue(document.hasExternalConflict)
        XCTAssertTrue(controller.isShowingFileChangedElsewhere)
        XCTAssertEqual(document.markdown, "고친 - 줄 1\n", "내 것은 그대로")
        XCTAssertEqual(try disk(url), "- 줄 1\n- 바깥 줄\n", "디스크도 그대로")
        try append("- 또 바깥 줄\n", to: url)
        document.reconcileWithDisk()
        XCTAssertEqual(document.markdown, "고친 - 줄 1\n", "고를 때까지 더 들이지 않는다")

        // 고르는 중에는 자동 저장이 쓰지 않는다 — 바깥 것을 덮지도, AppKit의 '다른 앱이 바꿨다' 창을 띄우지도 않는다.
        MarkdownDocument.autosavingEnabled = true
        defer { MarkdownDocument.autosavingEnabled = false }
        let autosaved = expectation(description: "자동 저장")
        document.autosave(withImplicitCancellability: false) { error in
            XCTAssertNil(error)
            autosaved.fulfill()
        }
        wait(for: [autosaved], timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertEqual(try disk(url), "- 줄 1\n- 바깥 줄\n- 또 바깥 줄\n")
        MarkdownDocument.autosavingEnabled = false

        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.fileChangedBand.keepButton.action),
                                       to: controller.fileChangedBand.keepButton.target, from: nil))
        let deadline = Date().addingTimeInterval(5)
        while (try? disk(url)) != "고친 - 줄 1\n", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(document.hasExternalConflict)
        XCTAssertFalse(controller.isShowingFileChangedElsewhere)
        XCTAssertEqual(try disk(url), "고친 - 줄 1\n")
        XCTAssertFalse(document.isDocumentEdited)
    }

    /// '다시 읽기'는 여기서 고친 것을 버리고 디스크의 것을 읽는다.
    func testReloadDiscardsMine() throws {
        let (document, controller, url) = try open("- 줄 1\n")
        type("고친 ", at: 0, in: controller)
        try Data("- 바깥에서 다시 씀\n".utf8).write(to: url)
        document.reconcileWithDisk()
        XCTAssertTrue(document.hasExternalConflict)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.fileChangedBand.reloadButton.action),
                                       to: controller.fileChangedBand.reloadButton.target, from: nil))
        XCTAssertEqual(document.markdown, "- 바깥에서 다시 씀\n")
        XCTAssertEqual(controller.editor.markdown, "- 바깥에서 다시 씀\n")
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertFalse(document.hasExternalConflict)
        XCTAssertFalse(controller.isShowingFileChangedElsewhere)
    }

    /// 띠의 글은 띠 폭에 맞춰 줄을 바꾸고 잘리지 않는다. 단추는 띠 안에 선다. 창 폭을 바꾸면 다시 맞춘다.
    func testBandWrapsToItsWidth() throws {
        let (document, controller, url) = try open("- 줄 1\n")
        type("고친 ", at: 0, in: controller)
        try append("- 바깥 줄\n", to: url)
        document.reconcileWithDisk()
        XCTAssertTrue(controller.isShowingFileChangedElsewhere)
        let window = try XCTUnwrap(controller.window)
        let band = controller.fileChangedBand
        let label = band.label
        for width in [620.0, 1500.0, 760.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.layoutIfNeeded()
            XCTAssertEqual(band.bounds.width, controller.editor.frame.width - 24, accuracy: 1, "문서 폭을 채운다 (\(width))")
            let cell = try XCTUnwrap(label.cell)
            let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height
            XCTAssertGreaterThanOrEqual(label.frame.height + 0.5, needed, "글이 잘리지 않는다 (\(width))")
            let keep = band.keepButton.convert(band.keepButton.bounds, to: band)
            XCTAssertLessThanOrEqual(keep.maxX, band.bounds.maxX, "단추가 띠 안에 (\(width))")
            if width == 620 { XCTAssertGreaterThan(label.frame.height, 24, "좁으면 여러 줄") }
        }
    }

    /// 수정 시각만 바뀐 것(`touch`)은 바뀐 것이 아니다 — 고친 것이 있어도 묻지 않는다.
    func testTouchIsNotAChange() throws {
        let (document, controller, url) = try open("- 줄 1\n")
        type("고친 ", at: 0, in: controller)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        document.reconcileWithDisk()
        XCTAssertFalse(document.hasExternalConflict)
        XCTAssertEqual(document.markdown, "고친 - 줄 1\n")
    }

    /// 감시까지 — 파일에 줄을 붙이면 따로 부르지 않아도 들어온다.
    func testWatcherBringsAppendsIn() throws {
        MarkdownDocument.watchesFiles = true
        let (document, _, url) = try open("- 줄 1\n", name: "감시.md")
        XCTAssertEqual(document.watchedURL?.resolvingSymlinksInPath().path, url.resolvingSymlinksInPath().path)
        try append("- 줄 2\n", to: url)
        let deadline = Date().addingTimeInterval(4)
        while document.markdown != "- 줄 1\n- 줄 2\n", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(document.markdown, "- 줄 1\n- 줄 2\n")
    }
}

/// 파일 감시 — 몰아서 알리고, 바꿔 넣는 저장과 지웠다 다시 만든 파일을 따라간다.
@MainActor
final class FileChangeWatcherTests: XCTestCase {

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("madi-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 4) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testFollowsAppendsAtomicReplaceAndRecreation() throws {
        let url = folder.appendingPathComponent("log.md")
        try Data("a\n".utf8).write(to: url)
        var count = 0
        let watcher = FileChangeWatcher(url: url, interval: 0.05) { count += 1 }
        defer { watcher.cancel() }
        XCTAssertTrue(watcher.isAttached)

        try append("b\n", to: url)
        spin { count >= 1 }
        XCTAssertEqual(count, 1, "붙이기")

        try Data("바꿔 넣음\n".utf8).write(to: url, options: .atomic)
        spin { count >= 2 }
        XCTAssertGreaterThanOrEqual(count, 2, "바꿔 넣는 저장")
        spin { watcher.isAttached }
        let afterReplace = count
        try append("c\n", to: url)
        spin { count > afterReplace }
        XCTAssertGreaterThan(count, afterReplace, "새 파일에 다시 붙었다")

        try FileManager.default.removeItem(at: url)
        spin { !watcher.isAttached }
        // 첫 다시 붙기(0.05초 뒤)가 빈 자리를 만나게 기다린다 — 그다음은 1초마다 다시 열어 보는 길이다.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(watcher.isAttached)
        let afterDelete = count
        try Data("다시 만듦\n".utf8).write(to: url)
        spin(until: { count > afterDelete && watcher.isAttached }, timeout: FileChangeWatcher.retryInterval + 3)
        XCTAssertTrue(watcher.isAttached, "지웠다 다시 만든 파일에도")
        XCTAssertGreaterThan(count, afterDelete)
    }

    /// 쉬지 않고 쓰는 로그 — 신호마다 알리지 않고, 그렇다고 멈출 때까지 미루지도 않는다.
    func testCoalescesButDoesNotStarve() throws {
        let url = folder.appendingPathComponent("busy.md")
        try Data().write(to: url)
        var count = 0
        let watcher = FileChangeWatcher(url: url, interval: 0.2) { count += 1 }
        defer { watcher.cancel() }
        let start = Date()
        while Date().timeIntervalSince(start) < 1.0 {
            try append("줄\n", to: url)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThanOrEqual(count, 3, "쓰는 동안에도 알린다(0.2초마다)")
        XCTAssertLessThanOrEqual(count, 7, "쓴 횟수(약 40번)만큼 알리지 않는다")
    }
}
