import AppKit

/// Fonts and colours for the live-preview editor. Everything resolves from
/// system semantic colours, so light and dark both work without a second table.
@MainActor
public struct MarkdownTheme {

    public var bodyPointSize: CGFloat = 15
    public var bodyFont: NSFont { .systemFont(ofSize: bodyPointSize) }
    public var monoFont: NSFont { .monospacedSystemFont(ofSize: bodyPointSize - 1, weight: .regular) }

    public static let headingScale: [CGFloat] = [1.85, 1.45, 1.22, 1.08, 1.0, 1.0]

    public func headingFont(level: Int) -> NSFont {
        let clamped = max(1, min(6, level))
        let size = bodyPointSize * Self.headingScale[clamped - 1]
        return .systemFont(ofSize: size, weight: clamped <= 2 ? .bold : .semibold)
    }

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

    /// Amber, matching the colour family a markdown editor conventionally uses
    /// for find-in-document highlighting.
    public var searchHighlight: NSColor {
        NSColor(calibratedRed: 0.973, green: 0.871, blue: 0.455, alpha: 0.82)
    }

    public var currentSearchHighlight: NSColor {
        NSColor(calibratedRed: 0.965, green: 0.780, blue: 0.267, alpha: 0.95)
    }

    public var insertionPoint: NSColor { .labelColor }

    public var lineSpacing: CGFloat { bodyPointSize * 0.42 }
    public var paragraphSpacing: CGFloat { bodyPointSize * 0.55 }
    public var textInsets: NSSize { NSSize(width: 28, height: 24) }

    public init() {}
}
