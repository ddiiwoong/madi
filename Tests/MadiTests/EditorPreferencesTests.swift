import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class EditorPreferencesTests: XCTestCase {

    /// 테스트는 **사용자의 실제 설정을 건드리지 않아야** 한다. 따로 저장소를 만든다.
    /// 디스크에도 쓰지 않는다(`MemoryDefaults`) — 쓴 도메인은 지워도 빈 파일이 남는다.
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = MemoryDefaults()
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    // MARK: 기본값

    func testFirstRunReadsTheStandardValues() {
        // 첫 실행에는 키가 하나도 없다. 그때 빈 값이 아니라 기본값이 나와야 한다.
        XCTAssertEqual(PreferenceStore(defaults: defaults).current, .standard)
    }

    func testStandardValuesAreTheOnesWeDesignedFor() {
        let standard = EditorPreferences.standard
        XCTAssertEqual(standard.bodyPointSize, 15)
        XCTAssertTrue(standard.highlightCode)
        XCTAssertTrue(standard.alignTables)
        XCTAssertTrue(standard.syntheticSlant)
        XCTAssertFalse(standard.openInCodeView, "새 창이 코드 보기로 열리는 것은 기본이 아니다")
    }

    // MARK: 왕복

    func testSavedValuesComeBack() {
        let store = PreferenceStore(defaults: defaults)
        var wanted = EditorPreferences.standard
        wanted.bodyPointSize = 18
        wanted.highlightCode = false
        wanted.alignTables = false
        wanted.syntheticSlant = false
        wanted.openInCodeView = true
        store.save(wanted)
        XCTAssertEqual(PreferenceStore(defaults: defaults).current, wanted)
    }

    func testResetGoesBackToTheStandardValues() {
        let store = PreferenceStore(defaults: defaults)
        var changed = EditorPreferences.standard
        changed.bodyPointSize = 24
        changed.highlightCode = false
        store.save(changed)
        store.reset()
        XCTAssertEqual(store.current, .standard)
    }

    // MARK: 값 가두기

    func testPointSizeIsClampedIntoTheReadableRange() {
        // 저장소에 손으로 쓴 값이나 옛 버전의 값이 들어와도 읽을 수 없는 화면이
        // 되지 않아야 한다.
        XCTAssertEqual(EditorPreferences.clamp(1), EditorPreferences.pointSizeRange.lowerBound)
        XCTAssertEqual(EditorPreferences.clamp(999), EditorPreferences.pointSizeRange.upperBound)
        XCTAssertEqual(EditorPreferences.clamp(15), 15)
    }

    func testNonFiniteSizeFallsBackToTheStandard() {
        // NaN과 무한은 "값이 없다"는 뜻이다. 무한을 최대값으로 가두면 사용자가
        // 고르지도 않은 28pt가 되므로, 둘 다 기본값으로 돌린다.
        XCTAssertEqual(EditorPreferences.clamp(.nan), EditorPreferences.standard.bodyPointSize)
        XCTAssertEqual(EditorPreferences.clamp(.infinity), EditorPreferences.standard.bodyPointSize)
        XCTAssertEqual(EditorPreferences.clamp(-.infinity), EditorPreferences.standard.bodyPointSize)
    }

    func testAnOutOfRangeStoredValueIsClampedOnRead() {
        defaults.set(500.0, forKey: "editor.bodyPointSize")
        XCTAssertEqual(PreferenceStore(defaults: defaults).current.bodyPointSize,
                       EditorPreferences.pointSizeRange.upperBound)
    }

    func testAWrongTypedStoredValueFallsBackInsteadOfCrashing() {
        // 다른 앱이나 옛 버전이 엉뚱한 타입을 써 둘 수 있다.
        defaults.set("열다섯", forKey: "editor.bodyPointSize")
        defaults.set("아니오", forKey: "editor.highlightCode")
        let current = PreferenceStore(defaults: defaults).current
        XCTAssertEqual(current.bodyPointSize, EditorPreferences.standard.bodyPointSize)
        XCTAssertEqual(current.highlightCode, EditorPreferences.standard.highlightCode)
    }

    func testPartiallyStoredSettingsKeepDefaultsForTheRest() {
        defaults.set(20.0, forKey: "editor.bodyPointSize")
        let current = PreferenceStore(defaults: defaults).current
        XCTAssertEqual(current.bodyPointSize, 20)
        XCTAssertEqual(current.alignTables, EditorPreferences.standard.alignTables)
    }

    // MARK: 글자 크기 한 단계 (⌘= · ⌘- · ⌘0)

    func testSteppingMovesOnePointAndStopsAtTheEnds() {
        var preferences = EditorPreferences.standard
        XCTAssertEqual(preferences.steppingBodyPointSize(by: 1).bodyPointSize, 16)
        XCTAssertEqual(preferences.steppingBodyPointSize(by: -1).bodyPointSize, 14)

        preferences.bodyPointSize = EditorPreferences.pointSizeRange.upperBound
        XCTAssertEqual(preferences.steppingBodyPointSize(by: 1).bodyPointSize,
                       EditorPreferences.pointSizeRange.upperBound, "끝에서는 그대로 — 부르는 쪽이 멈춘 것을 안다")
        preferences.bodyPointSize = EditorPreferences.pointSizeRange.lowerBound
        XCTAssertEqual(preferences.steppingBodyPointSize(by: -1).bodyPointSize,
                       EditorPreferences.pointSizeRange.lowerBound)
    }

    func testSteppingRoundsASliderValueFirst() {
        var preferences = EditorPreferences.standard
        preferences.bodyPointSize = 15.4         // 설정 창의 막대는 사이 값을 낼 수 있다
        XCTAssertEqual(preferences.steppingBodyPointSize(by: 1).bodyPointSize, 16)
    }

    func testStandardSizeLeavesOtherSettingsAlone() {
        var preferences = EditorPreferences.standard
        preferences.bodyPointSize = 22
        preferences.highlightCode = false
        let reset = preferences.withStandardBodyPointSize
        XCTAssertEqual(reset.bodyPointSize, EditorPreferences.standard.bodyPointSize)
        XCTAssertFalse(reset.highlightCode)
    }
}
