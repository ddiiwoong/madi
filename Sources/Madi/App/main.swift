import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = PreferenceStore()
    private let urlRunner = URLCommandRunner()
    /// 켜는 동안 받은 링크. 켜기가 끝난 뒤에 실행한다 — 먼저 실행하면 그 뒤에 되살아나는 창(지난번에 열어 둔 문서)이
    /// 링크의 창을 덮어, `append`가 묻는 시트가 가려진다(앱에서 처음 본 것).
    private var pendingLinks: [URL] = []
    private var finishedLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `madi://` 링크. 끝나기 전(will)에 단다 — 링크로 앱이 켜질 때 그 링크가 첫 사건으로 온다.
        // `application(_:open:)`을 쓰지 않는다: 그것을 두면 파일 열기까지 그쪽으로 와 문서 관리자의 열기를 떠맡게 된다.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        // 앱에 든 글꼴은 **창을 만들기 전에** 등록한다 — 먼저 만든 창은 시스템 글꼴로 그린다.
        for failure in BundledFonts.register() {
            AppLog.warning(String(localized: "앱에 든 글꼴을 등록하지 못했습니다 — 시스템 글꼴로 그립니다"),
                           detail: "\(failure.file): \(failure.reason)")
        }
        NSApp.mainMenu = AppMenu.mainMenu()
        // 모양은 **앱 전체**의 성질이라 창마다 두지 않는다. 설정이 바뀌면 다시 싣는다.
        applyAppearance()
        NotificationCenter.default.addObserver(
            forName: PreferenceStore.didChange, object: nil, queue: .main
        ) { _ in Task { @MainActor in self.applyAppearance() } }
        // 글꼴을 설치·삭제하면(설정의 '받기…'로 받아 설치한 것 등) 기억해 둔 글꼴을 버리고 열린 창을
        // 다시 칠한다 — '이 Mac에 없음'으로 기억한 이름이 설치한 뒤에도 시스템 글꼴로 남지 않게.
        NotificationCenter.default.addObserver(
            forName: NSFont.fontSetChangedNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                MarkdownTheme.forgetResolvedFonts()
                NotificationCenter.default.post(name: PreferenceStore.didChange, object: nil)
            }
        }
    }

    /// 시스템을 따를 때는 `nil`을 준다 — 아무 값이나 넣으면 사용자가 시스템 모양을
    /// 바꿔도 앱만 그대로 남는다.
    private func applyAppearance() {
        let current = preferences.current
        switch current.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        // 보기 ▸ 테마의 체크. 설정 창에서 바꿔도 메뉴가 따라온다.
        if let main = NSApp.mainMenu { AppMenu.markColorTheme(current.colorTheme, in: main) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        finishedLaunching = true
        // 되살린 문서는 다 읽은 뒤에 창을 띄운다 — 한 차례 뒤에 돌려 그 창들보다 나중에 앞으로 오게.
        DispatchQueue.main.async { [self] in
            let links = pendingLinks
            pendingLinks = []
            for link in links { urlRunner.handle(link) }
        }
        // 오래된 임시 그림(저장하지 않은 문서에 붙여 넣은 것)을 휴지통으로 — 되살린 문서가 다 열린 뒤에.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.cleanUpStagedImages() }
        // 새 판 확인(하루 한 번) — 켜자마자 묻는 창을 띄우지 않게 조금 뒤에.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { UpdateController.shared.launched() }
    }

    /// 받아 둔 새 판이 있으면 여기서 바꿔 넣는다(`UpdateController`).
    func applicationWillTerminate(_ notification: Notification) {
        UpdateController.shared.installPendingUpdate()
    }

    /// 열린 문서의 글은 여기(메인)서 모으고, 파일 읽기와 휴지통 넣기는 뒤에서.
    private func cleanUpStagedImages() {
        guard let staging = ImageImporter.defaultStagingFolder,
              FileManager.default.fileExists(atPath: staging.path) else { return }
        let controller = NSDocumentController.shared
        let openTexts = controller.documents.compactMap { ($0 as? MarkdownDocument)?.markdown }
        let recent = controller.recentDocumentURLs
        let autosave = try? FileManager.default.url(for: .autosavedInformationDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: false)
        DispatchQueue.global(qos: .utility).async {
            let trashed = StagedImageJanitor.run(stagingFolder: staging, openTexts: openTexts, autosaveFolder: autosave,
                                                 recentDocuments: recent, trash: StagedImageJanitor.moveToTrash)
            guard !trashed.isEmpty else { return }
            DispatchQueue.main.async {
                AppLog.info(String(localized: "오래된 임시 그림 \(trashed.count)개를 휴지통으로 옮겼습니다"),
                            detail: trashed.map(\.lastPathComponent).joined(separator: "\n"))
            }
        }
    }

    /// Open an untitled document on launch when nothing was restored, so the
    /// app starts in a state the user can type into.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.documents.isEmpty
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// `madi://…` — 실행은 `URLCommandRunner`.
    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = MadiURL.url(from: text) else { return }
        if finishedLaunching {
            urlRunner.handle(url)
        } else {
            pendingLinks.append(url)
        }
    }
}

// `@main` with an AppKit document app: NSDocumentController is created lazily by
// AppKit, and the Info.plist's NSDocumentClass points it at MarkdownDocument.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
