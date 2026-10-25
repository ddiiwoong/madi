import XCTest

/// 새로 들어간 설정 일곱 개.
///
/// 이 묶음이 노리는 것은 화면이 아니라 **값이 코드 경로에 닿는 모양**이다. 열거형을
/// raw 문자열로 저장하는 결정, 모르는 값이 기본값으로 떨어지는 길, 그리고 파생값
/// (줄 간격 pt, 글 폭 pt, 여백 pt)의 계산이다.
/// (`MarkdownTheme`이 `@MainActor`라 묶음도 그렇게 둔다.)
@MainActor
final class SettingsTests: XCTestCase {

    private func store() -> (PreferenceStore, UserDefaults) {
        // 사용자의 실제 설정을 건드리지 않는다.
        let suite = "madi.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PreferenceStore(defaults: defaults), defaults)
    }

    // MARK: 왕복

    func testEveryNewSettingRoundTrips() {
        let (store, _) = self.store()
        var saved = EditorPreferences.standard
        saved.appearance = .dark
        saved.lineSpacing = .loose
        saved.documentWidth = .narrow
        saved.loadsRemoteImages = true
        saved.printMargin = .wide
        saved.printOrientation = .landscape
        saved.printPaper = .a4
        store.save(saved)

        XCTAssertEqual(store.current, saved)
    }

    /// 첫 실행에는 키가 하나도 없다.
    func testFirstRunUsesDefaults() {
        let (store, _) = self.store()
        XCTAssertEqual(store.current, EditorPreferences.standard)
    }

    /// 원격 이미지는 **기본이 꺼짐이어야 한다.** 이 한 줄이 "문서를 열었을 뿐인데
    /// 바깥으로 요청이 나가지 않는다"는 약속을 지킨다.
    func testRemoteImagesAreOffByDefault() {
        XCTAssertFalse(EditorPreferences.standard.loadsRemoteImages)
        let (store, _) = self.store()
        XCTAssertFalse(store.current.loadsRemoteImages)
    }

    func testResetRestoresEverything() {
        let (store, _) = self.store()
        var saved = EditorPreferences.standard
        saved.appearance = .light
        saved.printPaper = .letter
        saved.loadsRemoteImages = true
        store.save(saved)
        store.reset()
        XCTAssertEqual(store.current, EditorPreferences.standard)
    }

    // MARK: 모르는 값

    /// 열거형을 숫자가 아니라 raw 문자열로 저장하는 이유가 여기 있다 — 모르는 값은
    /// **기본값으로 떨어져야** 하고, 조용히 다른 케이스가 되면 안 된다.
    func testUnknownStoredValueFallsBackToDefault() {
        let (store, defaults) = self.store()
        defaults.set("midnight", forKey: "editor.appearance")
        defaults.set("enormous", forKey: "editor.lineSpacing")
        defaults.set("A3", forKey: "print.paper")

        XCTAssertEqual(store.current.appearance, .system)
        XCTAssertEqual(store.current.lineSpacing, .normal)
        XCTAssertEqual(store.current.printPaper, .system)
    }

    /// 숫자로 저장된 옛 값(순서 색인)도 기본값으로 떨어진다.
    func testNumericLegacyValueFallsBackToDefault() {
        let (store, defaults) = self.store()
        defaults.set(2, forKey: "editor.appearance")
        XCTAssertEqual(store.current.appearance, .system)
    }

    // MARK: 파생값

    /// 줄 간격은 **배율**이다. 고정 pt로 두면 글자를 키울 때 줄이 붙는다.
    func testLineSpacingScalesWithBodySize() {
        var theme = MarkdownTheme()
        theme.bodyPointSize = 20
        theme.lineSpacingScale = EditorPreferences.LineSpacing.tight.scale
        let tight = theme.lineSpacing
        theme.lineSpacingScale = EditorPreferences.LineSpacing.loose.scale
        let loose = theme.lineSpacing

        XCTAssertLessThan(tight, loose)
        XCTAssertEqual(tight, 20 * 0.22, accuracy: 0.001)
        XCTAssertEqual(loose, 20 * 0.70, accuracy: 0.001)
    }

