import AppKit
import XCTest

/// 코드 강조 색이 **읽히는지**를 수치로 지킨다.
///
/// 왜 테스트가 필요한가: 처음에는 시스템 틴트 색(`.systemTeal`, `.systemPink`,
/// `.secondaryLabelColor`)을 썼고 "시스템 색이니 라이트/다크 모두 읽힌다"고 주석까지
/// 달아 두었다. 실제로 재 보니 라이트 모드에서 타입이 **2.03 : 1**, 문자열 3.36 : 1,
/// 키워드 3.43 : 1이었다 — 글자 대비 기준 4.5 : 1에 한참 못 미친다. 주석 색은 알파가
/// 0.50인 반투명 색이어서 말 그대로 투명하게 보였다. 눈으로 보고 "괜찮다"고 넘긴
/// 결함이라, 눈이 아니라 숫자가 지켜야 한다.
///
/// 기준은 WCAG의 보통 글자 기준 4.5 : 1을 쓴다. 코드는 작은 고정폭 글자라 더 엄할
/// 이유는 있어도 느슨할 이유는 없다.
final class MarkdownThemeContrastTests: XCTestCase {

    private let minimumTextContrast = 4.5

    /// 코드 블록의 실제 바탕색 — 문서 배경 위에 반투명한 코드 배경을 올린 결과다.
    /// 코드 글자는 이 색 위에 그려지므로 대비도 이 색을 기준으로 재야 한다.
    @MainActor
    private func codeBlockFill(_ theme: MarkdownTheme) -> NSColor {
        Self.composite(theme.codeBackground, over: .textBackgroundColor)
    }

    @MainActor
    func testEveryCodeRoleIsReadableInBothAppearances() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else {
                return XCTFail("외관 \(name.rawValue)을 만들 수 없다")
            }
            appearance.performAsCurrentDrawingAppearance {
                let theme = MarkdownTheme()
                let fill = codeBlockFill(theme)
                for role in CodeHighlighter.Span.Role.allCases {
                    let color = theme.codeColor(for: role)
                    let ratio = Self.contrast(Self.composite(color, over: fill), fill)
                    XCTAssertGreaterThanOrEqual(
                        ratio, minimumTextContrast,
                        "\(name.rawValue)의 \(role) 대비가 \(String(format: "%.2f", ratio)) : 1 — "
                        + "작은 고정폭 글자가 배경에 씻겨 보인다")
                }
            }
        }
    }

    @MainActor
    func testCodeRoleColorsAreOpaque() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                let theme = MarkdownTheme()
                for role in CodeHighlighter.Span.Role.allCases {
                    let alpha = theme.codeColor(for: role)
                        .usingColorSpace(.deviceRGB)?.alphaComponent ?? 0
                    XCTAssertEqual(Double(alpha), 1.0, accuracy: 0.001,
                                   "\(name.rawValue)의 \(role)이 반투명하다 — 배경이 섞이면 "
                                   + "대비가 배경에 따라 달라진다")
                }
            }
        }
    }

    /// 역할마다 **다른** 색이어야 한다. 대비만 보면 전부 검정으로 두어도 통과한다.
    @MainActor
    func testRolesAreDistinguishableFromPlainCodeText() {
        guard let appearance = NSAppearance(named: .aqua) else { return }
        appearance.performAsCurrentDrawingAppearance {
            let theme = MarkdownTheme()
            let plain = theme.codeText
            for role in CodeHighlighter.Span.Role.allCases {
                let color = theme.codeColor(for: role)
                XCTAssertGreaterThan(Self.distance(color, plain), 0.1,
                                     "\(role)이 본문 코드 글자와 구별되지 않는다")
            }
            // 서로도 구별되어야 한다.
            let roles = Array(CodeHighlighter.Span.Role.allCases)
            for i in roles.indices {
                for j in roles.indices where j > i {
                    XCTAssertGreaterThan(
                        Self.distance(theme.codeColor(for: roles[i]),
                                      theme.codeColor(for: roles[j])), 0.08,
                        "\(roles[i])과 \(roles[j])이 같은 색으로 보인다")
                }
            }
        }
    }

    /// 마커(`#`, `**`)는 일부러 흐리지만, 캐럿 줄에서는 보여야 한다. 글자 기준보다
    /// 느슨한 3 : 1을 쓴다 — 읽을 글이 아니라 구조를 가리키는 표시다.
    @MainActor
    func testCaretLineMarkersStayVisible() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                let theme = MarkdownTheme()
                let page = NSColor.textBackgroundColor
                let ratio = Self.contrast(Self.composite(theme.dim, over: page), page)
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "\(name.rawValue)의 마커 대비가 \(String(format: "%.2f", ratio)) : 1 — "
                    + "캐럿을 올려도 `#`이 보이지 않는다")
            }
        }
    }

    // MARK: 재는 법

    /// 알파가 있는 색을 바탕색 위에 올린 결과.
    private static func composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
        guard let t = top.usingColorSpace(.deviceRGB),
              let b = bottom.usingColorSpace(.deviceRGB) else { return top }
        let a = t.alphaComponent
        return NSColor(deviceRed: t.redComponent * a + b.redComponent * (1 - a),
                       green: t.greenComponent * a + b.greenComponent * (1 - a),
                       blue: t.blueComponent * a + b.blueComponent * (1 - a),
                       alpha: 1)
    }

    /// WCAG 상대 대비.
    private static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func relative(_ color: NSColor) -> Double {
            guard let c = color.usingColorSpace(.deviceRGB) else { return 0 }
            return 0.2126 * linear(Double(c.redComponent))
                + 0.7152 * linear(Double(c.greenComponent))
                + 0.0722 * linear(Double(c.blueComponent))
        }
        let (x, y) = (relative(a), relative(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> Double {
        guard let x = a.usingColorSpace(.deviceRGB), let y = b.usingColorSpace(.deviceRGB)
        else { return 0 }
        return abs(Double(x.redComponent - y.redComponent))
            + abs(Double(x.greenComponent - y.greenComponent))
            + abs(Double(x.blueComponent - y.blueComponent))
    }
}
