import AppKit

/// `madi://` 링크를 실행한다 — 주소를 읽는 일은 `MadiURL`, 여기는 문서를 열고 · 만들고 · 고친다.
///
/// 링크는 **웹 페이지도 누를 수 있다**. 그래서 파일을 바꾸는 명령(`append`)은 그 문서 창에 무엇을 더하려는지 보이고
/// 묻는다 — 문서가 제자리에 자동 저장되므로(`autosavesInPlace`) 묻지 않으면 링크 하나가 파일을 고치는 셈이다. 기본
/// 단추는 `취소`다(링크가 열린 순간 치던 Return이 더하기를 누르지 않게). 여는 것(`open`)과 새 문서(`new`)는 파일을
/// 바꾸지 않으므로 묻지 않는다.
@MainActor
final class URLCommandRunner {

    /// 파일을 연다(이미 열려 있으면 그 문서). 시험이 바꾼다 — 문서 종류가 없는 시험 프로세스에서는 문서 관리자가
    /// 문서를 만들지 못한다.
    var openDocument: (URL, @escaping (MarkdownDocument?, Error?) -> Void) -> Void = { url, done in
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            done(document as? MarkdownDocument, error)
        }
    }

    /// 새 문서를 보인다. 시험이 바꾼다 — 사용자 화면에 창을 띄우지 않게.
    var present: (MarkdownDocument) -> Void = { document in
        document.makeWindowControllers()
        document.showWindows()
    }

    /// 실패를 알린다. 시험이 바꾼다 — 경고창이 시험을 막지 않게.
    var reportFailure: (String) -> Void = { message in
        let alert = NSAlert()
        alert.messageText = String(localized: "madi:// 링크를 열 수 없습니다")
        alert.informativeText = message
        alert.runModal()
    }

    /// 글을 더하기 전에 묻는다 — 그 문서 창에 시트로, 더할 글을 보이며. 시험이 바꾼다.
    var confirmAppend: (DocumentWindowController, URL, String, @escaping (Bool) -> Void) -> Void = {
        controller, file, text, answer in
        let alert = NSAlert()
        alert.messageText = String(localized: "링크가 이 문서 끝에 글을 더하려 합니다")
        let preview = text.count > 400 ? String(text.prefix(400)) + "…" : text
        alert.informativeText = String(localized: "\(file.lastPathComponent)에 더할 글:\n\n\(preview)")
        alert.addButton(withTitle: String(localized: "더하기"))
        alert.addButton(withTitle: String(localized: "취소"))
        // 기본(Return)은 취소 — 링크가 열린 순간 치던 Return이 더하기를 누르지 않게.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        if let window = controller.window {
            alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
        } else {
            answer(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    var fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    /// 링크 하나를 받는다.
    func handle(_ url: URL) {
        switch MadiURL.parse(url) {
        case .failure(let failure):
            fail(failure.message, url: url)
        case .success(let command):
            AppLog.info(String(localized: "madi:// 링크를 받았습니다"), detail: url.absoluteString)
            run(command)
        }
    }

    func run(_ command: MadiURL.Command) {
        switch command {
        case let .new(text, title, file?):
            createFile(file, contents: MadiURL.newDocumentText(text, title: title, asFile: true))

        case let .new(text, title, nil):
            let document = MarkdownDocument()
            document.fileType = MarkdownDocument.writableTypes.first
            document.markdown = MadiURL.newDocumentText(text, title: title, asFile: false)
            if let title { document.displayName = title }
            NSDocumentController.shared.addDocument(document)
            // 글이 있으면 '편집됨' — 닫을 때 저장할지 묻는다. 빈 새 문서는 평소의 새 문서와 같다.
            if !document.markdown.isEmpty { document.updateChangeCount(.changeDone) }
            present(document)
            // 받은 글 뒤에서 이어 쓴다.
            document.windowControllers.compactMap { $0 as? DocumentWindowController }.first?.moveCaretToEnd()

        case let .open(file, line, search):
            guard fileExists(file) else { return fail(String(localized: "파일이 없습니다: \(file.path)")) }
            openDocument(file) { [weak self] document, error in
                guard let self else { return }
                guard let controller = self.controller(of: document, error: error) else { return }
                if let line { controller.goToFileLine(line) }
                if let search { controller.startSearch(search) }
            }

        case let .append(file, text):
            guard fileExists(file) else { return fail(String(localized: "파일이 없습니다: \(file.path)")) }
            openDocument(file) { [weak self] document, error in
                guard let self else { return }
                guard let controller = self.controller(of: document, error: error) else { return }
                self.confirmAppend(controller, file, text) { accepted in
                    if accepted {
                        controller.appendFromLink(text)
                    } else {
                        AppLog.info(String(localized: "링크의 글 더하기를 취소했습니다"), detail: file.path)
                    }
                }
            }
        }
    }

    /// `new?path=…` — 그 자리에 새 파일을 만들고 연다. **있는 파일은 덮어쓰지 않는다**(먼저 보고, 쓸 때도
    /// `withoutOverwriting` — 그 사이에 생긴 파일도 지키게). 폴더는 만들지 않는다 — 잘못 적은 경로가 폴더를 늘어놓지 않게.
    /// 묻지 않는다: 있던 글을 바꾸지 않고, 만든 파일은 곧 창으로 보인다.
    private func createFile(_ file: URL, contents: String) {
        if fileExists(file) {
            return fail(String(localized: "이미 있는 파일이라 덮어쓰지 않습니다: \(file.path)\n끝에 더하려면 madi://append를 씁니다."))
        }
        let folder = file.deletingLastPathComponent()
        guard fileExists(folder) else { return fail(String(localized: "폴더가 없습니다: \(folder.path)")) }
        do {
            try Data(contents.utf8).write(to: file, options: .withoutOverwriting)
        } catch {
            return fail(String(localized: "파일을 만들지 못했습니다: \(error.localizedDescription)"))
        }
        AppLog.info(String(localized: "링크로 새 파일을 만들었습니다"), detail: file.path)
        openDocument(file) { [weak self] document, error in
            guard let self, let controller = self.controller(of: document, error: error) else { return }
            controller.moveCaretToEnd()
        }
    }

    private func controller(of document: MarkdownDocument?, error: Error?) -> DocumentWindowController? {
        if let error {
            fail(error.localizedDescription)
            return nil
        }
        guard let controller = document?.windowControllers.compactMap({ $0 as? DocumentWindowController }).first
        else {
            fail(String(localized: "문서 창을 찾지 못했습니다."))
            return nil
        }
        // 이미 열린 문서면 뒤에 있거나 다른 탭일 수 있다 — 링크가 가리킨 창을 앞으로(탭이면 그 탭을 고른다).
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private func fail(_ message: String, url: URL? = nil) {
        AppLog.error(String(localized: "madi:// 링크를 열 수 없습니다"),
                     detail: [message, url?.absoluteString].compactMap { $0 }.joined(separator: " · "))
        reportFailure(message)
    }
}
