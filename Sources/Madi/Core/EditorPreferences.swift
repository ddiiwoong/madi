import Foundation

/// 편집기 설정.
///
/// **쓰이지 않는 설정은 넣지 않는다.** 설정 화면에 켜고 끌 수 있는 것이 있는데 아무
/// 일도 일어나지 않으면, 사용자는 자기가 무엇을 잘못했는지 찾느라 시간을 버린다.
/// 아래 전부가 실제 코드 경로에 붙어 있다:
///
/// - `bodyPointSize` → `MarkdownTheme`의 모든 글꼴 크기가 여기서 나온다
/// - `highlightCode` → `MarkdownStyler.highlightCode` 패스
/// - `alignTables` → `MarkdownStyler.alignTables` 패스
/// - `syntheticSlant` → CJK 강제 기울임
/// - `openInCodeView` → 새로 연 창의 코드 보기 초깃값
/// - `appearance` → `NSApp.appearance`
/// - `lineSpacing` → `MarkdownTheme.lineSpacing`
/// - `documentWidth` → 텍스트 컨테이너 가로 여백(그림 폭 맞춤과 표 열 맞추기가 따라온다)
/// - `loadsRemoteImages` → `InlineImageStore`의 원격 받기
/// - `printMargin` · `printOrientation` · `printPaper` → `NSPrintInfo`(프린트와 PDF 둘 다)
/// - `bodyFontFamily` · `codeFontFamily` → `MarkdownTheme`의 본문·제목·코드 글꼴
/// - `checksForUpdates` → 켤 때 하루 한 번 새 판 확인(`UpdateController.checkAtLaunchIfDue`)
public struct EditorPreferences: Equatable, Sendable {

    /// 화면 모양. 마디의 색은 거의 다 의미색이라 시스템을 저절로 따르는데, 그래서
    /// **고정할 수가 없었다** — 시스템이 다크인데 문서만 라이트로 보려는 경우가 막힌다.
    public enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark

