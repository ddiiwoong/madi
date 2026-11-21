import AppKit
import XCTest

/// 파일 종류 — 확장자로 마크다운 · 글 · 로그를 가린다(`TextFileKind`).
final class TextFileKindTests: XCTestCase {

    private func kind(_ name: String) -> TextFileKind { TextFileKind(url: URL(fileURLWithPath: "/tmp/\(name)")) }

    func testKindComesFromTheExtension() {
        XCTAssertEqual(TextFileKind(url: nil), .markdown, "저장하지 않은 새 문서는 마크다운")
        for name in ["a.md", "a.MARKDOWN", "a.mdown", "a.mkd", "a.mkdn", "a.mdx"] {
            XCTAssertEqual(kind(name), .markdown, name)
        }
        for name in ["메모.txt", "a.TEXT", "표.csv", "README"] {
            XCTAssertEqual(kind(name), .plainText, name)
        }
        for name in ["app.log", "SERVER.LOG"] {
            XCTAssertEqual(kind(name), .log, name)
        }
        XCTAssertTrue(TextFileKind.markdown.rendersMarkdown)
        XCTAssertFalse(TextFileKind.plainText.rendersMarkdown)
        XCTAssertFalse(TextFileKind.log.rendersMarkdown)
        XCTAssertEqual([TextFileKind.markdown, .plainText, .log].map(\.followsByDefault), [false, false, true])
    }

    /// `madi://open`도 로그를 연다. 마크다운 · 글 · 로그가 아닌 것은 여전히 거절한다.
    func testLinksOpenLogs() throws {
        let url = try XCTUnwrap(MadiURL.url(from: "madi://open?path=/tmp/app.log"))
        XCTAssertEqual(MadiURL.parse(url), .success(.open(file: URL(fileURLWithPath: "/tmp/app.log"), line: nil, search: nil)))
        let hosts = try XCTUnwrap(MadiURL.url(from: "madi://open?path=/etc/hosts"))
        XCTAssertEqual(MadiURL.parse(hosts), .failure(.unsupportedFile("/etc/hosts")))
        XCTAssertTrue(MadiURL.supportedExtensions.isSuperset(of: ["md", "markdown", "txt", "text", "log"]))
    }
}

/// 편집기 — 글 파일은 원본 보기에서 마크다운 표식을 흐리게 하지 않고, 목차를 비운다.
@MainActor
final class PlainTextEditorTests: XCTestCase {

    private func color(at index: Int, in editor: MarkdownEditorView) -> NSColor? {
        editor.textView.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    func testPlainTextDoesNotDimMarkersOrMakeAnOutline() {
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        editor.markdown = "# 주석\n- 줄\n본문\n"
        editor.isCodeView = true
        XCTAssertNotEqual(color(at: 0, in: editor), color(at: 2, in: editor), "마크다운 문서의 원본 보기는 `#`을 흐리게")
        XCTAssertEqual(editor.outline.map(\.title), ["주석"])

        editor.isPlainText = true
        XCTAssertEqual(color(at: 0, in: editor), color(at: 2, in: editor), "글 파일은 `#`도 글")
        XCTAssertEqual(color(at: 5, in: editor), color(at: 7, in: editor), "`-`도 글")
        XCTAssertEqual(editor.outline.count, 0, "로그의 `# ` 줄은 제목이 아니다")
        XCTAssertEqual(editor.markdown, "# 주석\n- 줄\n본문\n")

        editor.isCodeView = false
        XCTAssertEqual(editor.outline.map(\.title), ["주석"], "마크다운으로 보면 목차가 찬다")
    }
}

/// 문서 창 — `.txt` · `.log`를 쓴 그대로 보이고, 로그는 따라 보기로 연다. 따라 보기는 고칠 수 없게 하고 끝을 따라간다.
@MainActor
final class TextFileWindowTests: XCTestCase {

    private var folder: URL!
    private var documents: [MarkdownDocument] = []
    private var controllers: [DocumentWindowController] = []
    private var savedMainMenu: NSMenu?

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("madi-textfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 체크 표시는 앱 메뉴에 단다(`DocumentWindowControllerTests`와 같다).
        savedMainMenu = NSApplication.shared.mainMenu
        NSApp.mainMenu = AppMenu.mainMenu()
    }

