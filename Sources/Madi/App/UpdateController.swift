import AppKit

/// 새 판 확인과 업데이트의 화면 쪽 — 마디 메뉴의 `업데이트 확인…`, 켤 때와 켜 둔 동안의 하루 한 번, 묻는 알림, 받는 동안의
/// 작은 창, 끌 때 바꿔 넣기. 판 비교와 응답 읽기는 `ReleaseFeed`(Core), 받기 · 확인 · 바꿔 넣기는 `UpdateInstaller`(Services).
///
/// **자동 업데이트**(설정 ▸ 일반, 기본 켜짐 — 사용자 — "자동업데이트 기능"): 저절로 한 확인이 새 판을 찾으면 묻지 않고 뒤에서
/// 받아 서명까지 확인해 두고, 끌 때 바꿔 넣는다. 다시 켜지는 않는다 — 사용자가 끄려고 끈 것이다. 다음에 켤 때 바뀐 판을 한 번
/// 알린다. 받지 못하면 알리지 않고 기록에만 남긴다(다음 날 다시 한다). 바꿔 넣을 수 없는 자리(직접 빌드한 것, 디스크 이미지)면
/// 전처럼 묻는 창이 받는 페이지를 준다. 메뉴로 확인하면 늘 묻는다 — 사용자가 지금 하려는 것이다.
///
/// 바꿔 넣기는 **끌 때** 한다(`applicationWillTerminate` → `installPendingUpdate`). 켜져 있는 동안 앱 꾸러미를
/// 바꾸면 남은 시간 동안 새 판의 자원을 옛 코드가 읽게 된다. 끄기를 취소하면(저장 묻기에서 취소 등) 받아 둔 새 판은
/// 그대로 있다가 다음에 끌 때 들어가고, 그때는 다시 켜지 않는다 — 5분 넘게 지난 끄기는 사용자가 업데이트하려고
/// 끈 것이 아니다.
@MainActor
final class UpdateController: NSObject {

    static let shared = UpdateController()

    struct PendingInstall {
        let newApp: URL
        let target: URL
        /// 업데이트를 누른 때. 저절로 받은 것은 `.distantPast`라 끌 때 다시 켜지 않는다.
        var requestedAt: Date
        var staging: URL? = nil
        /// 받아 둔 판. 다시 켜지 않고 바꿔 넣었으면 다음에 켤 때 이 판을 알린다.
        var version: ReleaseVersion? = nil
    }

    /// 업데이트를 누른 뒤 이만큼 안에 꺼지면 새 판을 다시 연다.
    static let relaunchWindow: TimeInterval = 5 * 60
    /// 켜 둔 동안 확인할 때가 됐는지 보는 간격. 확인 자체는 하루 한 번이다(`ReleaseFeed.isCheckDue`) — 며칠씩 켜 두는
    /// 사람에게도 새 판이 간다.
    static let periodicInterval: TimeInterval = 60 * 60

    private let store: PreferenceStore
    private let checker: ReleaseChecker
    /// 실행 중인 앱의 팀 ID · 꾸러미 자리 · 식별자 · 판. 시험이 바꾼다.
    var teamIdentifier: @MainActor () -> String? = { UpdateInstaller.runningTeamIdentifier() }
    var appURL: URL = Bundle.main.bundleURL
    var bundleIdentifier: String = Bundle.main.bundleIdentifier ?? ""
    var currentVersion: String = AppVersion.short
    /// 알림을 띄우는 곳. 시험이 바꿔 단추를 고른다 — 앞에서부터 0, 1, 2.
    var presentAlert: @MainActor (NSAlert) -> Int = { alert in
        switch alert.runModal() {
        case .alertFirstButtonReturn: return 0
        case .alertSecondButtonReturn: return 1
        default: return 2
        }
    }
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    /// 받아서 확인까지(`UpdateInstaller.prepare`) — 새 판, 바꿀 앱 자리, 식별자, 팀 ID. 시험이 바꾼다.
    var prepareUpdate: @MainActor (AvailableRelease, URL, String, String) async throws -> UpdateInstaller.Prepared
    /// 켜 둔 동안의 확인을 시계에 걸지. 시험은 끈다.
    var schedulesPeriodicChecks = true

