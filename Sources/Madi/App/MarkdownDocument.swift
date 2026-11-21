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

    /// 자동 저장을 할지. 시험 과정만 끈다(`MadiTestsSetup` — 시험 번들의 첫 코드).
    ///
    /// 왜: 시험이 만든 이름 없는 문서를 고치면 약 15초 뒤 AppKit이 사용자의 `~/Library/Autosave Information`에
    /// `저장하지 않은 xctest 문서 N.md`로 써 두었다(쌓인 것 106개, 2026-11-08 하루에 74개). 시험은 창을 걷을 뿐 문서를
    /// 닫지 않으므로 지워지지도 않았다. `autosavesInPlace`를 끄면 제목 막대 · 저장 동작이 달라져 시험이 앱과 어긋나므로,
    /// 자동 저장 한 길만 막는다.
    static var autosavingEnabled = true

    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
                           completionHandler: @escaping @Sendable (Error?) -> Void) {
        // 바깥에서 바뀐 파일과 여기서 고친 것 가운데 무엇을 남길지 고르는 중에는 쓰지 않는다 — 쓰면 바깥 것을 덮는다.
        guard Self.autosavingEnabled, !hasExternalConflict else {
            completionHandler(nil)
            return
        }
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable,
                       completionHandler: completionHandler)
    }

    /// 파일 자리가 바뀌었다(처음 저장, 다른 이름으로 저장, Finder에서 옮김). 창이 편집기에 알리고, 처음 저장이면 저장하지
    /// 않았을 때 넣은 그림을 문서 옆으로 옮긴다.
    override var fileURL: URL? {
        didSet {
            guard fileURL != oldValue else { return }
            let old = oldValue
            MainActor.assumeIsolated {
                windowController?.documentFileURLDidChange(from: old)
                restartWatching()
            }
        }
    }

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
        guard let decoded = Self.decode(data) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError)
        }
        MainActor.assumeIsolated {
            diskIsUTF8 = decoded.isUTF8
            diskBaseline = DiskBaseline(data: data, modificationDate: fileURL.flatMap(Self.modificationDate(of:)))
            setExternalConflict(false)
            markdown = decoded.text
            windowController?.load(markdown: decoded.text)
        }
    }

    /// 파일의 바이트를 글로 — UTF-8, 아니면 UTF-16, 아니면 Latin-1(늘 읽힌다).
    nonisolated static func decode(_ data: Data) -> (text: String, isUTF8: Bool)? {
        if let text = String(data: data, encoding: .utf8) { return (text, true) }
        guard let text = String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return (text, false)
    }

    /// 저장이 디스크에 쓴 것을 기준으로 삼는다 — 그래야 마디가 쓴 것을 바깥 변경으로 읽지 않는다. 쓴 뒤의 파일을 다시 읽어
    /// 기준을 잡는다(바꿔 넣는 저장이 쓴 바이트 그대로). 다른 곳에 사본을 쓰는 것(`saveTo` · 이름 없는 문서의 자동 저장)은 이 파일이 아니다.
    ///
    /// 기준을 늦게(감시가 알릴 때) 잡으면 안 된다: 여기서 끝에 친 글이 저장된 뒤 바깥에서 줄이 붙으면, 옛 기준 뒤의 바이트 —
    /// 내가 친 글과 붙은 줄 — 를 '붙은 것'으로 읽어 내가 친 글이 두 번 들어간다.
    override nonisolated func writeSafely(to url: URL, ofType typeName: String,
                                          for saveOperation: NSDocument.SaveOperationType) throws {
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        guard saveOperation != .saveToOperation, saveOperation != .autosaveElsewhereOperation,
              let written = try? Data(contentsOf: url) else { return }
        let modified = Self.modificationDate(of: url)
        let record: @MainActor () -> Void = { [weak self] in
            self?.diskIsUTF8 = true
            self?.diskBaseline = DiskBaseline(data: written, modificationDate: modified)
        }
        if Thread.isMainThread { MainActor.assumeIsolated(record) } else { DispatchQueue.main.async(execute: record) }
    }

    /// 고친 상태(저장 안 함 ↔ 저장함)가 바뀔 수 있을 때 부른다. 창이 없는 문서(나란히 보기의
    /// 번역본)는 제목 막대가 없으므로, 그 칸의 머리가 이것으로 '편집됨'을 맞춘다.
    var changeCountDidChange: (() -> Void)?

    /// 창 없는 문서의 시트(저장 패널, '저장할까요?')를 띄울 창. 나란히 보기의 번역본은 원문 창에
    /// 띄운다 — 정하지 않으면 그때의 주 창에 뜨고, 주 창이 없으면 앱 전체를 막는 대화상자가 된다.
    weak var hostWindow: NSWindow?

    override var windowForSheet: NSWindow? {
        windowControllers.isEmpty ? (hostWindow ?? super.windowForSheet) : super.windowForSheet
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        changeCountDidChange?()
    }

    override func updateChangeCount(withToken changeCountToken: Any,
                                    for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        changeCountDidChange?()
    }

    // MARK: 바깥에서 바뀐 파일
    //
    // 열어 둔 파일을 다른 앱 · 로그를 쓰는 프로그램 · `git pull`이 바꾸면 다시 읽는다(사용자 — "로그 같이 실시간으로 변하는 것에
    // 대한 리로드 전략", 고른 감시: `DispatchSource`). 무엇이 바뀌었는지는 `ExternalFileChange`가, 화면에 들이는 것은 창이
    // (`DocumentWindowController.applyDiskText`) 한다.
    //
    // - 여기서 고친 것이 없으면 묻지 않고 들인다. 끝에 붙은 것은 붙은 바이트만 읽어 끝에 붙이고, 그 밖에는 다른 가운데만 갈아 끼운다.
    // - 고친 것이 있으면 섞지 않는다 — 띠로 묻고, 고를 때까지 자동 저장을 멈춘다(`hasExternalConflict`).
    // - 문서의 수정 시각(`fileModificationDate`)을 디스크에 맞춘다. 안 그러면 다음 저장이 '다른 앱이 바꿨다'로 막힌다.

    /// 디스크에서 마지막으로 맞춰 본 파일 — 읽은 것, 저장이 쓴 것, 바깥에서 들인 것.
    private(set) var diskBaseline: DiskBaseline?
    /// 디스크의 글이 UTF-8인가. 아니면 붙은 바이트를 UTF-8로 읽을 수 없어 늘 통째로 다시 읽는다. 마디의 저장은 늘 UTF-8이다.
    private var diskIsUTF8 = true
    private var watcher: FileChangeWatcher?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    /// 여기서 고친 것이 있는데 파일이 바깥에서 바뀌었다 — 고를 때까지 자동 저장을 멈춘다.
    private(set) var hasExternalConflict = false

    /// 파일을 지켜볼지. 시험 과정은 끈다(`MadiTestsSetup`) — 시험이 만든 문서마다 감시가 남아 임시 폴더를 다시 열어 본다. 감시를
    /// 보는 시험만 켠다.
    static var watchesFiles = true

    /// 지금 감시하고 있는 파일. 시험이 쓴다.
    var watchedURL: URL? { watcher?.url }

    nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func restartWatching() {
        watcher?.cancel()
        watcher = nil
        guard Self.watchesFiles, let url = fileURL, url.isFileURL else { return }
        watcher = FileChangeWatcher(url: url) { [weak self] in self?.reconcileWithDisk() }
        // 감시는 디스크 이미지 · 네트워크 볼륨에서 신호를 놓칠 수 있다 — 앱으로 돌아올 때 한 번 더 본다.
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileWithDisk() }
            }
        }
    }

    override func close() {
        watcher?.cancel()
        watcher = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        super.close()
    }

    /// 다른 프로세스가 파일 조정(`NSFileCoordinator`)을 거쳐 썼다 — 감시와 같은 길로 본다.
    override nonisolated func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reconcileWithDisk() }
        }
    }

    /// 디스크의 파일을 기준과 견주고, 바뀌었으면 들이거나(고친 것이 없을 때) 띠로 묻는다(있을 때). 감시가 0.3초에 한 번 부른다.
    func reconcileWithDisk() {
        guard let url = fileURL, let windowController, let baseline = diskBaseline, !hasExternalConflict,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else { return }
        // 파일이 없으면(지워짐, 바꿔 넣는 중, 로그를 돌려 옮김) 그대로 둔다 — 다시 생기면 감시가 다시 붙어 알린다.
        let modified = attributes[.modificationDate] as? Date
        let change: DiskChange
        do {
            change = try ExternalFileChange.detect(baseline: baseline, size: size, modificationDate: modified,
                                                   appendsAsUTF8: diskIsUTF8) { range in
                try Self.read(range, of: url)
            }
        } catch {
            AppLog.warning(String(localized: "바뀐 파일을 읽지 못했습니다"), detail: error.localizedDescription)
            return
        }
        switch change {
        case let .unchanged(fresh):
            diskBaseline = fresh
        case let .appended(text, fresh):
            guard !isDocumentEdited else { return setExternalConflict(true) }
            diskBaseline = fresh
            let newText = markdown + text
            windowController.applyDiskText(newText, appended: text)
            markdown = newText
            fileModificationDate = modified
        case let .replaced(data, fresh):
            guard !isDocumentEdited else { return setExternalConflict(true) }
            guard let decoded = Self.decode(data) else { return }
            diskBaseline = fresh
            diskIsUTF8 = decoded.isUTF8
            windowController.applyDiskText(decoded.text, appended: nil)
            markdown = decoded.text
            fileModificationDate = modified
            // 가운데가 바뀌었다 — 실행 취소의 옛 자리가 틀린다(편집기도 비웠다). 문서의 것도 비운다.
            undoManager?.removeAllActions()
            AppLog.info(String(localized: "다른 곳에서 바뀐 파일을 다시 읽었습니다"), detail: displayName)
        }
    }

    /// 파일의 바이트 구간. 그사이 파일이 줄었으면 덜 돌려준다.
    nonisolated static func read(_ range: Range<Int>, of url: URL) throws -> Data {
        guard !range.isEmpty else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: range.count) ?? Data()
    }

    private func setExternalConflict(_ conflict: Bool) {
        guard conflict != hasExternalConflict else { return }
        hasExternalConflict = conflict
        windowController?.showFileChangedElsewhere(conflict)
        if conflict {
            AppLog.warning(String(localized: "여기서 고친 것이 있는데 파일이 다른 곳에서 바뀌었습니다 — 고를 때까지 자동 저장을 멈춥니다"),
                           detail: displayName)
        }
    }

    /// 띠의 '다시 읽기' — 여기서 고친 것을 버리고 디스크의 것을 읽는다.
    func reloadFromDisk() {
        guard let url = fileURL, let type = fileType else { return }
        do {
            try revert(toContentsOf: url, ofType: type)
            undoManager?.removeAllActions()
            AppLog.info(String(localized: "여기서 고친 것을 버리고 파일을 다시 읽었습니다"), detail: displayName)
        } catch {
            presentError(error)
        }
    }

    /// 띠의 '내 것 지키기' — 다른 곳에서 바뀐 것을 덮어쓰고 여기서 고친 것을 저장한다. 지금 디스크의 것을 본 것으로 두어(수정 시각과
    /// 기준) 저장이 '다른 앱이 바꿨다'로 막히지 않게 한다.
    func keepMineOverDisk(completion: (@MainActor (Error?) -> Void)? = nil) {
        guard let url = fileURL, let type = fileType else { return }
        if let data = try? Data(contentsOf: url) {
            diskBaseline = DiskBaseline(data: data, modificationDate: Self.modificationDate(of: url))
        }
        fileModificationDate = Self.modificationDate(of: url)
        setExternalConflict(false)
        let name = displayName ?? ""
        save(to: url, ofType: type, for: .saveOperation) { error in
            MainActor.assumeIsolated {
                if let error {
                    AppLog.error(String(localized: "여기서 고친 것을 저장하지 못했습니다"), detail: error.localizedDescription)
                } else {
                    AppLog.info(String(localized: "다른 곳에서 바뀐 것을 덮어쓰고 여기서 고친 것을 저장했습니다"), detail: name)
                }
                completion?(error)
            }
        }
    }

    /// Called by the window controller when the user types.
    func editorDidChange(markdown text: String) {
        guard text != markdown else { return }
        markdown = text
        updateChangeCount(.changeDone)
    }
}
