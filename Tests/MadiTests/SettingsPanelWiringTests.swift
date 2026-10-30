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

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "madi.tests.\(UUID().uuidString)")!
        store = PreferenceStore(defaults: defaults)
        panel = SettingsPanel(store: store)
    }

    override func tearDown() {
        panel = nil
        store = nil
        defaults = nil
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

    func testFourTabsExist() {
        guard let tabs = tabView else { return XCTFail("NSTabView가 없다") }
        XCTAssertEqual(tabs.tabViewItems.map(\.label),
                       ["보기", "일반", "PDF·프린트", "정보"])
    }

    /// 고르개가 비어 있으면 사용자가 고를 것이 없다.
    func testEveryPickerIsPopulated() {
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

        let reopened = SettingsPanel(store: store)
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
        let reopened = SettingsPanel(store: store)
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

    private func fontPicker(system title: String) -> NSPopUpButton? {
        allViews.compactMap { $0 as? NSPopUpButton }.first { $0.itemArray.first?.title == title }
    }

    /// 두 고르개가 있고, 맨 위가 시스템이며, 이 Mac의 글꼴이 실려 있다.
    func testFontPickersListInstalledFamilies() {
        guard let body = fontPicker(system: "시스템 글꼴"),
              let code = fontPicker(system: "시스템 고정폭") else { return XCTFail("글꼴 고르개가 없다") }
        let bodyFamilies = body.itemArray.compactMap { $0.representedObject as? String }.filter { !$0.isEmpty }
        let codeFamilies = code.itemArray.compactMap { $0.representedObject as? String }.filter { !$0.isEmpty }
        XCTAssertTrue(bodyFamilies.contains("Helvetica"), "macOS에 늘 있는 글꼴이 빠졌다")
        XCTAssertTrue(codeFamilies.contains("Menlo"), "macOS에 늘 있는 고정폭이 빠졌다")
        XCTAssertGreaterThan(bodyFamilies.count, codeFamilies.count)
    }

    /// 코드 고르개에는 고정폭만 있다 — 하나라도 아니면 코드의 들여쓰기가 어긋난다.
    func testCodeFontPickerOffersOnlyFixedPitch() {
        guard let code = fontPicker(system: "시스템 고정폭") else { return XCTFail("코드 글꼴 고르개가 없다") }
        let families = code.itemArray.compactMap { $0.representedObject as? String }.filter { !$0.isEmpty }
        XCTAssertFalse(families.contains("Helvetica"))
        for family in families {
            XCTAssertEqual(NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?
                .isFixedPitch, true, family)
        }
    }

    func testChoosingFontsReachesTheStoreAndSystemClearsIt() {
        guard let body = fontPicker(system: "시스템 글꼴"),
              let code = fontPicker(system: "시스템 고정폭") else { return XCTFail("글꼴 고르개가 없다") }
        XCTAssertNotNil(body.action)
        XCTAssertNotNil(code.action)
        select("Helvetica", in: body)
        select("Menlo", in: code)
        fire(body)
        XCTAssertEqual(store.current.bodyFontFamily, "Helvetica")
        XCTAssertEqual(store.current.codeFontFamily, "Menlo")

        body.selectItem(at: 0)
        fire(body)
        XCTAssertNil(store.current.bodyFontFamily, "시스템을 고르면 지운다")
        XCTAssertNil(defaults.object(forKey: "editor.bodyFontFamily"), "빈 값을 남기지 않는다")
    }

    /// 이 Mac에 없는 글꼴이 저장돼 있으면 시스템을 고른 것처럼 보이지 않는다.
    func testMissingStoredFontIsShownByName() {
        var saved = EditorPreferences.standard
        saved.bodyFontFamily = "Nonexistent Font Family 123"
        store.save(saved)
        panel = SettingsPanel(store: store)
        let selected = fontPicker(system: "시스템 글꼴")?.selectedItem
        XCTAssertEqual(selected?.representedObject as? String, "Nonexistent Font Family 123")
        XCTAssertTrue(selected?.title.contains("이 Mac에 없음") == true, selected?.title ?? "")
    }

    /// 다른 설정을 바꿔도 번역 대상 언어를 잃지 않는다.
    ///
    /// 전에는 `changed()`가 설정을 새로 지으면서 이 값을 넘기지 않아, 체크박스 하나만 눌러도
    /// 고른 번역 언어가 영어로 돌아갔다(번역 언어 선택 시트가 기억해 둔 값이다).
    func testChangingAnotherSettingKeepsTheTranslationTarget() {
        var saved = EditorPreferences.standard
        saved.translationTarget = "ja"
        store.save(saved)
        panel = SettingsPanel(store: store)
        guard let check = checkbox("표 열 맞추기") else { return XCTFail("체크박스가 없다") }
        check.state = .off
        fire(check)
        XCTAssertEqual(store.current.translationTarget, "ja")
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
}
