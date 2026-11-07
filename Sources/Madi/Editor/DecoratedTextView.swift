import AppKit

/// 글자 속성으로는 그릴 수 없는 것을 그리는 텍스트 뷰 — 코드 블록 배경, 체크박스, 인라인 그림.
///
/// 왜 그리기로 넘겼는가: 전에는 코드 줄의 글자마다 `.backgroundColor`를 줬다. 그러면
/// 글자가 있는 만큼만 칠해져서 줄마다 오른쪽 끝이 다르고, 블록이 하나의 덩이로 보이지
/// 않는다. 글자 수에 따라 배경이 들쭉날쭉해지는 것은 속성으로는 고칠 수 없다 —
/// 배경이 글자의 성질이 아니라 **블록의 성질**이기 때문이다.
///
/// `NSTextBlock`을 쓰는 길도 있지만 문단마다 블록이 생겨 줄 사이에 이음선이 보이고,
/// 여백을 다루기가 까다롭다. 직접 그리면 블록 하나가 둥근 사각형 하나가 된다.
/// 블록 편집기의 `BlockTextView`가 이 클래스를 물려받는다(코드 배경·그림 그리기를
/// 그대로 쓰고 블록 경계 처리만 더한다). 그래서 `final`이 아니다.
public class DecoratedTextView: NSTextView {

    /// 칠할 코드 블록의 문자 범위. `MarkdownStyler`가 계산해 넘긴다.
    public var codeBlockRanges: [NSRange] = [] {
        didSet {
            guard codeBlockRanges != oldValue else { return }
            // 다 다시 그리므로 옛 자리 기억도 버린다.
            drawnDecorations = drawnDecorations.filter { $0.key.level != 0 }
            needsDisplay = true
        }
    }

    public var codeBlockColor: NSColor = .quaternarySystemFill {
        didSet { needsDisplay = true }
    }

    /// 글자와 배경 사이의 여백.
    public var codeBlockPadding = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
    public var codeBlockCornerRadius: CGFloat = 6

    /// 그림 자리. `MarkdownStyler`가 계산해 넘긴다.
    public var imagePlacements: [MarkdownStyler.ImagePlacement] = [] {
        didSet {
            guard imagePlacements != oldValue else { return }
            drawnDecorations = drawnDecorations.filter { $0.key.level != Decoration.image }
            needsDisplay = true
        }
    }