    /// 세 단계가 서로 달라야 한다 — 같은 값이 둘 있으면 설정이 아무 일도 하지 않는다.
    func testThreeLineSpacingStepsAreDistinct() {
        let scales = EditorPreferences.LineSpacing.allCases.map(\.scale)
        XCTAssertEqual(Set(scales).count, scales.count)
        XCTAssertEqual(scales, scales.sorted(), "좁게 < 보통 < 넓게 순서여야 한다")
    }

    /// 글 폭도 본문 크기의 배수다 — 큰 글씨에서 한 줄이 서른 자로 짧아지지 않아야 한다.
    func testDocumentWidthScalesWithBodySize() {
        var theme = MarkdownTheme()
        theme.documentWidthMultiple = EditorPreferences.DocumentWidth.normal.multipleOfBodySize
        theme.bodyPointSize = 15
        let small = theme.maxContentWidth
        theme.bodyPointSize = 30
        let large = theme.maxContentWidth

        XCTAssertNotNil(small)
        XCTAssertEqual(large!, small! * 2, accuracy: 0.001)
    }

    /// `창 너비`는 제한이 없다.
    func testFullWidthHasNoLimit() {
        XCTAssertNil(EditorPreferences.DocumentWidth.full.multipleOfBodySize)
        var theme = MarkdownTheme()
        theme.documentWidthMultiple = nil
        XCTAssertNil(theme.maxContentWidth)
        // 제한이 없으면 창이 아무리 넓어도 기본 여백 그대로다.
        XCTAssertEqual(theme.textInsets(forViewWidth: 4000).width, theme.textInsets.width)
    }

    /// 글이 창보다 좁으면 남는 폭을 반씩 나눠 가운데에 둔다.
    func testNarrowDocumentIsCentredInAWideWindow() {
        var theme = MarkdownTheme()
        theme.bodyPointSize = 15
        theme.documentWidthMultiple = 40        // 600pt
        let insets = theme.textInsets(forViewWidth: 1000)
        XCTAssertEqual(insets.width, 200, accuracy: 0.001)
        // 컨테이너 폭 = 창 - 여백 둘 = 600pt. 그 값이 글 폭이다.
        XCTAssertEqual(1000 - insets.width * 2, theme.maxContentWidth!, accuracy: 0.001)
    }

    /// 창이 글 폭보다 좁으면 기본 여백 아래로 **내려가지 않는다** — 음수 여백은
    /// 글을 창 밖으로 내보낸다.
    func testNarrowWindowKeepsTheBaseInset() {
        var theme = MarkdownTheme()
        theme.bodyPointSize = 15
        theme.documentWidthMultiple = 56        // 840pt
        let insets = theme.textInsets(forViewWidth: 400)
        XCTAssertEqual(insets.width, theme.textInsets.width)
    }