        public var label: String {
            switch self {
            case .system: return String(localized: "시스템")
            case .light: return String(localized: "라이트")
            case .dark: return String(localized: "다크")
            }
        }
    }

    /// 문서 색 묶음. 테마마다 라이트·다크 두 벌이 있고, 화면 모양(`Appearance`)이 그중 하나를 고른다.
    /// 색 값은 그리는 쪽에 있다(`ThemePalette`) — 여기는 무엇을 골랐는지만 안다.
    public enum ColorTheme: String, CaseIterable, Sendable {
        /// 시스템 색. 테마를 고르기 전의 모양 그대로다.
        case standard
        /// Notion 페이지의 색 — 흰 바탕(다크는 #191919)에 따뜻한 먹색 글, 링크는 글 색에 밑줄, 인용 막대도 글 색.
        case notion
        /// Confluence 페이지의 색 — Atlassian 디자인 토큰(2025년에 바뀐 판)의 글 · 링크 · 회색 바탕.
        case confluence
        /// GitHub 문서와 같은 색. 올렸을 때의 모양으로 본다.
        case github
        /// Obsidian 기본 테마의 색 — 보라 강조색의 링크와 인용 막대, 다크는 #1E1E1E.
        case obsidian
        /// 따뜻한 미색 바탕에 짙은 갈색 글 — 긴 원고를 읽기 편하다.
        case paper
        /// Solarized 색 조합. 글자 대비를 4.5 : 1 위로 맞추려고 강조색을 조금 진하게(다크는 밝게) 했다.
        case solarized
        /// 흰 바탕에 검은 글(다크는 반대). 밝은 곳이나 눈이 피로할 때.
        case highContrast

        /// 고르개 · 메뉴의 차례가 이 선언 차례다. 저장하는 값은 raw 문자열이라 차례를 바꿔도 고른 테마는 그대로다.
        public var label: String {
            switch self {
            case .standard: return String(localized: "theme.standard", defaultValue: "기본")
            case .notion: return "Notion"
            case .confluence: return "Confluence"
            case .github: return "GitHub"
            case .obsidian: return "Obsidian"
            case .paper: return String(localized: "종이")
            case .solarized: return "Solarized"
            case .highContrast: return String(localized: "고대비")
            }
        }
    }

    /// 줄 간격 — 본문 크기에 대한 배율이다. 고정 pt로 두면 글자를 키울 때 줄이 붙는다.
    public enum LineSpacing: String, CaseIterable, Sendable {
        case tight, normal, loose

        public var scale: Double {
            switch self {
            case .tight: return 0.22
            case .normal: return 0.42
            case .loose: return 0.70
            }
        }

        /// 좁게·넓게는 **따로 키를 둔다.** 한국어로는 글 넓이·여백과 같은 낱말이지만
        /// 영어로는 다르다(줄 간격은 Tight·Loose, 폭은 Narrow·Wide). 키 하나는 번역도
        /// 하나뿐이라, 같은 키를 쓰면 어느 한쪽이 틀린 말이 된다.
        public var label: String {
            switch self {
            case .tight: return String(localized: "lineSpacing.tight", defaultValue: "좁게")
            case .normal: return String(localized: "보통")
            case .loose: return String(localized: "lineSpacing.loose", defaultValue: "넓게")
            }
        }
    }

    /// 글 넓이. 창을 넓히면 한 줄이 끝까지 길어져 읽기 나쁘므로 글의 최대 폭을 둔다.
    ///
    /// 값은 **본문 글자 크기의 배수**다. 글자를 키우면 한 줄에 들어가는 글자 수가
    /// 비슷하게 유지되어야 하므로, 고정 pt로 두면 큰 글씨에서 줄이 너무 짧아진다.
    /// `nil`은 제한 없음(창 너비를 다 쓴다).
    public enum DocumentWidth: String, CaseIterable, Sendable {
        case narrow, normal, wide, full

        /// 본문 크기 1pt당 몇 pt를 글에 줄 것인가. 보통(normal)의 56배는 15pt에서
        /// 840pt이고, 그 폭에 한 줄 70~80자가 들어간다 — 읽기에 권하는 길이다.
        public var multipleOfBodySize: Double? {
            switch self {
            case .narrow: return 42
            case .normal: return 56
            case .wide: return 76
            case .full: return nil
            }
        }

        public var label: String {
            switch self {
            case .narrow: return String(localized: "좁게")
            case .normal: return String(localized: "보통")
            case .wide: return String(localized: "넓게")
            case .full: return String(localized: "창 너비")
            }
        }
    }

    /// PDF·프린트 여백.
    public enum PrintMargin: String, CaseIterable, Sendable {
        case narrow, normal, wide

        public var points: Double {
            switch self {
            case .narrow: return 24
            case .normal: return 48
            case .wide: return 84
            }
        }

        public var label: String {
            switch self {
            case .narrow: return String(localized: "좁게")
            case .normal: return String(localized: "보통")
            case .wide: return String(localized: "넓게")
            }
        }
    }

    public enum PrintOrientation: String, CaseIterable, Sendable {
        case portrait, landscape

        public var label: String {
            switch self {
            case .portrait: return String(localized: "세로")
            case .landscape: return String(localized: "가로")
            }
        }
    }

    /// 용지. 크기는 pt(1/72인치)다. `system`은 시스템 프린트 설정의 용지를 그대로 쓴다 —
    /// 사용자가 프린트 대화상자에서 고른 것이 있으면 그것을 덮지 않는 것이 맞다.
    public enum PrintPaper: String, CaseIterable, Sendable {
        case system, a4, letter

        /// 폭 × 높이, 세로 방향 기준. `nil`이면 시스템 설정을 그대로 둔다.
        public var portraitSize: (width: Double, height: Double)? {
            switch self {
            case .system: return nil
            case .a4: return (595.28, 841.89)      // 210 × 297 mm
            case .letter: return (612, 792)        // 8.5 × 11 in
            }
        }

        public var label: String {
            switch self {
            case .system: return String(localized: "시스템 기본")
            case .a4: return "A4"
            case .letter: return "Letter"
            }
        }
    }

    /// 본문 글자 크기. 제목·고정폭 크기도 여기서 파생된다.
    public var bodyPointSize: Double
    public var highlightCode: Bool
    public var alignTables: Bool
    public var syntheticSlant: Bool
    public var openInCodeView: Bool
    public var appearance: Appearance
    /// 문서 색 테마. 화면 모양과 따로 고른다 — 테마마다 라이트·다크가 있다. 프린트·PDF는 테마와 상관없이
    /// 흰 종이에 기본 색이다.
    public var colorTheme: ColorTheme
    public var lineSpacing: LineSpacing
    public var documentWidth: DocumentWidth
    /// 원격 그림을 받아올지. **기본이 꺼짐이고 그래야 한다** — 문서를 열었을 뿐인데
    /// 바깥으로 요청이 나가는 것은 사용자가 시킨 일이 아니고, 문서에 적힌 주소가
    /// 추적용일 수 있다. 켜는 경우에도 `https`만 받는다.
    public var loadsRemoteImages: Bool
    /// 켤 때 하루 한 번 GitHub에 새 판이 있는지 묻는다. 기본은 켜짐(2026-11-09, 사용자가 골랐다) — 원격 그림과
    /// 달리 문서가 시킨 요청이 아니고, 보내는 것은 판을 묻는 GET 하나다. 설정 ▸ 일반에서 끈다.
    public var checksForUpdates: Bool
    public var printMargin: PrintMargin
    public var printOrientation: PrintOrientation
    public var printPaper: PrintPaper
    /// 한국어 문서를 내보낼 때의 대상 언어(BCP-47 기본 코드). 사용자가 메뉴에서 고른
    /// 것을 기억한다 — 한 문서를 여러 번 번역하는 동안 매번 다시 고르게 하면 안 된다.
    /// 원문이 한국어가 **아닐** 때는 대상이 늘 한국어이므로 이 값이 쓰이지 않는다.
    public var translationTarget: String
    /// 본문 글꼴의 패밀리 이름(`NSFontManager`의 이름, 예: `Helvetica Neue`). `nil`이면 시스템
    /// 글꼴이다. 기본값은 앱에 들어 있는 Pretendard다. 이 Mac에 없는 이름이면 그리는 쪽이
    /// 시스템 글꼴로 떨어진다 — 설정을 다른 Mac으로 옮겨도 화면이 깨지지 않는다.
    public var bodyFontFamily: String?
    /// 코드 글꼴의 패밀리 이름. `nil`이면 시스템 고정폭이다. 기본값은 앱에 들어 있는
    /// IBM Plex Mono다. **고정폭만** 받는다 — 그리는 쪽이 고정폭이 아닌 이름을 시스템
    /// 고정폭으로 바꾼다(코드의 들여쓰기와 열이 맞아야 한다).
    public var codeFontFamily: String?
    /// 제목(h1~h6, `===`·`---` 밑줄 꼴 포함)의 글꼴. 기본은 본문과 같다. 다르게 고르면 제목에만
    /// 쓰이고 목록 표지·코드·표는 그대로다.
    public var headingFont: HeadingFont

    /// 제목 글꼴을 고르는 세 길.
    public enum HeadingFont: Equatable, Sendable {
        /// 본문 글꼴을 따른다 — 본문을 바꾸면 제목도 바뀐다.
        case sameAsBody
        /// 시스템 글꼴.
        case system
        /// 이 패밀리(`NSFontManager`의 이름).
        case family(String)

        /// 공백뿐인 이름은 시스템이다 — 본문·코드 글꼴과 같은 규칙.
        static func normalized(_ value: HeadingFont) -> HeadingFont {
            guard case let .family(name) = value else { return value }
            return EditorPreferences.family(name).map(HeadingFont.family) ?? .system
        }
    }

    /// 제목을 그릴 패밀리. `nil`이면 시스템 글꼴이다.
    public var headingFontFamily: String? {
        switch headingFont {
        case .sameAsBody: bodyFontFamily
        case .system: nil
        case let .family(name): name
        }
    }

    /// 앱에 들어 있는 글꼴(`Resources/Fonts`). 어느 Mac에서도 같은 모양이 나오고, 시스템
    /// 글꼴보다 한글 본문이 읽기 좋아 기본값으로 쓴다.
    public static let bundledBodyFamily = "Pretendard"
    public static let bundledCodeFamily = "IBM Plex Mono"

    /// 글자 크기의 허용 범위. 너무 작으면 한글이 뭉개지고, 너무 크면 표 열 맞추기가
    /// 한 줄에 들어가지 않는다.
    public static let pointSizeRange: ClosedRange<Double> = 10 ... 28

    public static let standard = EditorPreferences(
        bodyPointSize: 15,
        highlightCode: true,
        alignTables: true,
        syntheticSlant: true,
        openInCodeView: false,
        appearance: .system,
        lineSpacing: .normal,
        documentWidth: .normal,
        loadsRemoteImages: false,
        printMargin: .normal,
        printOrientation: .portrait,
        printPaper: .system,
        translationTarget: "en",
        bodyFontFamily: bundledBodyFamily,
        codeFontFamily: bundledCodeFamily
    )

    public init(bodyPointSize: Double, highlightCode: Bool, alignTables: Bool,
                syntheticSlant: Bool, openInCodeView: Bool,
                appearance: Appearance = .system,
                lineSpacing: LineSpacing = .normal,
                documentWidth: DocumentWidth = .normal,
                loadsRemoteImages: Bool = false,
                printMargin: PrintMargin = .normal,
                printOrientation: PrintOrientation = .portrait,
                printPaper: PrintPaper = .system,
                translationTarget: String = "en",
                bodyFontFamily: String? = nil,
                codeFontFamily: String? = nil,
                headingFont: HeadingFont = .sameAsBody,
                colorTheme: ColorTheme = .standard,
                checksForUpdates: Bool = true) {
        self.bodyPointSize = Self.clamp(bodyPointSize)
        self.checksForUpdates = checksForUpdates
        self.colorTheme = colorTheme
        self.highlightCode = highlightCode
        self.alignTables = alignTables
        self.syntheticSlant = syntheticSlant
        self.openInCodeView = openInCodeView
        self.appearance = appearance
        self.lineSpacing = lineSpacing
        self.documentWidth = documentWidth
        self.loadsRemoteImages = loadsRemoteImages
        self.printMargin = printMargin
        self.printOrientation = printOrientation
        self.printPaper = printPaper
        // 빈 값이나 공백이 저장소에 들어와도 읽을 수 있는 상태를 지킨다.
        let trimmed = translationTarget.trimmingCharacters(in: .whitespaces)
        self.translationTarget = trimmed.isEmpty ? "en" : trimmed
        self.bodyFontFamily = Self.family(bodyFontFamily)
        self.codeFontFamily = Self.family(codeFontFamily)
        self.headingFont = HeadingFont.normalized(headingFont)
    }

    /// 빈 이름과 공백뿐인 이름은 '시스템'(`nil`)이다 — 저장소에 손으로 쓴 빈 값이 이름 없는
    /// 글꼴을 찾게 하지 않는다.
    static func family(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 글자 크기 한 단계(⌘= · ⌘-). 설정 창의 막대 눈금과 같은 1pt다.
    public static let pointSizeStep: Double = 1

    /// 글자 크기를 `steps` 단계 바꾼 설정. 범위 끝에서는 그대로다 — 부르는 쪽이 같은 값을
    /// 받으면 더 갈 수 없다는 뜻이다. 설정 창의 막대로 고른 15.4pt 같은 값은 먼저 반올림한다.
    public func steppingBodyPointSize(by steps: Int) -> EditorPreferences {
        var next = self
        next.bodyPointSize = Self.clamp(bodyPointSize.rounded() + Double(steps) * Self.pointSizeStep)
        return next
    }

    /// 글자 크기만 기본값으로(⌘0). 다른 설정은 건드리지 않는다.
    public var withStandardBodyPointSize: EditorPreferences {
        var next = self
        next.bodyPointSize = Self.standard.bodyPointSize
        return next
    }

    /// 범위를 벗어난 값을 가둔다. 저장소에 손으로 쓴 값이나 옛 버전의 값이 들어와도
    /// 읽을 수 없는 화면이 되지 않아야 한다.
    public static func clamp(_ size: Double) -> Double {
        guard size.isFinite else { return standard.bodyPointSize }
        return min(max(size, pointSizeRange.lowerBound), pointSizeRange.upperBound)
    }
}

