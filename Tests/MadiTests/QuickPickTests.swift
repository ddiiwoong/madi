import AppKit
import XCTest

/// 빠른 열기·명령 팔레트의 걸러내기(`FuzzyMatch`).
final class FuzzyMatchTests: XCTestCase {

    func testLettersMustAppearInOrder() {
        XCTAssertNotNil(FuzzyMatch.score("fmd", in: "features.md"))
        XCTAssertNotNil(FuzzyMatch.score("줄복", in: "줄 복제"))
        XCTAssertNil(FuzzyMatch.score("dmf", in: "features.md"), "순서가 틀리면 맞지 않는다")
        XCTAssertNil(FuzzyMatch.score("xyz", in: "features.md"))
    }

    func testCaseAccentsAndSpacesAreIgnored() {
        XCTAssertNotNil(FuzzyMatch.score("README", in: "readme.md"))
        XCTAssertNotNil(FuzzyMatch.score("cafe", in: "Café.md"))
        XCTAssertNotNil(FuzzyMatch.score("줄 복", in: "줄복제"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatch.score("", in: "아무거나"), 0)
    }

    func testABackwardJumpStillFindsTheMatch() {
        // 낱말 첫 글자를 잡으러 뒤로 건너뛰면 못 맞추는 경우 — 바로 맞추기로 되돌아간다.
        XCTAssertNotNil(FuzzyMatch.score("ab", in: "xab-a"))
    }

    func testRankingPrefersPrefixesWordStartsAndRuns() {
        let names = ["block-editor-design.md", "features.md", "README.md", "TODO.md"]
        XCTAssertEqual(FuzzyMatch.rank(names, query: "fe") { ($0, nil) }.first, "features.md")
        XCTAssertEqual(FuzzyMatch.rank(names, query: "bed") { ($0, nil) }.first, "block-editor-design.md",
                       "낱말 첫 글자 b·e·d")
        XCTAssertEqual(FuzzyMatch.rank(names, query: "todo") { ($0, nil) }, ["TODO.md"])
    }

    func testTitleMatchesComeBeforePathOnlyMatches() {
        let items: [(String, String?)] = [("a.md", "docs/편집기"), ("편집기.md", "notes")]
        let ranked = FuzzyMatch.rank(items, query: "편집기") { ($0.0, $0.1) }
        XCTAssertEqual(ranked.map(\.0), ["편집기.md", "a.md"], "이름에 맞는 것이 먼저, 위치에만 맞는 것도 남는다")
    }

    func testTiesKeepTheOriginalOrder() {
        let ranked = FuzzyMatch.rank(["b", "a", "c"], query: "") { ($0, nil) }
        XCTAssertEqual(ranked, ["b", "a", "c"], "빈 질의는 원래 순서 그대로(최근 문서는 최근 순)")
    }
}

/// 빠른 열기가 훑는 문서와 목록.
final class QuickOpenSourceTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("madi-quickopen-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        for path in ["a.md", "docs/b.markdown", "docs/c.txt", "docs/x.png", ".hidden/d.md",
                     "node_modules/e.md", "노트.assets/f.md", "deep/1/2/3/g.md"] {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFindsMarkdownAndSkipsHiddenAndVendorFolders() {
        let names = QuickOpenSource.markdownFiles(under: folder).map(\.lastPathComponent)
        XCTAssertEqual(Set(names), ["a.md", "b.markdown", "c.txt", "g.md"])
    }

    func testStopsAtTheLimit() {
        XCTAssertEqual(QuickOpenSource.markdownFiles(under: folder, limit: 2).count, 2)
        XCTAssertLessThanOrEqual(QuickOpenSource.markdownFiles(under: folder, visitLimit: 2).count, 2,
                                 "들여다본 항목 수에도 상한이 있다 — 큰 폴더에서 끝없이 훑지 않는다")
    }

    func testCandidatesAreDeduplicatedInOrder() {
        let a = folder.appendingPathComponent("a.md")
        let b = folder.appendingPathComponent("docs/b.markdown")
        let candidates = QuickOpenSource.candidates(open: [b], recent: [a, b], folderFiles: [a, b], root: folder)
        XCTAssertEqual(candidates.map(\.url), [b, a], "열린 문서, 최근 문서, 폴더 순 — 같은 파일은 한 번")
        XCTAssertEqual(candidates.first?.detail, folder.lastPathComponent + "/docs")
    }

    func testDetailOutsideTheFolderIsShortenedToHome() {
        let url = URL(fileURLWithPath: "/Users/someone/notes/x.md")
        XCTAssertEqual(QuickOpenSource.detail(for: url, root: nil, home: "/Users/someone"), "~/notes")
        XCTAssertEqual(QuickOpenSource.detail(for: URL(fileURLWithPath: "/tmp/x.md"), root: nil, home: "/Users/someone"),
                       "/tmp")
    }
}

/// 명령 팔레트가 메뉴에서 명령을 얻는 방식과 고르개 창.
@MainActor
final class CommandPaletteTests: XCTestCase {

