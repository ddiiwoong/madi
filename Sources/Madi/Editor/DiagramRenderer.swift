import AppKit
import WebKit

/// 다이어그램·수식 하나를 그려 달라는 요청. 같은 요청은 같은 그림이다 — 캐시의 열쇠다.
public struct RenderRequest: Hashable, Sendable {
    public let kind: RenderedBlock.Kind
    public let source: String
    /// Mermaid 테마(`dark`/`default`)를 고른다.
    public let isDark: Bool
    /// 본문 글자 크기(pt). 웹뷰의 CSS px와 같은 크기다.
    public let fontSize: Double
    /// 수식 글자 색. `#rrggbb`.
    public let textColor: String
    /// CSS `font-family` 값. Mermaid 라벨과 수식 안의 `\text{}`가 쓴다.
    public let fontFamily: String

    public init(kind: RenderedBlock.Kind, source: String, isDark: Bool, fontSize: Double,
                textColor: String, fontFamily: String) {
        self.kind = kind
        self.source = source
        self.isDark = isDark
        self.fontSize = fontSize
        self.textColor = textColor
        self.fontFamily = fontFamily
    }
}

public enum RenderOutcome {
    case ready(NSImage)
    /// 그리는 중이다. 다 그리면 `DiagramRenderer.didRender`가 온다.
    case pending
    case failed(String)
}

/// 스타일러가 그림을 묻는 자리. 테스트가 웹뷰 없이 대역을 넣는다.
@MainActor
public protocol RenderedBlockImages: AnyObject {
    func image(for request: RenderRequest) -> RenderOutcome
}

/// Mermaid·KaTeX를 **숨은 웹뷰 하나로** 그린다.
///
/// 마디의 전제는 "웹뷰 없이 텍스트 시스템 하나로"다. 이 블록들만 그 전제의 예외다 —
/// Mermaid의 스물 가지가 넘는 그림 종류와 TeX 조판을 네이티브로 다시 짜는 것은 현실적이지
/// 않다(TODO '결정이 필요한 것', 2026-10-31에 숨은 웹뷰로 정했다). 그래서 예외를 좁게 둔다:
///
/// - **글은 웹뷰에 없다.** 편집은 여전히 `NSTextStorage` 하나에서 하고, 웹뷰는 블록 하나의
///   원문을 받아 그림을 돌려줄 뿐이다. 그림은 PDF로 받아 `NSImage`로 그린다 — 벡터라서
///   글자를 키우거나 프린트해도 흐려지지 않는다.
/// - **처음 필요할 때 만든다.** 그릴 블록이 없는 문서는 웹 프로세스를 띄우지 않는다.
/// - **앱 전체에 하나다**(`shared`). 창마다 만들면 웹 프로세스가 창 수만큼 뜬다.
/// - **바깥으로 아무것도 나가지 않는다.** 원격 그림을 기본으로 받지 않는 것과 같은 이유다.
///   세 겹으로 막는다: 페이지의 CSP(`default-src 'none'`, 파일만 허용), 웹킷 콘텐츠 규칙
///   (`http`·`https`·`ws`·`ftp` 차단), 처음 페이지 말고는 이동을 모두 거절하는 대리자.
///   Mermaid는 `securityLevel: strict`로 돌려 라벨의 HTML을 걷어 낸다.
/// - **원문은 인자로 넘긴다**(`callAsyncJavaScript(arguments:)`). 자바스크립트 문자열에
///   끼워 넣으면 원문의 따옴표 하나로 코드가 된다.
@MainActor
public final class DiagramRenderer: NSObject, RenderedBlockImages {

    /// 앱이 쓰는 하나. 자원은 앱 번들의 `Diagrams` 폴더다.
    public static let shared = DiagramRenderer(resources: Bundle.main.resourceURL?
        .appendingPathComponent("Diagrams", isDirectory: true))

    /// 그림이 새로 생기거나 실패가 정해졌다. `object`는 이 렌더러다 — 편집기가 다시 칠한다.
    public static let didRender = Notification.Name("DiagramRenderer.didRender")

    private let resources: URL?

    private var cache: [RenderRequest: NSImage] = [:]
    private var failures: [RenderRequest: String] = [:]
    private var queue: [RenderRequest] = []
    private var queued: Set<RenderRequest> = []
    private var isWorking = false
    /// 캐시가 무한정 자라지 않게 한다. 그림은 PDF라 하나가 수십 KB다.
    private let capacity = 96

    private var webView: WKWebView?
    private var pageLoad: CheckedContinuation<Void, Error>?

    /// 그린 횟수. 테스트가 캐시를 확인하는 데 쓴다.
    private(set) var renderCount = 0

    public init(resources: URL?) {
        self.resources = resources
        super.init()
    }

    public func image(for request: RenderRequest) -> RenderOutcome {
        if let image = cache[request] { return .ready(image) }
        if let failure = failures[request] { return .failed(failure) }
        if queued.insert(request).inserted {
            queue.append(request)
            startIfNeeded()
        }
        return .pending
    }

    /// 웹 프로세스를 내린다. 캐시는 남긴다.
    public func shutDown() {
        webView?.navigationDelegate = nil
        webView = nil
    }

    // MARK: 차례로 그리기

