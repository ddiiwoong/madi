import AppKit

/// 테마 하나의 색 — 문서를 그리는 색 전부(`EditorPreferences.ColorTheme`).
///
/// 색마다 라이트·다크 두 값을 가진 동적 색이라, 화면 모양(시스템 · 라이트 · 다크)이 바뀌면 다시 만들지
/// 않아도 그리는 때의 외관으로 풀린다. `기본`만 시스템 의미색을 쓴다 — 테마를 고르기 전의 모양 그대로다.
///
/// 값을 고른 규칙: 글자는 바탕과 **4.5 : 1 이상**(코드 글자는 코드 바탕 위에서), 마커는 3 : 1 이상,
/// 인용 글은 본문보다 옅되 4.5 : 1 이상. `MarkdownThemeContrastTests`가 모든 테마의 두 벌을 지킨다.
/// Solarized는 원래 강조색이 중간 밝기라 흰 바탕 위 글자로 쓰면 3~4 : 1이다 — 색상은 지키고 밝기만
/// 옮겨 기준을 넘겼다. GitHub는 Primer의 색(github.com 문서 화면)을 그대로 썼다.
///
/// Notion · Confluence · Obsidian은 그 앱의 **바탕 · 글 · 링크 · 코드 바탕**을 따랐다(Notion은 공개된 색표,
/// Confluence는 Atlassian 디자인 토큰, Obsidian은 기본 테마). 그 앱들이 정하지 않은 자리(코드 강조색 다섯, 알림
/// 다섯)는 그 앱의 색표에서 가까운 색을 골라 대비 기준까지 밝기만 옮겼다. 글꼴은 테마가 아니라 글꼴 탭이 정한다.
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

    // MARK: 테마 여덟

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

        case .notion:
            // 글 #37352F · 다크 #D4D4D4(바탕 #191919), 코드 블록 바탕 #F7F6F3. 링크는 글 색에 밑줄이고 인용 막대도
            // 글 색이다(Notion이 그렇게 그린다). 알림은 Notion 글 색표(파랑 · 초록 · 보라 · 주황 · 빨강)에서.
            return ThemePalette(
                background: pair(0xFF_FF_FF, 0x19_19_19), text: pair(0x37_35_2F, 0xD4_D4_D4),
                dim: pair(0x86_85_7F, 0x8C_8C_8C),
                quote: pair(0x55_53_4E, 0xB4_B4_B4), quoteBar: pair(0x37_35_2F, 0xD4_D4_D4),
                link: pair(0x37_35_2F, 0xD4_D4_D4),
                codeText: pair(0x37_35_2F, 0xD4_D4_D4), codeBackground: pair(0xF7_F6_F3, 0x25_25_25),
                rule: pair(0xE3_E2_E0, 0x37_37_37),
                tableLine: pair(0xDC_DB_D7, 0x3A_3A_3A), tableHeaderBackground: pair(0xF7_F6_F3, 0x20_20_20),
                selection: pair(0xC1_DC_F7, 0x24_40_5E),
                keyword: pair(0x07_67_9A, 0xCC_99_CD), type: pair(0xB8_30_4F, 0x6F_A8_DC),
                string: pair(0x4E_7A_00, 0x7E_C6_99), comment: pair(0x5F_6B_76, 0x99_99_99),
                number: pair(0x99_00_55, 0xF0_8D_49),
                note: pair(0x2B_6E_95, 0x4A_A6_DD), tip: pair(0x3B_75_56, 0x5B_AE_7E),
                important: pair(0x84_57_A6, 0xAF_7E_E0), warning: pair(0xA8_5A_0A, 0xD3_8B_55),
                caution: pair(0xC0_40_3B, 0xE8_66_64))

        case .confluence:
            // Atlassian 토큰: text #292A2E · #CECFD2, link #1868DB · #669DF1, surface #FFFFFF · #1F1F21,
            // background.neutral(코드 · 표 머리)을 바탕 위에 섞은 색. 알림은 Atlassian 색표의 파랑 · 초록 · 보라 · 주황 · 빨강.
            return ThemePalette(
                background: pair(0xFF_FF_FF, 0x1F_1F_21), text: pair(0x29_2A_2E, 0xCE_CF_D2),
                dim: pair(0x6B_6E_76, 0x96_99_9E),
                quote: pair(0x50_52_58, 0xA9_AB_AF), quoteBar: pair(0xC9_CB_CF, 0x4B_4D_51),
                link: pair(0x18_68_DB, 0x66_9D_F1),
                codeText: pair(0x29_2A_2E, 0xCE_CF_D2), codeBackground: pair(0xF0_F1_F2, 0x2B_2C_2F),
                rule: pair(0xDD_DE_E1, 0x3D_3F_43),
                tableLine: pair(0xC9_CB_CF, 0x4B_4D_51), tableHeaderBackground: pair(0xF0_F1_F2, 0x2B_2C_2F),
                selection: pair(0xD6_E5_FB, 0x1C_2B_42),
                keyword: pair(0x5E_4D_B2, 0xB8_AC_F6), type: pair(0x20_6A_83, 0x9D_D9_EE),
                string: pair(0x21_6E_4E, 0x7E_E2_B8), comment: pair(0x62_65_6C, 0x96_99_9E),
                number: pair(0xAE_2E_24, 0xFD_98_91),
                note: pair(0x18_68_DB, 0x66_9D_F1), tip: pair(0x21_6E_4E, 0x7E_E2_B8),
                important: pair(0x5E_4D_B2, 0xB8_AC_F6), warning: pair(0xA5_48_00, 0xFE_C5_7B),
                caution: pair(0xAE_2E_24, 0xFD_98_91))

        case .obsidian:
            // 기본 테마: 글 #222222 · #DADADA, 바탕 #FFFFFF · #1E1E1E, 옅은 글 #5C5C5C · #B3B3B3. 강조색(보라)이 링크와
            // 인용 막대다 — 흰 바탕의 링크는 대비를 맞추려고 조금 짙게(#6E46DC) 했다.
            return ThemePalette(
                background: pair(0xFF_FF_FF, 0x1E_1E_1E), text: pair(0x22_22_22, 0xDA_DA_DA),
                dim: pair(0x8A_8A_8A, 0x8A_8A_8A),
                quote: pair(0x5C_5C_5C, 0xB3_B3_B3), quoteBar: pair(0x8A_5C_F5, 0xA8_8B_FA),
                link: pair(0x6E_46_DC, 0xA8_8B_FA),
                codeText: pair(0x2E_2E_2E, 0xDA_DA_DA), codeBackground: pair(0xF6_F6_F6, 0x26_26_26),
                rule: pair(0xE0_E0_E0, 0x36_36_36),
                tableLine: pair(0xD4_D4_D4, 0x40_40_40), tableHeaderBackground: pair(0xFA_FA_FA, 0x26_26_26),
                selection: pair(0xE3_DA_FD, 0x3B_31_59),
                keyword: pair(0xBC_2A_73, 0xFA_99_CD), type: pair(0x00_77_7A, 0x53_DF_DD),
                string: pair(0x08_7A_35, 0x44_CF_6E), comment: pair(0x6B_6B_6B, 0x92_92_92),
                number: pair(0x6A_44_D8, 0xA8_82_FF),
                note: pair(0x08_60_C4, 0x5A_A4_FF), tip: pair(0x00_76_72, 0x53_DF_DD),
                important: pair(0x6E_46_DC, 0xA8_82_FF), warning: pair(0xA6_52_00, 0xE9_97_3F),
                caution: pair(0xC8_21_3A, 0xFB_64_69))

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
