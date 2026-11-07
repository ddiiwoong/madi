import AppKit
import XCTest

/// 색 테마 — 설정에 남고, 편집기의 바탕·글자·코드·표·막대가 그 색으로 그려지고, 내보낼 때는 흰 종이에
/// 기본 색으로 돌아간다. 색이 읽히는지는 `MarkdownThemeContrastTests`가 본다.
@MainActor
final class ColorThemeTests: XCTestCase {

    // MARK: 저장소

    func testThemeRoundTripsAndResetReturnsToStandard() {
        let defaults = MemoryDefaults()
        let store = PreferenceStore(defaults: defaults)
        XCTAssertEqual(store.current.colorTheme, .standard, "처음에는 기본")
        for theme in EditorPreferences.ColorTheme.allCases {
            var preferences = store.current
            preferences.colorTheme = theme
            store.save(preferences)
            XCTAssertEqual(store.current.colorTheme, theme)
            XCTAssertEqual(defaults.string(forKey: "editor.colorTheme"), theme.rawValue, "raw 문자열로 적는다")
        }
        store.reset()
        XCTAssertEqual(store.current.colorTheme, .standard)
    }

    /// 모르는 값(다음 판이 더한 테마, 손으로 고친 값)은 기본으로 읽는다.
    func testUnknownStoredThemeFallsBackToStandard() {
        let defaults = MemoryDefaults()
        defaults.set("neon", forKey: "editor.colorTheme")
        XCTAssertEqual(PreferenceStore(defaults: defaults).current.colorTheme, .standard)
    }

    /// 여덟 — 많이 쓰는 문서 도구의 모양(Notion · Confluence · GitHub · Obsidian)이 기본 다음에 온다(사용자 —
    /// "노션, 컨플루언스 등 많이 쓰는 디자인으로"). 저장 값(raw)은 차례와 상관없다.
    func testThemesHaveDistinctNamesAndPalettes() {
        let themes = EditorPreferences.ColorTheme.allCases
        XCTAssertEqual(themes.map(\.label),
                       ["기본", "Notion", "Confluence", "GitHub", "Obsidian", "종이", "Solarized", "고대비"])
        XCTAssertEqual(themes.map(\.rawValue),
                       ["standard", "notion", "confluence", "github", "obsidian", "paper", "solarized", "highContrast"],
                       "앞 판이 적어 둔 값(paper · github · solarized · highContrast)은 그대로 읽힌다")
        XCTAssertEqual(Set(themes.map { ObjectIdentifier(ThemePalette.palette(for: $0).background) }).count,
                       themes.count, "테마마다 바탕이 다르다")
    }

