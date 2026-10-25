import AppKit

/// The app's commands, defined once. `mainMenu()` builds the macOS menu bar and
/// `burgerMenu()` builds the toolbar's popup from the SAME table, so the two can
/// never drift apart.
///
/// Shortcuts match Mark.app's where they do not fight a macOS convention:
/// 파일 브라우저 ⌘⇧F, 최근 문서 ⌘⇧R, 목차 ⌘⇧O, 마크다운 원본 보기 ⌘E, 설정 ⌘,.
/// (Mark은 이 명령을 "코드 보기"라 부르지만, 무엇과 무엇을 오가는지 이름이 말하는
/// 쪽이 낫다 — 켜면 원본, 끄면 마크다운 문법으로 그린 문서다.)
/// One deliberate difference: ⌘N makes a new DOCUMENT here rather than a new
/// window, because this is an NSDocument app and ⌘N means new document
/// everywhere else on the system (a new document opens in its own window, so
/// the visible result is the same).
@MainActor
enum AppMenu {

    /// One command: a title, what it does, and its key equivalent.
    private struct Command {
        let title: String
        let action: Selector
        let key: String
        let modifiers: NSEvent.ModifierFlags
        /// nil routes through the responder chain (document / text view).
        let needsWindowTarget: Bool

        init(_ title: String, _ action: Selector, _ key: String = "",
             _ modifiers: NSEvent.ModifierFlags = .command, windowTarget: Bool = false) {
            self.title = title
            self.action = action
            self.key = key
            self.modifiers = modifiers
            self.needsWindowTarget = windowTarget
        }
    }

