import AppKit

/// Fonts and colours for the live-preview editor. Everything resolves from
/// system semantic colours, so light and dark both work without a second table.
@MainActor
public struct MarkdownTheme {

    public var bodyPointSize: CGFloat = 15
    /// 본문·코드 글꼴 패밀리. `nil`이면 시스템 글꼴이다(`EditorPreferences`와 같은 뜻).
    public var bodyFontFamily: String?
    public var codeFontFamily: String?
    /// 제목 글꼴. 기본은 본문을 따른다 — 본문만 바꾼 쪽(블록 편집기, 테스트)도 제목이 함께 바뀐다.
    public var headingFont: EditorPreferences.HeadingFont = .sameAsBody

    /// 제목을 그리는 패밀리. `nil`이면 시스템.
    public var headingFontFamily: String? {
        switch headingFont {
        case .sameAsBody: bodyFontFamily
        case .system: nil
        case let .family(name): name
        }
    }

    public var bodyFont: NSFont {
        Self.font(family: bodyFontFamily, size: bodyPointSize) ?? .systemFont(ofSize: bodyPointSize)
    }
    public var monoFont: NSFont {
        let size = bodyPointSize - 1
        // 고정폭이 아니면 쓰지 않는다 — 코드의 들여쓰기와 열이 어긋난다. 고르개가 이미
        // 거르지만, 저장소에 손으로 쓴 이름도 여기서 막힌다.
        if let font = Self.font(family: codeFontFamily, size: size), font.isFixedPitch { return font }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public static let headingScale: [CGFloat] = [1.85, 1.45, 1.22, 1.08, 1.0, 1.0]

    public func headingFont(level: Int) -> NSFont {
        let clamped = max(1, min(6, level))
        let size = bodyPointSize * Self.headingScale[clamped - 1]
        // 패밀리에 굵은꼴이 없으면 보통 굵기가 돌아온다 — 크기로만 제목이 갈린다.
        if let bold = Self.font(family: headingFontFamily, size: size, bold: true) { return bold }
        return .systemFont(ofSize: size, weight: clamped <= 2 ? .bold : .semibold)
    }

    /// 본문 크기의 굵은 본문 글꼴(알림 상자의 표식 등).
    public var semiboldBodyFont: NSFont {
        Self.font(family: bodyFontFamily, size: bodyPointSize, bold: true)
            ?? .systemFont(ofSize: bodyPointSize, weight: .semibold)
    }

    /// 패밀리의 글꼴. 이름이 없거나 이 Mac에 없으면 nil — 부르는 쪽이 시스템 글꼴로 떨어진다.
    ///
    /// 찾은 것을 기억한다. 스타일 패스가 줄마다 글꼴을 묻고(22만 자 문서에서 수천 번),
    /// `NSFontManager`의 패밀리 조회는 시스템 글꼴처럼 AppKit이 기억해 주지 않는다.
    /// 없는 이름도 기억한다(`NSNull`) — 없는 글꼴을 줄마다 다시 찾지 않게.
    static func font(family: String?, size: CGFloat, bold: Bool = false) -> NSFont? {
        guard let family else { return nil }
        let key = "\(family)|\(size)|\(bold)"
        if let cached = resolved[key] { return cached as? NSFont }
        // weight 5는 `NSFontManager`의 보통 굵기다(0~15, 5 = Regular).
        var font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
        if bold, let regular = font {
            font = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        }
        resolved[key] = font ?? NSNull()
        return font
    }

    private static var resolved: [String: Any] = [:]

    /// 기억해 둔 글꼴을 버린다. 글꼴을 새로 등록한 뒤에 부른다 — 등록 전에 찾았다가 '없음'으로
    /// 기억한 이름이 계속 없는 것으로 남지 않게.
    static func forgetResolvedFonts() { resolved = [:] }

    public var text: NSColor { .labelColor }
    /// 마커(`#`, `**`, 목록 글머리, 인용 막대) 색. 본문보다 물러나야 하지만 **보여야**
    /// 한다 — 캐럿을 올린 줄의 마커는 구조를 고치기 위해 읽는 것이다.
    /// `.tertiaryLabelColor`를 쓰던 때는 대비가 1.88 : 1이어서 캐럿을 올려도 `#`이
    /// 거의 보이지 않았다. 지금은 약 3.9 : 1이고 본문(14 : 1)과는 여전히 뚜렷이 다르다.
    /// `MarkdownThemeContrastTests`가 3 : 1 아래로 내려가지 않게 지킨다.
    public var dim: NSColor { .secondaryLabelColor }
    public var quote: NSColor { .secondaryLabelColor }
    public var link: NSColor { .linkColor }
    public var codeText: NSColor { .labelColor }
    public var codeBackground: NSColor { .quaternarySystemFill }
    public var rule: NSColor { .separatorColor }

    /// 코드 구문 강조 색.
    ///
    /// 시스템 틴트 색(`.systemTeal` 등)을 쓰지 않는다. 그 색들은 **버튼과 강조용**이라
    /// 흰 배경 위의 작은 고정폭 글자로는 씻겨 보인다 — 실측으로 라이트 모드 대비가
    /// 타입 2.03 : 1, 문자열 3.36 : 1, 키워드 3.43 : 1이었다(본문 글자는 14.26 : 1).
    /// 글자 대비 기준은 4.5 : 1이다. 주석에 쓰던 `.secondaryLabelColor`는 알파가
    /// 0.50인 **반투명** 색이라 말 그대로 투명하게 보였다.
    ///
    /// 그래서 외관마다 불투명한 색을 따로 둔다. 값은 Xcode의 기본 테마에서 가져왔다 —
    /// 같은 문제(흰/검은 배경 위의 작은 고정폭 글자)를 이미 푼 팔레트다.
    /// 대비는 `MarkdownThemeContrastTests`가 두 외관 모두에서 지킨다.
    public func codeColor(for role: CodeHighlighter.Span.Role) -> NSColor {
        switch role {
        case .keyword: return Self.dynamic(light: 0xA3_19_9B, dark: 0xFF_7A_B2)
        case .type:    return Self.dynamic(light: 0x0F_5A_63, dark: 0x6B_DF_FF)
        case .string:  return Self.dynamic(light: 0xB8_28_14, dark: 0xFF_81_70)
        case .comment: return Self.dynamic(light: 0x4A_5A_66, dark: 0x93_A1_AD)
        case .number:  return Self.dynamic(light: 0x21_24_BD, dark: 0xD9_C8_FF)
        }
    }

    /// 외관에 따라 갈라지는 불투명한 색. 두 값 다 알파 1이어야 한다 — 알파를 쓰면
    /// 배경이 섞여 대비가 배경에 따라 달라지고, 그것이 방금 고친 결함이다.
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                alpha: 1)
    }

    /// GitHub 알림의 색. 역할마다 다르고, 코드 색과 같은 이유로 외관별 불투명 색이다
    /// (시스템 틴트 색은 흰 배경의 작은 글자로 씻겨 보인다).
    /// 값은 GitHub의 알림 색을 라이트/다크에서 각각 읽히게 조정한 것이다.
    public func alertColor(for alert: GithubAlert) -> NSColor {
        switch alert {
        case .note:      return Self.dynamic(light: 0x0A_52_A1, dark: 0x6C_B6_FF)
        case .tip:       return Self.dynamic(light: 0x1A_65_32, dark: 0x5E_D2_86)
        case .important: return Self.dynamic(light: 0x6A_2D_9E, dark: 0xC2_97_FF)
        case .warning:   return Self.dynamic(light: 0x8A_52_00, dark: 0xE3_B3_41)
        case .caution:   return Self.dynamic(light: 0xA3_1C_1C, dark: 0xFF_81_82)
        }
    }

    /// Amber, matching the colour family a markdown editor conventionally uses
    /// for find-in-document highlighting.
    public var searchHighlight: NSColor {
        NSColor(calibratedRed: 0.973, green: 0.871, blue: 0.455, alpha: 0.82)
    }

    public var currentSearchHighlight: NSColor {
        NSColor(calibratedRed: 0.965, green: 0.780, blue: 0.267, alpha: 0.95)
    }

    public var insertionPoint: NSColor { .labelColor }

    public var lineSpacing: CGFloat { bodyPointSize * CGFloat(lineSpacingScale) }
    public var paragraphSpacing: CGFloat { bodyPointSize * 0.55 }
    public var textInsets: NSSize { NSSize(width: 28, height: 24) }

    /// 줄 간격 배율. 설정에서 온다(`EditorPreferences.LineSpacing.scale`).
    public var lineSpacingScale: Double = EditorPreferences.LineSpacing.normal.scale

    /// 글의 최대 폭. `nil`이면 창 너비를 다 쓴다.
    ///
    /// 본문 크기의 배수로 받는 이유: 글자를 키우면 한 줄에 들어가는 글자 수가 비슷하게
    /// 유지되어야 한다. 고정 pt로 두면 28pt에서 한 줄이 서른 자로 짧아진다.
    public var documentWidthMultiple: Double? = EditorPreferences.DocumentWidth.normal
        .multipleOfBodySize

    public var maxContentWidth: CGFloat? {
        documentWidthMultiple.map { CGFloat($0) * bodyPointSize }
    }

    /// 글을 가운데에 두기 위한 가로 여백. 창이 글보다 넓으면 남는 만큼을 반씩 나눈다.
    ///
    /// 왜 컨테이너 폭을 직접 줄이지 않는가: `widthTracksTextView`를 끄면 텍스트 뷰의
    /// 크기 변화를 따라가는 일을 전부 손으로 해야 하고, 그림 폭 맞춤과 표 열 맞추기가
    /// 모두 컨테이너 폭을 읽으므로 둘이 어긋날 길이 생긴다. 여백을 키우면 컨테이너
    /// 폭이 저절로 줄어들어 그 둘이 따라온다.
    public func textInsets(forViewWidth width: CGFloat) -> NSSize {
        let base = textInsets
        guard let maxWidth = maxContentWidth, width > 0 else { return base }
        let slack = (width - maxWidth) / 2
        return NSSize(width: max(base.width, slack), height: base.height)
    }

    public init() {}
}