    /// 새 테마 셋의 바탕 · 글 · 링크가 그 앱의 색이다(라이트 · 다크). 링크가 글 색인 것은 Notion이 그렇게 그려서다.
    func testNewThemesUseTheirAppsColors() throws {
        func hex(_ color: NSColor, _ name: NSAppearance.Name) throws -> UInt32 {
            var resolved: NSColor?
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB)
            }
            let c = try XCTUnwrap(resolved)
            return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8
                | UInt32((c.blueComponent * 255).rounded())
        }
        let expected: [(EditorPreferences.ColorTheme, background: (UInt32, UInt32), text: (UInt32, UInt32),
                        link: (UInt32, UInt32))] = [
            (.notion, (0xFFFFFF, 0x191919), (0x37352F, 0xD4D4D4), (0x37352F, 0xD4D4D4)),
            (.confluence, (0xFFFFFF, 0x1F1F21), (0x292A2E, 0xCECFD2), (0x1868DB, 0x669DF1)),
            (.obsidian, (0xFFFFFF, 0x1E1E1E), (0x222222, 0xDADADA), (0x6E46DC, 0xA88BFA)),
        ]
        for (theme, background, text, link) in expected {
            let palette = ThemePalette.palette(for: theme)
            for (name, pick) in [(NSAppearance.Name.aqua, 0), (.darkAqua, 1)] {
                func value(_ pair: (UInt32, UInt32)) -> UInt32 { pick == 0 ? pair.0 : pair.1 }
                XCTAssertEqual(try hex(palette.background, name), value(background), "\(theme) 바탕 \(name.rawValue)")
                XCTAssertEqual(try hex(palette.text, name), value(text), "\(theme) 글 \(name.rawValue)")
                XCTAssertEqual(try hex(palette.link, name), value(link), "\(theme) 링크 \(name.rawValue)")
            }
        }
    }

    // MARK: 편집기

    private func editor(_ markdown: String, theme: EditorPreferences.ColorTheme) -> MarkdownEditorView {
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        editor.markdown = markdown
        var preferences = EditorPreferences.standard
        preferences.colorTheme = theme
        editor.apply(preferences)
        editor.textView.setSelectedRange(NSRange(location: (markdown as NSString).length, length: 0))
        return editor
    }

    private let sample = "본문 [링크](https://example.com)\n\n```swift\nlet x = 1 // 주석\n```\n\n> 인용\n\n| 이름 | 값 |\n| --- | --- |\n| 가 | 1 |\n\n끝\n"

    /// 바탕·캐럿·고른 글·본문·링크·코드·인용 막대·표 격자가 모두 그 테마의 색이다.
    func testEditorPaintsEverythingInTheTheme() throws {
        let editor = editor(sample, theme: .paper)
        let palette = ThemePalette.palette(for: .paper)
        let textView = editor.textView
        XCTAssertTrue(textView.backgroundColor === palette.background)
        XCTAssertTrue(textView.insertionPointColor === palette.text)
        XCTAssertTrue(textView.selectedTextAttributes[.backgroundColor] as? NSColor === palette.selection)
        XCTAssertTrue(textView.codeBlockColor === palette.codeBackground)
        XCTAssertTrue(textView.quoteBarColor(nil) === palette.quoteBar)

        let storage = try XCTUnwrap(textView.textStorage)
        let text = storage.string as NSString
        func color(at needle: String) -> NSColor? {
            storage.attribute(.foregroundColor, at: text.range(of: needle).location, effectiveRange: nil) as? NSColor
        }
        XCTAssertTrue(color(at: "본문") === palette.text)
        XCTAssertTrue(color(at: "링크") === palette.link)
        XCTAssertTrue(color(at: "let") === palette.keyword)
        XCTAssertTrue(color(at: "// 주석") === palette.comment)
        XCTAssertTrue(color(at: "인용") === palette.quote)

        let header = text.lineRange(for: text.range(of: "| 이름"))
        let grid = try XCTUnwrap(editor.drawnTableGrid(headerLine: NSRange(location: header.location, length: header.length - 1)))
        let cell = grid.rows[1].cells[0]
        XCTAssertTrue(cell.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor === palette.text,
                      "격자 칸의 글도 테마 색이다")
    }

    /// 테마를 바꾸면 다시 칠한다 — 기억해 둔 표 격자도 새 색으로 짓는다.
    func testSwitchingThemesRepaints() throws {
        let editor = editor(sample, theme: .github)
        var preferences = EditorPreferences.standard
        preferences.colorTheme = .highContrast
        editor.apply(preferences)
        let palette = ThemePalette.palette(for: .highContrast)
        XCTAssertTrue(editor.textView.backgroundColor === palette.background)
        let storage = try XCTUnwrap(editor.textView.textStorage)
        XCTAssertTrue(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor === palette.text)
        let text = storage.string as NSString
        let header = text.lineRange(for: text.range(of: "| 이름"))
        let grid = try XCTUnwrap(editor.drawnTableGrid(headerLine: NSRange(location: header.location, length: header.length - 1)))
        XCTAssertTrue(grid.rows[1].cells[0].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                      === palette.text, "옛 테마의 격자가 남지 않는다")
    }

    /// `기본` 테마는 시스템이 고른 글 바탕(강조색)을 쓴다.
    func testStandardKeepsTheSystemSelectionColor() {
        let editor = editor("글\n", theme: .standard)
        XCTAssertEqual(editor.textView.selectedTextAttributes[.backgroundColor] as? NSColor,
                       NSColor.selectedTextBackgroundColor)
        XCTAssertTrue(editor.textView.backgroundColor === NSColor.textBackgroundColor)
    }

    /// 내보내는 동안은 흰 종이에 기본 색 — 텍스트 뷰를 라이트 외관으로 두고 기본 색으로 칠한다. 끝나면
    /// 고른 테마와 시스템 외관으로 돌아간다.
    func testOutputSwitchesToStandardColorsOnLightPaper() throws {
        let editor = editor(sample, theme: .solarized)
        let standard = ThemePalette.palette(for: .standard)
        let solarized = ThemePalette.palette(for: .solarized)
        let storage = try XCTUnwrap(editor.textView.textStorage)

        editor.isRenderingForOutput = true
        XCTAssertEqual(editor.textView.appearance?.name, .aqua)
        XCTAssertTrue(editor.textView.backgroundColor === standard.background)
        XCTAssertTrue(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor === standard.text)

        editor.isRenderingForOutput = false
        XCTAssertNil(editor.textView.appearance, "외관은 다시 창을 따른다")
        XCTAssertTrue(editor.textView.backgroundColor === solarized.background)
        XCTAssertTrue(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor === solarized.text)
    }

    // MARK: 옮겨 간 장식

    /// 그려 둔 장식(코드 블록 바탕·인용 막대·표 격자)의 자리를 기억하고, 레이아웃이 옮기면 새 자리로 고친다.
    /// 실측: 문서를 연 직후 코드 블록 바탕이 450pt 위에 띠로 남았다(진한 테마에서 보였다).
    func testDecorationsFollowALayoutChange() throws {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 640, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 640, height: 900))
        window.contentView = editor
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        editor.markdown = sample
        var preferences = EditorPreferences.standard
        preferences.colorTheme = .github
        editor.apply(preferences)
        editor.textView.setSelectedRange(NSRange(location: (sample as NSString).length, length: 0))
        let textView = editor.textView
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        // 그 자리에서 그린다(`display()`는 층이 있는 뷰에서 바로 그리지 않는다).
        let visible = textView.visibleRect
        let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: visible))
        textView.cacheDisplay(in: visible, to: rep)
        let before = textView.drawnDecorations
        XCTAssertEqual(Set(before.keys.map(\.level)), [0, 1, DecoratedTextView.Decoration.image],
                       "코드 블록·인용 막대·표 격자를 그렸다")

        // 글자는 그대로 두고 자리만 옮긴다(위에 40pt를 비운다) — 범위가 같아 다시 칠하지 않는 길이다.
        textView.setInsets(textView.baseInsets, topAccessory: 40)
        textView.revalidateDecorations()
        for (key, old) in before {
            let new = try XCTUnwrap(textView.drawnDecorations[key])
            XCTAssertEqual(new.minY - old.minY, 40, accuracy: 0.5, "\(key)가 새 자리로 옮겨 기억됐다")
        }
    }

    // MARK: 견본

    /// 견본은 그 테마의 바탕을 그린다 — 다크 외관에서는 다크 벌.
    func testSwatchDrawsTheThemeBackground() throws {
        func corner(_ theme: EditorPreferences.ColorTheme, _ name: NSAppearance.Name) throws -> NSColor {
            let image = ThemePalette.swatch(for: theme, size: NSSize(width: 30, height: 18))
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 18,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0))
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: 30, height: 18))
                NSGraphicsContext.restoreGraphicsState()
            }
            return try XCTUnwrap(rep.colorAt(x: 26, y: 9)?.usingColorSpace(.sRGB))
        }
        let paperLight = try corner(.paper, .aqua)
        let paperDark = try corner(.paper, .darkAqua)
        XCTAssertGreaterThan(paperLight.brightnessComponent, 0.85, "종이 라이트는 미색")
        XCTAssertLessThan(paperDark.brightnessComponent, 0.3, "종이 다크는 어둡다")
        XCTAssertGreaterThan(paperLight.redComponent, paperLight.blueComponent + 0.03, "따뜻한 색")
    }
}
