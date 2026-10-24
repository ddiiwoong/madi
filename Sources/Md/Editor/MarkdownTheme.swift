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
    public var dim: NSColor { .tertiaryLabelColor }
    public var quote: NSColor { .secondaryLabelColor }
    public var link: NSColor { .linkColor }
    public var codeText: NSColor { .labelColor }
    public var codeBackground: NSColor { .quaternarySystemFill }
    public var rule: NSColor { .separatorColor }

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
