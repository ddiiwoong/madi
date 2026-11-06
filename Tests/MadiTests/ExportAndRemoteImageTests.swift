import AppKit
import PDFKit
import XCTest

/// PDF 내보내기·프린트 설정 — 설정 창의 용지·방향·여백이 실제 출력에 들어가는가.
@MainActor
final class PrintAndPDFTests: XCTestCase {

    private var controllers: [DocumentWindowController] = []
    private var documents: [MarkdownDocument] = []
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("madi-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for controller in controllers {
            controller.document?.removeWindowController(controller)
            controller.window?.orderOut(nil)
        }
        controllers = []
        documents = []
        try? FileManager.default.removeItem(at: folder)
    }

    private func open(_ markdown: String, preferences: EditorPreferences) -> DocumentWindowController {
        let store = PreferenceStore(defaults: MemoryDefaults())
        store.save(preferences)
        let document = MarkdownDocument()
        document.markdown = markdown
        let controller = DocumentWindowController(preferences: store, autosavesFrame: false)
        document.addWindowController(controller)
        controller.window?.setFrameOrigin(NSPoint(x: -20000, y: 0))
        controller.window?.orderBack(nil)
        controller.load(markdown: markdown)
        controller.revealExportedFile = { _ in }
        controllers.append(controller)
        documents.append(document)
        return controller
    }

    private func settings(paper: EditorPreferences.PrintPaper, orientation: EditorPreferences.PrintOrientation,
                          margin: EditorPreferences.PrintMargin) -> EditorPreferences {
        var preferences = EditorPreferences.standard
        preferences.printPaper = paper
        preferences.printOrientation = orientation
        preferences.printMargin = margin
        return preferences
    }

    func testPrintInfoCarriesThePaperOrientationAndMargins() throws {
        let preferences = settings(paper: .a4, orientation: .landscape, margin: .narrow)
        let controller = open("본문\n", preferences: preferences)
        let info = controller.printInfo(forPDF: nil)
        // A4이고, 방향은 `orientation`이 정한다(크기를 가로로 넣고 방향까지 가로로 주면 두 번 돈다).
        XCTAssertEqual(Double(min(info.paperSize.width, info.paperSize.height)), 595.28, accuracy: 0.5)
        XCTAssertEqual(Double(max(info.paperSize.width, info.paperSize.height)), 841.89, accuracy: 0.5)
        XCTAssertEqual(info.orientation, .landscape)
        for margin in [info.topMargin, info.bottomMargin, info.leftMargin, info.rightMargin] {
            XCTAssertEqual(Double(margin), EditorPreferences.PrintMargin.narrow.points, accuracy: 0.01)
        }
        XCTAssertEqual(info.horizontalPagination, .fit, "가로로 넘치지 않게 맞춘다")
        XCTAssertNotEqual(info.jobDisposition, .save, "프린트는 파일로 보내지 않는다")
    }

    func testPDFExportWritesPagesOfTheChosenPaper() throws {
        let preferences = settings(paper: .letter, orientation: .portrait, margin: .normal)
        var markdown = "# 제목\n\n"
        for index in 0 ..< 120 { markdown += "문단 \(index) — 여러 쪽에 걸치는 문서다.\n\n" }
        let controller = open(markdown, preferences: preferences)
        controller.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))   // 캐럿은 제목에
        let url = folder.appendingPathComponent("문서.pdf")

        let info = controller.printInfo(forPDF: url)
        XCTAssertEqual(info.jobDisposition, .save)
        XCTAssertEqual(info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] as? URL, url)

        XCTAssertTrue(controller.exportPDF(to: url, showsProgress: false))
        let pdf = try XCTUnwrap(PDFDocument(url: url), "PDF가 생겼다")
        XCTAssertGreaterThan(pdf.pageCount, 1, "긴 문서는 여러 쪽")
        let page = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(page.width, 612, accuracy: 1, "Letter 폭")
        XCTAssertEqual(page.height, 792, accuracy: 1)
        XCTAssertTrue(pdf.string?.contains("제목") ?? false, "글이 들어 있다")
        XCTAssertFalse(pdf.string?.contains("# 제목") ?? true, "캐럿이 제목에 있어도 마커는 찍히지 않는다")
    }

    /// 캐럿이 있던 줄의 마커가 PDF에 찍히지 않는다. 실측: 캐럿을 제목에 두고 내보내면 `# 제목`이 나왔다.
    func testTheCaretLineDoesNotLeakItsMarkersIntoThePDF() throws {
        let controller = open("# 제목\n\n본문 **굵게**\n",
                              preferences: settings(paper: .a4, orientation: .portrait, margin: .normal))
        controller.editor.textView.setSelectedRange(NSRange(location: 2, length: 0))     // 제목 줄
        let url = folder.appendingPathComponent("캐럿.pdf")
        XCTAssertTrue(controller.exportPDF(to: url, showsProgress: false))
        let text = try XCTUnwrap(PDFDocument(url: url)?.string)
        XCTAssertFalse(text.contains("#"), text)
        XCTAssertFalse(text.contains("**"), text)
        XCTAssertFalse(controller.editor.isRenderingForOutput, "끝나면 되돌린다")
        let storage = try XCTUnwrap(controller.editor.textView.textStorage)
        XCTAssertNil(storage.attribute(.mdHiddenMarker, at: 0, effectiveRange: nil), "화면에서는 캐럿 줄의 마커가 다시 보인다")
    }

    /// PDF는 흰 종이에 기본 색이다 — 다크 화면에서 종이 테마를 골라 두어도. 전에는 테마가 없었지만 다크
    /// 화면이면 텍스트 뷰가 다크 바탕을 그대로 찍을 수 있었다. 끝나면 화면은 고른 테마로 돌아온다.
    func testPDFIsWhitePaperWhateverTheThemeAndAppearance() throws {
        var preferences = settings(paper: .letter, orientation: .portrait, margin: .normal)
        preferences.colorTheme = .paper
        let controller = open("본문 글 한 줄\n", preferences: preferences)
        controller.window?.appearance = NSAppearance(named: .darkAqua)
        let url = folder.appendingPathComponent("종이.pdf")
        XCTAssertTrue(controller.exportPDF(to: url, showsProgress: false))

        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: bounds.size, for: .mediaBox)
        let rep = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first
                                ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let scale = CGFloat(rep.pixelsWide) / bounds.width
        func color(x: CGFloat, yFromTop: CGFloat) -> NSColor? {
            rep.colorAt(x: Int(x * scale), y: Int(yFromTop * scale))?.usingColorSpace(.sRGB)
        }
        // 글 칸 안의 빈 자리(오른쪽 위, 글 아래)는 흰색이다 — 테마 바탕도, 다크 바탕도 아니다.
        for (x, y) in [(500.0, 120.0), (300.0, 300.0), (100.0, 600.0)] {
            let pixel = try XCTUnwrap(color(x: x, yFromTop: y))
            XCTAssertGreaterThan(pixel.brightnessComponent, 0.97, "(\(x), \(y))가 흰색이 아니다: \(pixel)")
            XCTAssertLessThan(abs(pixel.redComponent - pixel.blueComponent), 0.02, "미색이 아니다")
        }
        // 글자는 어둡다(다크 화면의 흰 글자가 흰 종이에 찍히지 않았다).
        var darkest: CGFloat = 1
        for x in stride(from: 40.0, to: 300.0, by: 1) {
            for y in stride(from: 40.0, to: 140.0, by: 1) {
                darkest = min(darkest, color(x: x, yFromTop: y)?.brightnessComponent ?? 1)
            }
        }
        XCTAssertLessThan(darkest, 0.3, "글자가 보이지 않는다")

        XCTAssertNil(controller.editor.textView.appearance, "화면은 창의 외관으로 돌아온다")
        XCTAssertTrue(controller.editor.textView.backgroundColor === ThemePalette.palette(for: .paper).background)
    }

    func testLandscapePDFPagesAreWide() throws {
        let controller = open("가로\n", preferences: settings(paper: .a4, orientation: .landscape, margin: .wide))
        let url = folder.appendingPathComponent("가로.pdf")
        XCTAssertTrue(controller.exportPDF(to: url, showsProgress: false))
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertGreaterThan(page.width, page.height)
        XCTAssertEqual(page.width, 841.89, accuracy: 1)
    }
}

