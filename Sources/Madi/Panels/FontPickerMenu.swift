import AppKit

/// 설정 창의 글꼴 고르개(본문 · 제목 · 코드)를 채운다.
///
/// 차례: (제목만) `본문과 같음` → **추천** → 시스템 → **이 Mac의 글꼴**. 수백 개인 설치 목록에서
/// 한국어 글꼴을 찾지 않아도 되게 추천을 위에 둔다(`RecommendedFonts`). 각 이름은 그 글꼴로 그려
/// 고르기 전에 모양이 보인다.
///
/// 항목의 `representedObject`:
/// - `String` — 고를 패밀리. `""`는 시스템, `sameAsBodyTag`는 '본문과 같음'.
/// - `RecommendedFont` — 아직 없는 추천 글꼴('받기…'). 고르면 설정을 바꾸지 않고 그 배포 페이지를 연다.
///
/// 항목의 `title`은 이름 옆의 흐린 설명까지 담는다(`attributedTitle`의 글자) — 이름이 필요하면
/// `representedObject`에서 읽는다.
@MainActor
enum FontPickerMenu {

    static let systemTag = ""
    /// 패밀리 이름은 `@`로 시작하지 않는다.
    static let sameAsBodyTag = "@body"

    struct Options {
        var use: RecommendedFont.Use
        var systemTitle: String
        var includesSameAsBody = false
        /// 이 Mac의 패밀리(코드면 고정폭만).
        var families: [String]
        /// 패밀리가 이 Mac에 있고 이 용도에 쓸 수 있는가(코드면 고정폭).
        var isUsable: (String) -> Bool
    }

    static func fill(_ picker: NSPopUpButton, _ options: Options) {
        picker.removeAllItems()
        guard let menu = picker.menu else { return }

        if options.includesSameAsBody {
            menu.addItem(item(String(localized: "본문과 같음"), tag: sameAsBodyTag))
            menu.addItem(.separator())
        }

        menu.addItem(.sectionHeader(title: String(localized: "추천")))
        var listed = Set<String>()
        for font in RecommendedFonts.list(for: options.use) {
            if let installed = font.installedName(isInstalled: options.isUsable) {
                listed.insert(installed)
                menu.addItem(item(installed, tag: installed, detail: detail(for: font), drawnIn: installed))
            } else if let page = font.downloadPage {
                let entry = item(font.family, tag: nil,
                                 detail: font.style + " · " + String(localized: "받기…"), drawnIn: nil)
                entry.representedObject = font
                entry.toolTip = String(localized: "이 Mac에 없습니다 — 고르면 내려받는 곳(\(page.host ?? ""))을 엽니다")
                menu.addItem(entry)
            }
        }
        menu.addItem(item(options.systemTitle, tag: systemTag))

        let rest = options.families.filter { !listed.contains($0) }
        if !rest.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "이 Mac의 글꼴")))
            for family in rest {
                menu.addItem(item(family, tag: family, drawnIn: family))
            }
        }
    }

    /// 이름 옆의 흐린 설명 — 갈래와 어디에 있는가.
    static func detail(for font: RecommendedFont) -> String {
        switch font.source {
        case .bundled: font.style + " · " + String(localized: "앱에 들어 있음 · 기본")
        case .system: font.style + " · macOS"
        case .download: font.style
        }
    }

    private static func item(_ title: String, tag: String?, detail: String? = nil,
                             drawnIn family: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.representedObject = tag
        let font = family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 13) }
        guard font != nil || detail != nil else { return entry }
        let text = NSMutableAttributedString(string: title, attributes: font.map { [.font: $0] } ?? [:])
        if let detail {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        entry.attributedTitle = text
        return entry
    }
}
