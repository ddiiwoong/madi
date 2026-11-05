import AppKit
import UniformTypeIdentifiers

/// Being a real `NSDocument` is what buys 열기 / 저장 / 최근 문서 / 자동 저장 /
/// 버전 / 복원 from the framework instead of hand-rolling them: the Open panel,
/// `NSDocumentController.recentDocumentURLs`, the dirty dot in the title bar and
/// the "unsaved changes" sheet all come for free.
@MainActor
final class MarkdownDocument: NSDocument {

    var markdown: String = "" {
        didSet {
            guard markdown != oldValue else { return }
            windowController?.documentContentDidChange()
        }
    }

    private weak var windowController: DocumentWindowController?

    override class var autosavesInPlace: Bool { true }

    static let supportedReadableTypes = [
        "net.daringfireball.markdown", "public.plain-text", "public.text",
    ]

    override class func isNativeType(_ type: String) -> Bool {
        supportedReadableTypes.contains(type)
    }

    override class var readableTypes: [String] { supportedReadableTypes }
    override class var writableTypes: [String] { ["net.daringfireball.markdown"] }

    override func makeWindowControllers() {
        let controller = DocumentWindowController()
        addWindowController(controller)
        controller.load(markdown: markdown)
    }

    /// 창 컨트롤러는 **붙는 자리에서** 기억한다. `makeWindowControllers`에서만 기억하면 다른 길로
    /// 붙은 창(테스트가 그렇게 붙인다)은 디스크에서 다시 읽힌 글을 받지 못한다.
    override func addWindowController(_ windowController: NSWindowController) {
        super.addWindowController(windowController)
        if let controller = windowController as? DocumentWindowController {
            self.windowController = controller
        }
    }

    // MARK: Reading and writing
    //
    // `data(ofType:)` and `read(from:ofType:)` override nonisolated superclass
    // methods, so they do not inherit the class's main-actor isolation. AppKit
    // calls both on the main thread unless `canConcurrentlyReadDocuments` is
    // true, which it is not here, so asserting that isolation is correct rather
    // than hopeful — and if the assumption ever breaks it traps loudly instead
    // of racing silently.

    override nonisolated func data(ofType typeName: String) throws -> Data {
        try MainActor.assumeIsolated {
            guard let data = markdown.data(using: .utf8) else {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteInapplicableStringEncodingError)
            }
            return data
        }
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError)
        }
        MainActor.assumeIsolated {
            markdown = text
            windowController?.load(markdown: text)
        }
    }

    /// Called by the window controller when the user types.
    func editorDidChange(markdown text: String) {
        guard text != markdown else { return }
        markdown = text
        updateChangeCount(.changeDone)
    }
}