    private func startIfNeeded() {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            await drain()
            isWorking = false
            NotificationCenter.default.post(name: Self.didRender, object: self)
            // 그리는 동안 들어온 요청이 남았으면 이어 간다.
            if !queue.isEmpty { startIfNeeded() }
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let request = queue.removeFirst()
            do {
                let image = try await render(request)
                if cache.count >= capacity { cache.removeAll() }    // 단순하게 비운다
                cache[request] = image
            } catch {
                let message = Self.message(of: error)
                failures[request] = message
                AppLog.warning(request.kind == .math
                               ? String(localized: "수식을 그리지 못했습니다")
                               : String(localized: "다이어그램을 그리지 못했습니다"),
                               detail: message)
            }
            queued.remove(request)
        }
    }

    private static func message(of error: Error) -> String {
        let info = (error as NSError).userInfo
        if let text = info["WKJavaScriptExceptionMessage"] as? String { return text }
        return error.localizedDescription
    }

    // MARK: 웹뷰

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func render(_ request: RenderRequest) async throws -> NSImage {
        let web = try await page()
        renderCount += 1
        let value = try await web.callAsyncJavaScript(
            "return await renderBlock(kind, source, dark, fontSize, color, fontFamily)",
            arguments: [
                "kind": request.kind.rawValue,
                "source": request.source,
                "dark": request.isDark,
                "fontSize": request.fontSize,
                "color": request.textColor,
                "fontFamily": request.fontFamily,
            ],
            in: nil, contentWorld: .page)
        guard let box = value as? [String: Any],
              let x = box["x"] as? Double, let y = box["y"] as? Double,
              let width = box["width"] as? Double, let height = box["height"] as? Double,
              width >= 1, height >= 1 else {
            throw Failure(message: String(localized: "그림의 크기를 알 수 없습니다"))
        }
        // 웹뷰보다 큰 그림은 잘린다 — 창을 그림만큼 키운 뒤 찍는다.
        let needed = NSSize(width: max(web.frame.width, ceil(x + width)),
                            height: max(web.frame.height, ceil(y + height)))
        if needed != web.frame.size { web.setFrameSize(needed) }

        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: x, y: y, width: ceil(width), height: ceil(height))
        let data = try await web.pdf(configuration: configuration)
        guard let image = NSImage(data: data), image.size.width > 0 else {
            throw Failure(message: String(localized: "그림을 PDF로 받지 못했습니다"))
        }
        return image
    }

    /// 그리는 페이지. 처음 부를 때 웹뷰를 만들고 페이지를 싣는다.
    private func page() async throws -> WKWebView {
        if let webView { return webView }
        guard let resources,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("render.html").path)
        else {
            throw Failure(message: String(localized: "그림을 그릴 자원이 앱에 없습니다"))
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        await attachOfflineRules(to: configuration)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1200),
                            configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")     // 그림 뒤를 비운다
        web.navigationDelegate = self
        webView = web

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pageLoad = continuation
                // 읽기 권한은 자원 폴더의 **부모**까지 준다 — 앱에 든 본문 글꼴(Pretendard)을
                // 페이지가 `@font-face`로 쓴다. 다른 곳은 읽을 수 없다.
                web.loadFileURL(resources.appendingPathComponent("render.html"),
                                allowingReadAccessTo: resources.deletingLastPathComponent())
            }
        } catch {
            webView = nil
            throw error
        }
        return web
    }

    /// 바깥 주소를 막는 웹킷 규칙. 저장소는 임시 폴더에 둔다 — 기본 저장소는 사용자의
    /// `~/Library`에 파일을 남긴다.
    private static func offlineRules() async throws -> WKContentRuleList? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("madi-content-rules", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: folder) else { return nil }
        return try await store.compileContentRuleList(forIdentifier: "madi.diagrams.offline",
                                                      encodedContentRuleList: offlineRuleSource)
    }

    /// 규칙 원문. **스킴마다 규칙 하나**다 — 웹킷의 규칙 정규식은 `|`를 받지 않는다
    /// (`^(https?|wss?|ftp)://`는 "Disjunctions are not supported"로 컴파일되지 않았다, 실측).
    static let offlineRuleSource: String = {
        let rules = ["^https?://", "^wss?://", "^ftp://"].map {
            #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"#
        }
        return "[" + rules.joined(separator: ",") + "]"
    }()

    /// 규칙이 실제로 붙었는가. 테스트가 본다 — 컴파일이 실패해도 그리기는 되므로, 보지 않으면
    /// 벽 하나가 조용히 빠진다.
    private(set) var hasOfflineRules = false

    private func attachOfflineRules(to configuration: WKWebViewConfiguration) async {
        do {
            if let rules = try await Self.offlineRules() {
                configuration.userContentController.add(rules)
                hasOfflineRules = true
            }
        } catch {
            AppLog.warning(String(localized: "웹뷰의 바깥 요청 차단 규칙을 만들지 못했습니다 — 페이지의 CSP만 막습니다"),
                           detail: error.localizedDescription)
        }
    }

    /// 테스트만 쓴다 — 페이지 안에서 바깥 요청이 막히는지 확인한다.
    func evaluateInPage(_ body: String) async throws -> Any? {
        let web = try await page()
        return try await web.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }
}

extension DiagramRenderer: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoad?.resume()
        pageLoad = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoad?.resume(throwing: error)
        pageLoad = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        pageLoad?.resume(throwing: error)
        pageLoad = nil
    }

    /// 처음 싣는 페이지 말고는 어디로도 가지 않는다 — 그림 안의 링크도, 스크립트의 이동도.
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, url.isFileURL,
              url.lastPathComponent == "render.html", pageLoad != nil else { return .cancel }
        return .allow
    }

    /// 웹 프로세스가 죽으면 다음 그림에서 다시 띄운다.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if self.webView === webView { self.webView = nil }
        pageLoad?.resume(throwing: Failure(message: String(localized: "그림을 그리던 웹 프로세스가 멈췄습니다")))
        pageLoad = nil
    }
}
