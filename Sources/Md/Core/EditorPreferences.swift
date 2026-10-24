import Foundation

/// 편집기 설정.
///
/// **쓰이지 않는 설정은 넣지 않는다.** 설정 화면에 켜고 끌 수 있는 것이 있는데 아무
/// 일도 일어나지 않으면, 사용자는 자기가 무엇을 잘못했는지 찾느라 시간을 버린다.
/// 아래 다섯 개는 모두 실제 코드 경로에 붙어 있다:
///
/// - `bodyPointSize` → `MarkdownTheme`의 모든 글꼴 크기가 여기서 나온다
/// - `highlightCode` → `MarkdownStyler.highlightCode` 패스
/// - `alignTables` → `MarkdownStyler.alignTables` 패스
/// - `syntheticSlant` → CJK 강제 기울임
/// - `openInCodeView` → 새로 연 창의 코드 보기 초깃값
public struct EditorPreferences: Equatable, Sendable {

    /// 본문 글자 크기. 제목·고정폭 크기도 여기서 파생된다.
    public var bodyPointSize: Double
    public var highlightCode: Bool
    public var alignTables: Bool
    public var syntheticSlant: Bool
    public var openInCodeView: Bool

    /// 글자 크기의 허용 범위. 너무 작으면 한글이 뭉개지고, 너무 크면 표 열 맞추기가
    /// 한 줄에 들어가지 않는다.
    public static let pointSizeRange: ClosedRange<Double> = 10 ... 28

    public static let standard = EditorPreferences(
        bodyPointSize: 15,
        highlightCode: true,
        alignTables: true,
        syntheticSlant: true,
        openInCodeView: false
    )

    public init(bodyPointSize: Double, highlightCode: Bool, alignTables: Bool,
                syntheticSlant: Bool, openInCodeView: Bool) {
        self.bodyPointSize = Self.clamp(bodyPointSize)
        self.highlightCode = highlightCode
        self.alignTables = alignTables
        self.syntheticSlant = syntheticSlant
        self.openInCodeView = openInCodeView
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
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 저장된 설정. 키가 없으면 기본값을 쓴다 — 첫 실행에서 모든 키가 없다.
    public var current: EditorPreferences {
        let standard = EditorPreferences.standard
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
                ?? standard.openInCodeView
        )
    }

    /// 저장한다. 값은 `EditorPreferences`의 이니셜라이저가 이미 가둬 둔 것이다.
    public func save(_ preferences: EditorPreferences) {
        defaults.set(preferences.bodyPointSize, forKey: Key.bodyPointSize)
        defaults.set(preferences.highlightCode, forKey: Key.highlightCode)
        defaults.set(preferences.alignTables, forKey: Key.alignTables)
        defaults.set(preferences.syntheticSlant, forKey: Key.syntheticSlant)
        defaults.set(preferences.openInCodeView, forKey: Key.openInCodeView)
    }

    /// 전부 기본값으로. 키를 지워 두면 다음에 기본값이 다시 읽힌다.
    public func reset() {
        for key in [Key.bodyPointSize, Key.highlightCode, Key.alignTables,
                    Key.syntheticSlant, Key.openInCodeView] {
            defaults.removeObject(forKey: key)
        }
    }
}
