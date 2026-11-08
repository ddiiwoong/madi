import AppKit
import XCTest

/// 기능 시험 문서(`docs/samples/madi-sample.md`)를 문서 창에 열어, 절마다 적어 둔 것이 그대로 그려지는지 본다(사용자 —
/// "테스트 진행할 여러 다양한 콘텐츠가 포함된 문서 하나 샘플로 남겨 줘"). 문서를 고치면 이 시험의 숫자도 함께 고친다.
///
/// 저장소의 문서를 그대로 열지 않고 임시 폴더에 그림과 함께 복사해 연다 — 창이 문서를 고치거나 저장해도 저장소는 그대로다.
@MainActor
final class SampleDocumentTests: XCTestCase {

    private var controllers: [DocumentWindowController] = []
    private var documents: [MarkdownDocument] = []
    private var folder: URL!
    private var savedMainMenu: NSMenu?

    static let sample = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/samples/madi-sample.md")

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("madi-sample-\(UUID().uuidString)")
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
        controllers = []
        documents = []
        NSApplication.shared.mainMenu = savedMainMenu
        try? FileManager.default.removeItem(at: folder)
    }

    private func openSample() throws -> (MarkdownDocument, DocumentWindowController, String) {
        let source = try String(contentsOf: Self.sample, encoding: .utf8)
        let copy = folder.appendingPathComponent("madi-sample.md")
        try FileManager.default.copyItem(at: Self.sample, to: copy)
        try FileManager.default.copyItem(at: Self.sample.deletingPathExtension().appendingPathExtension("assets"),
                                         to: folder.appendingPathComponent("madi-sample.assets"))
        let document = MarkdownDocument()
        try document.read(from: Data(contentsOf: copy), ofType: "net.daringfireball.markdown")
        let store = PreferenceStore(defaults: MemoryDefaults())
        store.save(.standard)
        let controller = DocumentWindowController(preferences: store, autosavesFrame: false)
        document.addWindowController(controller)
        document.fileURL = copy
        controller.window?.setFrameOrigin(NSPoint(x: -20000, y: 0))
        controller.window?.orderBack(nil)
        controller.load(markdown: document.markdown)
        controller.editor.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        controllers.append(controller)
        documents.append(document)
        return (document, controller, source)
    }

    private func storage(_ controller: DocumentWindowController) -> NSTextStorage {
        controller.editor.textView.textStorage!
    }

    /// 열어도 문서는 한 바이트도 바뀌지 않는다 — front matter까지.
    func testOpeningKeepsTheDocumentByteForByte() throws {
        let (document, controller, source) = try openSample()
        XCTAssertEqual(document.markdown, source)
        XCTAssertEqual(try document.data(ofType: "net.daringfireball.markdown"), Data(source.utf8))
        XCTAssertTrue(controller.editor.markdown.hasPrefix("# 마디 기능 시험 문서"), "편집기에는 본문만")
        XCTAssertFalse(document.isDocumentEdited)
    }

    /// 맨 위 카드 — 항목 다섯, 링크 열두 개 가운데 여덟만 보이고 `외 4개`.
    func testFrontMatterCardFoldsTheLongList() throws {
        let (_, controller, _) = try openSample()
        let card = try XCTUnwrap(controller.editor.textView.subviews.compactMap { $0 as? FrontMatterCardView }.first)
        XCTAssertFalse(card.isHidden)
        XCTAssertTrue(card.visibleText.contains("문서 메타데이터 · 5개 항목"), card.visibleText)
        XCTAssertTrue(card.visibleText.contains("외 4개"))
        XCTAssertLessThanOrEqual(card.frame.maxX, controller.editor.textView.bounds.width + 0.5)
    }

    /// 절 제목들이 목차에 모두 나온다 — 밑줄 제목 둘까지.
    func testOutlineListsEverySection() throws {
        let (_, controller, _) = try openSample()
        let titles = controller.editor.outline.map(\.title)
        for expected in ["마디 기능 시험 문서", "1. 글자 꾸밈 — 표시가 숨고 모양만 남아야 합니다", "제목 6", "밑줄 제목 1",
                         "밑줄 제목 2", "10. 구분선 · HTML · 그 밖"] {
            XCTAssertTrue(titles.contains(expected), "\(expected) 가 목차에 없다: \(titles)")
        }
        XCTAssertEqual(titles.filter { $0.first?.isNumber == true }.count, 10, "절 열 개")
    }

    /// 꾸밈 — 겹친 굵게 · 기울임의 표시와 Notion의 `****`가 숨는다. 글자로 남아야 하는 별표는 남는다.
    func testEmphasisMarkersHide() throws {
        let (_, controller, _) = try openSample()
        let text = controller.editor.markdown as NSString
        let store = storage(controller)
        func hidden(_ fragment: String, offset: Int = 0) -> Bool {
            let range = text.range(of: fragment)
            return store.attribute(.mdHiddenMarker, at: range.location + offset, effectiveRange: nil) != nil
        }
        XCTAssertTrue(hidden("***굵고 기울임***"), "***")
        XCTAssertTrue(hidden("(****`user", offset: 1), "Notion의 ****")
        XCTAssertTrue(hidden("***왜 이렇게"), "굵고 기울인 머리")
        XCTAssertFalse(hidden("\\*별표 그대로", offset: 1), "이스케이프한 별표는 글자")
        XCTAssertFalse(hidden("5 * 3", offset: 2), "곱하기 별표는 글자")
    }

    /// 목록 · 인용 · 알림 · 각주 — 할 일 상자 셋, 알림 머리 다섯, 인용 막대, 각주 참조 둘.
    func testBlocksAndFootnotes() throws {
        let (_, controller, _) = try openSample()
        let view = controller.editor.textView
        XCTAssertEqual(view.taskBoxes.count, 3)
        XCTAssertEqual(view.alertTitles.map(\.alert), [.note, .tip, .important, .warning, .caution])
        XCTAssertFalse(view.quoteBars.isEmpty)
        var references = 0
        storage(controller).enumerateAttribute(.mdFootnoteJump, in: NSRange(location: 0, length: storage(controller).length)) {
            value, _, _ in if (value as? String)?.hasPrefix("definition:") == true { references += 1 }
        }
        XCTAssertEqual(references, 2, "각주 참조 둘")
    }

    /// 표 셋은 격자, 열 열두 개 표와 긴 줄의 코드 블록은 글 칸보다 넓다(가로로 굴린다). 로컬 그림 둘이 그려진다 — 끝에 `\`가
    /// 붙은 줄까지. 글 사이에 끼인 그림과 없는 그림은 그리지 않는다.
    func testTablesWideBlocksAndImages() throws {
        let (_, controller, _) = try openSample()
        let editor = controller.editor
        let view = editor.textView
        let text = editor.markdown as NSString
        XCTAssertEqual(editor.drawnTableCount, 3)
        let wide = view.imagePlacements.filter(view.isWide)
        let wideCode = wide.filter { editor.codeRendering(at: $0.lineRange) != nil }
        XCTAssertEqual(wideCode.count, 1, "kubectl 블록만 넓다")
        XCTAssertTrue(text.substring(with: wideCode[0].lineRange).hasPrefix("```bash"))
        XCTAssertEqual(wide.count - wideCode.count, 1, "열 열두 개 표만 넓다 — 다른 표는 칸 안에서 줄을 바꾼다")

        let pictures = view.imagePlacements.filter { text.substring(with: $0.lineRange).hasPrefix("![") }
        XCTAssertEqual(pictures.count, 2, "자기 줄의 그림 둘(끝의 \\ 포함)")
        XCTAssertTrue(pictures.allSatisfy { $0.size.width > 100 })
    }
}
