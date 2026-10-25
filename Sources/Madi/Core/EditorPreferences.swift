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
public struct EditorPreferences: Equatable, Sendable {

    /// 화면 모양. 마디의 색은 거의 다 의미색이라 시스템을 저절로 따르는데, 그래서
    /// **고정할 수가 없었다** — 시스템이 다크인데 문서만 라이트로 보려는 경우가 막힌다.
    public enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark

        public var label: String {
            switch self {
            case .system: return "시스템"
            case .light: return "라이트"
            case .dark: return "다크"
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

        public var label: String {
            switch self {
            case .tight: return "좁게"
            case .normal: return "보통"
            case .loose: return "넓게"
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
            case .narrow: return "좁게"
            case .normal: return "보통"
            case .wide: return "넓게"
            case .full: return "창 너비"
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
            case .narrow: return "좁게"
            case .normal: return "보통"
            case .wide: return "넓게"
            }
        }
    }

    public enum PrintOrientation: String, CaseIterable, Sendable {
        case portrait, landscape

        public var label: String {
            switch self {
            case .portrait: return "세로"
            case .landscape: return "가로"
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
            case .system: return "시스템 기본"
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
    public var lineSpacing: LineSpacing
    public var documentWidth: DocumentWidth
    /// 원격 그림을 받아올지. **기본이 꺼짐이고 그래야 한다** — 문서를 열었을 뿐인데
    /// 바깥으로 요청이 나가는 것은 사용자가 시킨 일이 아니고, 문서에 적힌 주소가
    /// 추적용일 수 있다. 켜는 경우에도 `https`만 받는다.
    public var loadsRemoteImages: Bool
    public var printMargin: PrintMargin
    public var printOrientation: PrintOrientation
    public var printPaper: PrintPaper

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
        printPaper: .system
    )

    public init(bodyPointSize: Double, highlightCode: Bool, alignTables: Bool,
                syntheticSlant: Bool, openInCodeView: Bool,
                appearance: Appearance = .system,
                lineSpacing: LineSpacing = .normal,
                documentWidth: DocumentWidth = .normal,
                loadsRemoteImages: Bool = false,
                printMargin: PrintMargin = .normal,
                printOrientation: PrintOrientation = .portrait,
                printPaper: PrintPaper = .system) {
        self.bodyPointSize = Self.clamp(bodyPointSize)
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

        static let all = [bodyPointSize, highlightCode, alignTables, syntheticSlant,
                          openInCodeView, appearance, lineSpacing, documentWidth,
                          loadsRemoteImages, printMargin, printOrientation, printPaper]
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
            printPaper: value(Key.printPaper, standard.printPaper)
        )
    }

    /// 저장한다. 값은 `EditorPreferences`의 이니셜라이저가 이미 가둬 둔 것이다.
    public func save(_ preferences: EditorPreferences) {
        defaults.set(preferences.bodyPointSize, forKey: Key.bodyPointSize)
        defaults.set(preferences.highlightCode, forKey: Key.highlightCode)
        defaults.set(preferences.alignTables, forKey: Key.alignTables)
        defaults.set(preferences.syntheticSlant, forKey: Key.syntheticSlant)
        defaults.set(preferences.openInCodeView, forKey: Key.openInCodeView)
        defaults.set(preferences.appearance.rawValue, forKey: Key.appearance)
        defaults.set(preferences.lineSpacing.rawValue, forKey: Key.lineSpacing)
        defaults.set(preferences.documentWidth.rawValue, forKey: Key.documentWidth)
        defaults.set(preferences.loadsRemoteImages, forKey: Key.loadsRemoteImages)
        defaults.set(preferences.printMargin.rawValue, forKey: Key.printMargin)
        defaults.set(preferences.printOrientation.rawValue, forKey: Key.printOrientation)
        defaults.set(preferences.printPaper.rawValue, forKey: Key.printPaper)
    }

    /// 전부 기본값으로. 키를 지워 두면 다음에 기본값이 다시 읽힌다.
    public func reset() {
        for key in Key.all { defaults.removeObject(forKey: key) }
    }
}
