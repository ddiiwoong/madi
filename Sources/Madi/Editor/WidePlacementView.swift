import AppKit
import QuartzCore

/// 글 넓이보다 넓은 그림 — 긴 줄이 있는 코드 블록(`CodeBlockRendering`), 열을 읽을 만한 폭으로 둔 넓은 표
/// (`TableGrid`) — 을 **그 자리에서 가로로 굴려** 보이는 보기. 텍스트 뷰(`DecoratedTextView`) 안의 보조 뷰라
/// 글과 함께 위아래로 굴러간다. GitHub · Docusaurus의 `overflow-x: auto`와 같다.
///
/// - 자리: 글 칸의 왼쪽 끝에서 창 오른쪽의 빈자리까지 편다(`DecoratedTextView.wideFrame(of:)`). 넓은 창에서는 그 안에
///   다 들어 굴릴 것이 없다.
/// - 굴리기: 가로로 굴리면(트랙패드 두 손가락, ⇧+휠) 이 보기가 굴리고, 세로로 굴리면 문서가 굴러간다. 한 번의 몸짓
///   안에서는 처음 정한 방향을 지킨다 — 비스듬히 굴릴 때 두 쪽이 번갈아 받으면 화면이 떤다.
/// - 누르기: 텍스트 뷰가 정한다(`onMouseDown`, 점은 그림 좌표). 코드면 그 글자에 캐럿을 놓고(블록이 원문이 된다),
///   표면 ⌘클릭이 칸의 링크를 연다.
/// - 그래도 넘치면: 잘린 쪽을 흐리게 하고(`fadesLeadingEdge` · `fadesTrailingEdge`), 그림 아래에 **늘 보이는 막대**를
///   그린다(사용자 — "표 너비가 크면 다 안보이는", 고른 것: 잘린 쪽에 표시 + 늘 보이는 가로 막대). 전에는 겹쳐 그리는
///   시스템 막대가 마우스가 들어올 때만 잠깐 보여, 표가 글 칸 끝에서 그냥 끝난 것처럼 보였다. 시스템 막대는 쓰지 않는다 —
///   늘 보이는 시스템 막대는 칸에서 16pt를 가져가 그림의 아랫줄을 가리고 그 칸 안에서 세로로도 굴렀다(이 Mac에서 봄:
///   그림 78pt, 칸 62pt). 이 막대의 자리는 스타일러가 줄 높이에 비워 둔다(`ImagePlacement.scrollBarSpace`).
@MainActor
final class WidePlacementView: NSScrollView {

    private(set) var placement: MarkdownStyler.ImagePlacement
    /// 누른 점(그림 좌표)과 사건. 텍스트 뷰가 단다.
    var onMouseDown: ((MarkdownStyler.ImagePlacement, NSPoint, NSEvent) -> Void)?

    private let canvas = Canvas()
    private let bar = ScrollBar()
    /// 잘린 쪽을 흐리게 하는 가림 — 그림을 담은 칸(clip view)의 층에 씌운다. 바탕(코드 상자, 문서)이 무엇이든 그림만 옅어진다.
    private let fade = CAGradientLayer()

    /// 잘린 쪽을 흐리게 하는 폭.
    static let fadeWidth: CGFloat = 28

    /// 왼쪽이 잘렸는가(굴려서 앞이 가려졌다). 시험이 쓴다.
    private(set) var fadesLeadingEdge = false
    /// 오른쪽이 잘렸는가(뒤에 더 있다). 시험이 쓴다.
    private(set) var fadesTrailingEdge = false

    private enum Axis { case horizontal, vertical }
    /// 이번 몸짓이 굴리는 방향. 몸짓이 시작될 때 정한다.
    private var axis: Axis?

