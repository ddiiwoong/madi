import AppKit
import XCTest

/// 설정 **창**이 저장소에 닿는지.
///
/// 왜 이 묶음이 있는가: 설정 값 자체는 `SettingsTests`가 덮지만, 그 값이 화면의
/// 컨트롤에서 저장소까지 가는 길은 다른 문제다. 전에 이 환경에서 패널에 좌표 클릭이
/// 닿지 않아(네 번 시도) "체크박스 클릭 자체는 확인하지 못했다"고 TODO에 적어 두었다.
///
/// 여기서는 창을 실제로 만들고, **화면에 보이는 이름으로 컨트롤을 찾아** 그 컨트롤의
/// target-action을 AppKit과 같은 방식으로 쏜다. 좌표 클릭이 하지 못한 일을 테스트가
/// 한다 — 그리고 좌표 클릭과 달리 회귀를 막는다.
///
/// 창은 만들기만 하고 띄우지 않는다(사용자의 화면을 가로채지 않는다).
@MainActor
final class SettingsPanelWiringTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: PreferenceStore!
    private var panel: SettingsPanel!
    /// 화면 언어를 적을 도메인. 사용자의 실제 `AppleLanguages`를 건드리지 않는다.
    private var languageSuite: String!
    private var languageDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // 둘 다 디스크에 쓰지 않는다(`MemoryDefaults`).
        defaults = MemoryDefaults()
        store = PreferenceStore(defaults: defaults)
        languageSuite = "madi.tests.language"
        languageDefaults = MemoryDefaults(name: languageSuite)
        panel = makePanel()
    }

    /// 키는 메모리에 둔다 — 시험이 사용자의 키체인에 닿지 않는다.
    private var secrets = MemorySecretStore()
    private var checker = StubChecker()

    /// 키 확인 대역. 받은 것을 기억하고 정해 둔 결과를 준다.
    final class StubChecker: KeyChecking {
        var result = KeyCheckResult.accepted(models: 3, hasRecommended: true)
        private(set) var calls: [(LLMService, String, String?)] = []
        func check(_ service: LLMService, key: String, region: String?) async -> KeyCheckResult {
            calls.append((service, key, region))
            return result
        }
    }

    /// '받기…'가 연 주소. 브라우저를 띄우지 않는다.
    private var opened: [URL] = []
    /// 이 Mac에 있는 글꼴을 흉내 낸다. nil이면 이 Mac의 실제 글꼴.
    private var fakeFonts: FakeFonts?

    /// 흉내 낸 글꼴 목록. 테스트가 고쳐 '설치'한다.
    final class FakeFonts {
        var text: [String]
        var code: [String]
        init(text: [String], code: [String]) { self.text = text; self.code = code }
        func families(fixedPitchOnly: Bool) -> [String] { fixedPitchOnly ? code : text }
        func isUsable(_ family: String, _ use: RecommendedFont.Use) -> Bool {
            use == .code ? code.contains(family) : text.contains(family)
        }
    }

    private func makePanel() -> SettingsPanel {
        guard let fonts = fakeFonts else {
            return SettingsPanel(store: store, languageDefaults: languageDefaults, languageDomain: languageSuite,
                                 secrets: secrets, keyChecker: checker, llmDefaults: languageDefaults,
                                 openURL: { [unowned self] in opened.append($0) })
        }
        return SettingsPanel(store: store, languageDefaults: languageDefaults, languageDomain: languageSuite,
                             secrets: secrets, keyChecker: checker, llmDefaults: languageDefaults,
                             openURL: { [unowned self] in opened.append($0) },
                             fontFamilies: { fonts.families(fixedPitchOnly: $0) },
                             isFontUsable: { fonts.isUsable($0, $1) })
    }

    override func tearDown() {
        languageDefaults.removePersistentDomain(forName: languageSuite)
        panel = nil
        store = nil
        defaults = nil
        languageDefaults = nil
        super.tearDown()
    }

    // MARK: 화면 뒤지기

    private var root: NSView {
        guard let view = panel.window?.contentView else {
            XCTFail("설정 창에 콘텐츠 뷰가 없다")
            return NSView()
        }
        return view
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// 탭 안의 뷰는 `NSTabView`가 들고 있어 `subviews`만으로는 다 걸리지 않는다 —
    /// 선택되지 않은 탭의 뷰는 창에 붙어 있지 않다.
    private var allViews: [NSView] {
        var views = descendants(of: root)
        for tabs in views.compactMap({ $0 as? NSTabView }) {
            for item in tabs.tabViewItems {
                guard let view = item.view else { continue }
                views += [view] + descendants(of: view)
            }
        }
        return views
    }

    private var tabView: NSTabView? {
        allViews.compactMap { $0 as? NSTabView }.first
    }

    private func checkbox(_ title: String) -> NSButton? {
        allViews.compactMap { $0 as? NSButton }
            .first { $0.title == title && $0.allowsMixedState == false && $0.action != nil }
    }

    /// 고르개를 **담긴 값으로** 찾는다. 라벨 글자가 바뀌어도 테스트가 살아 있다.
    private func picker<T: RawRepresentable & CaseIterable>(for: T.Type) -> NSPopUpButton?
    where T.RawValue == String {
        let wanted = Set(T.allCases.map(\.rawValue))
        return allViews.compactMap { $0 as? NSPopUpButton }.first { button in
            Set(button.itemArray.compactMap { $0.representedObject as? String }) == wanted
        }
    }

    /// AppKit이 하는 그대로 컨트롤의 action을 쏜다.
    private func fire(_ control: NSControl) {
        guard let action = control.action else { return XCTFail("action이 없는 컨트롤") }
        XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control),
                      "action이 받아들여지지 않았다: \(action)")
    }

    // MARK: 창의 모양

    /// 글꼴이 맨 앞이다 — 설정 창에서 가장 자주 고치는 것이다.
    func testTabsExistWithFontsFirst() {
        guard let tabs = tabView else { return XCTFail("NSTabView가 없다") }
        XCTAssertEqual(tabs.tabViewItems.map(\.label),
                       ["글꼴", "보기", "일반", "PDF·프린트", "AI 교정", "정보"])
        XCTAssertEqual(panel.selectedTab, SettingsPanel.fontTab)
    }

    func testSelectTabSwitchesTabs() {
        panel.selectTab("print")
        XCTAssertEqual(panel.selectedTab, "print")
        panel.selectTab(SettingsPanel.fontTab)
        XCTAssertEqual(panel.selectedTab, SettingsPanel.fontTab)
    }

    /// 테마 고르개 — 다섯 테마가 견본과 함께 있고, 고르면 저장소까지 간다. 다시 열면 고른 것이 골라져 있다.
    func testThemePickerReachesTheStore() throws {
        let themes = try XCTUnwrap(picker(for: EditorPreferences.ColorTheme.self))
        XCTAssertEqual(themes.identifier?.rawValue, "view.theme")
        XCTAssertTrue(themes.itemArray.allSatisfy { $0.image != nil }, "견본이 붙어 있다")
        XCTAssertEqual(themes.selectedItem?.representedObject as? String, "standard")
        select("github", in: themes)
        fire(themes)
        XCTAssertEqual(store.current.colorTheme, .github)
        panel = makePanel()
        XCTAssertEqual(picker(for: EditorPreferences.ColorTheme.self)?.selectedItem?.representedObject as? String,
                       "github")
    }

    /// 고르개가 비어 있으면 사용자가 고를 것이 없다.
    func testEveryPickerIsPopulated() {
        XCTAssertEqual(picker(for: EditorPreferences.ColorTheme.self)?.numberOfItems, 5)
        XCTAssertEqual(picker(for: EditorPreferences.Appearance.self)?.numberOfItems, 3)
        XCTAssertEqual(picker(for: EditorPreferences.LineSpacing.self)?.numberOfItems, 3)
        XCTAssertEqual(picker(for: EditorPreferences.DocumentWidth.self)?.numberOfItems, 4)
        XCTAssertEqual(picker(for: EditorPreferences.PrintMargin.self)?.numberOfItems, 3)
        XCTAssertEqual(picker(for: EditorPreferences.PrintOrientation.self)?.numberOfItems, 2)
        XCTAssertEqual(picker(for: EditorPreferences.PrintPaper.self)?.numberOfItems, 3)
    }

    /// 저장된 값이 화면에 실려야 한다 — 창을 열면 지금 설정이 보여야 한다.
    func testStoredValuesAreLoadedIntoTheControls() {
        var saved = EditorPreferences.standard
        saved.appearance = .dark
        saved.documentWidth = .wide
        saved.loadsRemoteImages = true
        store.save(saved)

        let reopened = makePanel()
        panel = reopened       // allViews가 이 창을 보도록
        XCTAssertEqual(picker(for: EditorPreferences.Appearance.self)?
            .selectedItem?.representedObject as? String, "dark")
        XCTAssertEqual(picker(for: EditorPreferences.DocumentWidth.self)?
            .selectedItem?.representedObject as? String, "wide")
        XCTAssertEqual(checkbox("원격 이미지 불러오기")?.state, .on)
    }

    // MARK: 컨트롤 → 저장소

    /// **이것이 이 묶음의 요점이다.** 체크박스를 눌러 값이 저장소까지 가는지.
    func testTogglingRemoteImagesReachesTheStore() {
        guard let check = checkbox("원격 이미지 불러오기") else {
            return XCTFail("원격 이미지 체크박스를 찾지 못했다")
        }
        XCTAssertFalse(store.current.loadsRemoteImages, "기본은 꺼짐이어야 한다")

        check.state = .on
        fire(check)
        XCTAssertTrue(store.current.loadsRemoteImages)

        check.state = .off
        fire(check)
        XCTAssertFalse(store.current.loadsRemoteImages)
    }

    func testEachPickerReachesTheStore() {
        guard let appearance = picker(for: EditorPreferences.Appearance.self),
              let spacing = picker(for: EditorPreferences.LineSpacing.self),
              let width = picker(for: EditorPreferences.DocumentWidth.self),
              let margin = picker(for: EditorPreferences.PrintMargin.self),
              let orientation = picker(for: EditorPreferences.PrintOrientation.self),
              let paper = picker(for: EditorPreferences.PrintPaper.self)
        else { return XCTFail("고르개를 찾지 못했다") }

        // 고르개마다 **자기 action이 달려 있어야** 한다. 아래에서는 하나만 쏘는데,
        // `changed()`가 여섯 컨트롤을 모두 읽기 때문에 그것만으로는 배선이 끊긴
        // 고르개를 못 잡는다 — 사용자는 그 고르개를 돌려도 아무 일도 안 일어난다.
        for (name, control) in [("화면 모양", appearance), ("줄 간격", spacing),
                                ("글 넓이", width), ("여백", margin),
                                ("방향", orientation), ("용지", paper)] {
            XCTAssertNotNil(control.action, "\(name) 고르개에 action이 없다")
            XCTAssertNotNil(control.target, "\(name) 고르개에 target이 없다")
        }

        select("dark", in: appearance)
        select("loose", in: spacing)
        select("narrow", in: width)
        select("wide", in: margin)
        select("landscape", in: orientation)
        select("a4", in: paper)
        fire(appearance)

        let saved = store.current
        XCTAssertEqual(saved.appearance, .dark)
        XCTAssertEqual(saved.lineSpacing, .loose)
        XCTAssertEqual(saved.documentWidth, .narrow)
        XCTAssertEqual(saved.printMargin, .wide)
        XCTAssertEqual(saved.printOrientation, .landscape)
        XCTAssertEqual(saved.printPaper, .a4)
    }

    /// 설정이 바뀌면 열려 있는 창들이 다시 칠해야 하므로 알림이 나가야 한다.
    func testChangePostsTheNotification() {
        guard let check = checkbox("표 열 맞추기") else { return XCTFail("체크박스가 없다") }
        let expectation = XCTNSNotificationExpectation(name: PreferenceStore.didChange)
        check.state = .off
        fire(check)
        wait(for: [expectation], timeout: 2)
    }

    /// 기본값 버튼이 전부 되돌려야 한다.
    func testResetButtonRestoresDefaults() {
        var saved = EditorPreferences.standard
        saved.appearance = .light
        saved.printPaper = .letter
        saved.loadsRemoteImages = true
        store.save(saved)
        let reopened = makePanel()
        panel = reopened

        guard let reset = allViews.compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "기본값으로" })
        else { return XCTFail("기본값으로 버튼이 없다") }
        fire(reset)

        XCTAssertEqual(store.current, EditorPreferences.standard)
        XCTAssertEqual(picker(for: EditorPreferences.Appearance.self)?
            .selectedItem?.representedObject as? String, "system")
    }

    /// 창이 콘텐츠의 fitting size로 쪼그라들지 않아야 한다 — `contentViewController`를
    /// 넣으면 AppKit이 그렇게 줄이고, 전에 520x380 조각으로 뜬 적이 있다.
    func testWindowKeepsItsDeclaredSize() {
        guard let frame = panel.window?.contentView?.frame else { return XCTFail("창이 없다") }
        XCTAssertGreaterThanOrEqual(frame.width, 440)
        XCTAssertGreaterThanOrEqual(frame.height, 400)
    }

    // MARK: 글꼴

    /// 글꼴 고르개 — 본문 `font.body` · 제목 `font.heading` · 코드 `font.code`.
    private func fontPicker(_ identifier: String) -> NSPopUpButton? {
        allViews.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == identifier }
    }

    /// 고르개 항목을 읽기 쉬운 꼴로 — 머리는 `[제목]`, 받기는 `제목 ↓`, 고를 패밀리는 그 값.
    private func entries(_ picker: NSPopUpButton) -> [String] {
        picker.itemArray.compactMap { item in
            if item.isSeparatorItem { return nil }
            if item.isSectionHeader { return "[\(item.title)]" }
            if let font = item.representedObject as? RecommendedFont { return font.family + " ↓" }
            return item.representedObject as? String
        }
    }

    /// 흉내 낸 Mac. 추천 가운데 일부만 있고, 추천이 아닌 글꼴이 하나씩 있다.
    private func useFakeFonts() -> FakeFonts {
        let fonts = FakeFonts(text: ["AppleMyungjo", "Apple SD Gothic Neo", "Helvetica", "Nanum Gothic", "Pretendard"],
                              code: ["Courier", "IBM Plex Mono", "Menlo"])
        fakeFonts = fonts
        panel = makePanel()
        return fonts
    }

    /// 두 고르개가 있고, 맨 위가 시스템이며, 이 Mac의 글꼴이 실려 있다.
    func testFontPickersListInstalledFamilies() {
        guard let body = fontPicker("font.body"),
              let code = fontPicker("font.code") else { return XCTFail("글꼴 고르개가 없다") }
        let bodyFamilies = body.itemArray.compactMap { $0.representedObject as? String }.filter { !$0.isEmpty }
        let codeFamilies = code.itemArray.compactMap { $0.representedObject as? String }.filter { !$0.isEmpty }
        XCTAssertTrue(bodyFamilies.contains("Helvetica"), "macOS에 늘 있는 글꼴이 빠졌다")
        XCTAssertTrue(codeFamilies.contains("Menlo"), "macOS에 늘 있는 고정폭이 빠졌다")
        XCTAssertGreaterThan(bodyFamilies.count, codeFamilies.count)
    }

    /// 코드 고르개에는 고정폭만 있다 — 하나라도 아니면 코드의 들여쓰기가 어긋난다.
    func testCodeFontPickerOffersOnlyFixedPitch() {
        guard let code = fontPicker("font.code") else { return XCTFail("코드 글꼴 고르개가 없다") }
        let families = code.itemArray.compactMap { $0.representedObject as? String }.filter { !$0.isEmpty }
        XCTAssertFalse(families.contains("Helvetica"))
        for family in families {
            XCTAssertEqual(NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?
                .isFixedPitch, true, family)
        }
    }

    func testChoosingFontsReachesTheStoreAndSystemClearsIt() {
        guard let body = fontPicker("font.body"),
              let code = fontPicker("font.code") else { return XCTFail("글꼴 고르개가 없다") }
        XCTAssertNotNil(body.action)
        XCTAssertNotNil(code.action)
        select("Helvetica", in: body)
        select("Menlo", in: code)
        fire(body)
        XCTAssertEqual(store.current.bodyFontFamily, "Helvetica")
        XCTAssertEqual(store.current.codeFontFamily, "Menlo")

        guard let systemIndex = body.itemArray.firstIndex(where: { $0.title == "시스템 글꼴" }) else {
            return XCTFail("시스템 항목이 없다")
        }
        body.selectItem(at: systemIndex)
        fire(body)
        XCTAssertNil(store.current.bodyFontFamily, "시스템을 고르면 nil로 읽힌다")
        // 키를 지우면 기본값(앱에 든 글꼴)으로 읽히므로 빈 값으로 남는다.
        XCTAssertEqual(defaults.string(forKey: "editor.bodyFontFamily"), "")
    }

    /// 앱에 든 글꼴이 등록돼 있으면 추천의 맨 위에 '기본'으로 온다.
    func testBundledFontsAreListedFirst() {
        XCTAssertTrue(BundledFonts.register(from: FontPreferenceTests.repoFonts).isEmpty)
        panel = makePanel()
        guard let body = fontPicker("font.body"),
              let code = fontPicker("font.code") else { return XCTFail("글꼴 고르개가 없다") }
        XCTAssertEqual(entries(body).prefix(2), ["[추천]", "Pretendard"])
        XCTAssertEqual(entries(code).prefix(2), ["[추천]", "IBM Plex Mono"])
        // 처음 열면(아무것도 고른 적 없으면) 그것이 골라져 있다.
        XCTAssertEqual(body.selectedItem?.representedObject as? String, "Pretendard")
        XCTAssertEqual(code.selectedItem?.representedObject as? String, "IBM Plex Mono")
        XCTAssertEqual(body.itemArray.filter { ($0.representedObject as? String) == "Pretendard" }.count, 1,
                       "아래 목록에 한 번 더 나오지 않는다")
    }

    /// 이 Mac에 없는 글꼴이 저장돼 있으면 시스템을 고른 것처럼 보이지 않는다.
    func testMissingStoredFontIsShownByName() {
        var saved = EditorPreferences.standard
        saved.bodyFontFamily = "Nonexistent Font Family 123"
        store.save(saved)
        panel = makePanel()
        let selected = fontPicker("font.body")?.selectedItem
        XCTAssertEqual(selected?.representedObject as? String, "Nonexistent Font Family 123")
        XCTAssertTrue(selected?.title.contains("이 Mac에 없음") == true, selected?.title ?? "")
    }

    // MARK: 글꼴 — 추천 · 제목 · 받기 · 미리보기

    /// 추천이 위에 오고(있는 것은 그대로, 없는 것은 받기), 그다음 시스템, 그다음 나머지. 추천에 나온
    /// 글꼴은 아래에 다시 나오지 않는다.
    func testRecommendedFontsComeFirst() {
        _ = useFakeFonts()
        guard let body = fontPicker("font.body"), let code = fontPicker("font.code") else {
            return XCTFail("글꼴 고르개가 없다")
        }
        XCTAssertEqual(entries(body), [
            "[추천]", "Pretendard", "Apple SD Gothic Neo", "Nanum Gothic", "Noto Sans KR ↓", "IBM Plex Sans KR ↓",
            "AppleMyungjo", "Nanum Myeongjo ↓", "Noto Serif KR ↓",
            "",
            "[이 Mac의 글꼴]", "Helvetica",
        ])
        XCTAssertEqual(entries(code), [
            "[추천]", "IBM Plex Mono", "Menlo", "D2Coding ↓", "JetBrains Mono ↓",
            "",
            "[이 Mac의 글꼴]", "Courier",
        ])
        // 받기 항목은 갈래와 '받기…'를 이름 옆에 적고, 무엇을 여는지 미리 말한다.
        let noto = downloadItem("Noto Sans KR", in: body)
        XCTAssertEqual(noto?.title, "Noto Sans KR  고딕 · 받기…")
        XCTAssertEqual(noto?.toolTip?.contains("fonts.google.com"), true, noto?.toolTip ?? "")
        // 있는 추천 글꼴은 그 글꼴로 그리고, 갈래와 출처를 적는다.
        let gothic = body.itemArray.first { ($0.representedObject as? String) == "Apple SD Gothic Neo" }
        XCTAssertEqual(gothic?.title, "Apple SD Gothic Neo  고딕 · macOS")
        XCTAssertEqual((gothic?.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName,
                       "Apple SD Gothic Neo")
    }

    private func downloadItem(_ family: String, in picker: NSPopUpButton) -> NSMenuItem? {
        picker.itemArray.first { ($0.representedObject as? RecommendedFont)?.family == family }
    }

    /// '본문과 같음'은 제목 고르개에만 있고, 처음에는 그것이 골라져 있다.
    func testHeadingPickerDefaultsToSameAsBody() {
        _ = useFakeFonts()
        guard let heading = fontPicker("font.heading"), let body = fontPicker("font.body"),
              let code = fontPicker("font.code") else { return XCTFail("글꼴 고르개가 없다") }
        XCTAssertEqual(entries(heading).first, FontPickerMenu.sameAsBodyTag)
        XCTAssertEqual(heading.selectedItem?.representedObject as? String, FontPickerMenu.sameAsBodyTag)
        XCTAssertFalse(entries(body).contains(FontPickerMenu.sameAsBodyTag))
        XCTAssertFalse(entries(code).contains(FontPickerMenu.sameAsBodyTag))
        XCTAssertEqual(Array(entries(heading).dropFirst()), entries(body), "그 밖의 목록은 본문과 같다")
    }

    /// 제목 글꼴의 세 길이 저장소까지 간다 — 패밀리 · 시스템 · 본문과 같음.
    func testChoosingAHeadingFontReachesTheStore() {
        _ = useFakeFonts()
        guard let heading = fontPicker("font.heading") else { return XCTFail("제목 고르개가 없다") }
        let key = "editor.headingFontFamily"

        select("AppleMyungjo", in: heading)
        fire(heading)
        XCTAssertEqual(store.current.headingFont, .family("AppleMyungjo"))
        XCTAssertEqual(store.current.headingFontFamily, "AppleMyungjo")
        XCTAssertEqual(store.current.bodyFontFamily, "Pretendard", "본문은 그대로다")
        XCTAssertEqual(defaults.string(forKey: key), "AppleMyungjo")

        select(FontPickerMenu.systemTag, in: heading)
        fire(heading)
        XCTAssertEqual(store.current.headingFont, .system)
        XCTAssertEqual(defaults.string(forKey: key), "")

        select(FontPickerMenu.sameAsBodyTag, in: heading)
        fire(heading)
        XCTAssertEqual(store.current.headingFont, .sameAsBody)
        XCTAssertNil(defaults.object(forKey: key), "본문과 같음은 키를 지운다")
    }

    /// 다시 열면 고른 제목 글꼴이 골라져 있다.
    func testStoredHeadingFontIsLoaded() {
        var saved = EditorPreferences.standard
        saved.headingFont = .family("AppleMyungjo")
        store.save(saved)
        _ = useFakeFonts()
        XCTAssertEqual(fontPicker("font.heading")?.selectedItem?.representedObject as? String, "AppleMyungjo")

        saved.headingFont = .system
        store.save(saved)
        panel = makePanel()
        XCTAssertEqual(fontPicker("font.heading")?.selectedItem?.representedObject as? String,
                       FontPickerMenu.systemTag)
    }

    /// 없는 추천 글꼴을 고르면 배포 페이지를 열고, **설정은 그대로** 두며, 고르개도 원래 자리로 돌아간다.
    func testChoosingADownloadItemOpensItsPageOnly() throws {
        _ = useFakeFonts()
        let body = try XCTUnwrap(fontPicker("font.body"))
        let before = store.current
        let item = try XCTUnwrap(downloadItem("Noto Sans KR", in: body))
        let page = try XCTUnwrap((item.representedObject as? RecommendedFont)?.downloadPage)
        body.select(item)
        fire(body)

        XCTAssertEqual(opened, [page])
        XCTAssertEqual(page.host, "fonts.google.com")
        XCTAssertEqual(store.current, before, "받기는 설정을 바꾸지 않는다")
        XCTAssertEqual(body.selectedItem?.representedObject as? String, "Pretendard", "고르개가 원래 글꼴로 돌아간다")
        XCTAssertTrue(panel.fontNote.stringValue.contains("Noto Sans KR"), panel.fontNote.stringValue)
    }

    /// 받아 설치하면 창을 다시 열지 않아도 고르개에 바로 나온다 — 받기가 사라지고, 그 글꼴을 고를 수 있다.
    /// 저장돼 있던 이름이 '이 Mac에 없음'이었다면 이제 제 이름으로 골라진다.
    func testInstallingAFontRefillsThePickers() throws {
        var saved = EditorPreferences.standard
        saved.bodyFontFamily = "Noto Sans KR"
        store.save(saved)
        let fonts = useFakeFonts()
        let body = try XCTUnwrap(fontPicker("font.body"))
        XCTAssertTrue(entries(body).contains("Noto Sans KR ↓"))
        XCTAssertEqual(body.selectedItem?.title.contains("이 Mac에 없음"), true)

        fonts.text.append("Noto Sans KR")
        NotificationCenter.default.post(name: NSFont.fontSetChangedNotification, object: nil)
        // 다음 차례에 다시 채운다 — 시스템 목록이 그때 갱신되기 때문이다.
        let refilled = expectation(description: "다음 차례")
        DispatchQueue.main.async { refilled.fulfill() }
        wait(for: [refilled], timeout: 2)

        XCTAssertFalse(entries(body).contains("Noto Sans KR ↓"))
        XCTAssertEqual(entries(body).filter { $0 == "Noto Sans KR" }.count, 1, "추천 자리에 한 번만")
        XCTAssertEqual(body.selectedItem?.representedObject as? String, "Noto Sans KR")
        XCTAssertEqual(body.selectedItem?.title, "Noto Sans KR  고딕")
        XCTAssertFalse(body.itemArray.contains { $0.title.contains("이 Mac에 없음") }, "없음 항목이 남지 않는다")
    }

    /// 미리보기는 실제 편집기다 — 고르는 대로 그 글꼴로 다시 그린다. 마커는 숨긴다.
    func testPreviewFollowsTheChosenFonts() throws {
        _ = useFakeFonts()
        let body = try XCTUnwrap(fontPicker("font.body"))
        let heading = try XCTUnwrap(fontPicker("font.heading"))
        let code = try XCTUnwrap(fontPicker("font.code"))
        XCTAssertTrue(panel.preview.isRenderingForOutput)
        XCTAssertEqual(panel.preview.markdown, SettingsPanel.previewMarkdown)

        select("Helvetica", in: body)
        select("Courier", in: code)
        select(FontPickerMenu.sameAsBodyTag, in: heading)
        fire(body)
        // 한글 자리는 시스템이 한글 글꼴로 바꿔 끼운다 — 고른 패밀리는 라틴 문자·문장 부호 자리에서 본다.
        XCTAssertEqual(previewFont(at: "."), "Helvetica")
        XCTAssertEqual(previewFont(at: "let title"), "Courier")
        XCTAssertEqual(previewFont(at: " 이렇게"), "Helvetica", "제목이 본문을 따른다")

        select("Apple SD Gothic Neo", in: heading)
        fire(heading)
        XCTAssertEqual(previewFont(at: " 이렇게"), "Apple SD Gothic Neo")
        XCTAssertEqual(previewFont(at: "."), "Helvetica", "본문은 그대로다")
    }

    private func previewFont(at needle: String) -> String? {
        guard let storage = panel.preview.textView.textStorage else { return nil }
        let location = (storage.string as NSString).range(of: needle).location
        guard location != NSNotFound else { return nil }
        return (storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.familyName
    }

    /// 다른 설정을 바꿔도 번역 대상 언어를 잃지 않는다.
    ///
    /// 전에는 `changed()`가 설정을 새로 지으면서 이 값을 넘기지 않아, 체크박스 하나만 눌러도
    /// 고른 번역 언어가 영어로 돌아갔다(번역 언어 선택 시트가 기억해 둔 값이다).
    func testChangingAnotherSettingKeepsTheTranslationTarget() {
        var saved = EditorPreferences.standard
        saved.translationTarget = "ja"
        store.save(saved)
        panel = makePanel()
        guard let check = checkbox("표 열 맞추기") else { return XCTFail("체크박스가 없다") }
        check.state = .off
        fire(check)
        XCTAssertEqual(store.current.translationTarget, "ja")
    }

    // MARK: AI 교정 — 키

    private var servicePicker: NSPopUpButton? {
        let wanted = Set(LLMService.allCases.map(\.rawValue))
        return allViews.compactMap { $0 as? NSPopUpButton }.first { button in
            Set(button.itemArray.compactMap { $0.representedObject as? String }) == wanted
        }
    }

    private var keyField: NSSecureTextField? {
        allViews.compactMap { $0 as? NSSecureTextField }.first
    }

    private func button(_ title: String) -> NSButton? {
        allViews.compactMap { $0 as? NSButton }.first { $0.title == title && $0.action != nil }
    }

    private func label(containing text: String) -> NSTextField? {
        allViews.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains(text) && !$0.isEditable }
    }

    private func choose(_ service: LLMService) {
        guard let picker = servicePicker else { return XCTFail("서비스 고르개가 없다") }
        select(service.rawValue, in: picker)
        fire(picker)
    }

    /// 다섯 서비스를 고를 수 있다 — 소곤이 부르는 바깥 서비스와 같다.
    func testServicesAreListed() {
        XCTAssertEqual(servicePicker?.itemArray.map(\.title),
                       ["Anthropic Claude", "OpenAI", "Google Gemini", "Groq", "Amazon Bedrock"])
    }

    func testSavingAKeyStoresItTrimmedAndClearsTheField() {
        choose(.gemini)
        guard let field = keyField, let save = button("키체인에 저장") else { return XCTFail("키 칸·저장 단추가 없다") }
        XCTAssertNotNil(label(containing: "저장된 키가 없습니다"))
        field.stringValue = "  AIza-secret\n"
        fire(save)
        XCTAssertEqual(secrets.values["gemini"], "AIza-secret", "붙여 넣은 공백·줄바꿈을 뗀다")
        XCTAssertEqual(field.stringValue, "", "저장한 뒤 화면에 키를 남기지 않는다")
        XCTAssertNotNil(label(containing: "키체인에 저장된 키가 있습니다"))
        // 편집기 설정 저장소에는 키가 없다.
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { "\($0)".contains("AIza-secret") })
    }

    /// 기록 창에 키가 남지 않는다 — 기록은 복사해 붙여 넣는 곳이다.
    func testKeyIsNeverLogged() async {
        choose(.openai)
        keyField?.stringValue = "sk-never-logged"
        if let save = button("키체인에 저장") { fire(save) }
        if let check = button("키 확인") { fire(check) }
        await panel.keyCheckTask?.value
        let logged = AppLog.shared.entries.map { "\($0.message) \($0.detail ?? "")" }.joined(separator: "\n")
        XCTAssertFalse(logged.contains("sk-never-logged"))
    }

    func testRemovingAKeyDeletesIt() {
        try? secrets.setSecret("k", for: "groq", label: "")
        choose(.groq)
        guard let remove = button("지우기"), remove.isEnabled else { return XCTFail("지우기가 꺼져 있다") }
        fire(remove)
        XCTAssertNil(secrets.values["groq"])
        XCTAssertFalse(remove.isEnabled)
    }

    /// 화면을 그리면서 **값을 꺼내지 않는다** — ad-hoc 서명 빌드에서는 값을 꺼낼 때마다 키체인 창이
    /// 뜰 수 있다. 있는지만 묻고, 값은 키 확인을 누를 때만 꺼낸다.
    func testShowingTheTabDoesNotReadSecrets() {
        try? secrets.setSecret("k", for: "anthropic", label: "")
        panel = makePanel()
        for service in LLMService.allCases { choose(service) }
        XCTAssertEqual(secrets.reads, 0)
    }

    func testCheckUsesTheStoredKeyAndShowsTheResult() async {
        try? secrets.setSecret("sk-ant-x", for: "anthropic", label: "")
        panel = makePanel()
        choose(.anthropic)
        guard let check = button("키 확인"), check.isEnabled else { return XCTFail("키 확인이 꺼져 있다") }
        checker.result = .rejected(status: 401, message: "invalid x-api-key")
        fire(check)
        await panel.keyCheckTask?.value
        XCTAssertEqual(checker.calls.count, 1)
        XCTAssertEqual(checker.calls.first?.0, .anthropic)
        XCTAssertEqual(checker.calls.first?.1, "sk-ant-x")
        XCTAssertNil(checker.calls.first?.2, "Bedrock이 아니면 리전을 넘기지 않는다")
        XCTAssertNotNil(label(containing: "invalid x-api-key"))
    }

    func testCheckIsOffWithoutAKey() {
        choose(.openai)
        XCTAssertEqual(button("키 확인")?.isEnabled, false)
    }

    /// 리전은 Bedrock에만 보이고, 비밀이 아니므로 설정에 둔다. 확인이 그 리전으로 묻는다.
    func testBedrockRegionIsShownStoredAndUsed() async {
        try? secrets.setSecret("bedrock-key", for: "bedrock", label: "")
        panel = makePanel()
        let regionField = allViews.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == LLMService.defaultBedrockRegion }
        guard let regionField, let row = regionField.superview else { return XCTFail("리전 칸이 없다") }

        choose(.anthropic)
        XCTAssertTrue(row.isHidden, "Bedrock이 아니면 리전이 없다")
        choose(.bedrock)
        XCTAssertFalse(row.isHidden)

        regionField.stringValue = "ap-northeast-2"
        fire(regionField)
        XCTAssertEqual(languageDefaults.string(forKey: SettingsPanel.bedrockRegionKey), "ap-northeast-2")

        regionField.stringValue = "evil.example.com"
        fire(regionField)
        XCTAssertEqual(languageDefaults.string(forKey: SettingsPanel.bedrockRegionKey), "ap-northeast-2",
                       "리전이 아닌 글은 받지 않는다")

        if let check = button("키 확인") { fire(check) }
        await panel.keyCheckTask?.value
        XCTAssertEqual(checker.calls.last?.2, "ap-northeast-2")
    }

    /// `기본값으로`는 보기·프린트 설정을 되돌린다. 키를 지우지 않는다.
    func testResetKeepsKeys() {
        try? secrets.setSecret("k", for: "openai", label: "")
        guard let reset = allViews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "기본값으로" })
        else { return XCTFail("기본값으로 버튼이 없다") }
        fire(reset)
        XCTAssertEqual(secrets.values["openai"], "k")
    }

    // MARK: 화면 언어

    func testChoosingALanguageWritesTheAppDomain() {
        guard let languages = picker(for: InterfaceLanguage.self) else { return XCTFail("화면 언어 고르개가 없다") }
        XCTAssertEqual(languages.selectedItem?.representedObject as? String, "system")

        select("en", in: languages)
        fire(languages)
        XCTAssertEqual(languageDefaults.persistentDomain(forName: languageSuite)?["AppleLanguages"] as? [String],
                       ["en"])

        select("system", in: languages)
        fire(languages)
        XCTAssertNil(languageDefaults.persistentDomain(forName: languageSuite)?["AppleLanguages"])
    }

    /// 창을 열면 지금 고른 언어가 보여야 한다. **기본값으로** 단추는 언어를 되돌리지 않는다.
    func testStoredLanguageIsShownAndSurvivesReset() {
        InterfaceLanguage.korean.apply(to: languageDefaults)
        panel = makePanel()
        guard let languages = picker(for: InterfaceLanguage.self) else { return XCTFail("화면 언어 고르개가 없다") }
        XCTAssertEqual(languages.selectedItem?.representedObject as? String, "ko")

        guard let reset = allViews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "기본값으로" })
        else { return XCTFail("기본값으로 버튼이 없다") }
        fire(reset)
        XCTAssertEqual(InterfaceLanguage.current(in: languageDefaults.persistentDomain(forName: languageSuite)), .korean)
        XCTAssertEqual(languages.selectedItem?.representedObject as? String, "ko")
    }

    /// 판 번호가 비어 있으면 안 된다 — 문제를 신고할 때 쓰는 값이다.
    func testVersionDisplayIsNotEmpty() {
        XCTAssertFalse(AppVersion.display.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func select(_ raw: String, in picker: NSPopUpButton) {
        guard let index = picker.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == raw
        }) else { return XCTFail("\(raw) 항목이 없다") }
        picker.selectItem(at: index)
    }

    // MARK: 창 밖에서 바뀐 설정

    /// ⌘= · ⌘-가 글자 크기를 바꾸면 열린 설정 창이 따라온다. 안 따라오면 다음에 다른 항목을
    /// 고칠 때 설정 창이 **낡은 크기를 다시 저장한다**(모든 항목을 한 번에 저장한다).
    func testOpenPanelFollowsAChangeMadeElsewhere() throws {
        panel = makePanel()
        let slider = try XCTUnwrap(allViews.compactMap { $0 as? NSSlider }.first)
        XCTAssertEqual(slider.doubleValue, store.current.bodyPointSize)

        store.save(store.current.steppingBodyPointSize(by: 3))
        NotificationCenter.default.post(name: PreferenceStore.didChange, object: nil)
        XCTAssertEqual(slider.doubleValue, store.current.bodyPointSize, "설정 창이 새 값을 싣는다")

        // 그 뒤 다른 항목을 고쳐도 새 크기가 남는다.
        let size = store.current.bodyPointSize
        let check = try XCTUnwrap(allViews.compactMap { $0 as? NSButton }
            .first { $0.title == String(localized: "표 열 맞추기") })
        check.performClick(nil)
        XCTAssertEqual(store.current.bodyPointSize, size)
    }
}
