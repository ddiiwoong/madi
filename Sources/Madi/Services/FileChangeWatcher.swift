import Foundation

/// 파일 하나를 지켜보다가 바뀌면 알린다 — `DispatchSource`의 파일 감시(커널의 vnode 알림, 쉬는 동안 비용이 없다).
///
/// - **몰아서 알린다.** 로그는 초에 수십 번 쓸 수 있다. 첫 신호 뒤 `interval`(0.3초)이 지나면 한 번 알리고, 그동안 온 신호는
///   그 한 번에 묻는다. 신호마다 미루는(trailing) 방식은 쉬지 않고 쓰는 로그에서 한 번도 알리지 못한다.
/// - **바꿔 넣는 저장을 따라간다.** 편집기들(마디도)은 새 파일을 써서 옛 파일과 바꾼다 — 그러면 열어 둔 파일은 지워진 쪽이라
///   신호가 끊긴다. 지움 · 이름 바뀜이 오면 같은 경로를 다시 연다. 없으면(로그를 돌려 옮기고 아직 새로 만들지 않음) 1초마다 다시
///   열어 본다 — `open` 한 번이라 싸다.
/// - 알림은 메인 스레드에서 온다. 무엇이 바뀌었는지는 받는 쪽이 파일을 보고 정한다(`ExternalFileChange`).
@MainActor
final class FileChangeWatcher {

    let url: URL
    private let interval: TimeInterval
    private let onChange: @MainActor () -> Void
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var cancelled = false

    /// 지금 파일에 붙어 있는가. 시험이 쓴다.
    var isAttached: Bool { source != nil }

    static let retryInterval: TimeInterval = 1

    init(url: URL, interval: TimeInterval = 0.3, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.interval = interval
        self.onChange = onChange
        attach()
    }

    deinit {
        source?.cancel()
    }

    func cancel() {
        cancelled = true
        source?.cancel()
        source = nil
        pending?.cancel()
        pending = nil
        retry?.cancel()
        retry = nil
    }

    @discardableResult
    private func attach() -> Bool {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke, .link],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleEvent() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    private func handleEvent() {
        guard let source, !cancelled else { return }
        let events = source.data
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            // 붙어 있던 파일이 떠났다 — 바꿔 넣는 저장이면 같은 경로에 새 파일이 곧(이미) 선다.
            source.cancel()
            self.source = nil
            reattach(after: 0.05)
        }
        scheduleChange()
    }

    private func reattach(after delay: TimeInterval) {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.cancelled else { return }
                self.retry = nil
                if self.attach() {
                    self.scheduleChange()
                } else {
                    self.reattach(after: Self.retryInterval)
                }
            }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleChange() {
        guard pending == nil, !cancelled else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.cancelled else { return }
                self.pending = nil
                self.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }
}
