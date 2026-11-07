import AppKit
import XCTest

/// 편집기의 우클릭 메뉴 — 필수(잘라내기 · 복사 · 붙여넣기)와 마디의 것(링크 열기 · 링크 주소 복사)만.
///
/// 사용자 — "마우스 우측 메뉴도 너무 많다, 필수적이고 마디에서 핵심적인 것만". 시스템 메뉴는 항목이 열일곱이었다
/// (찾아보기 · 번역 · Google 검색 · 오려두기 · 복사하기 · 붙여넣기 · 붙여넣고 스타일 일치 · 공유 · 서체 · 글쓰기 도구
/// 셋 · 맞춤법 및 문법 · 대체 · 말하기 · 자동 완성 · 서비스, 앱에서 접근성 트리로 셌다).
@MainActor
final class ContextMenuTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func editor(_ markdown: String) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = editor
        window.orderBack(nil)
        windows.append(window)
        editor.markdown = markdown
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))     // 첫 줄 — 링크 줄에서 비킨다
        return editor
    }

    /// `fragment`의 글자 한가운데(텍스트 뷰 좌표).
    private func point(over fragment: String, in view: MarkdownEditorView) throws -> NSPoint {
        let range = (view.markdown as NSString).range(of: fragment)
        XCTAssertNotEqual(range.location, NSNotFound, "시험의 전제 — '\(fragment)'가 문서에 있다")
        let layout = try XCTUnwrap(view.textView.layoutManager)
        let container = try XCTUnwrap(view.textView.textContainer)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let origin = view.textView.textContainerOrigin
        return NSPoint(x: box.midX + origin.x, y: box.midY + origin.y)
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private final class LinkSpy: MarkdownEditorDelegate {
        var opened: [String] = []
        func markdownEditorDidChangeText(_ editor: MarkdownEditorView) {}
        func markdownEditor(_ editor: MarkdownEditorView, didClickLink url: String) { opened.append(url) }
    }

    private let source = "제목\n\n앞 글 [마디](https://example.com/madi) 뒤 글\n"

    /// 링크가 아닌 곳 — 잘라내기 · 복사 · 붙여넣기 셋뿐. 텍스트 뷰로 보내고, 단축키는 적지 않는다. 메뉴를 띄울 때
    /// macOS가 끼워 넣는 서비스 · 글쓰기 도구도 막는다.
    func testPlainTextGetsOnlyCutCopyPaste() throws {
        let view = editor(source)
        let menu = view.contextMenu(at: try point(over: "앞 글", in: view))
        XCTAssertEqual(titles(menu), ["잘라내기", "복사", "붙여넣기"])
        XCTAssertEqual(menu.items.map(\.action), [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
                                                  #selector(NSText.paste(_:))])
        XCTAssertTrue(menu.items.allSatisfy { $0.target === view.textView && $0.keyEquivalent.isEmpty })
        XCTAssertFalse(menu.allowsContextMenuPlugIns, "서비스 하위 메뉴")
        if #available(macOS 15.2, *) {
            XCTAssertFalse(menu.automaticallyInsertsWritingToolsItems, "글쓰기 도구")
        }
    }

    /// 링크 위 — 맨 위에 링크 열기 · 링크 주소 복사. 여는 것은 ⌘클릭과 같은 길(편집기 대리자)이다.
    func testALinkAddsOpenAndCopyAddress() throws {
        let view = editor(source)
        let spy = LinkSpy()
        view.editorDelegate = spy
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("madi-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        view.linkPasteboard = pasteboard

        let menu = view.contextMenu(at: try point(over: "마디", in: view))
        XCTAssertEqual(titles(menu), ["링크 열기", "링크 주소 복사", "—", "잘라내기", "복사", "붙여넣기"])

        // 앱을 띄우지 않는 시험이라 `NSApp`은 `shared`를 부르기 전까지 nil이다.
        let app = NSApplication.shared
        let open = menu.items[0]
        XCTAssertTrue(app.sendAction(try XCTUnwrap(open.action), to: open.target, from: open))
        XCTAssertEqual(spy.opened, ["https://example.com/madi"])

        let copy = menu.items[1]
        XCTAssertTrue(app.sendAction(try XCTUnwrap(copy.action), to: copy.target, from: copy))
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/madi")
    }

    /// 원본 보기에서는 링크를 열지 않는다 — ⌘클릭과 같다(원본에서는 고치러 들어가는 글이다).
    func testCodeViewOffersNoLink() throws {
        let view = editor(source)
        view.isCodeView = true
        let menu = view.contextMenu(at: try point(over: "마디", in: view))
        XCTAssertEqual(titles(menu), ["잘라내기", "복사", "붙여넣기"])
    }

    /// 실제 우클릭이 이 메뉴를 받는다 — 텍스트 뷰의 `menu(for:)`가 편집기에 묻는다(시스템 메뉴가 아니다).
    func testRightClickUsesTheEditorMenu() throws {
        let view = editor(source)
        let local = try point(over: "마디", in: view)
        let window = try XCTUnwrap(view.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: view.textView.convert(local, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1))
        let menu = try XCTUnwrap(view.textView.menu(for: event))
        XCTAssertEqual(titles(menu), ["링크 열기", "링크 주소 복사", "—", "잘라내기", "복사", "붙여넣기"])
    }

    /// 창이 더한 항목은 구분선 아래 맨 끝에 붙는다. 더한 것이 없으면 구분선도 없다.
    func testExtrasGoLastBelowASeparator() throws {
        let view = editor(source)
        let extra = NSMenuItem(title: "더한 것", action: nil, keyEquivalent: "")
        view.contextMenuExtras = { _ in [extra] }
        let menu = view.contextMenu(at: try point(over: "앞 글", in: view))
        XCTAssertEqual(titles(menu), ["잘라내기", "복사", "붙여넣기", "—", "더한 것"])
        view.contextMenuExtras = { _ in [] }
        XCTAssertEqual(titles(view.contextMenu(at: try point(over: "앞 글", in: view))), ["잘라내기", "복사", "붙여넣기"])
    }
}
