import AppKit
import XCTest

/// 숨은 웹뷰로 실제로 그리는지 — 저장소의 `Resources/Diagrams`를 싣는다.
///
/// 웹 프로세스를 띄우므로 한 묶음에 1초 남짓 걸린다. 대역으로 덮지 않는 이유: 이 길의 결함은
/// 거의 다 웹뷰 쪽에 있다(글꼴을 받기 전에 찍기, 그림이 페이지 폭을 따라가기, 크기 0) — 대역은
/// 그것을 하나도 보지 못한다.
@MainActor
final class DiagramRendererTests: XCTestCase {

    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MadiTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo
        .appendingPathComponent("Sources/Madi/Resources/Diagrams", isDirectory: true)

    private var renderer: DiagramRenderer!

    override func setUp() async throws {
        renderer = DiagramRenderer(resources: Self.resources)
    }

    override func tearDown() async throws {
        renderer.shutDown()
        renderer = nil
    }

    private func request(_ kind: RenderedBlock.Kind, _ source: String, dark: Bool = false) -> RenderRequest {
        RenderRequest(kind: kind, source: source, isDark: dark, fontSize: 15,
                      textColor: dark ? "#ffffff" : "#1d1d1f",
                      fontFamily: "\"Pretendard\", -apple-system, sans-serif")
    }

    /// 다 그릴 때까지 기다린다(`didRender`).
    private func outcome(of request: RenderRequest) async -> RenderOutcome {
        let first = renderer.image(for: request)
        guard case .pending = first else { return first }
        let arrived = expectation(forNotification: DiagramRenderer.didRender, object: renderer)
        await fulfillment(of: [arrived], timeout: 20)
        return renderer.image(for: request)
    }

    private func image(_ outcome: RenderOutcome, file: StaticString = #filePath,
                       line: UInt = #line) -> NSImage? {
        switch outcome {
        case let .ready(image): return image
        case .pending: XCTFail("아직 그리는 중", file: file, line: line)
        case let .failed(message): XCTFail("그리지 못했다: \(message)", file: file, line: line)
        }
        return nil
    }

    func testMermaidFlowchartRenders() async {
        let picture = image(await outcome(of: request(.mermaid, "graph TD\n  A[시작] --> B{조건}\n  B --> C[끝]")))
        let size = picture?.size ?? .zero
        // 그림 자신의 크기여야 한다 — 페이지 폭(1200)을 따라가면 viewBox 고정이 빠진 것이다.
        XCTAssertGreaterThan(size.width, 60)
        XCTAssertLessThan(size.width, 600)
        XCTAssertGreaterThan(size.height, 150, "세 칸이 세로로 선다")
        // 벡터(PDF)다 — 키워도 흐려지지 않는다.
        XCTAssertTrue(picture?.representations.contains { $0 is NSPDFImageRep } == true)
    }

    /// 그림은 **자기 크기**로 찍힌다. Mermaid는 그림을 `width="100%"`로 주는데, 그림 크기만 한
    /// 상자 안에서 100%는 정할 수 없어 웹킷이 기본값 300px로 접는다 — 원그래프·간트·마인드맵이
    /// 304pt로 찌그러졌다(실측, 고치기 전). 순서도처럼 `max-width`를 함께 주는 종류는 멀쩡해서
    /// 순서도만 보면 놓친다.
    func testDiagramsKeepTheirOwnSize() async {
        let pie = image(await outcome(of: request(.mermaid, "pie title 비율\n  \"가\" : 40\n  \"나\" : 60")))
        XCTAssertGreaterThan(pie?.size.width ?? 0, 400, "원그래프가 접혔다")

        let gantt = image(await outcome(of: request(.mermaid, """
            gantt
              dateFormat YYYY-MM-DD
              section 가
              일 하나 :a1, 2026-01-01, 30d
              일 둘 :after a1, 20d
            """)))
        // 간트는 정해 둔 폭(800)을 쓴다 — 숨은 페이지의 폭(1200)을 따라가지 않는다.
        XCTAssertEqual(gantt?.size.width ?? 0, 804, accuracy: 30)
    }