    private final class Target: NSObject {
        var calls: [String] = []
        @objc func first(_ sender: Any?) { calls.append("first") }
        @objc func second(_ sender: Any?) { calls.append("second") }
        @objc func disabled(_ sender: Any?) { calls.append("disabled") }
    }

    private var windows: [NSWindow] = []
    private var panels: [QuickPickPanel] = []

    override func setUp() async throws {
        // 메뉴 명령은 앱을 거쳐 보낸다. 앱을 띄우지 않는 테스트라 누가 부르기 전까지 `NSApp`이 nil이다.
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        for panel in panels { panel.dismiss() }
        for window in windows { window.orderOut(nil) }
        panels = []
        windows = []
    }

    private func menu(_ target: Target) -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()       // 제목은 기본값 — 앱 메뉴와 같다
        let edit = NSMenu(title: "편집")
        let first = edit.addItem(withTitle: "줄 복제", action: #selector(Target.first(_:)), keyEquivalent: "d")
        first.target = target
        edit.addItem(.separator())
        let second = edit.addItem(withTitle: "줄 위로 옮기기", action: #selector(Target.second(_:)), keyEquivalent: "[")
        second.keyEquivalentModifierMask = [.command, .option]
        second.target = target
        let off = edit.addItem(withTitle: "꺼진 명령", action: #selector(Target.disabled(_:)), keyEquivalent: "")
        off.target = target
        edit.autoenablesItems = false
        off.isEnabled = false
        let hidden = edit.addItem(withTitle: "숨긴 명령", action: #selector(Target.first(_:)), keyEquivalent: "+")
        hidden.target = target
        hidden.isHidden = true
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    func testMenuCommandsAreFlattenedWithTheirPlaceAndShortcut() {
        let target = Target()
        let items = CommandPaletteSource.items(from: menu(target))
        XCTAssertEqual(items.map(\.title), ["줄 복제", "줄 위로 옮기기"], "구분선·꺼진 것·숨긴 것은 빠진다")
        XCTAssertEqual(items.map(\.detail), ["편집", "편집"])
        XCTAssertEqual(items.map(\.shortcut), ["⌘D", "⌥⌘["])
    }

    func testExcludedActionsAreLeftOut() {
        let items = CommandPaletteSource.items(from: menu(Target()), excluding: [#selector(Target.first(_:))])
        XCTAssertEqual(items.map(\.title), ["줄 위로 옮기기"])
    }

    func testShortcutShowsShiftForAnUppercaseKey() {
        let item = NSMenuItem(title: "x", action: nil, keyEquivalent: "S")
        XCTAssertEqual(CommandPaletteSource.shortcut(for: item), "⇧⌘S")
        XCTAssertNil(CommandPaletteSource.shortcut(for: NSMenuItem(title: "y", action: nil, keyEquivalent: "")))
    }

    func testPerformingAnItemRunsTheMenuAction() {
        let target = Target()
        let main = menu(target)
        let items = CommandPaletteSource.items(from: main)
        items[1].perform()
        XCTAssertEqual(target.calls, ["second"])
    }

    private func panel(_ items: [QuickPickItem]) -> QuickPickPanel {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.orderBack(nil)
        windows.append(window)
        let panel = QuickPickPanel(placeholder: "찾기", emptyText: "없음")
        panels.append(panel)
        panel.present(over: window, items: items)
        return panel
    }

    func testTypingFiltersAndEnterRunsTheSelectionAfterClosing() async {
        var ran: [String] = []
        let names = ["README.md", "features.md", "TODO.md"]
        let picker = panel(names.map { name in QuickPickItem(title: name) { ran.append(name) } })
        XCTAssertEqual(picker.visible.map(\.title), names)

        picker.query = "fea"
        XCTAssertEqual(picker.visible.map(\.title), ["features.md"])
        picker.query = ".md"
        picker.moveSelection(by: 1)
        picker.chooseSelected()
        XCTAssertFalse(picker.window?.isVisible ?? true, "고르면 창이 닫힌다")
        XCTAssertTrue(ran.isEmpty, "실행은 문서 창이 키가 된 다음 차례")
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(ran.count, 1)
    }

    func testDocumentWindowOffersBothPickersInItsMenus() throws {
        let saved = NSApp.mainMenu
        defer { NSApp.mainMenu = saved }
        let menu = AppMenu.mainMenu()
        func find(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action { return item }
                if let sub = item.submenu, let found = find(action, in: sub) { return found }
            }
            return nil
        }
        let quickOpen = try XCTUnwrap(find(#selector(DocumentWindowController.showQuickOpenAction(_:)), in: menu))
        XCTAssertEqual(CommandPaletteSource.shortcut(for: quickOpen), "⌥⌘O")
        let palette = try XCTUnwrap(find(#selector(DocumentWindowController.showCommandPaletteAction(_:)), in: menu))
        XCTAssertEqual(CommandPaletteSource.shortcut(for: palette), "⇧⌘P")
    }
}
