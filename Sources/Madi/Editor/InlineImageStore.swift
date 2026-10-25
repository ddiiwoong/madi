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

    func image(at url: URL) -> NSImage? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let key = Key(path: url.path, modified: modified, bytes: bytes)

        if let cached = cache[key] { return cached }

        guard attributes != nil, let image = NSImage(contentsOf: url), image.size.width > 0 else {
            if !reported.contains(url.path) {
                reported.insert(url.path)
                AppLog.warning("그림을 읽지 못했습니다", detail: url.path)
            }
            return nil
        }

        if cache.count >= capacity { cache.removeAll() }   // 단순하게 비운다
        cache[key] = image
        reported.remove(url.path)
        return image
    }

    func forget() {
        cache.removeAll()
        reported.removeAll()
    }
}