    private(set) var pending: PendingInstall?
    private(set) var isChecking = false
    /// 뒤에서 받는 중인 판(자동 업데이트). 받는 동안 메뉴로 확인하면 그렇다고 알린다.
    private(set) var backgroundDownload: ReleaseVersion?
    private var downloadTask: Task<Void, Never>?
    private var progressWindow: NSPanel?
    private var periodicTimer: Timer?

    init(store: PreferenceStore = PreferenceStore(), checker: ReleaseChecker = ReleaseChecker(),
         installer: UpdateInstaller = UpdateInstaller()) {
        self.store = store
        self.checker = checker
        self.prepareUpdate = { release, target, identifier, team in
            try await installer.prepare(release, replacing: target, bundleIdentifier: identifier, teamIdentifier: team)
        }
    }

    // MARK: 확인

    /// 켤 때. 설정이 켜져 있고, 배포용으로 서명된 마디이고(직접 빌드한 것은 확인하지 않는다), 지난 확인에서
    /// 하루가 지났으면. 지난번 끌 때 바꿔 넣지 못했으면 그것부터, 저절로 바꿔 넣었으면 그 판을 알린다. 켜 둔 동안의
    /// 확인도 여기서 시계에 건다.
    func launched(now: Date = Date()) {
        if let failure = store.updateInstallFailure {
            store.updateInstallFailure = nil
            AppLog.error(String(localized: "지난번 업데이트가 끝나지 못했습니다"), detail: failure)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "지난번 업데이트가 끝나지 못했습니다")
            alert.informativeText = failure
            alert.addButton(withTitle: String(localized: "확인"))
            _ = presentAlert(alert)
        }
        if let installed = store.installedUpdateNotice {
            store.installedUpdateNotice = nil
            // 그 판으로 켜졌을 때만 — 다른 사본을 켰거나 바꿔 넣은 것이 되돌려졌으면 말이 틀린다.
            if installed == currentVersion { showInstalled(installed) }
        }
        if schedulesPeriodicChecks, periodicTimer == nil {
            let timer = Timer(timeInterval: Self.periodicInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.periodicCheck(now: Date()) }
            }
            timer.tolerance = 10 * 60
            RunLoop.main.add(timer, forMode: .common)
            periodicTimer = timer
        }
        guard shouldCheckAtLaunch(now: now) else { return }
        Task { await check(interactive: false) }
    }

    /// 켜 둔 동안 시계가 부른다 — 하루가 지났고, 받아 둔 것도 받는 중인 것도 없으면 확인한다. 시작한 확인을 돌려준다(시험).
    @discardableResult
    func periodicCheck(now: Date) -> Task<Void, Never>? {
        guard shouldCheckAtLaunch(now: now), pending == nil, downloadTask == nil, !isChecking else { return nil }
        return Task { await check(interactive: false) }
    }

    func shouldCheckAtLaunch(now: Date) -> Bool {
        store.current.checksForUpdates && teamIdentifier() != nil
            && ReleaseFeed.isCheckDue(lastCheck: store.lastUpdateCheck, now: now)
    }

    /// 마디 메뉴 ▸ 업데이트 확인…
    @objc func checkForUpdates(_ sender: Any?) {
        Task { await check(interactive: true) }
    }

    /// `interactive`이면 최신일 때와 실패했을 때도 알린다. 저절로 한 확인은 새 판이 있을 때만 — 자동 업데이트가 켜져 있고
    /// 바꿔 넣을 수 있으면 그때도 묻지 않고 뒤에서 받는다.
    func check(interactive: Bool) async {
        if interactive, let pending {
            showPendingReady(pending)
            return
        }
        if interactive, let version = backgroundDownload {
            showDownloadingInBackground(version)
            return
        }
        guard !isChecking, downloadTask == nil, pending == nil else { return }
        isChecking = true
        defer { isChecking = false }
        guard let current = ReleaseVersion(currentVersion) else {
            AppLog.warning(String(localized: "이 마디의 판 번호를 읽지 못해 새 판을 확인하지 않습니다"), detail: currentVersion)
            return
        }
        let latest: AvailableRelease
        do {
            latest = try await checker.latest(currentVersion: currentVersion)
        } catch {
            AppLog.warning(String(localized: "새 판을 확인하지 못했습니다"), detail: error.localizedDescription)
            if interactive { showFailure(error, page: nil) }
            return
        }
        store.lastUpdateCheck = Date()
        switch ReleaseFeed.compare(current: current, with: latest) {
        case let .upToDate(latestVersion):
            AppLog.info(String(localized: "마디가 최신입니다"), detail: "\(current) (GitHub \(latestVersion))")
            if interactive { showUpToDate(current) }
        case let .available(release):
            AppLog.info(String(localized: "새 판이 나왔습니다"), detail: "\(current) → \(release.version)")
            if !interactive, store.current.installsUpdatesAutomatically, blocker(for: release) == nil {
                downloadInBackground(release)
            } else {
                offer(release, current: current)
            }
        }
    }

    /// 뒤에서 받는 확인이 끝나기를 기다린다. 시험용.
    func waitForBackgroundDownload() async {
        await downloadTask?.value
    }

    /// 바꿔 넣을 수 없는 까닭. 없으면 nil.
    func blocker(for release: AvailableRelease) -> UpdateInstallBlocker? {
        let parent = appURL.deletingLastPathComponent()
        let readOnly = (try? appURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        return ReleaseFeed.installBlocker(
            appPath: appURL.path, onReadOnlyVolume: readOnly,
            parentIsWritable: FileManager.default.isWritableFile(atPath: parent.path),
            teamIdentifier: teamIdentifier(), release: release)
    }

    // MARK: 알림

    private func offer(_ release: AvailableRelease, current: ReleaseVersion) {
        let blocker = blocker(for: release)
        let alert = NSAlert()
        // 조사를 판 번호 뒤에 붙이지 않는다 — 숫자의 끝소리를 알 수 없다.
        alert.messageText = String(localized: "새 판이 나왔습니다 — 마디 \(release.version.description)")
        if let blocker {
            alert.informativeText = String(localized: "지금 쓰는 판: \(current.description)") + "\n\n" + blocker.explanation
            alert.addButton(withTitle: String(localized: "받는 페이지 열기"))
            alert.addButton(withTitle: String(localized: "나중에"))
            if presentAlert(alert) == 0 { openURL(release.page) }
            return
        }
        alert.informativeText = String(localized: "지금 쓰는 판: \(current.description)")
            + "\n\n" + String(localized: "업데이트하면 새 판을 받아 서명을 확인한 뒤, 마디를 닫고 새 판으로 다시 엽니다.")
        alert.addButton(withTitle: String(localized: "업데이트하고 다시 열기"))
        alert.addButton(withTitle: String(localized: "바뀐 점 보기"))
        alert.addButton(withTitle: String(localized: "나중에"))
        switch presentAlert(alert) {
        case 0: startUpdate(release)
        case 1: openURL(release.page)
        default: break
        }
    }

    /// 받아 둔 새 판이 있을 때 메뉴로 확인했다 — 지금 다시 열지, 끌 때 둘지.
    private func showPendingReady(_ pending: PendingInstall) {
        let alert = NSAlert()
        alert.messageText = pending.version.map { String(localized: "새 판을 받아 두었습니다 — 마디 \($0.description)") }
            ?? String(localized: "새 판을 받아 두었습니다")
        alert.informativeText = String(localized: "마디를 끌 때 바꿔 넣습니다. 지금 바꾸려면 다시 여십시오.")
        alert.addButton(withTitle: String(localized: "지금 다시 열기"))
        alert.addButton(withTitle: String(localized: "나중에"))
        guard presentAlert(alert) == 0 else { return }
        // 누른 지금부터 5분 — 끄면 새 판으로 다시 연다(`installPendingUpdate`).
        self.pending?.requestedAt = Date()
        terminate()
    }

    private func showDownloadingInBackground(_ version: ReleaseVersion) {
        let alert = NSAlert()
        alert.messageText = String(localized: "새 판을 받는 중입니다 — 마디 \(version.description)")
        alert.informativeText = String(localized: "다 받으면 마디를 끌 때 바꿔 넣습니다.")
        alert.addButton(withTitle: String(localized: "확인"))
        _ = presentAlert(alert)
    }

    /// 지난번 끌 때 저절로 바꿔 넣은 판을 알린다.
    private func showInstalled(_ version: String) {
        AppLog.info(String(localized: "새 판으로 바꿔 넣었습니다"), detail: version)
        let alert = NSAlert()
        alert.messageText = String(localized: "마디를 업데이트했습니다 — \(version)")
        alert.informativeText = String(localized: "지난번에 끌 때 새 판으로 바꿔 넣었습니다. 자동 업데이트는 설정 ▸ 일반에서 끌 수 있습니다.")
        alert.addButton(withTitle: String(localized: "바뀐 점 보기"))
        alert.addButton(withTitle: String(localized: "확인"))
        if presentAlert(alert) == 0, let page = URL(string: "https://github.com/\(ReleaseFeed.repository)/releases/tag/v\(version)") {
            openURL(page)
        }
    }

    private func showUpToDate(_ current: ReleaseVersion) {
        let alert = NSAlert()
        alert.messageText = String(localized: "마디가 최신입니다")
        alert.informativeText = String(localized: "지금 쓰는 판: \(current.description)")
        alert.addButton(withTitle: String(localized: "확인"))
        _ = presentAlert(alert)
    }

    private func showFailure(_ error: Error, page: URL?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = page == nil ? String(localized: "새 판을 확인하지 못했습니다")
                                        : String(localized: "업데이트하지 못했습니다")
        alert.informativeText = error.localizedDescription
        if let page {
            alert.addButton(withTitle: String(localized: "받는 페이지 열기"))
            alert.addButton(withTitle: String(localized: "닫기"))
            if presentAlert(alert) == 0 { openURL(page) }
        } else {
            alert.addButton(withTitle: String(localized: "확인"))
            _ = presentAlert(alert)
        }
    }

    // MARK: 받기와 바꿔 넣기

    private func startUpdate(_ release: AvailableRelease) {
        guard let team = teamIdentifier() else { return }
        let target = appURL
        let identifier = bundleIdentifier
        let prepare = prepareUpdate
        showProgress(for: release)
        downloadTask = Task {
            do {
                let prepared = try await prepare(release, target, identifier, team)
                self.finishDownload()
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: prepared.staging)
                    return
                }
                self.pending = PendingInstall(newApp: prepared.app, target: target, requestedAt: Date(),
                                              staging: prepared.staging, version: release.version)
                AppLog.info(String(localized: "새 판을 받아 서명을 확인했습니다 — 끌 때 바꿔 넣습니다"),
                            detail: "\(release.version) · \(prepared.app.path)")
                self.terminate()
            } catch {
                let cancelled = Task.isCancelled
                self.finishDownload()
                if cancelled { return }
                AppLog.error(String(localized: "업데이트하지 못했습니다"), detail: error.localizedDescription)
                self.showFailure(error, page: release.page)
            }
        }
    }

    /// 자동 업데이트 — 묻지 않고, 받는 창도 없이 받아 확인해 둔다. 끌 때 바꿔 넣고 다시 켜지 않는다(`requestedAt`이
    /// 먼 옛날). 실패는 기록에만 — 저절로 한 일이 창을 띄우면 안 된다. 다음 날 확인이 다시 해 본다.
    private func downloadInBackground(_ release: AvailableRelease) {
        guard let team = teamIdentifier() else { return }
        let target = appURL
        let identifier = bundleIdentifier
        let prepare = prepareUpdate
        backgroundDownload = release.version
        AppLog.info(String(localized: "새 판을 뒤에서 받습니다"), detail: release.version.description)
        downloadTask = Task {
            defer {
                self.backgroundDownload = nil
                self.downloadTask = nil
            }
            do {
                let prepared = try await prepare(release, target, identifier, team)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: prepared.staging)
                    return
                }
                self.pending = PendingInstall(newApp: prepared.app, target: target, requestedAt: .distantPast,
                                              staging: prepared.staging, version: release.version)
                AppLog.info(String(localized: "새 판을 받아 서명을 확인했습니다 — 끌 때 바꿔 넣습니다"),
                            detail: "\(release.version) · \(prepared.app.path)")
            } catch {
                AppLog.warning(String(localized: "새 판을 뒤에서 받지 못했습니다 — 내일 다시 해 봅니다"),
                               detail: error.localizedDescription)
            }
        }
    }

    private func finishDownload() {
        downloadTask = nil
        progressWindow?.orderOut(nil)
        progressWindow = nil
    }

    @objc private func cancelDownload(_ sender: Any?) {
        downloadTask?.cancel()
        finishDownload()
        AppLog.info(String(localized: "업데이트를 그만뒀습니다"))
    }

    /// 받는 동안의 작은 창 — 무엇을 하는 중인지와 취소.
    private func showProgress(for release: AvailableRelease) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = String(localized: "업데이트")
        panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: String(localized: "마디 \(release.version.description) 받는 중…"))
        let spinner = NSProgressIndicator()
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        let cancel = NSButton(title: String(localized: "취소"), target: self, action: #selector(cancelDownload(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let content = NSView()
        for view in [label, spinner, cancel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            spinner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            spinner.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 10),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        panel.contentView = content
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        progressWindow = panel
    }

    /// 끌 때(`applicationWillTerminate`). 받아 둔 새 판을 바꿔 넣고, 업데이트를 누르고 곧 끈 것이면 다시 연다. 다시 열지
    /// 않으면(저절로 받은 것, 누르고 한참 뒤에 끈 것) 다음에 켤 때 바뀐 판을 알린다.
    /// 실패는 끄는 중이라 알릴 수 없으므로 적어 두고 다음에 켤 때 알린다.
    func installPendingUpdate(now: Date = Date(), relaunch: (URL) throws -> Void = { app in
        try UpdateInstaller.relaunch(app, after: ProcessInfo.processInfo.processIdentifier)
    }) {
        guard let pending else { return }
        self.pending = nil
        do {
            try UpdateInstaller.install(pending.newApp, over: pending.target, staging: pending.staging)
        } catch {
            store.updateInstallFailure = error.localizedDescription
                + "\n\n" + String(localized: "지금 켜진 것은 전의 판입니다. 받는 페이지에서 받아 직접 바꿔 넣을 수 있습니다.")
            return
        }
        guard now.timeIntervalSince(pending.requestedAt) < Self.relaunchWindow else {
            store.installedUpdateNotice = pending.version?.description
            return
        }
        do {
            try relaunch(pending.target)
        } catch {
            store.updateInstallFailure = String(localized: "새 판으로 바꿔 넣었지만 다시 열지 못했습니다: \(error.localizedDescription)")
        }
    }

    /// 시험용 — 받아 둔 새 판을 정해 둔다.
    func setPendingForTesting(_ install: PendingInstall?) { pending = install }
}
