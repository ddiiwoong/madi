import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppMenu.mainMenu()
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