    init(placement: MarkdownStyler.ImagePlacement) {
        self.placement = placement
        super.init(frame: .zero)
        drawsBackground = false
        contentView.drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        documentCursor = .iBeam
        canvas.owner = self
        documentView = canvas
        bar.owner = self
        addSubview(bar)
        contentView.wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        show(placement, force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 그림을 바꾼다. 같은 그림이면 굴린 자리를 지킨다.
    func show(_ placement: MarkdownStyler.ImagePlacement) {
        show(placement, force: false)
    }

    private func show(_ placement: MarkdownStyler.ImagePlacement, force: Bool) {
        let changed = placement.image !== self.placement.image || placement.size != canvas.frame.size
        let barChanged = placement.scrollBarSpace != self.placement.scrollBarSpace
        self.placement = placement
        guard force || changed || barChanged || canvas.image == nil else { return }
        if force || changed || canvas.image == nil {
            canvas.image = placement.image
            canvas.setFrameSize(placement.size)
            canvas.needsDisplay = true
        }
        tile()
        reflectScrolledClipView(contentView)
    }

    /// 지금 굴린 만큼(pt). 시험이 쓴다.
    var horizontalOffset: CGFloat { contentView.bounds.origin.x }

    /// 가로로 더 굴릴 수 있는 만큼 — 그림의 폭에서 보이는 폭을 뺀 것. 0이면 다 보인다.
    var overflowWidth: CGFloat { max(0, canvas.frame.width - contentView.bounds.width) }

    /// 늘 보이는 막대. 다 보이면 숨는다. 시험이 쓴다.
    var scrollBar: NSView { bar }

    /// 그림을 담은 칸은 위에, 막대는 그 아래 비워 둔 자리에.
    override func tile() {
        super.tile()
        let space = min(placement.scrollBarSpace, bounds.height)
        let picture = bounds.height - space
        // 이 보기는 뒤집혀 있다(위가 0).
        contentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: picture)
        bar.frame = NSRect(x: 0, y: picture, width: bounds.width, height: space)
        updateEdges()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        updateEdges()
    }

    /// 잘린 쪽의 흐림과 막대를 지금 굴린 자리에 맞춘다.
    private func updateEdges() {
        let overflow = overflowWidth
        let offset = contentView.bounds.origin.x
        fadesLeadingEdge = overflow > 0.5 && offset > 0.5
        fadesTrailingEdge = overflow > 0.5 && offset < overflow - 0.5
        bar.isHidden = overflow <= 0.5 || bar.frame.height < ScrollBar.thickness
        bar.needsDisplay = true

        guard let layer = contentView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard fadesLeadingEdge || fadesTrailingEdge else {
            layer.mask = nil
            return
        }
        // 칸의 층은 굴리면 그 원점이 옮겨 간다 — 가림도 층의 지금 자리에 놓는다.
        fade.frame = layer.bounds
        let edge = min(0.4, Self.fadeWidth / max(1, layer.bounds.width))
        let solid = NSColor.black.cgColor
        let clear = NSColor.black.withAlphaComponent(0).cgColor
        fade.colors = [fadesLeadingEdge ? clear : solid, solid, solid, fadesTrailingEdge ? clear : solid]
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        if layer.mask !== fade { layer.mask = fade }
    }

    /// 몸짓 단위로 방향을 정한다. 휠(몸짓 없음)은 사건마다 정한다.
    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began || event.phase == .mayBegin {
            axis = nil
        }
        if axis == nil || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            if dx > 0 || dy > 0 { axis = dx > dy ? .horizontal : .vertical }
        }
        if axis == .horizontal {
            scrollHorizontally(by: event)
        } else {
            enclosingScrollView?.scrollWheel(with: event)
        }
    }

    /// 가로 몫을 직접 옮긴다. `NSScrollView`의 기본 굴리기는 이 보기처럼 안에 든 보기에서 사건을 받지 않는 때가 있었다
    /// (시험에서 같은 사건에 0pt). 정밀한 몫(트랙패드)은 그대로, 휠의 줄 단위는 한 줄을 16pt로 친다.
    private func scrollHorizontally(by event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 16
        scrollHorizontally(to: contentView.bounds.origin.x - delta)
    }

    /// 굴린 자리를 옮긴다(그림 좌표). 막대와 시험이 쓴다.
    func scrollHorizontally(to x: CGFloat) {
        let target = min(max(0, x), overflowWidth)
        guard target != contentView.bounds.origin.x else { return }
        contentView.scroll(to: NSPoint(x: target, y: 0))
        reflectScrolledClipView(contentView)
    }

    fileprivate func canvasMouseDown(at point: NSPoint, event: NSEvent) {
        onMouseDown?(placement, point, event)
    }

    /// 그림을 그리는 문서 뷰. 위가 0이다(그림 좌표와 같다).
    fileprivate final class Canvas: NSView {
        var image: NSImage?
        weak var owner: WidePlacementView?

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high])
        }

        override func mouseDown(with event: NSEvent) {
            owner?.canvasMouseDown(at: convert(event.locationInWindow, from: nil), event: event)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// 늘 보이는 가로 막대 — 옅은 길 위의 손잡이. 손잡이를 끌면 그만큼 굴리고, 길을 누르면 손잡이가 그 자리로 와서
    /// 이어 끌 수 있다. 마우스만 쓰는 사람도 ⇧+휠 없이 옆을 볼 수 있다.
    fileprivate final class ScrollBar: NSView {
        weak var owner: WidePlacementView?
        /// 끌기를 시작한 마우스의 x와 그때 굴린 자리.
        private var drag: (mouseX: CGFloat, offset: CGFloat)?
        private var isHovered = false

        static let thickness: CGFloat = 6
        static let minimumThumb: CGFloat = 28

        override var isFlipped: Bool { true }

        /// 길 — 막대 자리의 가운데 줄.
        var track: NSRect {
            NSRect(x: 0, y: ((bounds.height - Self.thickness) / 2).rounded(), width: bounds.width, height: Self.thickness)
        }

        /// 손잡이 — 보이는 몫만큼의 길이, 굴린 만큼의 자리.
        var thumb: NSRect {
            guard let owner, owner.overflowWidth > 0 else { return track }
            let total = owner.canvas.frame.width
            let visible = owner.contentView.bounds.width
            let width = min(track.width, max(Self.minimumThumb, (track.width * visible / max(1, total)).rounded()))
            let travel = track.width - width
            let x = travel * owner.horizontalOffset / owner.overflowWidth
            return NSRect(x: track.minX + x.rounded(), y: track.minY, width: width, height: track.height)
        }

        override func draw(_ dirtyRect: NSRect) {
            let radius = Self.thickness / 2
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            (isHovered || drag != nil ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: thumb, xRadius: radius, yRadius: radius).fill()
        }

        override func mouseDown(with event: NSEvent) {
            guard let owner else { return }
            let point = convert(event.locationInWindow, from: nil)
            if !thumb.insetBy(dx: 0, dy: -bounds.height).contains(point) {
                // 길을 눌렀다 — 손잡이의 가운데가 그 자리에 오게.
                owner.scrollHorizontally(to: offset(forThumbMidX: point.x))
            }
            drag = (point.x, owner.horizontalOffset)
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let owner, let drag else { return }
            let point = convert(event.locationInWindow, from: nil)
            let travel = track.width - thumb.width
            guard travel > 0 else { return }
            owner.scrollHorizontally(to: drag.offset + (point.x - drag.mouseX) * owner.overflowWidth / travel)
        }

        override func mouseUp(with event: NSEvent) {
            drag = nil
            needsDisplay = true
        }

        /// 손잡이의 가운데가 `x`(막대 좌표)에 오는 굴린 자리.
        private func offset(forThumbMidX x: CGFloat) -> CGFloat {
            guard let owner else { return 0 }
            let travel = track.width - thumb.width
            guard travel > 0 else { return 0 }
            return (x - track.minX - thumb.width / 2) / travel * owner.overflowWidth
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            isHovered = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovered = false
            needsDisplay = true
        }
    }
}
