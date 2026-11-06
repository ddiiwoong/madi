import AppKit

/// 테마 하나의 색 — 문서를 그리는 색 전부(`EditorPreferences.ColorTheme`).
///
/// 색마다 라이트·다크 두 값을 가진 동적 색이라, 화면 모양(시스템 · 라이트 · 다크)이 바뀌면 다시 만들지
/// 않아도 그리는 때의 외관으로 풀린다. `기본`만 시스템 의미색을 쓴다 — 테마를 고르기 전의 모양 그대로다.
///
/// 값을 고른 규칙: 글자는 바탕과 **4.5 : 1 이상**(코드 글자는 코드 바탕 위에서), 마커는 3 : 1 이상,
/// 인용 글은 본문보다 옅되 4.5 : 1 이상. `MarkdownThemeContrastTests`가 다섯 테마의 두 벌 모두를 지킨다.
/// Solarized는 원래 강조색이 중간 밝기라 흰 바탕 위 글자로 쓰면 3~4 : 1이다 — 색상은 지키고 밝기만
/// 옮겨 기준을 넘겼다. GitHub는 Primer의 색(github.com 문서 화면)을 그대로 썼다.
@MainActor
struct ThemePalette {
    var background: NSColor
    var text: NSColor
    var dim: NSColor
    var quote: NSColor
    var quoteBar: NSColor
    var link: NSColor
    var codeText: NSColor
    var codeBackground: NSColor
    var rule: NSColor
    var tableLine: NSColor
    var tableHeaderBackground: NSColor
    /// 고른 글의 바탕. nil이면 시스템 색(강조색에 따라 바뀐다).
    var selection: NSColor?
    var keyword: NSColor
    var type: NSColor
    var string: NSColor
    var comment: NSColor
    var number: NSColor
    var note: NSColor
    var tip: NSColor
    var important: NSColor
    var warning: NSColor
    var caution: NSColor

    func code(_ role: CodeHighlighter.Span.Role) -> NSColor {
        switch role {
        case .keyword: keyword
        case .type: type
        case .string: string
        case .comment: comment
        case .number: number
        }
    }

    func alert(_ alert: GithubAlert) -> NSColor {
        switch alert {
        case .note: note
        case .tip: tip
        case .important: important
        case .warning: warning
        case .caution: caution
        }
    }

    // MARK: 다섯 테마

    /// 테마의 색. 처음 물을 때 만들어 기억한다 — 색이 같은 객체여야 다시 칠할 때 그림이 바뀌었다고 보지 않는다.
    static func palette(for theme: EditorPreferences.ColorTheme) -> ThemePalette {
        if let cached = cache[theme] { return cached }
        let palette = make(theme)
        cache[theme] = palette
        return palette
    }

    private static var cache: [EditorPreferences.ColorTheme: ThemePalette] = [:]

    private static func pair(_ light: UInt32, _ dark: UInt32) -> NSColor {
        MarkdownTheme.dynamic(light: light, dark: dark)
    }

