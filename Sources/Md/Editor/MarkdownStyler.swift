import AppKit

/// Custom attribute marking syntax punctuation the layout manager should not
/// draw. Hiding happens at glyph generation, so the characters stay in the
/// document and editing still sees them — they merely take no space.
extension NSAttributedString.Key {
    static let mdHiddenMarker = NSAttributedString.Key("mdHiddenMarker")
    static let mdLinkTarget = NSAttributedString.Key("mdLinkTarget")
}

/// Applies rendered-looking attributes to the markdown source in place.
///
/// This is what makes "the viewer is editable" true: there is one text storage
/// holding markdown, and it is drawn as a formatted document. Syntax markers on
/// the line the caret sits on stay visible so the structure can be edited; on
/// every other line they are hidden.
@MainActor
public final class MarkdownStyler {

    public var theme = MarkdownTheme()
    /// 코드 보기 — render the raw markdown instead of the formatted document:
    /// monospace throughout, every marker visible. The text storage is the same
    /// either way, so this is purely how it is drawn.
    public var codeView = false
    private let syntax = MarkdownSyntax()

    public init() {}

    public struct SearchState {
        public var ranges: [NSRange] = []
        public var currentIndex: Int?
        public init() {}
    }

    /// - Parameters:
    ///   - caretLine: 1-based line the insertion point is on, or nil when the
    ///     view has no selection. Markers on that line are left visible.
    ///   - dirtyRange: restrict attribute writes to the lines intersecting this
    ///     range. Lines are still SCANNED from the top — whether a line sits
    ///     inside a fenced code block depends on every line before it, so a
    ///     window-only scan would mis-classify code as prose. Scanning is cheap;
    ///     writing attributes and invalidating layout is what costs.
    public func style(_ storage: NSTextStorage, caretLine: Int?, search: SearchState,
                      dirtyRange: NSRange? = nil) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        let writeRange = dirtyRange.map { text.lineRange(for: NSIntersectionRange($0, full)) } ?? full

        storage.beginEditing()
        defer { storage.endEditing() }

        if codeView {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = theme.lineSpacing * 0.5
            storage.setAttributes([
                .font: theme.monoFont,
                .foregroundColor: theme.text,
                .paragraphStyle: style,
            ], range: writeRange)
            // `setAttributes` above already replaced every attribute in the
            // range, hiding included; this makes that reliance explicit so a
            // later switch to `addAttributes` cannot leave markers invisible.
            storage.removeAttribute(.mdHiddenMarker, range: writeRange)
            for line in syntax.scanLines(in: text) {
                guard NSIntersectionRange(line.range, writeRange).length > 0 else { continue }
                for marker in line.markerRanges where marker.length > 0 {
                    storage.addAttribute(.foregroundColor, value: theme.dim, range: marker)
                }
            }
            for (index, range) in search.ranges.enumerated()
            where NSMaxRange(range) <= text.length && NSIntersectionRange(range, writeRange).length > 0 {
                storage.addAttribute(.backgroundColor,
                                     value: index == search.currentIndex
                                        ? theme.currentSearchHighlight : theme.searchHighlight,
                                     range: range)
            }
            return
        }

        storage.setAttributes([
            .font: theme.bodyFont,
            .foregroundColor: theme.text,
            .paragraphStyle: paragraphStyle(for: .paragraph),
        ], range: writeRange)

        for line in syntax.scanLines(in: text) {
            guard line.range.length == 0 || NSIntersectionRange(line.range, writeRange).length > 0
                    || NSLocationInRange(line.range.location, writeRange) else { continue }
            apply(line, in: storage, text: text, caretLine: caretLine)
        }

