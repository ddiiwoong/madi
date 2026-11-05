import AppKit
import UniformTypeIdentifiers
import XCTest

/// 사이드바의 최근 문서·파일 브라우저, 기록 패널 — 전에는 앱을 띄워 눈으로만 확인했다.
@MainActor
final class RecentDocumentsPanelTests: XCTestCase {

    private final class Opener: RecentDocumentsPanelDelegate {
        var opened: [URL] = []
        func recentDocumentsPanel(_ panel: RecentDocumentsPanelView, didOpen url: URL) { opened.append(url) }
    }

    private let urls = [URL(fileURLWithPath: "/글/하나.md"), URL(fileURLWithPath: "/글/둘.md")]

    func testListsTheRecentDocumentsAndOpensTheClickedOne() throws {
        let panel = RecentDocumentsPanelView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        let opener = Opener()
        panel.delegate = opener
        panel.source = { self.urls }
        panel.reload()

        XCTAssertEqual(panel.tableView.numberOfRows, 2)
        XCTAssertTrue(panel.emptyLabel.isHidden)
        XCTAssertFalse(panel.clearButton.isHidden)
        let cell = try XCTUnwrap(panel.tableView.delegate?.tableView?(panel.tableView, viewFor: nil, row: 1)
                                 as? NSTableCellView)
        XCTAssertEqual(cell.textField?.stringValue, "둘.md")

        panel.open(row: 1)
        XCTAssertEqual(opener.opened, [urls[1]])
        panel.open(row: 9)
        XCTAssertEqual(opener.opened.count, 1, "없는 줄은 열지 않는다")
    }

    func testEmptyListShowsTheEmptyLabel() {
        let panel = RecentDocumentsPanelView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        panel.source = { [] }
        panel.reload()
        XCTAssertFalse(panel.emptyLabel.isHidden)
        XCTAssertTrue(panel.clearButton.isHidden, "지울 것이 없으면 단추를 숨긴다")
    }

    func testClearingEmptiesTheSourceAndReloads() {
        let panel = RecentDocumentsPanelView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        var stored = urls
        panel.source = { stored }
        panel.clearSource = { stored = [] }
        panel.reload()
        panel.clearButton.performClick(nil)
        XCTAssertTrue(stored.isEmpty)
        XCTAssertEqual(panel.tableView.numberOfRows, 0)
        XCTAssertFalse(panel.emptyLabel.isHidden)
    }

    func testTheAppPanelReadsTheDocumentControllersList() {
        // 기본 출처가 문서 관리자의 목록이다 — 파일 ▸ 최근 문서 열기와 같은 목록.
        let panel = RecentDocumentsPanelView(frame: .zero)
        XCTAssertEqual(panel.source(), NSDocumentController.shared.recentDocumentURLs)
    }
}

@MainActor
final class FileBrowserPanelTests: XCTestCase {

    private final class Opener: FileBrowserPanelDelegate {
        var opened: [URL] = []
        func fileBrowserPanel(_ panel: FileBrowserPanelView, didOpen url: URL) { opened.append(url) }
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("madi-browser-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        for path in ["나중.md", "가.markdown", "메모.txt", "그림.png", ".숨김.md", "하위/안쪽.md", "하위/표.csv"] {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func names(_ panel: FileBrowserPanelView) -> [String] {
        (0 ..< panel.outlineView.numberOfRows).compactMap {
            (panel.outlineView.item(atRow: $0) as? URL)?.lastPathComponent
        }
    }

    func testShowsFoldersFirstThenMarkdownAndSkipsTheRest() {
        let panel = FileBrowserPanelView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        panel.show(folderOf: folder.appendingPathComponent("나중.md"))
        XCTAssertEqual(panel.currentRoot?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(names(panel), ["하위", "가.markdown", "나중.md", "메모.txt"],
                       "폴더가 먼저, 그다음 이름 순. 그림과 숨은 파일은 빠진다")
        XCTAssertEqual(panel.pathButton.title, folder.lastPathComponent)
    }

    func testClickingAFileOpensItAndAFolderDoesNot() {
        let panel = FileBrowserPanelView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        let opener = Opener()
        panel.delegate = opener
        panel.setRoot(folder)
        panel.click(row: 0)                                    // 하위 (폴더)
        XCTAssertTrue(opener.opened.isEmpty, "폴더를 한 번 누르면 아무것도 열지 않는다")
        panel.click(row: 2)                                    // 나중.md
        XCTAssertEqual(opener.opened.map(\.lastPathComponent), ["나중.md"])
    }

    func testDoubleClickingAFolderExpandsItInPlace() {
        let panel = FileBrowserPanelView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        let opener = Opener()
        panel.delegate = opener
        panel.setRoot(folder)
        panel.doubleClick(row: 0)
        XCTAssertEqual(names(panel), ["하위", "안쪽.md", "가.markdown", "나중.md", "메모.txt"],
                       "펼친 폴더 안의 마크다운만 보인다(표.csv는 빠진다)")
        panel.doubleClick(row: 1)
        XCTAssertEqual(opener.opened.map(\.lastPathComponent), ["안쪽.md"])
        panel.doubleClick(row: 0)
        XCTAssertEqual(names(panel).count, 4, "다시 두 번 누르면 접힌다")
    }

    func testAnUnsavedDocumentLeavesTheBrowserAlone() {
        let panel = FileBrowserPanelView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        panel.setRoot(folder)
        panel.show(folderOf: nil)
        XCTAssertEqual(panel.currentRoot?.standardizedFileURL, folder.standardizedFileURL)
    }
}

@MainActor
final class ActivityLogPanelTests: XCTestCase {