    private static var fileCommands: [Command?] {
        [
            Command("새로 만들기", #selector(NSDocumentController.newDocument(_:)), "n"),
            Command("문서 열기…", #selector(NSDocumentController.openDocument(_:)), "o"),
            Command("파일 브라우저", #selector(DocumentWindowController.showBrowserAction(_:)), "f",
                    [.command, .shift], windowTarget: true),
            Command("최근 문서", #selector(DocumentWindowController.showRecentAction(_:)), "r",
                    [.command, .shift], windowTarget: true),
            nil,
            Command("저장", #selector(NSDocument.save(_:)), "s"),
            Command("다른 이름으로 저장…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            Command("되돌리기", #selector(NSDocument.revertToSaved(_:))),
            nil,
            Command("이미지 포함 내보내기…",
                    #selector(DocumentWindowController.exportWithImagesAction(_:)),
                    "", .command, windowTarget: true),
            Command("PDF 내보내기…", #selector(DocumentWindowController.exportPDFAction(_:)),
                    "", .command, windowTarget: true),
            Command("프린트하기…", #selector(DocumentWindowController.printDocumentAction(_:)), "p",
                    .command, windowTarget: true),
            nil,
            Command("닫기", #selector(NSWindow.performClose(_:)), "w"),
        ]
    }

    private static var editCommands: [Command?] {
        [
            Command("실행 취소", Selector(("undo:")), "z"),
            Command("실행 복귀", Selector(("redo:")), "z", [.command, .shift]),
            nil,
            Command("잘라내기", #selector(NSText.cut(_:)), "x"),
            Command("복사", #selector(NSText.copy(_:)), "c"),
            Command("붙여넣기", #selector(NSText.paste(_:)), "v"),
            Command("모두 선택", #selector(NSText.selectAll(_:)), "a"),
            nil,
            Command("검색", #selector(DocumentWindowController.focusSearchAction(_:)), "f",
                    .command, windowTarget: true),
            Command("다음 찾기", #selector(DocumentWindowController.findNext(_:)), "g",
                    .command, windowTarget: true),
            Command("이전 찾기", #selector(DocumentWindowController.findPrevious(_:)), "g",
                    [.command, .shift], windowTarget: true),
        ]
    }

    private static var viewCommands: [Command?] {
        [
            Command("목차", #selector(DocumentWindowController.showOutlineAction(_:)), "o",
                    [.command, .shift], windowTarget: true),
            Command("마크다운 원본 보기", #selector(DocumentWindowController.toggleCodeViewAction(_:)), "e",
                    .command, windowTarget: true),
            // 설계 단계 1. 기본 편집기를 갈지 않고 평가할 수 있는 두 번째 창이다.
            Command("블록 편집기 (실험)",
                    #selector(DocumentWindowController.showBlockEditor(_:)), "b",
                    [.command, .option], windowTarget: true),
            nil,
            Command("전체 화면 시작", #selector(NSWindow.toggleFullScreen(_:))),
        ]
    }

    private static var toolCommands: [Command?] {
        [
            // 선택이 있으면 그 자리에서, 없으면 문서 전체를 새 문서로.
            Command("Apple 번역", #selector(DocumentWindowController.translateAction(_:)), "t",
                    [.command, .shift], windowTarget: true),
            nil,
            Command("기록 보기", #selector(DocumentWindowController.showActivityLog(_:)), "l",
                    [.command, .shift], windowTarget: true),
        ]
    }

    // MARK: Menu bar

    static func mainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "마디 정보",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "설정…",
                        action: #selector(DocumentWindowController.showSettings(_:)),
                        keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "마디 가리기", action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "기타 가리기",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "모두 보기",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "마디 종료", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        main.addItem(submenu("파일", fileCommands, insertRecentAfter: "문서 열기…"))
        main.addItem(submenu("편집", editCommands))
        main.addItem(submenu("보기", viewCommands))
        main.addItem(submenu("도구", toolCommands))

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "확대/축소", action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "모두 앞으로 가져오기",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    private static func submenu(_ title: String, _ commands: [Command?],
                                insertRecentAfter anchor: String? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        for command in commands {
            guard let command else {
                menu.addItem(.separator())
                continue
            }
            let entry = menu.addItem(withTitle: command.title, action: command.action,
                                     keyEquivalent: command.key)
            entry.keyEquivalentModifierMask = command.modifiers
            if command.title == anchor {
                // AppKit maintains this submenu itself.
                let recentItem = menu.addItem(withTitle: "최근 문서 열기", action: nil, keyEquivalent: "")
                let recentMenu = NSMenu(title: "최근 문서 열기")
                recentMenu.addItem(withTitle: "메뉴 지우기",
                                   action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                                   keyEquivalent: "")
                recentItem.submenu = recentMenu
            }
        }
        item.submenu = menu
        return item
    }

    // MARK: Burger

    /// The same commands flattened into the toolbar popup, in Mark.app's order.
    static func burgerMenu(target: DocumentWindowController) -> NSMenu {
        let menu = NSMenu()
        let ordered: [Command?] = [
            Command("새로 만들기", #selector(NSDocumentController.newDocument(_:)), "n"),
            Command("문서 열기", #selector(NSDocumentController.openDocument(_:)), "o"),
            Command("파일 브라우저", #selector(DocumentWindowController.showBrowserAction(_:)), "f",
                    [.command, .shift], windowTarget: true),
            Command("최근 문서", #selector(DocumentWindowController.showRecentAction(_:)), "r",
                    [.command, .shift], windowTarget: true),
            nil,
            Command("저장", #selector(NSDocument.save(_:)), "s"),
            Command("다른 이름으로 저장", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            nil,
            Command("목차", #selector(DocumentWindowController.showOutlineAction(_:)), "o",
                    [.command, .shift], windowTarget: true),
            Command("마크다운 원본 보기", #selector(DocumentWindowController.toggleCodeViewAction(_:)), "e",
                    .command, windowTarget: true),
            Command("블록 편집기 (실험)",
                    #selector(DocumentWindowController.showBlockEditor(_:)), "b",
                    [.command, .option], windowTarget: true),
            nil,
            Command("Apple 번역", #selector(DocumentWindowController.translateAction(_:)), "t",
                    [.command, .shift], windowTarget: true),
            Command("기록 보기", #selector(DocumentWindowController.showActivityLog(_:)), "l",
                    [.command, .shift], windowTarget: true),
            nil,
            Command("이미지 포함 내보내기",
                    #selector(DocumentWindowController.exportWithImagesAction(_:)),
                    "", .command, windowTarget: true),
            Command("PDF 내보내기", #selector(DocumentWindowController.exportPDFAction(_:)),
                    "", .command, windowTarget: true),
            Command("프린트하기", #selector(DocumentWindowController.printDocumentAction(_:)), "p",
                    .command, windowTarget: true),
            nil,
            Command("닫기", #selector(NSWindow.performClose(_:)), "w"),
        ]

        for command in ordered {
            guard let command else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: command.title, action: command.action,
                                  keyEquivalent: command.key)
            item.keyEquivalentModifierMask = command.modifiers
            // A popup menu has no responder chain of its own, so a window
            // command needs its target set explicitly or it renders greyed out.
            item.target = command.needsWindowTarget ? target : nil
            menu.addItem(item)
        }
        return menu
    }
}
