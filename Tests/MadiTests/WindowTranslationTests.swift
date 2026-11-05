import AppKit
import XCTest

/// 창에서 번역하기 — ⌘⇧T(선택은 제자리, 없으면 새 문서), ⌃⌘T(나란히 보기), 실패 알림.
///
/// 번역기와 언어 팩은 대역이다(`DocumentWindowController.TranslatorStub`). 계획·다시 번역·조립은 실제
/// 코드를 지난다 — 대역은 글자만 바꾼다.
@available(macOS 26.0, *)
@MainActor
final class WindowTranslationTests: XCTestCase {

    private var controllers: [DocumentWindowController] = []
    private var documents: [MarkdownDocument] = []
    private var copies: [MarkdownDocument] = []

    override func tearDown() async throws {
        for controller in controllers {
            controller.window?.attachedSheet.map { controller.window?.endSheet($0) }
            if let session = controller.sideBySide {
                session.document.updateChangeCount(.changeCleared)
                controller.closeSideBySide()
            }
            controller.document?.removeWindowController(controller)
            controller.window?.orderOut(nil)
        }
        for copy in copies {
            copy.updateChangeCount(.changeCleared)
            copy.close()
        }
        controllers = []
        documents = []
        copies = []
    }

    /// 낱말을 바꾸는 번역기. 자리표는 그대로 둔다.
    nonisolated private static let words: [String: String] = [
        "본문": "Body", "제목": "Title", "둘째": "Second", "문단": "paragraph", "굵게": "bold",
    ]

    nonisolated private static func translate(_ text: String) -> String {
        var out = text
        for (korean, english) in words.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: korean, with: english)
        }
        return out
    }

    private func open(_ markdown: String, installed: Bool = true,
                      translate: @escaping @Sendable (String) async throws -> String = { WindowTranslationTests.translate($0) })
        -> (MarkdownDocument, DocumentWindowController) {
        let store = PreferenceStore(defaults: MemoryDefaults())
        let document = MarkdownDocument()
        document.markdown = markdown
        let controller = DocumentWindowController(preferences: store, autosavesFrame: false)
        document.addWindowController(controller)
        controller.window?.setFrameOrigin(NSPoint(x: -20000, y: 0))
        controller.window?.orderBack(nil)
        controller.load(markdown: markdown)
        controller.translatorStub = .init(installed: installed, translate: translate)
        controller.presentTranslatedCopy = { [weak self] in self?.copies.append($0) }
        controllers.append(controller)
        documents.append(document)
        return (document, controller)
    }

    private func finish(_ controller: DocumentWindowController) async {
        await controller.translationTask?.value
    }

    private let english = TranslationDirection(source: "ko", target: "en")

    // MARK: ⌘⇧T

    func testSelectionIsTranslatedInPlace() async throws {
        let (document, controller) = open("# 제목\n\n본문 **굵게**\n\n둘째 문단\n")
        let ns = controller.editor.markdown as NSString
        controller.editor.textView.setSelectedRange(ns.range(of: "본문 **굵게**"))
        controller.translateAction(nil)
        await finish(controller)

        XCTAssertEqual(controller.editor.markdown, "# 제목\n\nBody **bold**\n\n둘째 문단\n", "고른 곳만, 마크업은 그대로")
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertTrue(copies.isEmpty, "새 문서를 열지 않는다")
        XCTAssertNil(controller.window?.attachedSheet, "진행 시트는 끝나면 닫힌다")
    }

    func testWithoutASelectionTheWholeDocumentOpensAsANewDocument() async throws {
        let source = "---\ntitle: 제목\nslug: jemok\n---\n# 제목\n\n본문\n"
        let (document, controller) = open(source)
        document.updateChangeCount(.changeCleared)
        controller.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.translateAction(nil)
        await finish(controller)

        let copy = try XCTUnwrap(copies.first, "번역본이 새 문서로 열린다")
        XCTAssertEqual(copy.markdown, "---\ntitle: Title\nslug: jemok\n---\n# Title\n\nBody\n",
                       "front matter는 title만 옮기고 slug는 그대로")
        XCTAssertTrue(copy.isDocumentEdited, "저장하지 않은 새 문서")
        XCTAssertEqual(controller.editor.markdown, "# 제목\n\n본문\n", "원문은 그대로")
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === copy })
    }

    func testAMissingLanguagePackShowsASheetAndChangesNothing() async throws {
        let (_, controller) = open("본문\n", installed: false)
        controller.editor.textView.setSelectedRange(NSRange(location: 0, length: 2))
        controller.translateAction(nil)
        await finish(controller)

        let sheet = try XCTUnwrap(controller.window?.attachedSheet, "이 창에 붙는 시트로 알린다 — 앱 전체를 막지 않는다")
        let texts = sheet.contentView.map(Self.texts(in:)) ?? []
        XCTAssertTrue(texts.contains { $0.contains(String(localized: "언어 설정 열기")) },
                      "받을 곳으로 가는 단추: \(texts)")
        XCTAssertEqual(controller.editor.markdown, "본문\n")
        XCTAssertTrue(copies.isEmpty)
    }

    func testRepairedSentencesAreLogged() async throws {
        // `{{n}}`의 감싼 표시만 버리는 번역기 — 실제로 본 실패. 다른 꼴로 다시 번역해 링크를 지킨다.
        let (_, controller) = open("본문 [문단](https://example.com) 끝\n", translate: { text in
            let regex = try! NSRegularExpression(pattern: #"\{\{(\d+)\}\}"#)
            return WindowTranslationTests.translate(regex.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1"))
        })
        let before = AppLog.shared.count
        controller.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.translateAction(nil)
        await finish(controller)

        XCTAssertEqual(copies.first?.markdown, "Body [paragraph](https://example.com) 끝\n")
        let recent = AppLog.shared.entries.prefix(AppLog.shared.count - before)
        XCTAssertTrue(recent.contains { $0.message == String(localized: "번역기가 링크·강조·각주 표시를 잃은 문장을 다시 번역했습니다") },
                      "다시 번역한 것을 기록에 남긴다")
    }

    // MARK: ⌃⌘T

    func testSideBySideTranslatesIntoTheRightPane() async throws {
        let (_, controller) = open("# 제목\n\n본문\n")
        controller.toggleSideBySideAction(nil)
        await finish(controller)

        let session = try XCTUnwrap(controller.sideBySide)
        XCTAssertEqual(session.pane.editor.markdown, "# Title\n\nBody\n")
        XCTAssertTrue(session.pane.window === controller.window)
        XCTAssertTrue(copies.isEmpty)
    }

    func testRetranslatingAfterTheSourceChangedRefreshesThePane() async throws {
        let (_, controller) = open("본문\n")
        controller.toggleSideBySideAction(nil)
        await finish(controller)
        let session = try XCTUnwrap(controller.sideBySide)

        let tv = controller.editor.textView
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.insertText(" 둘째", replacementRange: tv.selectedRange())
        XCTAssertFalse(session.pane.band.isHidden)
        session.pane.band.onRetranslate?()
        await finish(controller)
        XCTAssertEqual(session.pane.editor.markdown, "Body Second\n")
        XCTAssertTrue(session.pane.band.isHidden)
    }

    private static func texts(in view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField { out.append(field.stringValue) }
        if let button = view as? NSButton { out.append(button.title) }
        for sub in view.subviews { out += texts(in: sub) }
        return out
    }
}