/// 설정을 `UserDefaults`에 넣고 꺼낸다.
///
/// 저장소를 주입받는다 — 테스트가 사용자의 실제 설정을 건드리지 않고 돌 수 있어야 한다.
public final class PreferenceStore {

    /// 설정이 바뀌었음을 알린다. 열려 있는 창들이 받아 다시 칠한다.
    public static let didChange = Notification.Name("MdEditorPreferencesDidChange")

    private enum Key {
        static let bodyPointSize = "editor.bodyPointSize"
        static let highlightCode = "editor.highlightCode"
        static let alignTables = "editor.alignTables"
        static let syntheticSlant = "editor.syntheticSlant"
        static let openInCodeView = "editor.openInCodeView"
        static let appearance = "editor.appearance"
        static let lineSpacing = "editor.lineSpacing"
        static let documentWidth = "editor.documentWidth"
        static let loadsRemoteImages = "editor.loadsRemoteImages"
        static let printMargin = "print.margin"
        static let printOrientation = "print.orientation"
        static let printPaper = "print.paper"
        static let translationTarget = "translation.target"
        static let bodyFontFamily = "editor.bodyFontFamily"
        static let codeFontFamily = "editor.codeFontFamily"
        /// 없으면 본문과 같음, 빈 값이면 시스템, 이름이면 그 패밀리.
        static let headingFontFamily = "editor.headingFontFamily"
        static let colorTheme = "editor.colorTheme"
        static let checksForUpdates = "update.checkAtLaunch"

