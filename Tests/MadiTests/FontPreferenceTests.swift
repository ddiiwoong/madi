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
        XCTAssertNil(store.current.bodyFontFamily)
        XCTAssertNil(store.current.codeFontFamily)
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

    func testResetForgetsTheFamilies() {
        let (store, _) = freshStore()
        var preferences = EditorPreferences.standard
        preferences.bodyFontFamily = "Helvetica"
        store.save(preferences)
        store.reset()
        XCTAssertNil(store.current.bodyFontFamily)
    }
}
