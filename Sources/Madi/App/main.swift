import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = PreferenceStore()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppMenu.mainMenu()
        // 모양은 **앱 전체**의 성질이라 창마다 두지 않는다. 설정이 바뀌면 다시 싣는다.
        applyAppearance()
        NotificationCenter.default.addObserver(
            forName: PreferenceStore.didChange, object: nil, queue: .main
        ) { _ in Task { @MainActor in self.applyAppearance() } }
    }

    /// 시스템을 따를 때는 `nil`을 준다 — 아무 값이나 넣으면 사용자가 시스템 모양을
    /// 바꿔도 앱만 그대로 남는다.
    private func applyAppearance() {
        switch preferences.current.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    /// Open an untitled document on launch when nothing was restored, so the
    /// app starts in a state the user can type into.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.documents.isEmpty
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// `@main` with an AppKit document app: NSDocumentController is created lazily by
// AppKit, and the Info.plist's NSDocumentClass points it at MarkdownDocument.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
