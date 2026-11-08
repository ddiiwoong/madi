import AppKit

/// 글 넓이보다 넓은 그림 — 긴 줄이 있는 코드 블록(`CodeBlockRendering`), 열을 읽을 만한 폭으로 둔 넓은 표
/// (`TableGrid`) — 을 **그 자리에서 가로로 굴려** 보이는 보기. 텍스트 뷰(`DecoratedTextView`) 안의 보조 뷰라
/// 글과 함께 위아래로 굴러간다. GitHub · Docusaurus의 `overflow-x: auto`와 같다.
///
/// - 굴리기: 가로로 굴리면(트랙패드 두 손가락, ⇧+휠) 이 보기가 굴리고, 세로로 굴리면 문서가 굴러간다. 한 번의 몸짓
///   안에서는 처음 정한 방향을 지킨다 — 비스듬히 굴릴 때 두 쪽이 번갈아 받으면 화면이 떤다.
/// - 누르기: 텍스트 뷰가 정한다(`onMouseDown`, 점은 그림 좌표). 코드면 그 글자에 캐럿을 놓고(블록이 원문이 된다),
///   표면 ⌘클릭이 칸의 링크를 연다.
/// - 막대: 겹쳐 그리는 스크롤 막대를 쓴다 — 늘 보이는 막대는 그림의 아랫줄을 가린다. 마우스가 들어오면 막대를 잠깐
///   보여, 옆으로 더 있다는 것을 알린다.
@MainActor
final class WidePlacementView: NSScrollView {

    private(set) var placement: MarkdownStyler.ImagePlacement
    /// 누른 점(그림 좌표)과 사건. 텍스트 뷰가 단다.
    var onMouseDown: ((MarkdownStyler.ImagePlacement, NSPoint, NSEvent) -> Void)?

    private let canvas = Canvas()

    private enum Axis { case horizontal, vertical }
    /// 이번 몸짓이 굴리는 방향. 몸짓이 시작될 때 정한다.
    private var axis: Axis?

    init(placement: MarkdownStyler.ImagePlacement) {
        self.placement = placement
        super.init(frame: .zero)
        drawsBackground = false
        contentView.drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .allowed
        usesPredominantAxisScrolling = true
        documentCursor = .iBeam
        canvas.owner = self
        documentView = canvas
        show(placement)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 그림을 바꾼다. 같은 그림이면 굴린 자리를 지킨다.
    func show(_ placement: MarkdownStyler.ImagePlacement) {
        let changed = placement.image !== self.placement.image || placement.size != canvas.frame.size
        self.placement = placement
        guard changed || canvas.image == nil else { return }
        canvas.image = placement.image
        canvas.setFrameSize(placement.size)
        canvas.needsDisplay = true
        reflectScrolledClipView(contentView)
    }

    /// 지금 굴린 만큼(pt). 시험이 쓴다.
    var horizontalOffset: CGFloat { contentView.bounds.origin.x }

    /// 늘 겹쳐 그리는 막대 — 시스템이 '항상 보이기'(마우스를 쓰는 Mac)여도. 늘 보이는 막대는 칸에서 16pt를 가져가
    /// 그림의 아랫줄을 가리고 그 칸 안에서 세로로도 굴렀다(이 Mac에서 처음 봄: 그림 78pt, 칸 62pt). 겹친 막대는 마우스가
    /// 들어올 때 잠깐 보이고(`flashScrollers`) 그때 끌 수 있다.
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
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
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) { flashScrollers() }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 16
        let widest = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        let x = min(max(0, contentView.bounds.origin.x - delta), widest)
        guard x != contentView.bounds.origin.x else { return }
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }

    /// 굴린 자리를 옮긴다(그림 좌표). 시험이 쓴다.
    func scrollHorizontally(to x: CGFloat) {
        let widest = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        contentView.scroll(to: NSPoint(x: min(max(0, x), widest), y: 0))
        reflectScrolledClipView(contentView)
    }

    // MARK: 마우스가 들어오면 막대를 잠깐

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["wide"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["wide": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        flashScrollers()
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
}
