import AppKit
import XCTest

/// 언어 고르개가 **어느 방향을 조립하는가**.
///
/// 이 화면의 일은 "방향 두 가지 × 고른 언어"를 하나의 `TranslationDirection`으로 만드는
/// 것이고, 그것이 틀리면 사용자가 고른 것과 다른 언어로 번역된다. 화면을 그리는 것은
/// 눈으로 봤고(시트가 뜨고 짐작한 원문·기본 대상·바로 되는지가 보인다), 여기서는 그
/// 조립을 못박는다.
///
/// 창은 띄우지 않는다 — `loadView`만 불러 컨트롤을 세운다.
@MainActor
final class TranslationLanguageSheetTests: XCTestCase {

    private let languages = [
        TranslationDirection.Language(code: "en", name: "영어",
                                      outboundInstalled: true, inboundInstalled: true),
        TranslationDirection.Language(code: "ja", name: "일본어",
                                      outboundInstalled: true, inboundInstalled: false),
        TranslationDirection.Language(code: "de", name: "독일어",
                                      outboundInstalled: false, inboundInstalled: false),
    ]

    private func sheet(detected: String, target: String = "en") -> TranslationLanguageSheet {
        let sheet = TranslationLanguageSheet(detectedSource: detected,
                                             initialTarget: target,
                                             languages: languages)
        _ = sheet.view          // loadView를 돈다
        return sheet
    }

    /// 짐작한 원문이 한국어면 '내보내기'가 기본이고, 대상은 기억해 둔 언어다.
    func testKoreanSourceDefaultsToExportingWithTheRememberedTarget() {
        XCTAssertEqual(sheet(detected: "ko", target: "ja").direction,
                       TranslationDirection(source: "ko", target: "ja"))
    }

    /// 짐작한 원문이 한국어가 **아니면** '가져오기'가 기본이고, 고른 언어는 그 원문이다.
    /// 영어 문서를 열고 이 화면을 띄웠을 때 하려던 일이 그것이다.
    func testNonKoreanSourceDefaultsToImportingThatLanguage() {
        XCTAssertEqual(sheet(detected: "ja").direction,
                       TranslationDirection(source: "ja", target: "ko"))
    }

    /// 짐작한 원문이 목록에 없으면(지원되지 않는 언어) 첫 항목으로 떨어진다 —
    /// 빈 선택으로 두면 번역 버튼이 무엇을 할지 알 수 없다.
    func testUnknownDetectedLanguageFallsBackToTheFirstItem() {
        let direction = sheet(detected: "xx").direction
        XCTAssertEqual(direction.target, "ko", "모르는 원문은 가져오기로 본다")
        XCTAssertFalse(direction.source.isEmpty)
        XCTAssertTrue(languages.map(\.code).contains(direction.source))
    }

    /// 받아지지 않은 언어도 **목록에 남는다.** 빠지면 왜 없는지 알 수 없고, 고를 수
    /// 있어야 번역을 눌러 받는 길을 볼 수 있다.
    func testNotInstalledLanguagesStayInTheList() {
        let popups = allPopups(in: sheet(detected: "ko").view)
        guard let languagePicker = popups.last else { return XCTFail("고르개가 없다") }
        let titles = languagePicker.itemArray.map(\.title)
        XCTAssertEqual(languagePicker.numberOfItems, languages.count)
        XCTAssertTrue(titles.contains { $0.contains("독일어") }, "실제 \(titles)")
        XCTAssertTrue(titles.contains { $0.contains("받아야 함") },
                      "받아야 하는 언어임을 글로 보여야 한다 — 실제 \(titles)")
    }

    /// 받아져 있는 언어에는 그 꼬리말이 붙지 않는다 — 붙으면 전부 받아야 하는 것처럼 읽힌다.
    func testInstalledLanguagesHaveNoSuffix() {
        let popups = allPopups(in: sheet(detected: "ko").view)
        guard let languagePicker = popups.last else { return XCTFail("고르개가 없다") }
        let english = languagePicker.itemArray.first { $0.title.contains("영어") }
        XCTAssertEqual(english?.title, "영어")
    }

    /// 번역 버튼을 누르면 고른 방향이 그대로 넘어간다.
    ///
    /// 시트를 **띄운 뒤에** 누른다 — 버튼 처리가 `dismiss(self)`를 지나고, 띄우지 않은
    /// 컨트롤러를 닫으면 AppKit이 항의한다(처음에 그렇게 썼다가 테스트가 잡았다).
    /// 창은 화면 밖에 둔다.
    func testTranslateHandsOverTheChosenDirection() {
        let sheet = self.sheet(detected: "ko", target: "ja")
        var received: TranslationDirection?
        sheet.onTranslate = { received = $0 }
        let host = present(sheet)
        defer { host.orderOut(nil) }

        guard let button = allButtons(in: sheet.view).first(where: { $0.title == "번역" }),
              let action = button.action else { return XCTFail("번역 버튼이 없다") }
        _ = NSApp.sendAction(action, to: button.target, from: button)

        XCTAssertEqual(received, TranslationDirection(source: "ko", target: "ja"))
    }

    /// 취소는 아무것도 넘기지 않는다.
    func testCancelHandsOverNothing() {
        let sheet = self.sheet(detected: "ko")
        var received: TranslationDirection?
        sheet.onTranslate = { received = $0 }
        let host = present(sheet)
        defer { host.orderOut(nil) }

        guard let button = allButtons(in: sheet.view).first(where: { $0.title == "취소" }),
              let action = button.action else { return XCTFail("취소 버튼이 없다") }
        _ = NSApp.sendAction(action, to: button.target, from: button)

        XCTAssertNil(received)
    }

    /// 화면 밖 창에 주인 컨트롤러를 두고 시트로 띄운다.
    private func present(_ sheet: NSViewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSViewController()
        host.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentViewController = host
        window.orderBack(nil)
        host.presentAsSheet(sheet)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return window
    }

    // MARK: 화면 뒤지기

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func allPopups(in view: NSView) -> [NSPopUpButton] {
        descendants(of: view).compactMap { $0 as? NSPopUpButton }
    }

    private func allButtons(in view: NSView) -> [NSButton] {
        descendants(of: view).compactMap { $0 as? NSButton }
            .filter { !($0 is NSPopUpButton) }
    }
}
