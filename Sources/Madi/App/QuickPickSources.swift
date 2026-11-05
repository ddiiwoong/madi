import AppKit

/// 명령 팔레트(⇧⌘P)가 보여 줄 명령 — **메뉴 바를 훑어** 얻는다.
///
/// 명령 목록을 따로 두지 않는다. 메뉴와 버거 메뉴가 같은 명령 표에서 나오듯, 팔레트도 메뉴에서
/// 나와야 셋이 어긋나지 않는다. 그리고 메뉴는 이미 "지금 쓸 수 있는가"를 판정한다(검색 칸에
/// 캐럿이 있으면 줄 편집이 회색이다) — 그 판정을 그대로 쓴다.
@MainActor
enum CommandPaletteSource {

    /// 쓸 수 있는 메뉴 명령. 하위 메뉴는 펼치고, 구분선·숨긴 항목·꺼진 항목은 뺀다.
    /// 부르기 전에 키 창이 문서 창이어야 판정이 맞다(판정은 키 창의 응답자 연쇄로 한다).
    static func items(from menu: NSMenu, excluding excluded: Set<Selector> = [],
                      path: [String] = []) -> [QuickPickItem] {
        menu.update()
        var out: [QuickPickItem] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                // 메뉴 바의 이름은 하위 메뉴의 제목이다(항목의 제목은 기본값 `NSMenuItem`일 수 있다).
                // 맨 왼쪽 앱 메뉴는 제목이 비어 있다 — 시스템이 앱 이름을 그린다.
                out += items(from: submenu, excluding: excluded,
                             path: path + [submenu.title.isEmpty ? appName : submenu.title])
                continue
            }
            guard let action = item.action, item.isEnabled, !excluded.contains(action) else { continue }
            out.append(QuickPickItem(title: item.title,
                                     detail: path.isEmpty ? nil : path.joined(separator: " ▸ "),
                                     shortcut: shortcut(for: item)) { [weak item] in
                guard let item, let menu = item.menu else { return }
                let index = menu.index(of: item)
                guard index >= 0 else { return }
                menu.performActionForItem(at: index)
            })
        }
        return out
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    /// 메뉴가 그리는 모양의 단축키 — `⌥⌘[`. 보조 키 순서는 macOS 관례(⌃⌥⇧⌘)다.
    static func shortcut(for item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var flags = item.keyEquivalentModifierMask
        // 대문자 키는 ⇧가 숨어 있다(`S` = ⇧S).
        if key.count == 1, let scalar = key.unicodeScalars.first,
           CharacterSet.uppercaseLetters.contains(scalar) { flags.insert(.shift) }
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + display(key)
    }

    private static func display(_ key: String) -> String {
        switch key {
        case "\r": return "↩"
        case "\t": return "⇥"
        case " ": return "Space"
        case "\u{1B}": return "⎋"
        case "\u{8}", "\u{7F}": return "⌫"
        default: return key.uppercased()
        }
    }
}

/// 빠른 열기(⌥⌘O)가 보여 줄 문서 — 열린 문서, 최근 문서, 그리고 지금 폴더의 마크다운 파일.
enum QuickOpenSource {

    struct Candidate: Equatable, Sendable {
        let url: URL
        /// 흐린 둘째 줄 — 폴더 안이면 폴더 기준 위치, 밖이면 `~`로 줄인 위치.
        let detail: String
    }

    /// 훑지 않는 폴더. 숨은 폴더(`.git` 등)와 패키지는 열거기가 이미 건너뛴다.
    static let skippedFolders: Set<String> = ["node_modules", "DerivedData", "Pods", "vendor"]

    /// `root` 아래의 마크다운 파일. **상한이 둘이다** — 찾은 파일 수와 들여다본 항목 수.
    /// 홈 폴더 같은 큰 곳에서 열어도 끝없이 훑지 않는다. 위치 순으로 돌려준다.
    static func markdownFiles(under root: URL, limit: Int = 2000, visitLimit: Int = 20_000) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        var visited = 0
        while let url = walker.nextObject() as? URL {
            visited += 1
            if visited > visitLimit || found.count >= limit { break }
            let isDirectory = (try? url.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
            if isDirectory {
                let name = url.lastPathComponent
                if skippedFolders.contains(name) || name.hasSuffix(".assets") { walker.skipDescendants() }
                continue
            }
            if FileBrowserPanelView.markdownExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// 한 목록으로 — 열린 문서, 최근 문서, 폴더의 파일 순. 같은 파일은 한 번만.
    static func candidates(open: [URL], recent: [URL], folderFiles: [URL], root: URL?,
                           home: String = NSHomeDirectory()) -> [Candidate] {
        var seen = Set<String>()
        var out: [Candidate] = []
        for url in open + recent + folderFiles {
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard seen.insert(key).inserted else { continue }
            out.append(Candidate(url: url, detail: detail(for: url, root: root, home: home)))
        }
        return out
    }

    static func detail(for url: URL, root: URL?, home: String) -> String {
        let folder = url.deletingLastPathComponent()
        if let root {
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path
            let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
            if path == base { return root.lastPathComponent }
            if path.hasPrefix(base + "/") { return root.lastPathComponent + "/" + path.dropFirst(base.count + 1) }
        }
        let path = folder.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }
}
