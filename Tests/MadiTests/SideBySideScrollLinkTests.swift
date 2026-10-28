import XCTest

/// 나란히 보기의 스크롤 잇기를 **실제 `NSTextView`와 클립 뷰를 지나** 확인한다.
///
/// 짝짓기와 위치 옮기기 자체는 `BlockAlignmentTests`(Core)가 본다. 여기서는 그 판단이
/// 픽셀까지 이어지는지, 그리고 옮겨 놓은 쪽의 알림이 되돌아와 사용자가 움직인 쪽을
/// 끌어당기지 않는지 본다. 창은 화면 밖에 만든다.
@MainActor
final class SideBySideScrollLinkTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var left: MarkdownEditorView!
    private var right: MarkdownEditorView!
    private var link: SideBySideScrollLink!

    /// 블록이 많고 높이가 고르지 않은 문서 — 스크롤할 거리가 있어야 한다.
    private func document(paragraphs: Int, extraAt: Int? = nil, longFactor: Int = 1) -> String {
        var out = "# 제목\n\n"
        for index in 0..<paragraphs {
            out += "## 절 \(index)\n\n"
            let sentence = String(repeating: "문단 \(index)의 글입니다. ", count: 3 + (index % 4) * longFactor)
            out += sentence + "\n\n"
            if index == extraAt {
                out += "> 번역본에만 있는 인용\n> 둘째 줄\n> 셋째 줄\n\n"
            }
        }
        return out
    }

    private func makeEditor(x: CGFloat, markdown: String) -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000 + x, y: 0, width: 520, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        window.contentView = editor
        editor.frame = window.contentView!.bounds
        window.orderBack(nil)
        editor.markdown = markdown
        windows.append(window)
        return editor
    }

    private func setUp(source: String, target: String) {
        left = makeEditor(x: 0, markdown: source)
        right = makeEditor(x: 600, markdown: target)
        settle()
        link = SideBySideScrollLink(source: left, target: right)
    }

    override func tearDown() async throws {
        link?.disconnect()
        for window in windows { window.orderOut(nil) }
        windows = []
        left = nil
        right = nil
        link = nil
    }

    private func settle() {
        for window in windows { window.contentView?.layoutSubtreeIfNeeded() }
        for editor in [left, right].compactMap({ $0 }) {
            editor.textView.layoutManager?.ensureLayout(for: editor.textView.textContainer!)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// 사용자가 스크롤한 것처럼 — 잇기 객체를 거치지 않고 클립 뷰를 직접 옮긴다.
    private func userScroll(_ editor: MarkdownEditorView, to y: CGFloat) {
        editor.clipView.scroll(to: NSPoint(x: 0, y: y))
        (editor.clipView.superview as? NSScrollView)?.reflectScrolledClipView(editor.clipView)
        settle()
    }

    private func maxOrigin(_ editor: MarkdownEditorView) -> CGFloat {
        editor.textView.frame.height - editor.clipView.bounds.height
    }

    // MARK: 전제

    func testPremiseDocumentsAreScrollable() {
        setUp(source: document(paragraphs: 30), target: document(paragraphs: 30))
        XCTAssertGreaterThan(maxOrigin(left), 2_000, "전제: 스크롤할 거리가 있다")
        XCTAssertGreaterThan(left.blocks.count, 100, "전제: 블록이 여럿이다")
    }

    // MARK: 같은 구조

    func testIdenticalDocumentsScrollTogether() {
        let text = document(paragraphs: 30)
        setUp(source: text, target: text)
        userScroll(left, to: 1_234)
        XCTAssertEqual(right.clipView.bounds.origin.y, 1_234, accuracy: 1.0)
    }

    /// 메아리가 사용자가 움직인 쪽을 끌어당기지 않는다.
    func testDrivenSideDoesNotPullTheDriverBack() {
        let text = document(paragraphs: 30)
        setUp(source: text, target: document(paragraphs: 30, extraAt: 4))
        userScroll(left, to: 1_500)
        XCTAssertEqual(left.clipView.bounds.origin.y, 1_500, accuracy: 0.01)
        XCTAssertGreaterThan(right.clipView.bounds.origin.y, 0, "전제: 상대가 따라왔다")
    }

    /// 메아리가 실제로 해가 되는 자리 — 움직인 쪽에만 있는 블록 **가운데.**
    ///
    /// 그 블록을 지나는 동안 상대는 블록 경계에 서 있다(폭 0인 구간). 상대의 알림이
    /// 되돌아와 옮겨지면, 그 경계는 움직인 쪽에서 **짝 없는 블록들이 끝나는 자리**에
    /// 해당하므로 사용자가 보던 자리가 그리로 튄다. 짝지어진 블록 안에서는 왕복이 항등이라
    /// 메아리가 되돌아와도 티가 나지 않는다 — 그래서 위 테스트는 이 결함을 못 잡는다.
    func testEchoDoesNotYankTheDriverOutOfABlockOnlyItHas() throws {
        setUp(source: document(paragraphs: 30, extraAt: 4), target: document(paragraphs: 30))
        let quote = try XCTUnwrap(left.blocks.firstIndex { $0.kind == .quote })
        let inside = left.originForReferencePosition(Double(quote) + 0.5)
        let blockEnd = left.originForReferencePosition(Double(quote) + 1)
        XCTAssertGreaterThan(blockEnd - inside, 5, "전제: 블록 가운데와 끝이 다른 자리다")

        userScroll(left, to: inside)
        XCTAssertEqual(left.clipView.bounds.origin.y, inside, accuracy: 0.5,
                       "사용자가 보던 자리가 튀었다")
        let alignment = try XCTUnwrap(link.currentAlignment())
        XCTAssertEqual(right.scrollReferencePosition(),
                       alignment.targetPosition(forSource: left.scrollReferencePosition()),
                       accuracy: 0.02, "전제: 상대는 경계에 서 있다")
    }

    func testFollowsInBothDirections() {
        let text = document(paragraphs: 30)
        setUp(source: text, target: text)
        userScroll(right, to: 900)
        XCTAssertEqual(left.clipView.bounds.origin.y, 900, accuracy: 1.0)
        userScroll(left, to: 300)
        XCTAssertEqual(right.clipView.bounds.origin.y, 300, accuracy: 1.0)
    }

    // MARK: 높이와 구조가 다를 때

    /// 번역하면 문단 높이가 달라진다 — 픽셀이 아니라 **블록**이 맞아야 한다.
    func testDifferentHeightsAlignByBlock() {
        setUp(source: document(paragraphs: 30), target: document(paragraphs: 30, longFactor: 6))
        XCTAssertGreaterThan(maxOrigin(right), maxOrigin(left) * 1.2, "전제: 오른쪽이 훨씬 길다")
        userScroll(left, to: 1_800)
        let leftPosition = left.scrollReferencePosition()
        XCTAssertEqual(right.scrollReferencePosition(), leftPosition, accuracy: 0.02,
                       "같은 블록 자리여야 한다")
        XCTAssertNotEqual(right.clipView.bounds.origin.y, 1_800, accuracy: 50,
                          "픽셀로 맞췄다면 같은 값이었을 것이다")
    }

    /// 번역본에만 있는 블록 뒤에서도 짝지어진 블록끼리 맞는다.
    func testExtraBlockOnOneSideIsSkippedOver() throws {
        setUp(source: document(paragraphs: 30), target: document(paragraphs: 30, extraAt: 4))
        XCTAssertEqual(right.blocks.count, left.blocks.count + 2, "전제: 인용과 빈 줄이 더 있다")
        userScroll(left, to: 2_200)
        let alignment = try XCTUnwrap(link.currentAlignment())
        XCTAssertEqual(right.scrollReferencePosition(),
                       alignment.targetPosition(forSource: left.scrollReferencePosition()),
                       accuracy: 0.02)
        // 왼쪽 블록 번호와 오른쪽 블록 번호가 **다르다**(짝짓기가 한 일이다).
        XCTAssertEqual(right.scrollReferencePosition() - left.scrollReferencePosition(), 2, accuracy: 0.05)
    }

    func testEndsMeetEnds() {
        setUp(source: document(paragraphs: 30), target: document(paragraphs: 30, longFactor: 6))
        userScroll(left, to: maxOrigin(left))
        XCTAssertEqual(right.clipView.bounds.origin.y, maxOrigin(right), accuracy: 1.0)
        userScroll(left, to: 0)
        XCTAssertEqual(right.clipView.bounds.origin.y, 0, accuracy: 1.0)
    }

    // MARK: 글이 바뀔 때

    /// 한쪽에서 블록을 더하면 짝짓기를 다시 한다 — 옛 짝짓기로 옮기면 두 블록 어긋난다.
    func testEditingOneSideRebuildsTheAlignment() throws {
        let text = document(paragraphs: 30)
        setUp(source: text, target: text)
        let before = try XCTUnwrap(link.currentAlignment())
        XCTAssertEqual(before.pairs.count, left.blocks.count)

        right.markdown = document(paragraphs: 30, extraAt: 4)
        settle()
        let after = try XCTUnwrap(link.currentAlignment())
        XCTAssertEqual(after.targetCount, left.blocks.count + 2)
        userScroll(left, to: 2_200)
        XCTAssertEqual(right.scrollReferencePosition() - left.scrollReferencePosition(), 2, accuracy: 0.05)
    }

    func testDisconnectStopsFollowing() {
        let text = document(paragraphs: 30)
        setUp(source: text, target: text)
        link.disconnect()
        // 편집기는 레이아웃을 마치며 스스로 조금 스크롤한다(실측 24pt) — 0이 아니라
        // 끊기 직전의 자리와 견준다.
        let before = right.clipView.bounds.origin.y
        userScroll(left, to: 1_000)
        XCTAssertEqual(right.clipView.bounds.origin.y, before, accuracy: 0.01)
        XCTAssertFalse(link.isConnected)
    }
}