        static let all = [bodyPointSize, highlightCode, alignTables, syntheticSlant,
                          openInCodeView, appearance, lineSpacing, documentWidth,
                          loadsRemoteImages, printMargin, printOrientation, printPaper,
                          translationTarget, bodyFontFamily, codeFontFamily, headingFontFamily,
                          colorTheme, checksForUpdates]
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 저장된 설정. 키가 없으면 기본값을 쓴다 — 첫 실행에서 모든 키가 없다.
    ///
    /// 열거형은 raw 문자열로 저장한다. 숫자로 저장하면 나중에 케이스 순서를 바꾸는
    /// 순간 사용자의 설정이 **조용히 다른 값으로** 바뀐다. 모르는 문자열(옛 버전이
    /// 쓴 값, 손으로 고친 값)은 기본값으로 떨어진다.
    public var current: EditorPreferences {
        let standard = EditorPreferences.standard
        func value<T: RawRepresentable>(_ key: String, _ fallback: T) -> T
        where T.RawValue == String {
            guard let raw = defaults.string(forKey: key), let parsed = T(rawValue: raw)
            else { return fallback }
            return parsed
        }
        return EditorPreferences(
            bodyPointSize: defaults.object(forKey: Key.bodyPointSize) as? Double
                ?? standard.bodyPointSize,
            highlightCode: defaults.object(forKey: Key.highlightCode) as? Bool
                ?? standard.highlightCode,
            alignTables: defaults.object(forKey: Key.alignTables) as? Bool
                ?? standard.alignTables,
            syntheticSlant: defaults.object(forKey: Key.syntheticSlant) as? Bool
                ?? standard.syntheticSlant,
            openInCodeView: defaults.object(forKey: Key.openInCodeView) as? Bool
                ?? standard.openInCodeView,
            appearance: value(Key.appearance, standard.appearance),
            lineSpacing: value(Key.lineSpacing, standard.lineSpacing),
            documentWidth: value(Key.documentWidth, standard.documentWidth),
            loadsRemoteImages: defaults.object(forKey: Key.loadsRemoteImages) as? Bool
                ?? standard.loadsRemoteImages,
            printMargin: value(Key.printMargin, standard.printMargin),
            printOrientation: value(Key.printOrientation, standard.printOrientation),
            printPaper: value(Key.printPaper, standard.printPaper),
            translationTarget: defaults.string(forKey: Key.translationTarget)
                ?? standard.translationTarget,
            bodyFontFamily: family(Key.bodyFontFamily, standard.bodyFontFamily),
            codeFontFamily: family(Key.codeFontFamily, standard.codeFontFamily),
            headingFont: headingFont(),
            colorTheme: value(Key.colorTheme, standard.colorTheme),
            checksForUpdates: defaults.object(forKey: Key.checksForUpdates) as? Bool
                ?? standard.checksForUpdates
        )
    }