    /// 상자로 그릴 체크박스. `MarkdownStyler`가 계산해 넘긴다(그 글자는 투명하게 칠해 두었다).
    public var taskBoxes: [MarkdownStyler.TaskBox] = [] {
        didSet {
            guard taskBoxes != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 인용 막대. `MarkdownStyler`가 계산해 넘긴다(`>` 글자는 캐럿이 없는 줄에서 숨는다).
    public var quoteBars: [MarkdownStyler.QuoteBar] = [] {
        didSet {
            guard quoteBars != oldValue else { return }
            drawnDecorations = drawnDecorations.filter { $0.key.level == 0 }
            needsDisplay = true
        }
    }

    /// 막대의 색. 알림 상자(`> [!NOTE]`)의 바깥 막대는 그 종류의 색이다. 알림 머리도 이 색으로 그린다.
    public var quoteBarColor: (GithubAlert?) -> NSColor = { _ in .separatorColor }

    /// 알림 머리 — 표식 자리에 그리는 아이콘과 제목. `MarkdownStyler`가 계산해 넘긴다(표식 글자는 투명하다).
    public var alertTitles: [MarkdownStyler.AlertTitle] = [] {
        didSet {
            guard alertTitles != oldValue else { return }
            drawnDecorations = drawnDecorations.filter { $0.key.level != Decoration.alertTitle }
            needsDisplay = true
        }
    }

    // MARK: 글 위의 자리

    /// 글 위에 비워 둘 높이 — 문서 메타데이터 카드가 그 자리에 놓인다(`MarkdownEditorView.headerView`).
    ///
    /// 카드를 편집기 **밖** 위에 두면 굴려도 그 자리에 남아 읽을 자리를 먹는다(실측: 항목 열두 개인
    /// 카드가 752pt 창의 310pt). 그래서 카드를 텍스트 뷰 안에 두고 글을 이만큼 내려, 카드가 글과 함께
    /// 굴러가게 한다.
    ///
    /// 위아래 여백(`textContainerInset.height`)에 반씩 더하고 글의 시작을 반만큼 더 내린다 — 텍스트
    /// 뷰의 높이는 `글 + 여백 × 2`라, 이렇게 해야 높이가 카드만큼 늘고 아래 여백은 그대로다.
    public private(set) var topAccessoryHeight: CGFloat = 0

    /// 여백을 정한다. `base`는 카드가 없을 때의 여백이다.
    public func setInsets(_ base: NSSize, topAccessory: CGFloat) {
        let inset = NSSize(width: base.width, height: base.height + topAccessory / 2)
        guard inset != textContainerInset || topAccessory != topAccessoryHeight else { return }
        topAccessoryHeight = topAccessory
        textContainerInset = inset
        invalidateTextContainerOrigin()
        needsDisplay = true
    }

    /// 카드가 없을 때의 여백 — `setInsets`에 넘긴 `base`.
    public var baseInsets: NSSize {
        NSSize(width: textContainerInset.width, height: textContainerInset.height - topAccessoryHeight / 2)
    }

    public override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        origin.y += topAccessoryHeight / 2
        return origin
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let visible = visibleCharacterRange(in: rect) else { return }
        drawCodeBlocks(in: rect, visible: visible)
        drawQuoteBars(in: rect, visible: visible)
        drawAlertTitles(in: rect, visible: visible)
        drawTaskBoxes(in: rect, visible: visible)
        drawImages(in: rect, visible: visible)
    }

    /// 그릴 사각형에 걸친 글자 범위. 블록과 그림은 **이 범위에 닿는 것만** 묻는다.
    ///
    /// 왜(실측, 22만 자 문서): 전에는 그릴 때마다 문서의 코드 블록 **전부**에
    /// `boundingRect`를 물었다. 문서 끝의 블록을 물으면 TextKit이 거기까지 레이아웃을
    /// 끝내야 하므로, 첫 화면 하나를 그리는 데 문서 전체를 놓았다 — 그것도 한 번에
    /// 놓는 것(`ensureLayout`, 0.41초)보다 열 배 느리게 조각조각(4.7초). 글 앞쪽에서
    /// 한 글자를 칠 때마다 그 뒤의 레이아웃이 무효가 되므로 **타이핑 한 번에 4.5초**가
    /// 들었다. 이 질의는 사각형까지만 레이아웃한다.
    ///
    /// 위아래로 블록 여백만큼 넓혀 묻는다 — 배경은 글자보다 여백만큼 크므로, 글자가
    /// 사각형 밖에 있어도 배경의 가장자리는 안에 들어올 수 있다.
    private func visibleCharacterRange(in rect: NSRect) -> NSRange? {
        guard let layoutManager, let textContainer else { return nil }
        let origin = textContainerOrigin
        let margin = max(codeBlockPadding.top, codeBlockPadding.bottom) + 1
        let query = NSRect(x: rect.minX - origin.x, y: rect.minY - origin.y - margin,
                           width: rect.width, height: rect.height + margin * 2)
        let glyphs = layoutManager.glyphRange(forBoundingRect: query, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// `ranges`(위치 순) 가운데 `visible`에 닿는 것. 블록이 수백 개라 이분 탐색으로
    /// 첫 후보를 찾는다.
    static func ranges(_ ranges: [NSRange], touching visible: NSRange) -> ArraySlice<NSRange> {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(ranges[mid]) < visible.location { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < ranges.count, ranges[end].location <= NSMaxRange(visible) { end += 1 }
        return ranges[lo ..< end]
    }

    private func drawCodeBlocks(in rect: NSRect, visible: NSRange) {
        guard !codeBlockRanges.isEmpty,
              let layoutManager, let textContainer else { return }

        codeBlockColor.setFill()

        for range in Self.ranges(codeBlockRanges, touching: visible) {
            // 보이는 데만 그린다 — 큰 문서를 굴릴 때 블록 전부를 칠할 이유가 없다.
            guard let padded = codeBlockFrame(range), padded.intersects(rect) else { continue }
            drawnDecorations[Decoration(range: range, level: 0)] = padded
            NSBezierPath(roundedRect: padded,
                         xRadius: codeBlockCornerRadius,
                         yRadius: codeBlockCornerRadius).fill()
        }
    }

    /// 코드 블록 하나의 바탕 자리(뷰 좌표).
    private func codeBlockFrame(_ range: NSRange) -> NSRect? {
        guard range.length > 0, NSMaxRange(range) <= (textStorage?.length ?? 0),
              let layoutManager, let textContainer else { return nil }
        let origin = textContainerOrigin
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }

        // 블록이 차지하는 줄들의 높이. 가로는 쓰지 않는다 — 글자 폭을 따라가면
        // 다시 들쭉날쭉해지므로 **글 넓이 전체**로 바꿔 끼운다.
        var box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        box.origin.x = origin.x + textContainer.lineFragmentPadding
        box.size.width = textContainer.size.width - textContainer.lineFragmentPadding * 2
        box.origin.y += origin.y
        return NSRect(x: box.minX - codeBlockPadding.left, y: box.minY - codeBlockPadding.top,
                      width: box.width + codeBlockPadding.left + codeBlockPadding.right,
                      height: box.height + codeBlockPadding.top + codeBlockPadding.bottom)
    }

    // MARK: 옮겨 간 장식

    /// 그린 장식 하나 — 코드 블록(`level` 0), 인용 막대(`level` = 겹), 그림·표 격자(`image`), 알림 머리.
    struct Decoration: Hashable {
        let range: NSRange
        let level: Int
        static let image = -1
        static let alertTitle = -2
    }

    /// 마지막으로 그린 자리. 레이아웃이 자리를 고친 뒤 옛 자리를 지우는 데 쓴다(`revalidateDecorations`).
    private(set) var drawnDecorations: [Decoration: NSRect] = [:]

    /// 그려 둔 장식 가운데 레이아웃이 옮긴 것의 옛 자리와 새 자리를 다시 그린다.
    ///
    /// 장식은 글자가 아니라 이 뷰가 그린 그림이라, 끊어 놓기가 어림 자리를 고쳐도 레이아웃 관리자는 그
    /// 옛 자리를 다시 그려 주지 않는다 — 바탕이 엉뚱한 줄에 띠로 남는다(`MarkdownEditorView`의 레이아웃
    /// 알림에 실측). 그린 것만 다시 재므로 화면에 보이는 몇 개뿐이다.
    func revalidateDecorations() {
        guard !drawnDecorations.isEmpty else { return }
        let bars = Dictionary(quoteBars.map { (Decoration(range: $0.range, level: $0.level), $0) },
                              uniquingKeysWith: { first, _ in first })
        let images = Dictionary(imagePlacements.map { ($0.lineRange, $0) }, uniquingKeysWith: { first, _ in first })
        let titles = Dictionary(alertTitles.map { ($0.range, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, old) in drawnDecorations {
            let current: NSRect?
            switch key.level {
            case 0: current = codeBlockFrame(key.range)
            case Decoration.image: current = images[key.range].flatMap(frame(of:))
            case Decoration.alertTitle: current = titles[key.range].flatMap(alertTitleFrame)
            default: current = bars[key].flatMap(quoteBarFrame)
            }
            guard current != old else { continue }
            setNeedsDisplay(old)
            if let current { setNeedsDisplay(current) }
            drawnDecorations[key] = current
        }
    }

    // MARK: 인용 막대

    /// 막대 하나의 자리 — 걸친 줄들의 위아래, 글 칸 왼쪽에서 `level`만큼 들어간 자리.
    ///
    /// 위아래는 줄 조각이 아니라 **글자가 쓰인 자리**(used rect)로 잰다. 줄 조각에는 그 줄 뒤의
    /// 문단 간격이 들어 있어, 덩이의 끝 막대가 글 아래로 늘어진다.
    static func quoteBarFrame(level: Int, top: CGFloat, bottom: CGFloat, textLeft: CGFloat) -> NSRect {
        let x = textLeft + MarkdownStyler.quoteIndentStep * CGFloat(level - 1) + MarkdownStyler.quoteBarInset
        return NSRect(x: x.rounded(), y: top.rounded(), width: MarkdownStyler.quoteBarWidth,
                      height: max(1, (bottom - top).rounded()))
    }

    private func drawQuoteBars(in rect: NSRect, visible: NSRange) {
        guard !quoteBars.isEmpty else { return }
        // 범위로만 거른다(이분 탐색을 쓰지 않는다). 겹친 인용에서는 바깥 막대가 안쪽 막대보다 먼저
        // 시작해 늦게 끝나므로 끝 위치가 차례대로 늘지 않는다. 막대는 문서에 많아야 수백 개다.
        for bar in quoteBars
        where NSIntersectionRange(bar.range, visible).length > 0 || NSLocationInRange(visible.location, bar.range) {
            guard let frame = quoteBarFrame(bar), frame.intersects(rect) else { continue }
            drawnDecorations[Decoration(range: bar.range, level: bar.level)] = frame
            quoteBarColor(bar.alert).setFill()
            NSBezierPath(roundedRect: frame, xRadius: frame.width / 2, yRadius: frame.width / 2).fill()
        }
    }

    /// 막대 하나의 자리(뷰 좌표).
    private func quoteBarFrame(_ bar: MarkdownStyler.QuoteBar) -> NSRect? {
        guard bar.range.length > 0, NSMaxRange(bar.range) <= (textStorage?.length ?? 0),
              let layoutManager, let textContainer else { return nil }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forCharacterRange: bar.range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let first = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layoutManager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return Self.quoteBarFrame(level: bar.level, top: first.minY + origin.y, bottom: last.maxY + origin.y,
                                  textLeft: origin.x + textContainer.lineFragmentPadding)
    }

    // MARK: 알림 머리

    /// GitHub의 알림 아이콘(Octicons)에 가장 가까운 SF Symbols — 원, 전구, 말풍선, 세모, 팔각형.
    static func alertSymbol(_ alert: GithubAlert) -> String {
        switch alert {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.bubble"
        case .warning: "exclamationmark.triangle"
        case .caution: "exclamationmark.octagon"
        }
    }

    /// 머리의 폭 — 아이콘, 틈, 제목. 스타일러가 표식 글자의 폭을 이만큼으로 맞춘다.
    static func alertTitleWidth(_ alert: GithubAlert, font: NSFont) -> CGFloat {
        let icon = (font.capHeight * 1.35).rounded()
        let title = NSAttributedString(string: alert.title, attributes: [.font: font]).size().width
        return icon + gap(for: font) + ceil(title)
    }

    private static func gap(for font: NSFont) -> CGFloat { (font.pointSize * 0.4).rounded() }

    /// 머리 하나의 자리(뷰 좌표) — 투명한 표식 글자가 차지한 자리.
    private func alertTitleFrame(_ title: MarkdownStyler.AlertTitle) -> NSRect? {
        guard title.range.length > 0, NSMaxRange(title.range) <= (textStorage?.length ?? 0),
              let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: title.range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        bounds.origin.x += textContainerOrigin.x
        bounds.origin.y += textContainerOrigin.y
        return bounds
    }

    private func drawAlertTitles(in rect: NSRect, visible: NSRange) {
        guard !alertTitles.isEmpty, let layoutManager, let storage = textStorage else { return }
        for title in alertTitles
        where NSIntersectionRange(title.range, visible).length > 0 || NSLocationInRange(title.range.location, visible) {
            guard let frame = alertTitleFrame(title), frame.intersects(rect) else { continue }
            drawnDecorations[Decoration(range: title.range, level: Decoration.alertTitle)] = frame
            let glyph = layoutManager.glyphIndexForCharacter(at: title.range.location)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyph).y + textContainerOrigin.y
            let font = storage.attribute(.font, at: title.range.location, effectiveRange: nil) as? NSFont
                ?? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            Self.drawAlertTitle(title.alert, at: NSPoint(x: frame.minX, y: baseline), font: font,
                                color: quoteBarColor(title.alert))
        }
    }

    /// 머리 하나 — 기준선(`origin.y`, 뒤집힌 좌표) 위에 아이콘과 제목을 그 종류의 색으로.
    static func drawAlertTitle(_ alert: GithubAlert, at origin: NSPoint, font: NSFont, color: NSColor) {
        let side = (font.capHeight * 1.35).rounded()
        let iconRect = NSRect(x: origin.x, y: (origin.y - font.capHeight / 2 - side / 2).rounded(),
                              width: side, height: side)
        let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        if let icon = NSImage(systemSymbolName: alertSymbol(alert), accessibilityDescription: alert.title)?
            .withSymbolConfiguration(configuration) {
            // 기호마다 비율이 달라(세모는 넓고 전구는 좁다) 정사각형 안에 비율대로 맞춘다.
            let size = icon.size
            let scale = min(side / max(size.width, 1), side / max(size.height, 1))
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            let target = NSRect(x: iconRect.midX - drawn.width / 2, y: iconRect.midY - drawn.height / 2,
                                width: drawn.width, height: drawn.height)
            icon.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
        let text = NSAttributedString(string: alert.title, attributes: [.font: font, .foregroundColor: color])
        // `draw(at:)`은 글줄의 위(ascender)를 기준으로 놓는다 — 기준선이 표식 글자와 맞게 그만큼 올린다.
        text.draw(at: NSPoint(x: origin.x + side + gap(for: font), y: origin.y - font.ascender))
    }

    // MARK: 체크박스

    /// `boxes`(위치 순) 가운데 `visible`에 닿는 것. `ranges(_:touching:)`과 같은 이분 탐색이다.
    static func taskBoxes(_ boxes: [MarkdownStyler.TaskBox],
                          touching visible: NSRange) -> ArraySlice<MarkdownStyler.TaskBox> {
        var lo = 0, hi = boxes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(boxes[mid].range) < visible.location { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < boxes.count, boxes[end].range.location <= NSMaxRange(visible) { end += 1 }
        return boxes[lo ..< end]
    }

    /// 상자의 자리 — `[ ]` 세 글자의 가운데, 글자의 대문자 높이에 맞춘 정사각형. 줄 높이가 아니라
    /// **글자**에 맞춘다: 줄 간격까지 넣은 줄 조각의 가운데에 두면 글보다 아래로 처진다.
    /// 세 글자의 폭을 넘지 않는다 — 넘으면 뒤의 공백을 덮어 상자가 글에 붙는다(실측: `[ ] new`).
    ///
    /// - Parameters:
    ///   - glyphs: 세 글자를 감싼 사각형(뷰 좌표).
    ///   - baseline: 그 줄의 기준선(뷰 좌표, 아래로 갈수록 크다).
    static func taskBoxFrame(glyphs: NSRect, baseline: CGFloat, capHeight: CGFloat) -> NSRect {
        let side = max(8, min((capHeight * 1.3).rounded(), glyphs.width.rounded(.down)))
        let centerY = baseline - capHeight / 2
        return NSRect(x: (glyphs.midX - side / 2).rounded(), y: (centerY - side / 2).rounded(),
                      width: side, height: side)
    }

    private func drawTaskBoxes(in rect: NSRect, visible: NSRange) {
        guard !taskBoxes.isEmpty, let layoutManager, let textContainer, let storage = textStorage else { return }
        let origin = textContainerOrigin
        for box in Self.taskBoxes(taskBoxes, touching: visible) where NSMaxRange(box.range) <= storage.length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: box.range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            var bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            bounds.origin.x += origin.x
            bounds.origin.y += origin.y
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyphs.location).y + origin.y
            let font = storage.attribute(.font, at: box.range.location, effectiveRange: nil) as? NSFont
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let frame = Self.taskBoxFrame(glyphs: bounds, baseline: baseline, capHeight: font.capHeight)
            guard frame.intersects(rect) else { continue }
            Self.drawTaskBox(in: frame, checked: box.checked)
        }
    }

    /// 상자 하나. 빈 칸은 테두리, 한 일은 강조색으로 채우고 흰 체크 표시 — macOS 체크박스의 모양이다.
    static func drawTaskBox(in frame: NSRect, checked: Bool) {
        let side = frame.width
        let shape = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: side * 0.24, yRadius: side * 0.24)
        guard checked else {
            NSColor.secondaryLabelColor.setStroke()
            shape.lineWidth = 1.2
            shape.stroke()
            return
        }
        NSColor.controlAccentColor.setFill()
        shape.fill()
        // 뒤집힌 좌표(아래로 갈수록 y가 크다)의 체크 표시.
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: frame.minX + side * 0.26, y: frame.minY + side * 0.52))
        mark.line(to: NSPoint(x: frame.minX + side * 0.43, y: frame.minY + side * 0.69))
        mark.line(to: NSPoint(x: frame.minX + side * 0.75, y: frame.minY + side * 0.33))
        mark.lineWidth = max(1.4, side * 0.13)
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        NSColor.white.setStroke()
        mark.stroke()
    }

    /// 비워 둔 줄 안에서 그림이 놓일 자리. 보통은 왼쪽 맞춤이고, `centered`면 **글 넓이**의
    /// 가운데다 — 줄 조각의 가운데가 아니다(빈 줄 조각은 글자가 없어 폭이 0일 수 있다).
    static func imageFrame(for placement: MarkdownStyler.ImagePlacement, lineBox: NSRect,
                           textOriginX: CGFloat, containerWidth: CGFloat, padding: CGFloat) -> NSRect {
        let left = textOriginX + padding
        let available = containerWidth - padding * 2
        let x = placement.centered
            ? left + max(0, (available - placement.size.width) / 2)
            : lineBox.minX + padding
        return NSRect(x: x, y: lineBox.minY, width: placement.size.width,
                      height: min(placement.size.height, lineBox.height))
    }

    /// 그림을 그린다.
    ///
    /// 문서에 첨부 글자(U+FFFC)를 끼워 넣지 않는다. 그 길은 **실측으로 막혔다**:
    /// 보통 글자에 `.attachment` 속성만 주면 줄 높이가 18pt에서 꼼짝도 하지 않았고
    /// (U+FFFC를 넣은 쪽은 80pt가 됐다), 글자를 끼워 넣으면 원문이 달라진다.
    /// 그래서 스타일러가 `minimumLineHeight`로 자리를 비우고(문서 불변, 실측 80pt
    /// 확보) 여기서 그 자리에 그린다.
    /// 그림 하나가 그려지는 자리(뷰 좌표). 그리기와 클릭(격자로 그린 표의 ⌘클릭)이 같은 자리를 쓴다.
    func frame(of placement: MarkdownStyler.ImagePlacement) -> NSRect? {
        guard placement.size.width > 0, placement.size.height > 0,
              NSMaxRange(placement.lineRange) <= (textStorage?.length ?? 0),
              let layoutManager, let textContainer else { return nil }
        let origin = textContainerOrigin
        let glyphRange = layoutManager.glyphRange(forCharacterRange: placement.lineRange,
                                                  actualCharacterRange: nil)
        var box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        box.origin.x += origin.x
        box.origin.y += origin.y
        return Self.imageFrame(for: placement, lineBox: box, textOriginX: origin.x,
                               containerWidth: textContainer.size.width,
                               padding: textContainer.lineFragmentPadding)
    }

    private func drawImages(in rect: NSRect, visible: NSRange) {
        guard !imagePlacements.isEmpty else { return }

        for placement in imagePlacements
        where NSIntersectionRange(placement.lineRange, visible).length > 0
            || NSLocationInRange(placement.lineRange.location, visible) {
            guard let frame = frame(of: placement), frame.intersects(rect) else { continue }
            drawnDecorations[Decoration(range: placement.lineRange, level: Decoration.image)] = frame
            placement.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                                 respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }
}
