import AppKit
import XCTest

/// 본문·코드 글꼴 설정이 테마와 편집기까지 닿는지.
@MainActor
final class FontPreferenceTests: XCTestCase {

    func testSystemFontsWhenNothingIsChosen() {
        let theme = MarkdownTheme()
        XCTAssertEqual(theme.bodyFont, .systemFont(ofSize: theme.bodyPointSize))
        XCTAssertTrue(theme.monoFont.isFixedPitch)
    }

    func testChosenFamiliesAreUsed() {
        var theme = MarkdownTheme()
        theme.bodyFontFamily = "Helvetica"
        theme.codeFontFamily = "Menlo"
        XCTAssertEqual(theme.bodyFont.familyName, "Helvetica")
        XCTAssertEqual(theme.monoFont.familyName, "Menlo")
        XCTAssertEqual(theme.monoFont.pointSize, theme.bodyPointSize - 1)
        // 제목은 같은 패밀리의 굵은꼴, 크기는 단계대로.
        let heading = theme.headingFont(level: 1)
        XCTAssertEqual(heading.familyName, "Helvetica")
        XCTAssertTrue(NSFontManager.shared.traits(of: heading).contains(.boldFontMask))
        XCTAssertEqual(heading.pointSize, theme.bodyPointSize * MarkdownTheme.headingScale[0], accuracy: 0.01)
    }

    /// 이 Mac에 없는 이름은 시스템 글꼴로 떨어진다 — 설정을 다른 Mac으로 옮겨도 화면이 깨지지 않는다.
    func testMissingFamilyFallsBackToSystem() {
        var theme = MarkdownTheme()
        theme.bodyFontFamily = "Nonexistent Font Family 123"
        theme.codeFontFamily = "Nonexistent Font Family 123"
        XCTAssertEqual(theme.bodyFont, .systemFont(ofSize: theme.bodyPointSize))
        XCTAssertEqual(theme.monoFont, .monospacedSystemFont(ofSize: theme.bodyPointSize - 1, weight: .regular))
        XCTAssertEqual(theme.headingFont(level: 1),
                       .systemFont(ofSize: theme.bodyPointSize * MarkdownTheme.headingScale[0], weight: .bold))
    }

    /// 고정폭이 아닌 코드 글꼴은 쓰지 않는다 — 저장소에 손으로 쓴 값도 여기서 막힌다.
    func testProportionalCodeFamilyIsRefused() {
        var theme = MarkdownTheme()
        theme.codeFontFamily = "Helvetica"
        XCTAssertTrue(theme.monoFont.isFixedPitch)
        XCTAssertNotEqual(theme.monoFont.familyName, "Helvetica")
    }

    /// 설정 → 편집기 → 저장소의 글자 속성까지.
    func testEditorAppliesTheChosenFonts() {
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        // 첫 글자는 라틴 문자여야 한다 — 한글 자리는 시스템이 한글 글꼴(Apple SD Gothic Neo)로
        // 바꿔 끼우므로(글꼴 고치기) 고른 패밀리가 보이지 않는다(실측).
        editor.markdown = "Body 본문 글\n\n```swift\nlet x = 1\n```\n"
        var preferences = EditorPreferences.standard
        preferences.bodyFontFamily = "Helvetica"
        preferences.codeFontFamily = "Menlo"
        editor.apply(preferences)
        let storage = editor.textView.textStorage!
        let text = storage.string as NSString
        let body = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let code = storage.attribute(.font, at: text.range(of: "let x").location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(body?.familyName, "Helvetica")
        XCTAssertEqual(code?.familyName, "Menlo")

        editor.apply(.standard)
        let reset = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotEqual(reset?.familyName, "Helvetica", "시스템으로 돌리면 돌아와야 한다")
    }

    // MARK: 저장소

    private func freshStore() -> (PreferenceStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "madi.tests.\(UUID().uuidString)")!
        return (PreferenceStore(defaults: defaults), defaults)
    }

    func testFamiliesRoundTripThroughTheStore() {
        let (store, _) = freshStore()
        // 아무것도 고른 적 없으면 앱에 든 글꼴이다.
        XCTAssertEqual(store.current.bodyFontFamily, "Pretendard")
        XCTAssertEqual(store.current.codeFontFamily, "IBM Plex Mono")
        var preferences = EditorPreferences.standard
        preferences.bodyFontFamily = "Helvetica"
        preferences.codeFontFamily = "Menlo"
        store.save(preferences)
        XCTAssertEqual(store.current, preferences)
    }

    /// 빈 값·공백은 '시스템'이다.
    func testBlankStoredFamilyMeansSystem() {
        let (store, defaults) = freshStore()
        defaults.set("   ", forKey: "editor.bodyFontFamily")
        defaults.set("", forKey: "editor.codeFontFamily")
        XCTAssertNil(store.current.bodyFontFamily)
        XCTAssertNil(store.current.codeFontFamily)
    }

    func testResetReturnsToTheBundledFonts() {
        let (store, _) = freshStore()
        var preferences = EditorPreferences.standard
        preferences.bodyFontFamily = "Helvetica"
        store.save(preferences)
        store.reset()
        XCTAssertEqual(store.current.bodyFontFamily, "Pretendard")
    }

    /// 시스템 글꼴을 고르면 다시 열어도 시스템 글꼴이다 — 기본값(앱에 든 글꼴)으로 돌아가지 않는다.
    func testChoosingSystemFontSurvivesReload() {
        let (store, _) = freshStore()
        var preferences = EditorPreferences.standard
        preferences.bodyFontFamily = nil
        preferences.codeFontFamily = nil
        store.save(preferences)
        XCTAssertNil(store.current.bodyFontFamily)
        XCTAssertNil(store.current.codeFontFamily)
    }

