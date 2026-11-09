import AppKit

/// The app's commands, defined once. `mainMenu()` builds the macOS menu bar from
/// this table. The command palette (⇧⌘P) and the toolbar's burger menu both READ
/// that menu bar, so none of the three can drift apart.
///
/// 버거 메뉴는 2026-11-07에 한 번 뺐다가 같은 날 다시 넣었다(사용자 — "메뉴 바와 내용이 같았으면, 설정도").
/// 뺀 판은 명령 표에서 열일곱을 따로 골라 만들어 편집 · 테마 · 글꼴이 없고 이름도 조금 달랐다. 다시 넣은 판은
/// 메뉴 바를 그대로 옮겨 싣는다(`burgerItems(mirroring:)`).
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

    /// One command: a title, what it does, and its key equivalent. Menu bar items
    /// have no target — they route through the responder chain (text view →
    /// window controller → document).
    private struct Command {
        let title: String
        let action: Selector
        let key: String
        let modifiers: NSEvent.ModifierFlags

        init(_ title: String, _ action: Selector, _ key: String = "",
             _ modifiers: NSEvent.ModifierFlags = .command) {
            self.title = title
            self.action = action
            self.key = key
            self.modifiers = modifiers
        }
    }

    private static var fileCommands: [Command?] {
        [
            Command(String(localized: "새로 만들기"), #selector(NSDocumentController.newDocument(_:)), "n"),
            Command(String(localized: "문서 열기…"), #selector(NSDocumentController.openDocument(_:)), "o"),
            Command(String(localized: "빠른 열기…"), #selector(DocumentWindowController.showQuickOpenAction(_:)), "o",
                    [.command, .option]),
            Command(String(localized: "파일 브라우저"), #selector(DocumentWindowController.showBrowserAction(_:)), "f",
                    [.command, .shift]),
            Command(String(localized: "최근 문서"), #selector(DocumentWindowController.showRecentAction(_:)), "r",
                    [.command, .shift]),
            nil,
            Command(String(localized: "저장"), #selector(NSDocument.save(_:)), "s"),
            Command(String(localized: "다른 이름으로 저장…"), #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            Command(String(localized: "되돌리기"), #selector(NSDocument.revertToSaved(_:))),
            nil,
            Command(String(localized: "이미지 포함 내보내기…"),
                    #selector(DocumentWindowController.exportWithImagesAction(_:)),
                    "", .command),
            Command(String(localized: "PDF 내보내기…"), #selector(DocumentWindowController.exportPDFAction(_:)),
                    "", .command),
            Command(String(localized: "프린트하기…"), #selector(DocumentWindowController.printDocumentAction(_:)), "p",
                    .command),
            nil,
            Command(String(localized: "닫기"), #selector(NSWindow.performClose(_:)), "w"),
        ]
    }

    private static var editCommands: [Command?] {
        [
            Command(String(localized: "실행 취소"), Selector(("undo:")), "z"),
            Command(String(localized: "실행 복귀"), Selector(("redo:")), "z", [.command, .shift]),
            nil,
            Command(String(localized: "잘라내기"), #selector(NSText.cut(_:)), "x"),
            Command(String(localized: "복사"), #selector(NSText.copy(_:)), "c"),
            Command(String(localized: "붙여넣기"), #selector(NSText.paste(_:)), "v"),
            Command(String(localized: "모두 선택"), #selector(NSText.selectAll(_:)), "a"),
            nil,
            Command(String(localized: "검색"), #selector(DocumentWindowController.focusSearchAction(_:)), "f",
                    .command),
            Command(String(localized: "다음 찾기"), #selector(DocumentWindowController.findNext(_:)), "g",
                    .command),
            Command(String(localized: "이전 찾기"), #selector(DocumentWindowController.findPrevious(_:)), "g",
                    [.command, .shift]),
            nil,
            // 줄 편집. 대상 없이 보내 응답자 연쇄로 편집기(`MarkdownEditorView`)에 닿는다 — 검색
            // 칸에 캐럿이 있으면 닿지 않아 회색이 된다. 옮기기는 Xcode의 단축키, 지우기는 VS Code의 것.
            Command(String(localized: "줄 위로 옮기기"), #selector(MarkdownEditorView.moveLinesUpAction(_:)), "[",
                    [.command, .option]),
            Command(String(localized: "줄 아래로 옮기기"), #selector(MarkdownEditorView.moveLinesDownAction(_:)), "]",
                    [.command, .option]),
            Command(String(localized: "줄 복제"), #selector(MarkdownEditorView.duplicateLinesAction(_:)), "d"),
            Command(String(localized: "줄 지우기"), #selector(MarkdownEditorView.deleteLinesAction(_:)), "k",
                    [.command, .shift]),
        ]
    }

    /// 서식 — 마크다운 원문에 표식을 넣고 뺀다(`MarkdownFormatting`). 다시 누르면 풀린다. 맨 위의 `제목 ▸`은
    /// `addHeadingMenu`가 넣는다.
    ///
    /// 단축키는 널리 쓰는 것을 따랐다: 굵게 `⌘B` · 기울임 `⌘I` · 링크 `⌘K`(거의 모든 편집기), 취소선 `⇧⌘X` ·
    /// 번호 `⇧⌘7` · 글머리 `⇧⌘8` · 할 일 `⇧⌘9`(Google 문서), 인라인 코드 `⇧⌘C`(Slack), 인용 `⌥⌘Q` · 코드 블록
    /// `⌥⌘C`(Typora). 인라인 코드에 흔히 쓰는 `⌘E`는 마크다운 원본 보기가 쓴다. Steno 도움말에는 서식 메뉴가
    /// 적혀 있지 않아 따라 할 표가 없었다.
    private static var formatCommands: [Command?] {
        [
            nil,
            Command(String(localized: "굵게"), #selector(MarkdownEditorView.formatBoldAction(_:)), "b"),
            Command(String(localized: "기울임"), #selector(MarkdownEditorView.formatItalicAction(_:)), "i"),
            Command(String(localized: "취소선"), #selector(MarkdownEditorView.formatStrikethroughAction(_:)), "x",
                    [.command, .shift]),
            Command(String(localized: "인라인 코드"), #selector(MarkdownEditorView.formatInlineCodeAction(_:)), "c",
                    [.command, .shift]),
            nil,
            Command(String(localized: "링크"), #selector(MarkdownEditorView.formatLinkAction(_:)), "k"),
            nil,
            Command(String(localized: "글머리 목록"), #selector(MarkdownEditorView.formatBulletListAction(_:)), "8",
                    [.command, .shift]),
            Command(String(localized: "번호 목록"), #selector(MarkdownEditorView.formatNumberedListAction(_:)), "7",
                    [.command, .shift]),
            Command(String(localized: "할 일 목록"), #selector(MarkdownEditorView.formatTaskListAction(_:)), "9",
                    [.command, .shift]),
            Command(String(localized: "인용"), #selector(MarkdownEditorView.formatQuoteAction(_:)), "q",
                    [.command, .option]),
            nil,
            Command(String(localized: "코드 블록"), #selector(MarkdownEditorView.formatCodeBlockAction(_:)), "c",
                    [.command, .option]),
            Command(String(localized: "표"), #selector(MarkdownEditorView.formatTableAction(_:))),
            Command(String(localized: "구분선"), #selector(MarkdownEditorView.formatRuleAction(_:))),
        ]
    }

    private static var viewCommands: [Command?] {
        [
            Command(String(localized: "명령 팔레트…"), #selector(DocumentWindowController.showCommandPaletteAction(_:)),
                    "p", [.command, .shift]),
            nil,
            Command(String(localized: "목차"), #selector(DocumentWindowController.showOutlineAction(_:)), "o",
                    [.command, .shift]),
            Command(String(localized: "마크다운 원본 보기"), #selector(DocumentWindowController.toggleCodeViewAction(_:)), "e",
                    .command),
            // 설계 단계 1. 기본 편집기를 갈지 않고 평가할 수 있는 두 번째 창이다.
            Command(String(localized: "블록 편집기 (실험)"),
                    #selector(DocumentWindowController.showBlockEditor(_:)), "b",
                    [.command, .option]),
            nil,
            Command(String(localized: "글꼴…"), #selector(DocumentWindowController.showFontSettings(_:)), "",
                    .command),
            Command(String(localized: "글자 크게"), #selector(DocumentWindowController.makeTextLargerAction(_:)), "=",
                    .command),
            Command(String(localized: "글자 작게"), #selector(DocumentWindowController.makeTextSmallerAction(_:)), "-",
                    .command),
            Command(String(localized: "글자 기본 크기"),
                    #selector(DocumentWindowController.makeTextStandardSizeAction(_:)), "0",
                    .command),
            nil,
            Command(String(localized: "전체 화면 시작"), #selector(NSWindow.toggleFullScreen(_:))),
        ]
    }

    private static var toolCommands: [Command?] {
        [
            // 선택이 있으면 그 자리에서, 없으면 문서 전체를 새 문서로.
            Command(String(localized: "Apple 번역"), #selector(DocumentWindowController.translateAction(_:)), "t",
                    [.command, .shift]),
            // 짐작이 틀렸거나 한국어를 다른 언어로 내보낼 때.
            Command(String(localized: "번역 언어 선택…"),
                    #selector(DocumentWindowController.chooseTranslationLanguageAction(_:)),
                    "t", [.command, .shift, .option]),
            // 번역본을 자기 창으로 열어 원문 창 옆에 붙이고, 두 창의 스크롤을 블록으로 맞춘다.
            Command(String(localized: "원문·번역 나란히 보기"),
                    #selector(DocumentWindowController.toggleSideBySideAction(_:)),
                    "t", [.command, .control]),
            nil,
            Command(String(localized: "기록 보기"), #selector(DocumentWindowController.showActivityLog(_:)), "l",
                    [.command, .shift]),
        ]
    }

    // MARK: Menu bar

    static func mainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "마디 정보"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        // 응답자 연쇄가 아니라 컨트롤러에 바로 보낸다 — 창이 하나도 없어도 확인할 수 있어야 한다.
        let update = appMenu.addItem(withTitle: String(localized: "업데이트 확인…"),
                                     action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = UpdateController.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "설정…"),
                        action: #selector(DocumentWindowController.showSettings(_:)),
                        keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "마디 가리기"), action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: String(localized: "기타 가리기"),
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "모두 보기"),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "마디 종료"), action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        main.addItem(submenu(String(localized: "파일"), fileCommands, insertRecentAfter: String(localized: "문서 열기…")))
        main.addItem(submenu(String(localized: "편집"), editCommands))
        let format = submenu(String(localized: "서식"), formatCommands)
        if let menu = format.submenu { addHeadingMenu(to: menu) }
        main.addItem(format)
        let view = submenu(String(localized: "보기"), viewCommands)
        if let menu = view.submenu {
            addHiddenPlusShortcut(to: menu)
            addThemeMenu(to: menu)
        }
        main.addItem(view)
        main.addItem(submenu(String(localized: "도구"), toolCommands))

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "윈도우"))
        windowMenu.addItem(withTitle: String(localized: "최소화"), action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "확대/축소"), action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: String(localized: "모두 앞으로 가져오기"),
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    /// `⌘+`도 글자를 키우게 한다. 단축키 표시는 `⌘=` 하나지만, 미국 자판에서 `+`는 ⇧를 함께
    /// 눌러야 나오고 `⌘+`로 누르는 사람도 많다. 키 대조는 글자로 하므로 `=` 항목은 `⌘⇧=`에
    /// 답하지 않는다. 숨긴 항목을 하나 두어 받는다(Safari가 같은 방식이다).
    private static func addHiddenPlusShortcut(to menu: NSMenu) {
        let action = #selector(DocumentWindowController.makeTextLargerAction(_:))
        guard let index = menu.items.firstIndex(where: { $0.action == action }) else { return }
        let plus = NSMenuItem(title: menu.items[index].title, action: action, keyEquivalent: "+")
        plus.keyEquivalentModifierMask = [.command]
        plus.isHidden = true
        plus.allowsKeyEquivalentWhenHidden = true
        menu.insertItem(plus, at: index + 1)
    }

    /// 보기 ▸ 테마 — 다섯 테마를 고르는 하위 메뉴. `글꼴…` 바로 앞에 둔다. 항목마다 색 견본을 붙이고,
    /// 지금 테마에 체크를 단다(`markColorTheme`). 명령 팔레트도 이 메뉴를 읽어 `보기 › 테마 › 종이`로 보인다.
    private static func addThemeMenu(to menu: NSMenu) {
        let fonts = #selector(DocumentWindowController.showFontSettings(_:))
        let index = menu.items.firstIndex { $0.action == fonts } ?? menu.items.count
        let title = String(localized: "테마")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let themes = NSMenu(title: title)
        for theme in EditorPreferences.ColorTheme.allCases {
            let entry = themes.addItem(withTitle: theme.label,
                                       action: #selector(DocumentWindowController.chooseColorThemeAction(_:)),
                                       keyEquivalent: "")
            entry.representedObject = theme.rawValue
            entry.image = ThemePalette.swatch(for: theme)
        }
        item.submenu = themes
        menu.insertItem(item, at: index)
    }

    /// 서식 ▸ 제목 — 본문(`⌥⌘0`)과 제목 1~6(`⌘1`~`⌘6`). 항목의 `tag`가 단계다. `⌘0`은 글자 기본 크기가 쓰고
    /// 있어 본문은 `⌥⌘0`이다. 서식 메뉴 맨 위에 둔다.
    private static func addHeadingMenu(to menu: NSMenu) {
        let title = String(localized: "제목")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let headings = NSMenu(title: title)
        let action = #selector(MarkdownEditorView.formatHeadingAction(_:))
        let body = headings.addItem(withTitle: String(localized: "본문"), action: action, keyEquivalent: "0")
        body.keyEquivalentModifierMask = [.command, .option]
        body.tag = 0
        for level in 1...6 {
            let entry = headings.addItem(withTitle: String(localized: "제목 \(level)"), action: action,
                                         keyEquivalent: "\(level)")
            entry.keyEquivalentModifierMask = [.command]
            entry.tag = level
        }
        item.submenu = headings
        menu.insertItem(item, at: 0)
    }

    /// 테마 메뉴의 체크 — 지금 테마 하나에만. 앱이 설정이 바뀔 때마다 부른다.
    ///
    /// `validateMenuItem`으로 하지 않는 까닭은 원본 보기의 체크와 같다(`DocumentWindowController.mark`).
    static func markColorTheme(_ theme: EditorPreferences.ColorTheme, in menu: NSMenu) {
        let action = #selector(DocumentWindowController.chooseColorThemeAction(_:))
        for item in menu.items {
            if item.action == action {
                item.state = (item.representedObject as? String) == theme.rawValue ? .on : .off
            }
            if let submenu = item.submenu { markColorTheme(theme, in: submenu) }
        }
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
                let recentItem = menu.addItem(withTitle: String(localized: "최근 문서 열기"), action: nil, keyEquivalent: "")
                let recentMenu = NSMenu(title: String(localized: "최근 문서 열기"))
                recentMenu.addItem(withTitle: String(localized: "메뉴 지우기"),
                                   action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                                   keyEquivalent: "")
                recentItem.submenu = recentMenu
            }
        }
        item.submenu = menu
        return item
    }

    // MARK: Burger

    /// 버거 메뉴 맨 위에 바로 꺼내 두는 **주요 명령** 하나.
    enum BurgerPick {
        /// 메뉴 바에서 이 동작의 항목.
        case command(Selector)
        /// 이 동작의 항목들을 담은 하위 메뉴(보기 ▸ 테마처럼, 부모 항목에는 동작이 없다).
        case submenuOf(Selector)
        case separator
    }

    /// 버거 메뉴 맨 위의 주요 명령과 차례(사용자 — "주요 메뉴는 최상위로"). 여기에는 **무엇을, 어떤 차례로**만
    /// 적는다. 이름 · 단축키 · 켜짐 · 체크는 메뉴 바의 같은 항목을 복사해 받으므로 메뉴 바와 어긋날 수 없다.
    ///
    /// 도구 막대에 단추가 있는 것(사이드바 셋 · 원본 보기 · 나란히 번역 · 검색)은 넣지 않는다 — 단추 바로 옆에서
    /// 같은 것을 또 고르게 할 까닭이 없다. 나머지는 모두 아래의 메뉴 바 전체(파일 ▸ …)에 있다.
    static var burgerPicks: [BurgerPick] {
        [
            .command(#selector(NSDocumentController.newDocument(_:))),
            .command(#selector(NSDocumentController.openDocument(_:))),
            .command(#selector(DocumentWindowController.showQuickOpenAction(_:))),
            .separator,
            .command(#selector(NSDocument.save(_:))),
            .command(#selector(NSDocument.saveAs(_:))),
            .separator,
            .command(#selector(DocumentWindowController.exportPDFAction(_:))),
            .command(#selector(DocumentWindowController.exportWithImagesAction(_:))),
            .command(#selector(DocumentWindowController.printDocumentAction(_:))),
            .separator,
            .submenuOf(#selector(DocumentWindowController.chooseColorThemeAction(_:))),
            .command(#selector(DocumentWindowController.showFontSettings(_:))),
            .separator,
            .command(#selector(DocumentWindowController.translateAction(_:))),
            .command(#selector(DocumentWindowController.chooseTranslationLanguageAction(_:))),
            .separator,
            .command(#selector(DocumentWindowController.showCommandPaletteAction(_:))),
        ]
    }

    /// 도구 막대 버거 메뉴의 항목 — 위에서부터 **주요 명령**(`burgerPicks`), **메뉴 바 전체**(파일 · 편집 · 보기 ·
    /// 도구 · 윈도우를 같은 이름의 하위 메뉴로), 앱 메뉴의 `설정…`.
    ///
    /// 따로 표를 두지 않고 **그 순간의 메뉴 바를 복사**한다(`NSMenu.copy` · `NSMenuItem.copy`는 하위 메뉴까지 새로
    /// 만든다). 그래서 체크 표시(원본 보기 · 테마)와 최근 문서 · 창 목록까지 메뉴 바와 같다. 항목은 메뉴 바처럼
    /// 대상 없이 응답자 연쇄로 가므로 켜지고 꺼지는 것도 같다. 메뉴 바에서 찾지 못한 주요 명령은 건너뛴다.
    ///
    /// 앱 메뉴의 나머지(마디 정보 · 가리기 · 종료)는 싣지 않는다 — 도구 막대에서 고를 까닭이 없는 시스템 항목이다.
    static func burgerItems(mirroring main: NSMenu) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        func separate() {
            if let last = items.last, !last.isSeparatorItem { items.append(.separator()) }
        }
        for pick in burgerPicks {
            switch pick {
            case .separator:
                separate()
            case .command(let action):
                if let source = item(for: action, in: main), let copy = source.copy() as? NSMenuItem {
                    items.append(copy)
                }
            case .submenuOf(let action):
                if let entry = item(for: action, in: main), let menu = entry.menu,
                   let source = menu.supermenu?.items.first(where: { $0.submenu === menu }),
                   let copy = source.copy() as? NSMenuItem {
                    items.append(copy)
                }
            }
        }
        separate()
        items.append(.sectionHeader(title: String(localized: "모든 메뉴")))
        // 첫 칸은 앱 메뉴다(macOS가 앱 이름을 제목으로 단다).
        for top in main.items.dropFirst() {
            guard let source = top.submenu, let copy = source.copy() as? NSMenu else { continue }
            let item = NSMenuItem(title: source.title, action: nil, keyEquivalent: "")
            item.submenu = copy
            items.append(item)
        }
        let settings = #selector(DocumentWindowController.showSettings(_:))
        if let source = main.items.first?.submenu?.items.first(where: { $0.action == settings }),
           let copy = source.copy() as? NSMenuItem {
            items.append(.separator())
            items.append(copy)
        }
        return items
    }

    /// 메뉴 바에서 이 동작의 항목 — 메뉴 바 차례로 처음 것. 숨긴 항목(`⌘+`를 받는 글자 크게)은 건너뛴다.
    static func item(for action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items where !item.isHidden {
            if item.action == action { return item }
            if let submenu = item.submenu, let found = self.item(for: action, in: submenu) { return found }
        }
        return nil
    }
}

/// 버거 메뉴를 **열 때마다** 메뉴 바에서 새로 채우고(`AppMenu.burgerItems`), 닫으면 비운다.
///
/// 단축키는 메뉴 바만 받는다. 복사본에도 같은 단축키가 적혀 있어(보여 주려고 둔다) 버거 메뉴가 받기 시작하면
/// 같은 키가 두 메뉴에 걸린다. 그래서 단축키를 묻는 물음에 늘 "없다"고 답하고(`menuHasKeyEquivalent`), 열려
/// 있지 않은 동안에는 항목을 두지 않는다.
@MainActor
final class BurgerMenuFeeder: NSObject, NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let main = NSApp.mainMenu else { return }
        // 도구 막대의 메뉴 단추(`NSMenuToolbarItem`)는 끌어내림 단추라, 첫 항목을 단추 몫으로 쓰고 메뉴에는 보이지
        // 않는다(실측: 맨 앞의 '파일'이 빠지고 편집부터 나왔다). 그 자리에 빈 항목을 둔다. 숨겨 두는 까닭: 창이 좁아
        // 버거가 도구 막대의 펼침(») 메뉴로 들어가면 **같은 메뉴**가 하위 메뉴로 그대로 나오는데(실측:
        // `menuFormRepresentation.submenu`가 이 메뉴다), 그때는 첫 항목이 빈 줄로 보인다.
        let placeholder = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        placeholder.isHidden = true
        menu.addItem(placeholder)
        for item in AppMenu.burgerItems(mirroring: main) {
            menu.addItem(item)
        }
    }

    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent,
                              target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    func menuDidClose(_ menu: NSMenu) {
        // 고른 항목의 동작은 메뉴가 닫힌 **뒤에** 간다. 바로 비우면 그 항목이 메뉴에서 빠진 채 가므로 한 바퀴 미룬다.
        DispatchQueue.main.async { menu.removeAllItems() }
    }
}
