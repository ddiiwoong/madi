import XCTest

/// 큰 문서 성능을 고친 것들을 **시간을 재지 않고** 지킨다.
///
/// 시간은 기계와 부하에 따라 두 배씩 흔들려 테스트의 기준이 될 수 없다. 대신 느렸던 원인
/// 하나하나를 구조로 못박는다 — 첫 화면을 그리는데 문서 끝까지 레이아웃하지 않는다, 문서를
/// 열 때 전체 칠하기는 한 번이다, 줄 표는 글이 바뀐 그 자리에서 낡은 것이 된다, 빠른 줄
/// 판정은 정규식 판정과 같은 답을 낸다. 실측 숫자는 `TODO.md`의 '큰 문서 성능'에 있다.
@MainActor
final class LargeDocumentTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    // MARK: 문서

    /// 코드 블록이 처음과 끝에 있는 긴 문서. 끝의 블록을 물으면 끝까지 레이아웃해야 한다.
    private func longDocument(paragraphs: Int = 400) -> String {
        var out = "# 제목\n\n```swift\nlet first = 1\n```\n\n"
        for index in 0..<paragraphs {
            out += "문단 \(index)입니다. 한글과 English가 섞인 줄이 화면 밖까지 이어집니다.\n\n"
        }
        out += "```swift\nlet last = 2\n```\n"
        return out
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func makeEditor(markdown: String = "") -> MarkdownEditorView {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 520, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        window.contentView = editor
        editor.frame = window.contentView!.bounds
        window.orderBack(nil)
        windows.append(window)
        if !markdown.isEmpty { editor.markdown = markdown }
        return editor
    }

    /// 편집기와 따로, **이어 놓기(기본값)** 레이아웃의 `DecoratedTextView`. 그리기가
    /// 레이아웃을 어디까지 끌어내는지는 이어 놓기에서만 `firstUnlaidCharacterIndex`로 보인다.
    ///
    /// **빈 채로 붙인 뒤 글을 넣는다**(실측): 글이 든 텍스트 뷰를 스크롤 뷰에 붙이는 순간
    /// 크기를 맞추느라 끝까지 레이아웃해 버려, 그리기가 무엇을 했는지 볼 수 없다.
    private func makeContiguousTextView(_ text: String) -> DecoratedTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        layout.backgroundLayoutEnabled = false
        let container = NSTextContainer(size: NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let view = DecoratedTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 400),
                                     textContainer: container)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        scroll.documentView = view
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 500, width: 480, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderBack(nil)
        windows.append(window)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                  with: NSAttributedString(string: text,
                                                           attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        return view
    }

    /// 맨 위 한 화면을 그린다. 화면 밖 창의 `display()`는 아무것도 그리지 않아(실측) 비트맵에
    /// 그린다 — 이 길도 `drawBackground(in:)`를 지난다.
    private func drawTopScreen(of view: NSView) {
        let rect = NSRect(x: 0, y: 0, width: view.bounds.width, height: 400)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else {
            return XCTFail("비트맵을 만들지 못했다")
        }
        view.cacheDisplay(in: rect, to: rep)
    }

    private func codeBlocks(in text: String) -> [NSRange] {
        let styler = MarkdownStyler()
        styler.style(NSTextStorage(string: text), caretLine: nil, search: .init())
        return styler.codeBlockRanges
    }

    // MARK: 그리기가 레이아웃을 끌어내지 않는다

    /// 전제: 이 문서는 한 화면보다 훨씬 길고, 코드 블록이 처음과 **끝**에 있다. 아니면 아래
    /// 두 테스트가 아무것도 보지 않는다.
    func testPremiseLongDocumentHasCodeBlocksAtBothEnds() {
        let text = longDocument()
        let blocks = codeBlocks(in: text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertGreaterThan(blocks.last!.location, (text as NSString).length - 40)
        let view = makeContiguousTextView(text)
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        XCTAssertGreaterThan(view.frame.height, 10 * 400, "한 화면의 열 배는 넘어야 한다")
    }

    /// 첫 화면을 그리는 데 문서 끝까지 레이아웃하지 않는다.
    ///
    /// 전에는 그릴 때마다 코드 블록 **전부**에 `boundingRect`를 물어, 끝의 블록 때문에 문서
    /// 전체를 놓았다(22만 자에서 첫 화면 4.7초, 글 앞쪽 타이핑 한 번에 4.5초).
    func testDrawingTheFirstScreenDoesNotLayOutTheWholeDocument() {
        let text = longDocument()
        let view = makeContiguousTextView(text)
        XCTAssertEqual(view.layoutManager!.firstUnlaidCharacterIndex(), 0, "전제: 그리기 전에는 놓지 않았다")
        view.codeBlockRanges = codeBlocks(in: text)
        drawTopScreen(of: view)
        let length = (text as NSString).length
        let unlaid = view.layoutManager!.firstUnlaidCharacterIndex()
        XCTAssertGreaterThan(unlaid, 0, "전제: 첫 화면은 그렸다(레이아웃이 조금은 돌았다)")
        XCTAssertLessThan(unlaid, length / 2,
                          "첫 화면을 그리며 \(unlaid)/\(length)자까지 레이아웃했다 — 화면 밖 블록을 물었다")
    }

    func testRangesTouchingPicksOnlyOverlappingBlocks() {
        let blocks = [NSRange(location: 0, length: 10), NSRange(location: 20, length: 5),
                      NSRange(location: 40, length: 10), NSRange(location: 90, length: 3)]
        XCTAssertEqual(Array(DecoratedTextView.ranges(blocks, touching: NSRange(location: 22, length: 20))),
                       [blocks[1], blocks[2]])
        XCTAssertEqual(Array(DecoratedTextView.ranges(blocks, touching: NSRange(location: 60, length: 10))), [])
        XCTAssertEqual(Array(DecoratedTextView.ranges(blocks, touching: NSRange(location: 0, length: 100))),
                       blocks)
        // 경계에 닿기만 해도 넣는다 — 배경은 글자보다 여백만큼 크다.
        XCTAssertEqual(Array(DecoratedTextView.ranges(blocks, touching: NSRange(location: 10, length: 0))),
                       [blocks[0]])
        XCTAssertEqual(Array(DecoratedTextView.ranges([], touching: NSRange(location: 0, length: 5))), [])
    }

    /// 편집기는 끊어 놓기 레이아웃을 쓴다 — 글 앞쪽의 한 글자가 그 뒤 레이아웃 전부를
    /// 무효로 만들지 않게(실측: 이어 놓기에서 첫 미배치 글자가 227,846 → 71).
    func testEditorUsesNonContiguousLayout() {
        XCTAssertTrue(makeEditor().textView.layoutManager!.allowsNonContiguousLayout)
    }

    // MARK: 전체 칠하기 모으기

    func testOpeningADocumentStylesOnce() {
        let editor = makeEditor()
        let before = editor.fullRestyleCount
        editor.batchUpdates {
            editor.markdown = longDocument(paragraphs: 20)
            editor.documentURL = URL(fileURLWithPath: "/tmp/madi-batch-test.md")
            editor.apply(.standard)
        }
        XCTAssertEqual(editor.fullRestyleCount - before, 1)
        // 모은 한 번이 실제로 칠했다 — 캐럿이 없는 줄(펜스)의 마커가 숨었다.
        let storage = editor.textView.textStorage!
        let fence = (storage.string as NSString).range(of: "```")
        XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: fence.location, effectiveRange: nil),
                        "모은 패스가 칠하지 않았다")
    }

    func testOutsideABatchEachChangeStillStyles() {
        let editor = makeEditor()
        let before = editor.fullRestyleCount
        editor.markdown = "# 하나\n"
        editor.apply(.standard)
        XCTAssertEqual(editor.fullRestyleCount - before, 2)
    }

    /// 창을 끌어 바꾸는 동안에는 칠하지 않고 놓을 때 한 번 칠한다.
    func testLiveResizeStylesOnceAtTheEnd() {
        let editor = makeEditor(markdown: longDocument(paragraphs: 20))
        var preferences = EditorPreferences.standard
        preferences.documentWidth = .narrow    // 가운데 맞춤이라 폭이 바뀌면 여백이 바뀐다
        editor.apply(preferences)
        let before = editor.fullRestyleCount

        editor.viewWillStartLiveResize()
        for width in stride(from: 700, through: 900, by: 50) {
            editor.setFrameSize(NSSize(width: CGFloat(width), height: 400))
        }
        XCTAssertEqual(editor.fullRestyleCount, before, "끄는 동안 칠했다")
        editor.viewDidEndLiveResize()
        XCTAssertEqual(editor.fullRestyleCount - before, 1)

        // 끌기가 아니면 바뀔 때마다 칠한다(그림 폭이 글 폭을 따라가야 한다).
        editor.setFrameSize(NSSize(width: 650, height: 400))
        XCTAssertEqual(editor.fullRestyleCount - before, 2)
    }

    // MARK: 줄 표

    /// 줄 표는 **저장소가 바뀐 그 자리에서** 낡은 것이 된다 — 텍스트 뷰의 알림을 기다리지 않는다.
    func testLineTableFollowsTheStorageDirectly() {
        let editor = makeEditor(markdown: "# 하나\n둘\n")
        XCTAssertEqual(editor.currentLines().count, 3)
        editor.textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0),
                                                       with: "새 줄\n또 한 줄\n")
        let lines = editor.currentLines()
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.last.map { NSMaxRange($0.range) }, editor.textView.textStorage!.length)
    }

    /// 캐럿 줄 찾기(이분 탐색)가 줄을 처음부터 세는 것과 같은 답을 낸다 — 모든 자리에서.
    func testCaretLineMatchesCountingLines() {
        for text in ["", "한 줄", "하나\n", "하나\n둘\n\n셋", "a\r\nb\r\n", "a\u{2028}b\nc", "\n\n\n"] {
            let ns = text as NSString
            let lines = MarkdownSyntax().scanLines(in: ns)
            for location in 0 ... ns.length {
                // 줄을 처음부터 센다: location 이전에 **줄바꿈까지 끝난** 줄의 수 + 1.
                // 줄바꿈 없이 문서 끝에서 끝나는 줄은 다음 줄을 만들지 않는다.
                var expected = 1
                var index = 0
                while index < ns.length {
                    var end = 0, contentsEnd = 0
                    ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                                    for: NSRange(location: index, length: 0))
                    if contentsEnd < end, end <= location { expected += 1 }
                    index = end
                }
                XCTAssertEqual(MarkdownEditorView.lineNumber(at: location, in: lines), expected,
                               "\(text.debugDescription) @\(location)")
            }
        }
    }

    /// 끝에 줄바꿈이 없는 문서에서 캐럿이 맨 끝에 있으면 그 줄의 마커가 보인다.
    ///
    /// 전에는 캐럿 줄을 셀 때 여기서 없는 줄(마지막 + 1)을 돌려줘 마커가 숨었다 — 문서 끝의
    /// 제목을 고치려고 끝으로 가면 `#`이 보이지 않았다.
    func testMarkersShowOnLastLineWithoutTrailingNewline() {
        let editor = makeEditor(markdown: "본문\n## 끝 제목")
        let storage = editor.textView.textStorage!
        editor.textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        let hashes = (storage.string as NSString).range(of: "## ")
        XCTAssertNil(storage.attribute(.mdHiddenMarker, at: hashes.location, effectiveRange: nil),
                     "캐럿이 있는 마지막 줄의 마커가 숨었다")
        // 캐럿이 떠나면 숨는다 — 위 단정이 늘 참인 것이 아님을 보인다.
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNotNil(storage.attribute(.mdHiddenMarker, at: hashes.location, effectiveRange: nil))
    }

    func testOutlineFromCachedLinesMatchesFreshScan() throws {
        let text = try String(contentsOf: repoRoot().appendingPathComponent("TODO.md"), encoding: .utf8) as NSString
        let lines = MarkdownSyntax().scanLines(in: text)
        XCTAssertEqual(Outline.entries(lines: lines, in: text), Outline.entries(in: text))
        XCTAssertGreaterThan(Outline.entries(in: text).count, 10)
    }

    // MARK: 그림

    private func writePNG(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// 한 줄을 고쳐도 **다른 줄의 그림이 사라지지 않는다.**
    ///
    /// 부분 칠하기는 고친 줄만 다시 칠하는데, 그림 자리 목록은 그 패스에서 본 그림으로
    /// 통째로 바뀌었다. 그래서 글자 하나를 치면 다른 그림이 전부 목록에서 빠지고 —
    /// 줄 높이는 그림 크기로 남은 채 — 빈 자리만 그려졌다.
    func testEditingOneLineKeepsOtherImages() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("madi-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writePNG(to: folder.appendingPathComponent("a.png"))
        try writePNG(to: folder.appendingPathComponent("b.png"))

        let editor = makeEditor()
        editor.batchUpdates {
            editor.documentURL = folder.appendingPathComponent("doc.md")
            editor.markdown = "처음\n\n![가](a.png)\n\n가운데 문단\n\n![나](b.png)\n"
        }
        XCTAssertEqual(editor.textView.imagePlacements.count, 2, "전제: 두 그림 모두 자리를 잡았다")

        let middle = (editor.textView.string as NSString).range(of: "가운데")
        editor.textView.setSelectedRange(NSRange(location: middle.location, length: 0))
        editor.textView.insertText("새 ", replacementRange: NSRange(location: middle.location, length: 0))
        XCTAssertEqual(editor.textView.imagePlacements.count, 2, "한 줄을 고치자 그림이 빠졌다")

        // 빠지지 않은 자리가 **지금 글의** 줄을 가리킨다(글이 밀린 만큼 함께 밀렸다).
        let text = editor.textView.string as NSString
        for placement in editor.textView.imagePlacements {
            XCTAssertTrue(text.substring(with: placement.lineRange).hasPrefix("!["),
                          "그림 자리가 낡은 줄을 가리킨다: \(text.substring(with: placement.lineRange))")
        }
    }

    // MARK: 빠른 줄 판정 = 정규식 판정

    /// 판정이 갈리기 쉬운 앞머리를 섞은 줄. 씨앗이 고정이라 실패하면 같은 줄이 다시 나온다.
    private func generatedLines(count: Int, seed: UInt64) -> [String] {
        let pieces = [" ", "  ", "   ", "    ", "\t", "\u{a0}", "\u{3000}", "\u{2003}", "\u{0b}", "\u{0c}",
                      "\u{85}", "\u{180e}", "\u{200b}", "#", "##", "###### ", "####### ", "# ", "#\t",
                      ">", "> ", ">>", "-", "- ", "* ", "+ ", "1. ", "1) ", "12.", "\u{661}. ", "\u{ff11}. ",
                      "\u{1d7ce}. ", "```", "~~~", "```swift", "``` import", "~~~ py", "````", "---", "***",
                      "___", "===", "= =", "- - -", "|", "| a | b |", "|---|:-:|", ":--", ":-:|",
                      "[ref]: http://x", "[a b]: <u v> \"t\"", "[x]", "[ ]", "가나다", "abc", "**", "_",
                      "`", "!", "[", "]", "(", ")", "<", "=", "-", "*", "~", "[!NOTE]", "\\", "1", "x"]
        var state = seed
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        return (0..<count).map { _ in
            (0..<[0, 1, 1, 2, 2, 3, 4, 5][next(8)]).map { _ in pieces[next(pieces.count)] }.joined()
        }
    }

    /// 빠른 길이 답하는 모든 줄에서 그 답이 정규식 판정과 같다 — 펜스 안과 밖 둘 다.
    func testFastLineTokenAgreesWithRegexScan() throws {
        var corpus = generatedLines(count: 20000, seed: 7)
        for name in ["README.md", "TODO.md", "docs/features.md", "docs/block-editor-design.md"] {
            let text = try String(contentsOf: repoRoot().appendingPathComponent(name), encoding: .utf8)
            corpus += text.components(separatedBy: "\n")
        }
        let syntax = MarkdownSyntax()
        var answered = 0
        for line in corpus {
            let text = line as NSString
            let range = NSRange(location: 0, length: text.length)
            for (inFence, language) in [(false, nil), (true, "swift"), (true, nil)] as [(Bool, String?)] {
                guard let fast = MarkdownSyntax.fastToken(in: text, range: range, lineNumber: 1,
                                                          inFence: inFence, fenceLanguage: language)
                else { continue }
                answered += 1
                var fence = inFence
                var lang = language
                let slow = syntax.scanLine(line, at: range, lineNumber: 1,
                                           inFence: &fence, fenceLanguage: &lang)
                XCTAssertEqual(fast, slow, "\(line.debugDescription) inFence=\(inFence)")
                XCTAssertEqual(fence, inFence, "빠른 길이 답한 줄이 펜스 상태를 바꿨다: \(line.debugDescription)")
            }
        }
        // 빠른 길이 거의 답하지 않으면 위 비교가 아무것도 보지 않는다.
        XCTAssertGreaterThan(answered, corpus.count, "빠른 길이 답한 줄이 너무 적다: \(answered)")
    }

    /// 밑줄 문지기가 거절한 줄은 정식 판정도 밑줄이 아니라고 한다.
    func testSetextGateNeverRejectsAnUnderline() {
        for line in generatedLines(count: 20000, seed: 11) + ["===", "  ---", "   =", "\t--", " = ", "\u{3000}==="] {
            let text = line as NSString
            let range = NSRange(location: 0, length: text.length)
            if !MarkdownSyntax.mayBeSetextUnderline(text, range) {
                XCTAssertNil(MarkdownSyntax.setextLevel(of: line), line.debugDescription)
            }
        }
    }
}
