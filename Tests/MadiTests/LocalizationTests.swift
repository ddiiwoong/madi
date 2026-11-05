import Foundation
import XCTest

/// 영어 화면 글자(`en.lproj/Localizable.strings`)와 화면 언어 고르기.
///
/// 표가 소스의 키를 **다 덮는지**는 `make l10n-check`가 본다 — 키는 컴파일러만 정확히
/// 뽑을 수 있어 테스트 안에서는 알 수 없다. 여기서는 표 자체가 지켜야 할 것을 본다.
final class LocalizationTests: XCTestCase {

    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MadiTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo
        .appendingPathComponent("Sources/Madi/Resources")

    private static var englishURL: URL {
        resources.appendingPathComponent("en.lproj/Localizable.strings")
    }

    private func englishTable() throws -> [String: String] {
        let table = NSDictionary(contentsOf: Self.englishURL) as? [String: String]
        return try XCTUnwrap(table, "영어 표를 읽지 못했다 — .strings 문법이 깨졌을 수 있다")
    }

    /// `%@`·`%lld`를 순서대로. `%%`는 글자다.
    private func specifiers(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(ll|l|q)?([@dDiuUxXoOfeEgGcCsS%])"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let whole = String(text[Range(match.range, in: text)!])
            return whole == "%%" ? nil : whole
        }
    }

    func testEnglishTableCoversTheInterface() throws {
        let table = try englishTable()
        XCTAssertGreaterThan(table.count, 200, "표가 거의 비었다")
        XCTAssertEqual(table["저장"], "Save")
        XCTAssertEqual(table["마디 종료"], "Quit Madi")
    }

    /// 지정자가 다르면 실행 중에 엉뚱한 값이 들어가거나(`%@` 자리에 정수) 죽는다.
    func testEveryTranslationKeepsTheFormatSpecifiers() throws {
        for (key, value) in try englishTable() {
            XCTAssertEqual(specifiers(key), specifiers(value), "지정자가 어긋났다: \(key) → \(value)")
        }
    }

    /// 번역하지 않고 한국어를 그대로 둔 항목을 잡는다. 앱 이름의 한글 표기만 예외다.
    func testTranslationsAreNotLeftInKorean() throws {
        let hangul = try NSRegularExpression(pattern: "[\u{AC00}-\u{D7A3}]")
        for (key, value) in try englishTable() {
            let rest = value.replacingOccurrences(of: "마디", with: "")
            XCTAssertNil(hangul.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                         "영어 표에 한국어가 남았다: \(key) → \(value)")
        }
    }

    /// 표를 **번들로** 읽어 본다 — 앱이 읽는 길과 같은 `String(localized:bundle:)`이다.
    /// 영어만 든 번들이므로 어느 시스템 언어에서도 영어 표가 골라진다.
    func testTableIsReadThroughABundle() throws {
        let bundle = try englishOnlyBundle()
        XCTAssertEqual(String(localized: "저장", bundle: bundle), "Save")
        // 형식 문장도 보간 값이 제자리에 들어가야 한다.
        let count = 3
        XCTAssertEqual(String(localized: "블록 \(count)개 · 뷰 \(count)개", bundle: bundle),
                       "Blocks: 3 · Views: 3")
    }

    /// 언어 이름은 화면 글자와 같은 언어다 — 영어 화면에 '일본어'가 나오면 안 된다.
    func testLanguageNamesFollowTheTable() throws {
        let english = try englishOnlyBundle()
        XCTAssertEqual(TranslationDirection.displayLanguage(in: english), "en")
        XCTAssertEqual(TranslationDirection.name(of: "ja", in: "en"), "Japanese")
        // 표가 없는 번들(테스트 번들)은 개발 언어인 한국어다.
        XCTAssertEqual(TranslationDirection.displayLanguage(in: Bundle(for: Self.self)), "ko")
    }

    /// 개발 언어는 **한국어여야** 한다. 영어로 두면 한국어 사용자에게도 영어가 나온다 —
    /// 고른 언어(ko)에 표가 없으면 번들이 개발 언어의 표로 내려가기 때문이다(실측).
    /// 그리고 ko.lproj가 있어야 번들이 한국어를 자기 언어로 내세운다.
    func testKoreanIsTheDevelopmentLanguage() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: Self.resources.appendingPathComponent("Info.plist")))
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "ko")
        let korean = NSDictionary(contentsOf: Self.resources.appendingPathComponent("ko.lproj/InfoPlist.strings"))
        XCTAssertEqual(korean?["CFBundleDisplayName"] as? String, "마디")
        let english = NSDictionary(contentsOf: Self.resources.appendingPathComponent("en.lproj/InfoPlist.strings"))
        XCTAssertEqual(english?["CFBundleDisplayName"] as? String, "Madi")
    }

    private func englishOnlyBundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("madi-l10n-\(UUID().uuidString).bundle")
        let lproj = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.englishURL,
                                         to: lproj.appendingPathComponent("Localizable.strings"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try XCTUnwrap(Bundle(url: root))
    }
}

/// 화면 언어 — 앱 도메인의 `AppleLanguages`.
final class InterfaceLanguageTests: XCTestCase {

    func testReadsOnlyWhatTheAppDomainSays() {
        XCTAssertEqual(InterfaceLanguage.current(in: nil), .system)
        XCTAssertEqual(InterfaceLanguage.current(in: [:]), .system)
        XCTAssertEqual(InterfaceLanguage.current(in: ["AppleLanguages": [String]()]), .system)
        XCTAssertEqual(InterfaceLanguage.current(in: ["AppleLanguages": ["en"]]), .english)
        XCTAssertEqual(InterfaceLanguage.current(in: ["AppleLanguages": ["ko-KR", "en"]]), .korean)
        // 마디에 없는 언어는 번들이 쓰지 못하므로 '시스템'이다.
        XCTAssertEqual(InterfaceLanguage.current(in: ["AppleLanguages": ["ja"]]), .system)
    }

    func testApplyWritesAndSystemClears() throws {
        let name = "madi.tests.language"
        let defaults = MemoryDefaults(name: name)

        InterfaceLanguage.english.apply(to: defaults)
        XCTAssertEqual(defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String], ["en"])
        XCTAssertEqual(InterfaceLanguage.current(in: defaults.persistentDomain(forName: name)), .english)

        // 시스템은 값을 **지운다** — 빈 목록을 적으면 시스템 언어를 가린다.
        InterfaceLanguage.system.apply(to: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: name)?["AppleLanguages"])
    }

    /// 언어 이름은 그 언어로 — 읽지 못하는 화면에서 자기 언어를 찾을 수 있어야 한다.
    func testLanguagesAreNamedInThemselves() {
        XCTAssertEqual(InterfaceLanguage.korean.label, "한국어")
        XCTAssertEqual(InterfaceLanguage.english.label, "English")
    }
}