    /// 수식은 KaTeX 글꼴을 **받은 뒤에** 찍어야 한다. 전에(시제품) 글꼴을 기다리지 않아
    /// ∫·e·π가 빠진 채 찍혔다 — 그때 폭이 132pt, 글꼴이 있으면 145pt였다.
    func testMathRendersWithItsFonts() async throws {
        // 다이어그램을 먼저 그린다 — 시제품에서 글꼴이 빠졌던 것도 그 순서였다(페이지가 이미
        // 떠 있고 KaTeX 글꼴은 아직 한 번도 쓰이지 않은 상태).
        _ = await outcome(of: request(.mermaid, "graph TD\n  A --> B"))
        let source = "\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}"
        let picture = image(await outcome(of: request(.math, source)))
        XCTAssertGreaterThan(picture?.size.height ?? 0, 30)
        // 찍힌 PDF에 KaTeX 글꼴이 들어 있어야 한다. 페이지의 글꼴 상태를 나중에 물으면 그사이에
        // 받기가 끝나 있어 놓친다 — 그림 자체를 본다.
        let pdf = picture?.representations.compactMap { ($0 as? NSPDFImageRep)?.pdfRepresentation }.first
        let bytes = String(decoding: pdf ?? Data(), as: UTF8.self)
        XCTAssertTrue(bytes.contains("KaTeX_Main"), "본문 글꼴이 PDF에 없다")
        XCTAssertTrue(bytes.contains("KaTeX_Size"), "적분 기호(Size 글꼴)가 PDF에 없다")
    }

    func testBrokenSourceFailsWithTheParserMessage() async {
        guard case let .failed(message) = await outcome(of: request(.mermaid, "graph TD\n  A -->")) else {
            return XCTFail("틀린 원문이 그림이 됐다")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("parse"), message)

        guard case let .failed(math) = await outcome(of: request(.math, "\\frac{1}{")) else {
            return XCTFail("틀린 수식이 그림이 됐다")
        }
        XCTAssertTrue(math.contains("KaTeX"), math)
    }

    /// 원문은 **인자로** 넘긴다. 자바스크립트에 끼워 넣었다면 따옴표·백틱·`</script>`가 코드를
    /// 끊어 실패했을 것이다.
    func testSourceIsPassedAsDataNotCode() async {
        let tricky = "graph LR\n  A[\"따옴표 ' ` ${x} </script>\"] --> B"
        let result = await outcome(of: request(.mermaid, tricky))
        XCTAssertNotNil(image(result))
    }

    /// 같은 요청은 다시 그리지 않는다. 외관이 바뀌면 다시 그린다(테마가 다르다).
    func testSameRequestIsCached() async {
        let light = request(.math, "a^2 + b^2 = c^2")
        _ = await outcome(of: light)
        let count = renderer.renderCount
        guard case .ready = renderer.image(for: light) else { return XCTFail("캐시에 없다") }
        XCTAssertEqual(renderer.renderCount, count)

        _ = image(await outcome(of: request(.math, "a^2 + b^2 = c^2", dark: true)))
        XCTAssertEqual(renderer.renderCount, count + 1)
    }

    /// 바깥으로 나가지 않는다 — 페이지의 CSP가 막는지 본다. 막혔으면 위반 이벤트가 온다.
    /// (요청이 그냥 실패한 것과 가른다: 네트워크가 없어도 fetch는 실패한다.)
    func testPageCannotReachTheNetwork() async throws {
        let result = try await renderer.evaluateInPage("""
            let violated = "";
            document.addEventListener("securitypolicyviolation", e => { violated = e.violatedDirective; });
            try { await fetch("https://example.com/"); } catch (e) {}
            const img = new Image(); img.src = "https://example.com/x.png";
            await new Promise(r => setTimeout(r, 300));
            return violated;
            """) as? String ?? ""
        XCTAssertFalse(result.isEmpty, "CSP 위반이 없었다 — 요청이 막히지 않았다")
        // 두 번째 벽(웹킷 콘텐츠 규칙)도 붙어 있어야 한다. 처음 쓴 규칙은 정규식에 `|`가 있어
        // 컴파일되지 않았고, 그래도 그리기는 되어서 아무도 몰랐다.
        XCTAssertTrue(renderer.hasOfflineRules, "콘텐츠 규칙이 붙지 않았다")
    }

    /// 자원이 없으면(번들이 깨졌을 때) 실패로 끝난다 — 기다리다 멈추지 않는다.
    func testMissingResourcesFail() async {
        let broken = DiagramRenderer(resources: URL(fileURLWithPath: "/nonexistent/Diagrams"))
        renderer = broken
        guard case .failed = await outcome(of: request(.math, "x")) else {
            return XCTFail("자원 없이 그렸다")
        }
    }
}