    /// 세 폭 단계가 서로 다르고 넓어지는 순서여야 한다.
    func testThreeWidthStepsAreDistinctAndOrdered() {
        let steps = [EditorPreferences.DocumentWidth.narrow, .normal, .wide]
            .compactMap(\.multipleOfBodySize)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps, steps.sorted())
        XCTAssertEqual(Set(steps).count, 3)
    }

    // MARK: 프린트

    func testThreeMarginStepsAreDistinctAndOrdered() {
        let steps = EditorPreferences.PrintMargin.allCases.map(\.points)
        XCTAssertEqual(steps, steps.sorted())
        XCTAssertEqual(Set(steps).count, steps.count)
    }

    /// 용지 크기는 **세로 기준**이다. 방향은 `NSPrintInfo.orientation`이 따로 주므로,
    /// 가로 크기를 넣으면 두 번 돌아간다.
    func testPaperSizesArePortraitOriented() {
        for paper in EditorPreferences.PrintPaper.allCases {
            guard let size = paper.portraitSize else { continue }
            XCTAssertLessThan(size.width, size.height, "\(paper.rawValue)이 세로 기준이 아니다")
        }
    }

    func testSystemPaperLeavesTheSizeAlone() {
        XCTAssertNil(EditorPreferences.PrintPaper.system.portraitSize)
    }

    /// A4와 Letter의 실제 크기(pt = 1/72인치)다. 여기가 틀리면 여백이 맞아도
    /// 쪽이 잘린다.
    func testKnownPaperSizes() {
        let a4 = EditorPreferences.PrintPaper.a4.portraitSize!
        XCTAssertEqual(a4.width, 595.28, accuracy: 0.01)    // 210mm
        XCTAssertEqual(a4.height, 841.89, accuracy: 0.01)   // 297mm
        let letter = EditorPreferences.PrintPaper.letter.portraitSize!
        XCTAssertEqual(letter.width, 612, accuracy: 0.01)   // 8.5in
        XCTAssertEqual(letter.height, 792, accuracy: 0.01)  // 11in
    }

    // MARK: 라벨

    /// 고르개에 빈 이름이 들어가면 사용자는 무엇을 고르는지 알 수 없다.
    func testEveryChoiceHasALabel() {
        let labels = EditorPreferences.Appearance.allCases.map(\.label)
            + EditorPreferences.LineSpacing.allCases.map(\.label)
            + EditorPreferences.DocumentWidth.allCases.map(\.label)
            + EditorPreferences.PrintMargin.allCases.map(\.label)
            + EditorPreferences.PrintOrientation.allCases.map(\.label)
            + EditorPreferences.PrintPaper.allCases.map(\.label)
        XCTAssertFalse(labels.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }
}

/// 원격 그림 주소 풀기. **https만** 받는다.
final class RemoteImageReferenceTests: XCTestCase {

    func testHTTPSIsAccepted() {
        XCTAssertEqual(ImageReference.remoteURL(for: "https://example.com/a.png")?.absoluteString,
                       "https://example.com/a.png")
    }

    /// 평문 요청은 중간에 있는 누구나 어떤 문서를 열었는지 볼 수 있다. 설정에서
    /// 원격 받기를 켠 사용자도 그것까지 켠 것은 아니다.
    func testPlainHTTPIsRefused() {
        XCTAssertNil(ImageReference.remoteURL(for: "http://example.com/a.png"))
    }

    func testNonNetworkSchemesAreRefused() {
        for raw in ["data:image/png;base64,AAAA", "javascript:alert(1)",
                    "//example.com/a.png", "file:///tmp/a.png", "a.png", ""] {
            XCTAssertNil(ImageReference.remoteURL(for: raw), "거절해야 한다: \(raw)")
        }
    }

    func testAngleBracketsAreUnwrapped() {
        XCTAssertEqual(ImageReference.remoteURL(for: "<https://example.com/a.png>")?.host,
                       "example.com")
    }

    /// 호스트가 없는 주소는 받을 곳이 없다.
    func testHostlessURLIsRefused() {
        XCTAssertNil(ImageReference.remoteURL(for: "https:///a.png"))
    }

    /// 로컬 풀기와 원격 풀기는 **겹치지 않아야 한다** — 하나의 주소가 양쪽으로 풀리면
    /// 어느 쪽이 쓰이는지 호출 순서가 정한다.
    func testLocalAndRemoteResolutionAreDisjoint() {
        let base = URL(fileURLWithPath: "/tmp/doc.md")
        for raw in ["https://example.com/a.png", "a.png", "/tmp/b.png", "~/c.png",
                    "http://example.com/d.png"] {
            let local = ImageReference.localURL(for: raw, relativeTo: base)
            let remote = ImageReference.remoteURL(for: raw)
            XCTAssertFalse(local != nil && remote != nil, "양쪽으로 풀린다: \(raw)")
        }
    }
}