    /// 키가 **없으면** 기본값(앱에 든 글꼴), 빈 값이면 시스템 글꼴(`nil`)이다. 둘을 갈라야
    /// '시스템 글꼴을 골랐다'와 '아직 고른 적이 없다'가 다르게 읽힌다.
    private func family(_ key: String, _ fallback: String?) -> String? {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return EditorPreferences.family(defaults.string(forKey: key))
    }

    private func headingFont() -> EditorPreferences.HeadingFont {
        guard let raw = defaults.string(forKey: Key.headingFontFamily) else { return .sameAsBody }
        return EditorPreferences.family(raw).map(EditorPreferences.HeadingFont.family) ?? .system
    }

    /// 저장한다. 값은 `EditorPreferences`의 이니셜라이저가 이미 가둬 둔 것이다.
    public func save(_ preferences: EditorPreferences) {
        defaults.set(preferences.bodyPointSize, forKey: Key.bodyPointSize)
        defaults.set(preferences.highlightCode, forKey: Key.highlightCode)
        defaults.set(preferences.alignTables, forKey: Key.alignTables)
        defaults.set(preferences.syntheticSlant, forKey: Key.syntheticSlant)
        defaults.set(preferences.openInCodeView, forKey: Key.openInCodeView)
        defaults.set(preferences.appearance.rawValue, forKey: Key.appearance)
        defaults.set(preferences.colorTheme.rawValue, forKey: Key.colorTheme)
        defaults.set(preferences.lineSpacing.rawValue, forKey: Key.lineSpacing)
        defaults.set(preferences.documentWidth.rawValue, forKey: Key.documentWidth)
        defaults.set(preferences.loadsRemoteImages, forKey: Key.loadsRemoteImages)
        defaults.set(preferences.checksForUpdates, forKey: Key.checksForUpdates)
        defaults.set(preferences.printMargin.rawValue, forKey: Key.printMargin)
        defaults.set(preferences.printOrientation.rawValue, forKey: Key.printOrientation)
        defaults.set(preferences.printPaper.rawValue, forKey: Key.printPaper)
        defaults.set(preferences.translationTarget, forKey: Key.translationTarget)
        // 시스템 글꼴(`nil`)은 **빈 값으로** 적는다. 키를 지우면 기본값(앱에 든 글꼴)으로
        // 읽혀, 시스템 글꼴을 골라도 다음에 열면 Pretendard로 돌아간다.
        defaults.set(preferences.bodyFontFamily ?? "", forKey: Key.bodyFontFamily)
        defaults.set(preferences.codeFontFamily ?? "", forKey: Key.codeFontFamily)
        // '본문과 같음'은 키를 지워 둔다 — 없을 때의 뜻이 그것이다.
        switch preferences.headingFont {
        case .sameAsBody: defaults.removeObject(forKey: Key.headingFontFamily)
        case .system: defaults.set("", forKey: Key.headingFontFamily)
        case let .family(name): defaults.set(name, forKey: Key.headingFontFamily)
        }
    }

