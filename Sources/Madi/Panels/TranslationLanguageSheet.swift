import AppKit

/// 번역할 언어를 고르는 시트.
///
/// 왜 시트인가: 메뉴 하위 메뉴로 두면 메뉴 바와 버거 메뉴 **두 곳**에 동적 목록을 붙여야
/// 하고(버거 메뉴는 열 때마다 새로 만들어진다), 받아지지 않은 언어를 어떻게 보일지
/// 메뉴에서는 표현할 길이 마땅치 않다. 시트는 한 곳이고, 언어마다 받아져 있는지를
/// 글로 적을 수 있다.
///
/// 목록은 **시스템이 준 것**이다(`AppleTranslator.supportedLanguagesWithKorean`가
/// 만들어 넘긴다 — 이 화면은 번역 엔진을 알지 못한다).
/// 손으로 적으면 OS가 언어를 더해도 마디는 모른다.
@MainActor
final class TranslationLanguageSheet: NSViewController {

    /// 사용자가 고른 방향. 취소하면 불리지 않는다.
    var onTranslate: ((TranslationDirection) -> Void)?

    private let detectedSource: String
    private let initialTarget: String
    private let languages: [TranslationDirection.Language]

    private let directionPicker = NSPopUpButton()
    private let languagePicker = NSPopUpButton()
    private let note = NSTextField(wrappingLabelWithString: "")

    /// 방향은 두 가지뿐이다 — 한국어에서 내보내기, 한국어로 가져오기. 임의의 두 언어
    /// 사이(예: 영어→일본어)는 Apple이 지원하더라도 **마디가 다루지 않는다**: 한국어
    /// 사용자의 문서 도구이고, 양쪽을 다 고르게 하면 고를 것이 두 배가 되면서
    /// 쓰이지 않는 조합이 대부분을 차지한다.
    private enum Flow: Int {
        case fromKorean = 0      // 한국어 → 고른 언어
        case toKorean = 1        // 고른 언어 → 한국어
    }

    init(detectedSource: String, initialTarget: String,
         languages: [TranslationDirection.Language]) {
        self.detectedSource = detectedSource
        self.initialTarget = initialTarget
        self.languages = languages
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let heading = NSTextField(labelWithString: String(localized: "번역 언어"))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        directionPicker.addItem(withTitle: String(localized: "한국어 → 다른 언어"))
        directionPicker.addItem(withTitle: String(localized: "다른 언어 → 한국어"))
        directionPicker.target = self
        directionPicker.action = #selector(flowChanged)
        // 글에서 짐작한 원문이 한국어가 아니면 '가져오기'가 하려던 일이다.
        directionPicker.selectItem(at: detectedSource == "ko" ? Flow.fromKorean.rawValue
                                                              : Flow.toKorean.rawValue)

        for language in languages {
            languagePicker.addItem(withTitle: title(for: language))
            languagePicker.lastItem?.representedObject = language.code
        }
        languagePicker.target = self
        languagePicker.action = #selector(flowChanged)
        select(code: detectedSource == "ko" ? initialTarget : detectedSource)

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let translate = NSButton(title: String(localized: "번역"), target: self, action: #selector(translate))
        translate.keyEquivalent = "\r"
        let cancel = NSButton(title: String(localized: "취소"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancel, translate])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [heading, directionPicker, languagePicker, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            directionPicker.widthAnchor.constraint(greaterThanOrEqualTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        preferredContentSize = NSSize(width: 380, height: 210)
        updateNote()
    }

    /// 목록의 항목 글. 받아지지 않은 언어도 **남긴다** — 고를 수 있어야 그 언어의
    /// 안내(받는 길)를 볼 수 있고, 목록에서 아예 빠지면 왜 없는지 알 수 없다.
    private func title(for language: TranslationDirection.Language) -> String {
        language.isInstalled ? language.name : String(localized: "\(language.name) (받아야 함)")
    }

    private func select(code: String) {
        let index = languagePicker.itemArray.firstIndex {
            ($0.representedObject as? String) == code
        }
        languagePicker.selectItem(at: index ?? 0)
    }

    private var chosenCode: String {
        (languagePicker.selectedItem?.representedObject as? String) ?? "en"
    }

    private var flow: Flow {
        Flow(rawValue: directionPicker.indexOfSelectedItem) ?? .fromKorean
    }

    var direction: TranslationDirection {
        flow == .fromKorean
            ? TranslationDirection(source: "ko", target: chosenCode)
            : TranslationDirection(source: chosenCode, target: "ko")
    }

    /// 지금 고른 조합이 바로 되는지 글로 말한다. 번역을 눌러 경고를 받기 **전에**
    /// 알 수 있어야 한다.
    private func updateNote() {
        let code = chosenCode
        guard let language = languages.first(where: { $0.code == code }) else {
            note.stringValue = ""
            return
        }
        let ready = flow == .fromKorean ? language.outboundInstalled : language.inboundInstalled
        note.stringValue = ready
            ? String(localized: "\(direction.label) — 바로 번역할 수 있습니다.")
            : String(localized: """
              \(direction.label) — 이 언어는 아직 받아져 있지 않습니다. \
              번역을 누르면 받는 길을 알려 드립니다.
              """)
    }

    @objc private func flowChanged() { updateNote() }

    @objc private func translate() {
        let chosen = direction
        dismiss(self)
        onTranslate?(chosen)
    }

    @objc private func cancel() { dismiss(self) }
}