    private var panels: [ActivityLogPanel] = []
    private var boards: [NSPasteboard] = []

    override func tearDown() async throws {
        for panel in panels { panel.window?.orderOut(nil) }
        for board in boards { board.releaseGlobally() }
        panels = []
        boards = []
    }

    private func panel(_ log: ActivityLog) -> (ActivityLogPanel, NSPasteboard) {
        let board = NSPasteboard(name: NSPasteboard.Name("madi-log-\(UUID().uuidString)"))
        boards.append(board)
        let panel = ActivityLogPanel(log: log, autosavesFrame: false, pasteboard: board)
        panels.append(panel)
        return (panel, board)
    }

    private func sampleLog() -> ActivityLog {
        let log = ActivityLog()
        log.append(.info, "문서를 열었습니다")
        log.append(.warning, "그림을 읽지 못했습니다", detail: "/없는/그림.png")
        log.append(.error, "번역하지 못했습니다")
        return log
    }

    func testShowsEveryEntryNewestFirstAndFiltersByLevel() throws {
        let (panel, _) = panel(sampleLog())
        XCTAssertEqual(panel.table.numberOfRows, 3)
        XCTAssertEqual(panel.shown.map(\.message), ["번역하지 못했습니다", "그림을 읽지 못했습니다", "문서를 열었습니다"])
        let first = try XCTUnwrap(panel.table.delegate?.tableView?(panel.table, viewFor: nil, row: 0) as? NSTextField)
        XCTAssertTrue(first.stringValue.contains("번역하지 못했습니다"))
        XCTAssertEqual(first.textColor, .systemRed, "실패는 빨갛게")

        panel.filter.selectedSegment = 1
        panel.filterChanged(panel.filter)
        XCTAssertEqual(panel.shown.map(\.level), [.error, .warning], "주의 이상")
        panel.filter.selectedSegment = 2
        panel.filterChanged(panel.filter)
        XCTAssertEqual(panel.shown.map(\.level), [.error], "실패만")
    }

    func testCopyAllPutsTheShownLinesOnThePasteboard() throws {
        let (panel, board) = panel(sampleLog())
        panel.copyAll()
        let text = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(text.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(text.contains("/없는/그림.png"), "자세한 내용도 함께")
    }

    func testClearEmptiesTheLogAndTheTable() {
        let log = sampleLog()
        let (panel, board) = panel(log)
        panel.clearLog()
        XCTAssertEqual(log.count, 0)
        XCTAssertEqual(panel.table.numberOfRows, 0)
        board.clearContents()
        panel.copyAll()
        XCTAssertNil(board.string(forType: .string), "비었으면 대지를 건드리지 않는다")
    }

    func testTheWindowCanBeClosedAndShownAgain() {
        let (panel, _) = panel(sampleLog())
        XCTAssertEqual(panel.window?.isReleasedWhenClosed, false, "닫아도 풀리지 않는다 — 다시 연다")
        XCTAssertEqual(panel.window?.frameAutosaveName, "", "테스트 창은 자리를 저장하지 않는다")
    }
}

@MainActor
final class FileAssociationTests: XCTestCase {

    func testStatusLineSaysWhichAppOpensMarkdown() {
        XCTAssertEqual(FileAssociation.statusLine(isMadiDefault: true, handlerName: "마디"),
                       String(localized: "Markdown 파일은 현재 마디에서 열립니다."))
        XCTAssertEqual(FileAssociation.statusLine(isMadiDefault: false, handlerName: "Typora"),
                       String(localized: "Markdown 파일은 현재 ‘Typora’에서 열립니다."))
        XCTAssertEqual(FileAssociation.statusLine(isMadiDefault: false, handlerName: nil),
                       String(localized: "Markdown 파일을 여는 기본 앱이 정해져 있지 않습니다."))
    }

    func testTheMarkdownTypeIsTheOneMdFilesHave() throws {
        let type = try XCTUnwrap(FileAssociation.markdownType)
        XCTAssertTrue(type.conforms(to: .text) || type.identifier == "net.daringfireball.markdown", type.identifier)
        XCTAssertEqual(type, UTType(filenameExtension: "md"))
    }
}