    /// 전부 기본값으로. 키를 지워 두면 다음에 기본값이 다시 읽힌다.
    public func reset() {
        for key in Key.all { defaults.removeObject(forKey: key) }
    }

    // MARK: 화면 상태

    /// 문서 메타데이터 카드를 접어 두었는가. 접으면 다음에 여는 문서의 카드도 접힌 채 열린다 —
    /// 카드를 매번 접는 사람은 매번 접어야 했다.
    ///
    /// 설정이 아니라 화면 상태라 `EditorPreferences`에 넣지 않는다. 설정 창에 항목이 없고,
    /// `기본값으로`가 되돌리지 않는다(`Key.all`에 없다). 문서마다가 아니라 앱에 하나다.
    public var collapsesFrontMatter: Bool {
        get { defaults.bool(forKey: Self.frontMatterCollapsedKey) }
        set { defaults.set(newValue, forKey: Self.frontMatterCollapsedKey) }
    }

    static let frontMatterCollapsedKey = "frontMatter.collapsed"

    /// 도구 막대 보이기 — `iconAndLabel`(기본, nil) · `iconOnly` · `labelOnly`. 사용자가 도구 막대를 우클릭해
    /// 고른 것이다. 카드 접힘과 같은 화면 상태라 `기본값으로`가 되돌리지 않는다.
    public var toolbarDisplayMode: String? {
        get { defaults.string(forKey: Self.toolbarDisplayModeKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.toolbarDisplayModeKey) }
            else { defaults.removeObject(forKey: Self.toolbarDisplayModeKey) }
        }
    }

    static let toolbarDisplayModeKey = "toolbar.displayMode"

    /// 마지막으로 새 판을 확인한 때(성공한 확인만). 켤 때의 하루 한 번을 잰다.
    public var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Self.lastUpdateCheckKey) as? Date }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.lastUpdateCheckKey) }
            else { defaults.removeObject(forKey: Self.lastUpdateCheckKey) }
        }
    }

    static let lastUpdateCheckKey = "update.lastCheck"

    /// 끌 때 새 판을 바꿔 넣다가 실패한 까닭. 끄는 중에는 알릴 수 없어 적어 두고, 다음에 켤 때 한 번 알린다.
    public var updateInstallFailure: String? {
        get { defaults.string(forKey: Self.updateInstallFailureKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.updateInstallFailureKey) }
            else { defaults.removeObject(forKey: Self.updateInstallFailureKey) }
        }
    }

    static let updateInstallFailureKey = "update.installFailure"
}