    // MARK: 앱에 든 글꼴

    static var repoFonts: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Madi/Resources/Fonts")
    }

    /// 글꼴 파일과 라이선스 전문이 함께 있다 — 라이선스(OFL 2조)는 글꼴과 함께 나가야 한다.
    func testBundledFontFilesAndLicensesArePresent() throws {
        for file in BundledFonts.fontFiles + BundledFonts.licenseFiles {
            XCTAssertNotNil(BundledFonts.url(of: file, in: Self.repoFonts), "\(file)이 없다")
        }
        for license in BundledFonts.licenseFiles {
            let text = try String(contentsOf: Self.repoFonts.appendingPathComponent(license), encoding: .utf8)
            XCTAssertTrue(text.contains("SIL OPEN FONT LICENSE Version 1.1"), license)
        }
    }

    /// 등록하면 두 글꼴이 이 프로세스에서 쓰이고, 코드 글꼴은 고정폭이다 — 고정폭이 아니면 테마가
    /// 조용히 시스템 고정폭으로 바꿔, 넣은 글꼴이 코드에 쓰이지 않는다.
    func testRegisteredBundledFontsResolveWithTheirFaces() {
        XCTAssertEqual(BundledFonts.register(from: Self.repoFonts).map(\.file), [])
        var theme = MarkdownTheme()
        theme.bodyFontFamily = EditorPreferences.standard.bodyFontFamily
        theme.codeFontFamily = EditorPreferences.standard.codeFontFamily
        XCTAssertEqual(theme.bodyFont.familyName, "Pretendard")
        XCTAssertEqual(theme.monoFont.familyName, "IBM Plex Mono")
        XCTAssertTrue(theme.monoFont.isFixedPitch)
        XCTAssertTrue(NSFontManager.shared.traits(of: theme.headingFont(level: 1)).contains(.boldFontMask),
                      "제목은 Pretendard 굵은꼴이어야 한다")
        let codeItalic = NSFontManager.shared.convert(theme.monoFont, toHaveTrait: .italicFontMask)
        XCTAssertTrue(NSFontManager.shared.traits(of: codeItalic).contains(.italicFontMask))
        // 두 번 불러도 실패로 세지 않는다.
        XCTAssertEqual(BundledFonts.register(from: Self.repoFonts).map(\.file), [])
    }

    /// 없는 폴더에서 부르면 빠진 파일을 하나하나 알려 준다(조용히 시스템 글꼴로 그리지 않는다).
    func testMissingFontFilesAreReported() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("madi-no-fonts-\(UUID().uuidString)")
        let failures = BundledFonts.register(from: empty)
        XCTAssertEqual(failures.map(\.file), BundledFonts.fontFiles)
    }

    /// Pretendard에는 기울임꼴이 없다 — 영문 `*강조*`도 강제로 기울여야 보인다.
    func testEmphasisInAFontWithoutItalicIsSlanted() {
        XCTAssertTrue(BundledFonts.register(from: Self.repoFonts).isEmpty)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        editor.markdown = "Plain *word* 그리고 *한글*\n\n끝\n"
        editor.apply(.standard)
        editor.textView.setSelectedRange(NSRange(location: (editor.markdown as NSString).length, length: 0))
        let storage = editor.textView.textStorage!
        let text = storage.string as NSString
        let latin = text.range(of: "word").location
        let hangul = text.range(of: "한글").location
        XCTAssertEqual((storage.attribute(.font, at: latin, effectiveRange: nil) as? NSFont)?.familyName, "Pretendard")
        XCTAssertNotNil(storage.attribute(.obliqueness, at: latin, effectiveRange: nil),
                        "기울임꼴이 없는 글꼴의 영문이 기울지 않았다")
        XCTAssertNotNil(storage.attribute(.obliqueness, at: hangul, effectiveRange: nil))
        // 강조가 아닌 글자는 기울지 않는다.
        XCTAssertNil(storage.attribute(.obliqueness, at: text.range(of: "Plain").location, effectiveRange: nil))
    }

    /// 기울임꼴이 있는 글꼴에서는 영문을 두 번 기울이지 않는다.
    func testEmphasisInAFontWithItalicSlantsOnlyCJK() {
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        editor.markdown = "Plain *word* 그리고 *한글*\n\n끝\n"
        var preferences = EditorPreferences.standard
        preferences.bodyFontFamily = nil       // 시스템 글꼴 — 기울임꼴이 있다
        editor.apply(preferences)
        editor.textView.setSelectedRange(NSRange(location: (editor.markdown as NSString).length, length: 0))
        let storage = editor.textView.textStorage!
        let text = storage.string as NSString
        XCTAssertNil(storage.attribute(.obliqueness, at: text.range(of: "word").location, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.obliqueness, at: text.range(of: "한글").location, effectiveRange: nil))
    }

    func testSlantRangesFollowFontAndSetting() {
        let text = "ab한글cd" as NSString
        let all = NSRange(location: 0, length: text.length)
        let hangul = NSRange(location: 2, length: 2)
        XCTAssertEqual(SyntheticSlant.ranges(in: text, range: all, fontHasItalic: true, cjk: true), [hangul])
        XCTAssertEqual(SyntheticSlant.ranges(in: text, range: all, fontHasItalic: true, cjk: false), [])
        XCTAssertEqual(SyntheticSlant.ranges(in: text, range: all, fontHasItalic: false, cjk: true), [all])
        XCTAssertEqual(SyntheticSlant.ranges(in: text, range: all, fontHasItalic: false, cjk: false),
                       [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
    }
}
