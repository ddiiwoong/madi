import AppKit
import XCTest

/// `madi://` 링크 실행(`URLCommandRunner`) — 열기 · 새 문서 · 더하기(묻고 나서), 실패 알림.
///
/// 문서 관리자의 열기는 시험 프로세스에 문서 종류가 없어 쓸 수 없다 — 파일을 읽어 화면 밖 창을 붙이는 대역을 넣는다.
@MainActor
final class URLCommandRunnerTests: XCTestCase {

    private var folder: URL!
    private var controllers: [DocumentWindowController] = []
    private var documents: [MarkdownDocument] = []
    private var savedMainMenu: NSMenu?
    private var failures: [String] = []
    /// 붙이는 편집기에 줄 실행 취소 관리자. 이벤트로 묶지 않는 관리자를 주고 시험이 직접 묶는다 — 시험은 한 차례
    /// 안에서 돌아 이벤트 묶음이 닫히지 않는다.
    private var undoOverride: UndoManager?

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("madi-url-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        savedMainMenu = app.mainMenu
        app.mainMenu = AppMenu.mainMenu()
    }

    override func tearDown() async throws {
        for controller in controllers {
            controller.document?.removeWindowController(controller)
            controller.window?.orderOut(nil)
        }
        for document in documents { NSDocumentController.shared.removeDocument(document) }
        controllers = []
        documents = []
        NSApplication.shared.mainMenu = savedMainMenu
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 문서 창을 화면 밖에 붙인다 — 문서 관리자가 하는 일의 대역.
    private func attach(_ document: MarkdownDocument) -> DocumentWindowController {
        let controller = DocumentWindowController(preferences: PreferenceStore(defaults: MemoryDefaults()),
                                                  autosavesFrame: false)
        document.addWindowController(controller)
        controller.editor.undoManagerOverride = undoOverride
        controller.window?.setFrameOrigin(NSPoint(x: -20000, y: 0))
        controller.window?.orderBack(nil)
        controller.load(markdown: document.markdown)
        controllers.append(controller)
        documents.append(document)
        return controller
    }

    private func runner(confirm answer: Bool = true, asked: ((URL, String) -> Void)? = nil) -> URLCommandRunner {
        let runner = URLCommandRunner()
        runner.openDocument = { [unowned self] url, done in
            let document = MarkdownDocument()
            do {
                try document.read(from: url, ofType: "net.daringfireball.markdown")
                document.fileURL = url
                _ = self.attach(document)
                done(document, nil)
            } catch {
                done(nil, error)
            }
        }
        runner.present = { [unowned self] document in _ = self.attach(document) }
        runner.reportFailure = { [unowned self] message in self.failures.append(message) }
        runner.confirmAppend = { _, file, text, reply in
            asked?(file, text)
            reply(answer)
        }
        return runner
    }

    private func link(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    // MARK: new

    /// `madi://new` — 그 글로 새 문서. 제목이 있으면 맨 위에 `# 제목`, 저장할 때의 이름으로도 제안한다. 글이 있으니
    /// '편집됨'(닫을 때 묻는다).
    func testNewOpensAnUnsavedDocumentWithTheText() throws {
        runner().handle(try link("madi://new?text=\(encoded("본문 한 줄"))&title=\(encoded("회의 메모"))"))
        let controller = try XCTUnwrap(controllers.last)
        let document = try XCTUnwrap(documents.last)
        XCTAssertEqual(controller.editor.markdown, "# 회의 메모\n\n본문 한 줄")
        XCTAssertEqual(document.displayName, "회의 메모")
        XCTAssertNil(document.fileURL, "저장하지 않았다 — 자리는 사용자가 고른다")
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertTrue(failures.isEmpty)
    }

    // MARK: open

    /// `madi://open` — 열고, 파일의 줄 번호(front matter 포함)로 가고, 낱말을 찾는다.
    func testOpenGoesToTheFileLineAndSearches() throws {
        let file = try write("---\ntitle: 메모\n---\n\n# 제목\n\n첫 문단\n\n마디가 있는 문단\n", to: "메모.md")
        // 9번째 줄 = 본문의 5번째 줄("마디가 있는 문단").
        runner().handle(try link("madi://open?path=\(encoded(file.path))&line=9&search=\(encoded("마디"))"))
        let controller = try XCTUnwrap(controllers.last)
        let body = controller.editor.markdown as NSString
        XCTAssertEqual(body.substring(from: controller.editor.textView.selectedRange().location)
            .components(separatedBy: "\n").first, "마디가 있는 문단", "9번째 줄로 갔다")
        XCTAssertEqual(controller.editor.searchMatchCount, 1, "낱말을 찾았다")
        XCTAssertTrue(failures.isEmpty)
    }

    func testOpenMissingFileFailsWithoutOpening() throws {
        runner().handle(try link("madi://open?path=\(encoded(folder.appendingPathComponent("없음.md").path))"))
        XCTAssertTrue(controllers.isEmpty)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("없음.md"))
    }

    func testBadLinkIsReportedNotRun() throws {
        runner().handle(try link("madi://append?path=~/.ssh/authorized_keys&text=x"))
        XCTAssertTrue(controllers.isEmpty)
        XCTAssertEqual(failures, [MadiURL.Failure.unsupportedFile(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/authorized_keys")
                .standardizedFileURL.path).message])
    }

    // MARK: append

    /// `madi://append` — 문서 창에 무엇을 더하는지 보이고 묻는다. 더하면 끝에 붙고(목록 뒤의 항목은 같은 목록으로 —
    /// 규칙은 `MadiURL.appendEdit`), 실행 취소 한 번에 되돌아간다. 취소하면 그대로다.
    func testAppendAsksFirstThenAddsUndoably() throws {
        let file = try write("# 할 일\n\n- [ ] 빵", to: "할일.md")
        let undo = UndoManager()
        undo.groupsByEvent = false
        undoOverride = undo
        var asked: [(URL, String)] = []
        undo.beginUndoGrouping()
        runner(confirm: true, asked: { asked.append(($0, $1)) })
            .handle(try link("madi://append?path=\(encoded(file.path))&text=\(encoded("- [ ] 우유"))"))
        undo.endUndoGrouping()
        let controller = try XCTUnwrap(controllers.last)
        XCTAssertEqual(asked.map(\.0.lastPathComponent), ["할일.md"])
        XCTAssertEqual(asked.map(\.1), ["- [ ] 우유"])
        XCTAssertEqual(controller.editor.markdown, "# 할 일\n\n- [ ] 빵\n- [ ] 우유\n")
        XCTAssertEqual(undo.undoActionName, "링크로 더하기")
        undo.undo()
        XCTAssertEqual(controller.editor.markdown, "# 할 일\n\n- [ ] 빵", "한 번에 되돌아간다")
    }

    func testAppendDeclinedLeavesTheDocumentAlone() throws {
        let file = try write("# 할 일\n", to: "할일.md")
        runner(confirm: false).handle(try link("madi://append?path=\(encoded(file.path))&text=x"))
        let controller = try XCTUnwrap(controllers.last)
        XCTAssertEqual(controller.editor.markdown, "# 할 일\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# 할 일\n", "파일도 그대로")
    }
}