    private static func make(_ theme: EditorPreferences.ColorTheme) -> ThemePalette {
        switch theme {
        case .standard:
            // 테마를 넣기 전의 색 그대로다(`MarkdownTheme`에 있던 값).
            return ThemePalette(
                background: .textBackgroundColor, text: .labelColor, dim: .secondaryLabelColor,
                quote: pair(0x55_59_5E, 0xB6_BA_BF), quoteBar: pair(0xC9_CF_D6, 0x4D_54_5C),
                link: .linkColor, codeText: .labelColor, codeBackground: .quaternarySystemFill,
                rule: .separatorColor,
                tableLine: pair(0xD5_D9_DE, 0x45_4A_51), tableHeaderBackground: pair(0xF3_F4_F6, 0x2B_2E_33),
                selection: nil,
                keyword: pair(0xA3_19_9B, 0xFF_7A_B2), type: pair(0x0F_5A_63, 0x6B_DF_FF),
                string: pair(0xB8_28_14, 0xFF_81_70), comment: pair(0x4A_5A_66, 0x93_A1_AD),
                number: pair(0x21_24_BD, 0xD9_C8_FF),
                note: pair(0x0A_52_A1, 0x6C_B6_FF), tip: pair(0x1A_65_32, 0x5E_D2_86),
                important: pair(0x6A_2D_9E, 0xC2_97_FF), warning: pair(0x8A_52_00, 0xE3_B3_41),
                caution: pair(0xA3_1C_1C, 0xFF_81_82))

        case .paper:
            return ThemePalette(
                background: pair(0xF7_F1_E3, 0x2A_25_20), text: pair(0x3B_2F_24, 0xE8_DC_C8),
                dim: pair(0x7D_6C_57, 0xA3_92_79),
                quote: pair(0x65_54_3F, 0xC4_B4_9C), quoteBar: pair(0xD8_C9_AE, 0x5C_4F_40),
                link: pair(0x9C_3F_14, 0xE9_A4_6E),
                codeText: pair(0x3B_2F_24, 0xE8_DC_C8), codeBackground: pair(0xEE_E5_D1, 0x35_2E_27),
                rule: pair(0xD8_C9_AE, 0x5C_4F_40),
                tableLine: pair(0xCF_BF_A2, 0x5A_4D_3E), tableHeaderBackground: pair(0xEE_E4_CF, 0x35_2E_27),
                selection: pair(0xE6_D5_AE, 0x5A_4A_36),
                keyword: pair(0x8E_2A_63, 0xE7_9B_C2), type: pair(0x2C_64_55, 0x93_D3_BD),
                string: pair(0x96_3A_12, 0xF2_A9_82), comment: pair(0x6A_5D_4C, 0xAD_9E_86),
                number: pair(0x36_49_9A, 0xAE_BD_F2),
                note: pair(0x1F_4F_8F, 0x8D_B8_F0), tip: pair(0x2E_5F_2A, 0x9B_D4_8E),
                important: pair(0x5E_34_88, 0xC9_A8_F2), warning: pair(0x7A_4B_00, 0xE8_BE_6A),
                caution: pair(0x9A_2A_1A, 0xF2_9A_88))

        case .github:
            return ThemePalette(
                background: pair(0xFF_FF_FF, 0x0D_11_17), text: pair(0x1F_23_28, 0xF0_F6_FC),
                dim: pair(0x59_63_6E, 0x91_98_A1),
                quote: pair(0x59_63_6E, 0x91_98_A1), quoteBar: pair(0xD1_D9_E0, 0x3D_44_4D),
                link: pair(0x09_69_DA, 0x44_93_F8),
                codeText: pair(0x1F_23_28, 0xF0_F6_FC), codeBackground: pair(0xF6_F8_FA, 0x15_1B_23),
                rule: pair(0xD1_D9_E0, 0x3D_44_4D),
                tableLine: pair(0xD1_D9_E0, 0x3D_44_4D), tableHeaderBackground: pair(0xF6_F8_FA, 0x15_1B_23),
                selection: pair(0xCC_E4_FF, 0x1F_3B_5E),
                keyword: pair(0xCF_22_2E, 0xFF_7B_72), type: pair(0x95_38_00, 0xFF_A6_57),
                string: pair(0x0A_30_69, 0xA5_D6_FF), comment: pair(0x59_63_6E, 0x91_98_A1),
                number: pair(0x05_50_AE, 0x79_C0_FF),
                note: pair(0x09_69_DA, 0x44_93_F8), tip: pair(0x1A_7F_37, 0x3F_B9_50),
                important: pair(0x82_50_DF, 0xAB_7D_F8), warning: pair(0x9A_67_00, 0xD2_99_22),
                caution: pair(0xD1_24_2F, 0xF8_51_49))

        case .solarized:
            // 바탕은 base3 · base03, 코드 바탕은 base2 · base02 그대로다.
            return ThemePalette(
                background: pair(0xFD_F6_E3, 0x00_2B_36), text: pair(0x4A_5D_65, 0x9B_A9_A9),
                dim: pair(0x6F_81_86, 0x7A_8E_92),
                quote: pair(0x5B_6E_75, 0x86_97_9A), quoteBar: pair(0xD6_CF_B9, 0x2E_4A_52),
                link: pair(0x1D_6B_A3, 0x5A_A9_E0),
                codeText: pair(0x4A_5D_65, 0x9B_A9_A9), codeBackground: pair(0xEE_E8_D5, 0x07_36_42),
                rule: pair(0xD6_CF_B9, 0x2E_4A_52),
                tableLine: pair(0xD3_CC_B5, 0x2F_50_59), tableHeaderBackground: pair(0xEE_E8_D5, 0x07_36_42),
                selection: pair(0xE3_D9_BB, 0x0A_3F_4C),
                keyword: pair(0x5A_6A_00, 0xA3_B8_00), type: pair(0x76_56_00, 0xD1_A9_28),
                string: pair(0x1A_70_69, 0x3D_BD_B2), comment: pair(0x52_64_6A, 0x8A_9C_9F),
                number: pair(0xA3_24_5F, 0xEC_74_A8),
                note: pair(0x1D_6B_A3, 0x5A_A9_E0), tip: pair(0x5A_6A_00, 0xA3_B8_00),
                important: pair(0x55_49_A0, 0x9D_A1_E6), warning: pair(0x84_55_00, 0xD8_AA_2A),
                caution: pair(0xAE_2A_27, 0xF2_72_6C))

        case .highContrast:
            return ThemePalette(
                background: pair(0xFF_FF_FF, 0x00_00_00), text: pair(0x00_00_00, 0xFF_FF_FF),
                dim: pair(0x4D_4D_4D, 0xBF_BF_BF),
                quote: pair(0x33_33_33, 0xE0_E0_E0), quoteBar: pair(0x6B_6B_6B, 0x9A_9A_9A),
                link: pair(0x00_33_CC, 0x8C_B4_FF),
                codeText: pair(0x00_00_00, 0xFF_FF_FF), codeBackground: pair(0xF0_F0_F0, 0x1A_1A_1A),
                rule: pair(0x7A_7A_7A, 0x8C_8C_8C),
                tableLine: pair(0x5C_5C_5C, 0x8C_8C_8C), tableHeaderBackground: pair(0xE6_E6_E6, 0x26_26_26),
                selection: pair(0xB3_D7_FF, 0x1F_4F_8F),
                keyword: pair(0x8B_00_70, 0xFF_8A_D8), type: pair(0x00_55_7A, 0x7F_E0_FF),
                string: pair(0xA0_00_00, 0xFF_A0_8A), comment: pair(0x4D_4D_4D, 0xBF_BF_BF),
                number: pair(0x1A_1A_A6, 0xC9_B8_FF),
                note: pair(0x00_3D_99, 0x8C_C2_FF), tip: pair(0x00_6B_1B, 0x7E_E2_9A),
                important: pair(0x5A_1A_99, 0xD1_B0_FF), warning: pair(0x6E_44_00, 0xFF_D2_7A),
                caution: pair(0x9E_00_00, 0xFF_9A_9A))
        }
    }

    // MARK: 견본

    /// 고르개에 붙이는 작은 견본 — 바탕 위에 본문 줄 둘과 링크 색 줄 하나. 그리는 때의 외관으로 그린다
    /// (메뉴가 다크면 다크 벌).
    static func swatch(for theme: EditorPreferences.ColorTheme, size: NSSize = NSSize(width: 30, height: 18)) -> NSImage {
        let palette = palette(for: theme)
        let image = NSImage(size: size, flipped: true) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            palette.background.setFill()
            box.fill()
            NSColor.separatorColor.setStroke()
            box.lineWidth = 1
            box.stroke()
            let left = rect.minX + 5
            let width = rect.width - 10
            palette.text.setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: rect.minY + 4, width: width, height: 2.5),
                         xRadius: 1.25, yRadius: 1.25).fill()
            NSBezierPath(roundedRect: NSRect(x: left, y: rect.minY + 8, width: width * 0.7, height: 2.5),
                         xRadius: 1.25, yRadius: 1.25).fill()
            palette.link.setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: rect.minY + 12, width: width * 0.45, height: 2.5),
                         xRadius: 1.25, yRadius: 1.25).fill()
            return true
        }
        image.cacheMode = .never
        return image
    }
}