/// 원격 그림 받기의 정책 — 꺼져 있으면 아무것도 안 나가고, `https`만, 20MB까지, 실패한 주소는 다시
/// 시도하지 않는다. 바깥으로 요청을 내지 않고 받기를 흉내 낸다.
@MainActor
final class RemoteImageTests: XCTestCase {

    private final class FakeNetwork {
        var requests: [URL] = []
        var respond: (URL) -> (Data?, Int, Error?) = { _ in (nil, 404, nil) }
    }

    private func png() -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return bitmap.representation(using: .png, properties: [:])!
    }

    private func store(_ network: FakeNetwork) -> InlineImageStore {
        let store = InlineImageStore()
        store.fetch = { request, completion in
            let url = request.url!
            network.requests.append(url)
            let (data, code, error) = network.respond(url)
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)
            completion(data, response, error)
        }
        return store
    }

    /// 받기의 끝은 메인 액터로 건너와 실린다. 그 차례를 기다린다.
    private func settle() async {
        for _ in 0 ..< 3 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private let address = URL(string: "https://example.com/a.png")!

    func testNothingIsFetchedWhileTheSettingIsOff() {
        let network = FakeNetwork()
        let images = store(network)
        XCTAssertNil(images.remoteImage(at: address))
        XCTAssertTrue(network.requests.isEmpty, "문서를 열었을 뿐인데 요청이 나가면 안 된다")
    }

    func testHTTPSImagesArriveOnceAndRepaint() async throws {
        let network = FakeNetwork()
        let data = png()
        network.respond = { _ in (data, 200, nil) }
        let images = store(network)
        images.loadsRemote = true
        var repaints = 0
        images.onRemoteImageLoaded = { repaints += 1 }

        XCTAssertNil(images.remoteImage(at: address), "기다리지 않는다 — 도착하면 다시 칠한다")
        XCTAssertNil(images.remoteImage(at: address))
        XCTAssertEqual(network.requests.count, 1, "받는 중이면 다시 보내지 않는다")
        await settle()
        XCTAssertEqual(repaints, 1)
        let image = try XCTUnwrap(images.remoteImage(at: address))
        XCTAssertEqual(image.size.width, 3)
        XCTAssertEqual(network.requests.count, 1, "받아 둔 것을 쓴다")
    }

    func testPlainHTTPIsRefusedWithoutARequest() {
        let network = FakeNetwork()
        let images = store(network)
        images.loadsRemote = true
        XCTAssertNil(images.remoteImage(at: URL(string: "http://example.com/a.png")!))
        XCTAssertTrue(network.requests.isEmpty, "평문 요청은 아예 내지 않는다")
    }

    func testFailuresAreNotRetried() async {
        let network = FakeNetwork()
        let images = store(network)
        images.loadsRemote = true
        _ = images.remoteImage(at: address)
        await settle()
        _ = images.remoteImage(at: address)
        XCTAssertEqual(network.requests.count, 1, "스타일 패스마다 다시 시도하면 타이핑 한 번에 요청이 수십 번 나간다")
    }

    func testOversizedImagesAreDropped() async {
        let network = FakeNetwork()
        let huge = png() + Data(count: InlineImageStore.maxRemoteBytes)
        network.respond = { _ in (huge, 200, nil) }
        let images = store(network)
        images.loadsRemote = true
        _ = images.remoteImage(at: address)
        await settle()
        XCTAssertNil(images.remoteImage(at: address))
    }

    func testTurningTheSettingOffForgetsWhatWasFetched() async {
        let network = FakeNetwork()
        let data = png()
        network.respond = { _ in (data, 200, nil) }
        let images = store(network)
        images.loadsRemote = true
        _ = images.remoteImage(at: address)
        await settle()
        XCTAssertNotNil(images.remoteImage(at: address))
        images.loadsRemote = false
        XCTAssertNil(images.remoteImage(at: address))
        images.loadsRemote = true
        XCTAssertNil(images.remoteImage(at: address), "껐다 켜면 다시 받는다 — 끈 뒤에도 보이면 껐다는 말이 거짓")
        XCTAssertEqual(network.requests.count, 2)
    }

    // MARK: 리다이렉트

    private func redirect(to target: String, task: URLSessionTask) -> URLRequest? {
        let response = HTTPURLResponse(url: address, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var followed: URLRequest?
        InlineImageStore.RedirectGuard.shared.urlSession(
            URLSession.shared, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: target)!)) { followed = $0 }
        return followed
    }

    func testRedirectsFollowHTTPSOnlyAndAtMostThreeHops() {
        let task = URLSession.shared.dataTask(with: address)       // 보내지 않는다
        defer { InlineImageStore.RedirectGuard.shared.urlSession(URLSession.shared, task: task,
                                                                 didCompleteWithError: nil) }
        XCTAssertNil(redirect(to: "http://example.com/b.png", task: task), "https → http 강등은 따라가지 않는다")
        let other = URLSession.shared.dataTask(with: address)
        defer { InlineImageStore.RedirectGuard.shared.urlSession(URLSession.shared, task: other,
                                                                 didCompleteWithError: nil) }
        for hop in 1 ... InlineImageStore.RedirectGuard.maxHops {
            XCTAssertNotNil(redirect(to: "https://example.com/\(hop).png", task: other), "\(hop)번째")
        }
        XCTAssertNil(redirect(to: "https://example.com/more.png", task: other), "넷째부터는 멈춘다")
    }
}
