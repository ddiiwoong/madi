import AppKit

// README 그림을 **실제 편집기**로 그린다 — 화면 밖 창, 라이트 모양, 2배 해상도. `make screenshots`.
//
// 앱 창을 찍지 않는 이유: 창에는 최근 문서 목록·파일 브라우저·창 제목이 함께 나오고, 그것은
// 찍는 사람의 계정과 파일을 드러낸다. 여기서는 공개용 샘플 문서(`docs/images/sample.md`)만
// 그린다. 화면이 바뀌면 이것을 다시 돌려 그림을 맞춘다.
//
// 사용: render <샘플.md> <출력 폴더>
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let source = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]
// 앱처럼 앱에 든 글꼴로 그린다 — 안 하면 그림만 시스템 글꼴로 나와 앱과 다르다.
let fontFailures = BundledFonts.register(from: URL(fileURLWithPath: "Sources/Madi/Resources/Fonts"))
guard fontFailures.isEmpty else {
    FileHandle.standardError.write("글꼴을 등록하지 못했습니다: \(fontFailures)\n".data(using: .utf8)!)
    exit(1)
}

/// 다이어그램·수식을 그리는 숨은 웹뷰. 저장소의 자원을 싣는다(이 실행 파일에는 앱 번들이 없다).
let diagrams = DiagramRenderer(resources: URL(fileURLWithPath: "Sources/Madi/Resources/Diagrams"))

@MainActor
func render(_ name: String, source: String, width: CGFloat, codeView: Bool, caretOn needle: String?,
            expectsPictures: Int = 0) {
    let text = try! String(contentsOfFile: source, encoding: .utf8)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: width, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
    window.contentView = editor
    window.orderBack(nil)
    editor.useDiagramRenderer(diagrams)
    editor.batchUpdates {
        editor.markdown = text
        editor.documentURL = URL(fileURLWithPath: source)
        editor.apply(.standard)
    }
    editor.isCodeView = codeView
    if let needle {
        let at = (editor.markdown as NSString).range(of: needle).location
        editor.textView.setSelectedRange(NSRange(location: at, length: 0))
    } else {
        editor.textView.setSelectedRange(NSRange(location: (editor.markdown as NSString).length, length: 0))
    }
    // 그림은 웹뷰에서 나중에 온다. 다 올 때까지 런루프를 돌린다(20초에서 포기한다).
    let deadline = Date().addingTimeInterval(20)
    while editor.renderedImageCount < expectsPictures, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard editor.renderedImageCount >= expectsPictures else {
        FileHandle.standardError.write("\(name): 그림 \(expectsPictures)개 중 \(editor.renderedImageCount)개만 왔습니다\n"
            .data(using: .utf8)!)
        exit(1)
    }
    let textView = editor.textView
    textView.layoutManager!.ensureLayout(for: textView.textContainer!)
    // 캐럿은 그리지 않는다 — 깜빡임의 어느 순간이 찍힐지 정할 수 없다.
    textView.insertionPointColor = .clear
    let bounds = textView.bounds
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = bounds.size
    textView.cacheDisplay(in: bounds, to: rep)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print(name, "\(Int(bounds.width))x\(Int(bounds.height))pt")
}

render("live-preview.png", source: source, width: 720, codeView: false, caretOn: "보는 화면에서")
render("source-view.png", source: source, width: 720, codeView: true, caretOn: nil)
// 구문 강조는 따로 — 세 언어를 한 장에. 같은 폴더의 `highlight.md`를 그린다.
let highlight = URL(fileURLWithPath: source).deletingLastPathComponent()
    .appendingPathComponent("highlight.md").path
render("highlight.png", source: highlight, width: 560, codeView: false, caretOn: nil)
// 다이어그램과 수식 — 숨은 웹뷰가 그린 그림이 들어간다.
let diagramSample = URL(fileURLWithPath: source).deletingLastPathComponent()
    .appendingPathComponent("diagrams.md").path
render("diagrams.png", source: diagramSample, width: 640, codeView: false, caretOn: nil, expectsPictures: 2)