    override func tearDown() async throws {
        for controller in controllers { controller.window?.orderOut(nil) }
        for document in documents { document.close() }
        controllers = []
        documents = []
        NSApp.mainMenu = savedMainMenu
        try? FileManager.default.removeItem(at: folder)
    }

    private func open(_ text: String, name: String, type: String = "public.plain-text")
        throws -> (MarkdownDocument, DocumentWindowController, URL) {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let document = try MarkdownDocument(contentsOf: url, ofType: type)
        let store = PreferenceStore(defaults: MemoryDefaults())
        store.save(.standard)
        let controller = DocumentWindowController(preferences: store, autosavesFrame: false)
        document.addWindowController(controller)
        controller.window?.setFrameOrigin(NSPoint(x: -20000, y: 0))
        controller.window?.orderBack(nil)
        controller.load(markdown: document.markdown)
        controller.window?.layoutIfNeeded()
        documents.append(document)
        controllers.append(controller)
        return (document, controller, url)
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func type(_ text: String, at location: Int, in controller: DocumentWindowController) {
        controller.editor.textView.insertText(text, replacementRange: NSRange(location: location, length: 0))
        settle()
    }

    private func menuItem(_ action: Selector, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let found = menuItem(action, in: item.submenu) { return found }
        }
        return nil
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private static let logLines = (1 ... 300).map { "2026-11-21 10:00:\($0 % 60) INFO  [main] 줄 \($0)" }

    /// 로그는 쓴 그대로(앞머리 · 제목 · 숨긴 표식 없이), 원본 보기 · 따라 보기로 연다 — 끝에서 시작하고, 고칠 수 없고, 붙는 줄을
    /// 따라간다.
    func testLogOpensAsWrittenAndFollowsTheEnd() throws {
        let text = "---\nnot: front matter\n---\n# 주석처럼 보이는 줄\n**별표** _밑줄_\n---\n"
            + Self.logLines.joined(separator: "\n") + "\n"
        let (document, controller, url) = try open(text, name: "app.log")
        let editor = controller.editor
        settle()
        XCTAssertEqual(controller.fileKind, .log)
        XCTAssertEqual(editor.markdown, text, "앞머리를 가르지 않는다 — 글 전체가 편집기에")
        XCTAssertTrue(controller.frontMatterCard.isHidden)
        XCTAssertTrue(editor.isCodeView)
        XCTAssertTrue(editor.isPlainText)
        XCTAssertTrue(editor.isFollowing)
        XCTAssertFalse(editor.textView.isEditable)
        XCTAssertTrue(editor.isShowingEnd, "끝에서 시작한다")
        XCTAssertEqual(editor.outline.count, 0)
        XCTAssertEqual(controller.window?.subtitle, String(localized: "따라 보기"))
        XCTAssertEqual(menuItem(#selector(DocumentWindowController.toggleFollowAction(_:)))?.state, .on)
        XCTAssertEqual(menuItem(#selector(DocumentWindowController.toggleCodeViewAction(_:)))?.state, .on)

        // 칠 수 없다 — 글도 문서도 그대로.
        type("x", at: 0, in: controller)
        XCTAssertEqual(editor.markdown, text)
        XCTAssertFalse(document.isDocumentEdited)

        // 붙는 줄을 따라간다. `---`로 시작하는 로그라도 끝에 붙인다(앞머리를 가르지 않으니 닫힐 것이 없다).
        try append("2026-11-21 10:05:00 WARN  새 줄\n---\n", to: url)
        document.reconcileWithDisk()
        controller.window?.layoutIfNeeded()
        XCTAssertEqual(editor.markdown, text + "2026-11-21 10:05:00 WARN  새 줄\n---\n")
        XCTAssertTrue(editor.isShowingEnd)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertFalse(controller.isShowingFileChangedElsewhere)

        // 가운데가 바뀌어도(로그를 돌려 다시 씀) 바뀐 곳만 갈아 끼운다 — `---`로 시작해도 앞머리로 보지 않으니 통째로 싣지 않는다.
        let restyles = editor.fullRestyleCount
        let rewritten = editor.markdown.replacingOccurrences(of: "줄 150\n", with: "줄 150 (고침)\n")
        try Data(rewritten.utf8).write(to: url)
        document.reconcileWithDisk()
        XCTAssertEqual(editor.markdown, rewritten)
        XCTAssertEqual(editor.fullRestyleCount, restyles, "문서 전체를 다시 칠하지 않았다")
        XCTAssertFalse(document.isDocumentEdited)
    }

    /// `.txt`는 원본 보기로 열되 따라 보지 않고 고칠 수 있다. 원본 보기를 끄면 마크다운으로 그린다. 저장은 쓴 그대로 — `---` 줄도
    /// 그 자리에. 다시 읽어도 고른 보기를 둔다.
    func testTextFileOpensAsWrittenAndCanBeShownAsMarkdown() throws {
        let text = "---\ntitle: 앞머리처럼\n---\n# 텍스트 파일\n본문 줄\n"
        let (document, controller, url) = try open(text, name: "메모.txt")
        let editor = controller.editor
        XCTAssertEqual(controller.fileKind, .plainText)
        XCTAssertEqual(editor.markdown, text)
        XCTAssertTrue(controller.frontMatterCard.isHidden)
        XCTAssertTrue(editor.isCodeView)
        XCTAssertFalse(editor.isFollowing)
        XCTAssertTrue(editor.textView.isEditable)
        XCTAssertEqual(controller.window?.subtitle, "")
        XCTAssertEqual(menuItem(#selector(DocumentWindowController.toggleFollowAction(_:)))?.state, .off)

        controller.toggleCodeViewAction(nil)
        XCTAssertFalse(editor.isCodeView)
        XCTAssertEqual(controller.window?.subtitle, String(localized: "마크다운으로 보기"))
        // 앞머리를 가르지 않았으니 `title:` 줄도 마크다운의 제목(`---` 밑줄)으로 읽힌다 — 마크다운으로 적은 글이면 `.md`로 둔다.
        XCTAssertTrue(controller.outlineEntries.map(\.title).contains("텍스트 파일"), "마크다운으로 보면 목차가 찬다")

        type("더한 ", at: (editor.markdown as NSString).range(of: "본문").location, in: controller)
        let saved = expectation(description: "저장")
        document.save(to: url, ofType: try XCTUnwrap(document.fileType), for: .saveOperation) { _ in saved.fulfill() }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "---\ntitle: 앞머리처럼\n---\n# 텍스트 파일\n더한 본문 줄\n")

        // `---`로 시작해도 붙은 줄은 끝에 붙인다 — 실행 취소가 남는다(갈아 끼우면 비운다).
        try append("붙은 줄\n", to: url)
        document.reconcileWithDisk()
        XCTAssertEqual(editor.markdown, "---\ntitle: 앞머리처럼\n---\n# 텍스트 파일\n더한 본문 줄\n붙은 줄\n")
        XCTAssertEqual(editor.textView.undoManager?.canUndo, true, "끝에 붙였다 — 친 것을 되돌릴 수 있다")

        try document.revert(toContentsOf: url, ofType: try XCTUnwrap(document.fileType))
        XCTAssertFalse(editor.isCodeView, "다시 읽어도 고른 보기 그대로")
        XCTAssertEqual(editor.markdown, "---\ntitle: 앞머리처럼\n---\n# 텍스트 파일\n더한 본문 줄\n붙은 줄\n")
    }

    /// 다른 이름으로 저장해 종류가 바뀌면(`.md` → `.txt`) 글 파일로 다루되 보기는 그대로 둔다 — 저장했을 뿐인데 화면이 바뀌면
    /// 안 된다. 부제가 지금 보기를 말한다.
    func testSavingAsATextFileKeepsTheView() throws {
        let (document, controller, _) = try open("# 제목\n본문\n", name: "글.md", type: "net.daringfireball.markdown")
        XCTAssertFalse(controller.editor.isPlainText)
        document.fileURL = folder.appendingPathComponent("글.txt")
        XCTAssertEqual(controller.fileKind, .plainText)
        XCTAssertTrue(controller.editor.isPlainText)
        XCTAssertFalse(controller.editor.isCodeView)
        XCTAssertEqual(controller.window?.subtitle, String(localized: "마크다운으로 보기"))
    }

    /// 글 파일은 창 폭을 다 쓴다 — 창을 넓히면 줄도 길어진다. 마크다운 문서는 읽기 좋은 폭(보통 840pt)에서 멈춘다. 글 파일을
    /// 마크다운으로 보면 문서처럼 멈춘다.
    func testTextFilesUseTheWindowWidth() throws {
        let line = "2026-11-21 10:00:00 INFO  [main] " + String(repeating: "긴 로그 내용 abc ", count: 20)
        let (_, log, _) = try open((1 ... 50).map { "\($0) \(line)" }.joined(separator: "\n") + "\n", name: "긴.log")
        let (_, markdown, _) = try open("# 제목\n\n" + line + "\n", name: "글.md", type: "net.daringfireball.markdown")
        func column(_ controller: DocumentWindowController, at width: CGFloat) throws -> CGFloat {
            let window = try XCTUnwrap(controller.window)
            window.setContentSize(NSSize(width: width, height: 700))
            window.layoutIfNeeded()
            settle()
            return controller.editor.textView.textColumnWidth
        }
        XCTAssertGreaterThan(try column(log, at: 1800), 1650, "넓은 창을 다 쓴다")
        XCTAssertGreaterThan(try column(log, at: 1200), 1080)
        XCTAssertLessThan(try column(log, at: 1200), 1200)
        XCTAssertLessThan(try column(markdown, at: 1800), 900, "마크다운 문서는 읽기 좋은 폭에서 멈춘다")

        log.toggleCodeViewAction(nil)
        XCTAssertLessThan(try column(log, at: 1800), 900, "마크다운으로 보면 문서처럼")
        log.toggleCodeViewAction(nil)
        XCTAssertGreaterThan(try column(log, at: 1800), 1650)

        // 다른 이름으로 저장해 마크다운이 되면 문서처럼 멈춘다(보기는 원본 보기 그대로).
        let (document, text, _) = try open(line + "\n", name: "메모.txt")
        XCTAssertGreaterThan(try column(text, at: 1800), 1650)
        document.fileURL = folder.appendingPathComponent("메모.md")
        XCTAssertTrue(text.editor.isCodeView)
        XCTAssertLessThan(try column(text, at: 1800), 900)
    }

    /// 따라 보기에서 끝을 보고 있으면 창 크기 · 글자 크기 · 보기를 바꿔도 끝에 남는다 — 좁히면 줄이 더 감겨 글이 길어진다. 위를
    /// 읽는 중이면 끌어 내리지 않는다.
    func testFollowingStaysAtTheEndWhenTheSizeChanges() throws {
        let line = "2026-11-21 10:00:00 INFO  [main] " + String(repeating: "긴 로그 내용 abc ", count: 20)
        let (_, controller, _) = try open((1 ... 300).map { "\($0) \(line)" }.joined(separator: "\n") + "\n",
                                          name: "긴.log")
        let editor = controller.editor
        let window = try XCTUnwrap(controller.window)
        func resize(_ width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 700))
            window.layoutIfNeeded()
            settle()
        }
        resize(1600)
        editor.scrollToEnd()
        XCTAssertTrue(editor.isShowingEnd, "시험의 전제")
        let tall = editor.textView.frame.height
        resize(900)
        XCTAssertGreaterThan(editor.textView.frame.height, tall, "시험의 전제 — 좁히면 글이 길어진다")
        XCTAssertTrue(editor.isShowingEnd, "좁혀도 끝")
        resize(1400)
        XCTAssertTrue(editor.isShowingEnd, "넓혀도 끝")
        controller.makeTextLargerAction(nil)
        controller.makeTextLargerAction(nil)
        settle()
        XCTAssertTrue(editor.isShowingEnd, "글자를 키워도 끝")
        controller.toggleCodeViewAction(nil)
        settle()
        XCTAssertTrue(editor.isShowingEnd, "보기를 바꿔도 끝")
        controller.toggleCodeViewAction(nil)
        settle()

        editor.clipView.scroll(to: NSPoint(x: 0, y: 200))
        XCTAssertFalse(editor.isShowingEnd)
        resize(1000)
        XCTAssertFalse(editor.isShowingEnd, "위를 읽는 중이면 그 자리에")
        controller.makeTextSmallerAction(nil)
        settle()
        XCTAssertFalse(editor.isShowingEnd)
    }

    /// 마크다운 문서는 전과 같다 — 앞머리는 카드로, 마크다운으로 그리고, 고칠 수 있다. 따라 보기를 켜면 끝으로 가고 고칠 수
    /// 없고(치기 · 서식 · 서식 막대), 끄면 다시 고칠 수 있다. 메뉴의 체크와 창 부제가 따라온다.
    func testFollowModeIsReadOnlyUntilTurnedOff() throws {
        let body = (1 ... 200).map { "- 줄 \($0)" }.joined(separator: "\n") + "\n"
        let (document, controller, _) = try open("---\ntitle: 글\n---\n\n" + body, name: "글.md",
                                                 type: "net.daringfireball.markdown")
        let editor = controller.editor
        let follow = try XCTUnwrap(menuItem(#selector(DocumentWindowController.toggleFollowAction(_:))))
        XCTAssertEqual(follow.keyEquivalent, "l")
        XCTAssertEqual(follow.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(controller.fileKind, .markdown)
        XCTAssertFalse(controller.frontMatterCard.isHidden, "앞머리는 카드로")
        XCTAssertEqual(editor.markdown, body)
        XCTAssertFalse(editor.isCodeView)
        XCTAssertFalse(editor.isPlainText)
        XCTAssertFalse(editor.isFollowing)
        XCTAssertEqual(follow.state, .off)

        // 고른 글 위의 서식 막대는 따라 보기를 켜면 걷힌다.
        editor.formatBarDelay = 0
        controller.window?.makeFirstResponder(editor.textView)
        editor.textView.setSelectedRange(NSRange(location: 2, length: 4))
        settle()
        XCTAssertEqual(editor.formatBar?.isHidden, false, "시험의 전제 — 고칠 수 있을 때는 막대가 뜬다")

        controller.toggleFollowAction(nil)
        settle()
        XCTAssertTrue(editor.formatBar?.isHidden ?? true, "켜면 막대를 걷는다")
        XCTAssertTrue(editor.isFollowing)
        XCTAssertFalse(editor.textView.isEditable)
        XCTAssertTrue(editor.isShowingEnd)
        XCTAssertEqual(follow.state, .on)
        XCTAssertEqual(controller.window?.subtitle, String(localized: "따라 보기"))
        type("x", at: 0, in: controller)
        editor.textView.setSelectedRange(NSRange(location: 2, length: 3))
        editor.formatBoldAction(nil)
        XCTAssertEqual(editor.markdown, body, "치기도 서식도 들지 않는다")
        XCTAssertFalse(document.isDocumentEdited)
        editor.textView.setSelectedRange(NSRange(location: 2, length: 4))
        settle()
        XCTAssertTrue(editor.formatBar?.isHidden ?? true, "고쳐 넣는 서식 막대를 띄우지 않는다")
        controller.toggleCodeViewAction(nil)
        XCTAssertEqual(controller.window?.subtitle, String(localized: "원본 보기") + " · " + String(localized: "따라 보기"))
        controller.toggleCodeViewAction(nil)

        controller.toggleFollowAction(nil)
        XCTAssertFalse(editor.isFollowing)
        XCTAssertTrue(editor.textView.isEditable)
        XCTAssertEqual(follow.state, .off)
        XCTAssertEqual(controller.window?.subtitle, "")
        type("x", at: 0, in: controller)
        XCTAssertEqual(editor.markdown, "x" + body)
        XCTAssertTrue(document.isDocumentEdited)
        document.updateChangeCount(.changeCleared)
    }
}