        for (index, range) in search.ranges.enumerated()
        where NSMaxRange(range) <= text.length && NSIntersectionRange(range, writeRange).length > 0 {
            let isCurrent = index == search.currentIndex
            storage.addAttribute(.backgroundColor,
                                 value: isCurrent ? theme.currentSearchHighlight : theme.searchHighlight,
                                 range: range)
        }
    }

    // MARK: Blocks

    private func apply(_ line: LineToken, in storage: NSTextStorage, text: NSString, caretLine: Int?) {
        guard line.range.length > 0 || line.kind == .blank else { return }
        let onCaretLine = caretLine == line.lineNumber
        let style = paragraphStyle(for: line.kind)
        if line.range.length > 0 {
            storage.addAttribute(.paragraphStyle, value: style, range: line.range)
        }

        switch line.kind {
        case let .heading(level):
            storage.addAttribute(.font, value: theme.headingFont(level: level), range: line.range)
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)

        case .quote:
            storage.addAttributes([.foregroundColor: theme.quote], range: line.range)
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)

        case .listItem:
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)

        case .codeFence, .codeBody:
            storage.addAttributes([
                .font: theme.monoFont,
                .foregroundColor: theme.codeText,
                .backgroundColor: theme.codeBackground,
            ], range: line.range)

        case .thematicBreak:
            storage.addAttributes([.foregroundColor: theme.rule], range: line.range)

        case .tableRow, .tableDelimiter:
            // No real grid in this version; aligned monospace is honest about that.
            storage.addAttribute(.font, value: theme.monoFont, range: line.range)

        case .paragraph:
            styleInline(in: storage, text: text, content: line.contentRange, onCaretLine: onCaretLine)

        case .blank:
            break
        }

        // Markers: dimmed on the caret's line, hidden everywhere else.
        for marker in line.markerRanges where marker.length > 0 && NSMaxRange(marker) <= text.length {
            if case .codeFence = line.kind {
                storage.addAttribute(.foregroundColor, value: theme.dim, range: marker)
                if !onCaretLine { hide(marker, in: storage) }
                continue
            }
            if case .thematicBreak = line.kind { continue }
            if case .tableDelimiter = line.kind { continue }

            storage.addAttribute(.foregroundColor, value: theme.dim, range: marker)
            // A list bullet and a quote bar are part of the rendered look, so
            // they stay; only the markup that a renderer would consume is hidden.
            if !onCaretLine, shouldHideMarker(for: line.kind) {
                hide(marker, in: storage)
            }
        }
    }

    private func shouldHideMarker(for kind: BlockKind) -> Bool {
        switch kind {
        case .heading, .codeFence: return true
        case .quote, .listItem, .thematicBreak, .tableRow, .tableDelimiter,
             .codeBody, .paragraph, .blank: return false
        }
    }

    // MARK: Inlines

    private func styleInline(in storage: NSTextStorage, text: NSString,
                             content: NSRange, onCaretLine: Bool) {
        guard content.location != NSNotFound, content.length > 0,
              NSMaxRange(content) <= text.length else { return }

        for token in syntax.scanInline(in: text, range: content) {
            let existing = storage.attribute(.font, at: token.range.location,
                                             effectiveRange: nil) as? NSFont ?? theme.bodyFont

            switch token.kind {
            case .strong:
                storage.addAttribute(.font, value: bold(existing), range: token.contentRange)
            case .emphasis:
                storage.addAttribute(.font, value: italic(existing), range: token.contentRange)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle,
                                     value: NSUnderlineStyle.single.rawValue, range: token.contentRange)
            case .code:
                storage.addAttributes([
                    .font: theme.monoFont,
                    .backgroundColor: theme.codeBackground,
                ], range: token.contentRange)
            case let .link(url), let .image(url), let .autolink(url):
                storage.addAttributes([
                    .foregroundColor: theme.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .mdLinkTarget: url,
                ], range: token.contentRange)
            }

            for marker in token.markerRanges where marker.length > 0 {
                storage.addAttribute(.foregroundColor, value: theme.dim, range: marker)
                if !onCaretLine { hide(marker, in: storage) }
            }
        }
    }

    private func hide(_ range: NSRange, in storage: NSTextStorage) {
        storage.addAttribute(.mdHiddenMarker, value: true, range: range)
    }

    private func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    // MARK: Paragraph styles

    private func paragraphStyle(for kind: BlockKind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        style.paragraphSpacing = theme.paragraphSpacing

        switch kind {
        case .heading:
            style.paragraphSpacingBefore = theme.bodyPointSize * 0.9
            style.paragraphSpacing = theme.bodyPointSize * 0.3
        case .quote:
            style.firstLineHeadIndent = 18
            style.headIndent = 18
        case .listItem:
            style.firstLineHeadIndent = 4
            style.headIndent = 22
            style.paragraphSpacing = theme.bodyPointSize * 0.18
        case .codeBody, .codeFence:
            style.lineSpacing = theme.lineSpacing * 0.5
            style.paragraphSpacing = 0
            style.firstLineHeadIndent = 10
            style.headIndent = 10
        default:
            break
        }
        return style
    }
}
