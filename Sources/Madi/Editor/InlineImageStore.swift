import AppKit

/// 문서에 걸린 그림을 읽어 두고 다시 쓴다.
///
/// 왜 캐시가 필요한가: 스타일 패스는 글자를 칠 때마다 돈다. 그때마다 디스크에서 그림을
/// 다시 읽으면 타이핑이 멈춘다.
///
/// 열쇠에 **수정 시각과 크기**를 넣는다. 경로만 열쇠로 쓰면 사용자가 그림 파일을 고쳐도
/// 옛 그림이 계속 보인다.
@MainActor
final class InlineImageStore {

    private struct Key: Hashable {
        let path: String
        let modified: TimeInterval
        let bytes: Int
    }

    private var cache: [Key: NSImage] = [:]
    /// 읽기에 실패한 경로. 같은 실패를 기록에 반복해 쌓지 않기 위해 기억한다.
    private var reported: Set<String> = []

    /// 캐시가 무한정 자라지 않게 한다. 그림이 큰 문서를 여러 개 열어 둘 수 있다.
    private let capacity = 48

    // MARK: 원격 그림

    /// 원격 그림을 받아올지. **기본이 꺼짐이다.** 설정에서만 켜진다.
    var loadsRemote = false {
        didSet {
            guard oldValue != loadsRemote, !loadsRemote else { return }
            // 꺼면 받아 둔 것도 버린다 — 끈 뒤에도 보이면 껐다는 말이 거짓이 된다.
            remoteCache.removeAll()
            remoteFailed.removeAll()
            inFlight.removeAll()
        }
    }

    /// 받아 둔 원격 그림. 열쇠는 주소다(원격은 수정 시각을 알 수 없다).
    private var remoteCache: [String: NSImage] = [:]
    /// 받기에 실패한 주소. 다시 시도하지 않는다 — 스타일 패스마다 재시도하면
    /// 타이핑 한 번에 요청이 수십 번 나간다.
    private var remoteFailed: Set<String> = []
    /// 지금 받고 있는 주소. 같은 그림을 두 번 받지 않기 위한 것이다.
    private var inFlight: Set<String> = []

    /// 받아 두는 크기의 상한. 문서에 걸린 주소가 몇 백 MB 파일을 가리킬 수도 있다.
    static let maxRemoteBytes = 20 * 1024 * 1024

    /// 원격 그림이 도착했을 때 부를 것. 편집기가 넣어 주고, 다시 칠하게 한다.
    var onRemoteImageLoaded: (() -> Void)?

    /// 요청 하나를 보내고 끝나면 부른다. 앱은 아래 세션이고, 테스트가 바꾼다 — 바깥으로 요청을
    /// 내지 않고 받기 정책(https만, 크기 상한, 실패는 다시 안 함)을 시험한다.
    typealias Fetch = (URLRequest, @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> Void
    lazy var fetch: Fetch = { [unowned self] request, completion in
        self.session.dataTask(with: request, completionHandler: completion).resume()
    }

    /// 받기에 쓰는 세션. 리다이렉트는 대리자가 가려 **https만** 따라간다.
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration,
                          delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    func image(at url: URL) -> NSImage? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let key = Key(path: url.path, modified: modified, bytes: bytes)

        if let cached = cache[key] { return cached }

        guard attributes != nil, let image = NSImage(contentsOf: url), image.size.width > 0 else {
            if !reported.contains(url.path) {
                reported.insert(url.path)
                AppLog.warning(String(localized: "그림을 읽지 못했습니다"), detail: url.path)
            }
            return nil
        }

        if cache.count >= capacity { cache.removeAll() }   // 단순하게 비운다
        cache[key] = image
        reported.remove(url.path)
        return image
    }

    /// 원격 그림. 이미 받아 뒀으면 그것을, 아니면 **nil을 돌려주고 받기를 시작한다** —
    /// 스타일 패스는 기다릴 수 없다(타이핑 중에 돈다). 도착하면
    /// `onRemoteImageLoaded`가 불려 다시 칠한다.
    func remoteImage(at url: URL) -> NSImage? {
        guard loadsRemote else { return nil }
        let key = url.absoluteString
        if let cached = remoteCache[key] { return cached }
        guard !remoteFailed.contains(key), !inFlight.contains(key) else { return nil }
        guard url.scheme?.lowercased() == "https" else {
            remoteFailed.insert(key)
            AppLog.warning(String(localized: "https가 아닌 원격 그림은 받지 않습니다"), detail: key)
            return nil
        }

        inFlight.insert(key)
        fetch(URLRequest(url: url)) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight.remove(key)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, (200 ..< 300).contains(code), let data,
                      data.count <= Self.maxRemoteBytes,
                      let image = NSImage(data: data), image.size.width > 0 else {
                    self.remoteFailed.insert(key)
                    AppLog.warning(String(localized: "원격 그림을 받지 못했습니다"),
                                   detail: "\(key) — \(error?.localizedDescription ?? "HTTP \(code)")")
                    return
                }
                if self.remoteCache.count >= self.capacity { self.remoteCache.removeAll() }
                self.remoteCache[key] = image
                AppLog.info(String(localized: "원격 그림을 받았습니다"), detail: String(localized: "\(key) — \(data.count)바이트"))
                self.onRemoteImageLoaded?()
            }
        }
        return nil
    }

    func forget() {
        cache.removeAll()
        reported.removeAll()
        remoteCache.removeAll()
        remoteFailed.removeAll()
    }

    /// 리다이렉트를 가린다. `https` → `http` 강등을 막는다 — 그 한 걸음에서 요청이
    /// 평문으로 나가고, 중간에 있는 누구나 어떤 문서를 열었는지 볼 수 있다.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = RedirectGuard()

        /// 따라갈 리다이렉트 수의 상한. 끝없는 리다이렉트 사슬을 막는다.
        static let maxHops = 3
        private let lock = NSLock()
        private var hops: [Int: Int] = [:]

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            lock.lock()
            let count = (hops[task.taskIdentifier] ?? 0) + 1
            hops[task.taskIdentifier] = count
            lock.unlock()

            guard count <= Self.maxHops,
                  request.url?.scheme?.lowercased() == "https" else {
                completionHandler(nil)      // 따라가지 않는다
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            lock.lock()
            hops[task.taskIdentifier] = nil
            lock.unlock()
        }
    }
}
