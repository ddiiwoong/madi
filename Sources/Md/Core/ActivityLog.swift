import Foundation

/// 앱이 한 일과 실패를 남기는 기록.
///
/// 왜 필요한가: 전에는 모든 상태 문구가 모달 경고창이었다. 그래서 두 가지가 동시에
/// 나빴다 — 성공했다는 말이 작업을 가로막고(「번역했습니다」를 읽고 확인을 눌러야 했다),
/// 실패는 **닫는 순간 사라졌다**. 긴 번역이 실패했는데 경고창을 무심코 닫으면 무엇이
/// 왜 실패했는지 다시 볼 길이 없었다.
///
/// 그래서 기록을 따로 둔다. 성공은 가로막지 않고 지나가되 기록에 남고, 실패는 즉시
/// 알리면서 **기록에도 남는다**.
///
/// 한계가 있는 고리 버퍼다. 오래 켜 둔 창이 기억을 무한정 먹지 않게 `capacity`를 넘으면
/// 가장 오래된 것을 버린다.
public final class ActivityLog {

    public enum Level: String, Sendable, CaseIterable {
        case info
        case warning
        case error

        /// 목록에서 눈에 띄게 하는 머리글자.
        public var symbol: String {
            switch self {
            case .info: return "·"
            case .warning: return "!"
            case .error: return "✕"
            }
        }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let date: Date
        public let level: Level
        public let message: String
        /// 자세한 내용(오류 설명 등). 없을 수 있다.
        public let detail: String?

        public init(id: UUID = UUID(), date: Date = Date(), level: Level,
                    message: String, detail: String? = nil) {
            self.id = id
            self.date = date
            self.level = level
            self.message = message
            self.detail = detail
        }
    }

    public let capacity: Int
    private var storage: [Entry] = []

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    /// 기록을 더한다. 가장 오래된 것이 한계를 넘으면 버려진다.
    public func append(_ entry: Entry) {
        storage.append(entry)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public func append(_ level: Level, _ message: String, detail: String? = nil) {
        append(Entry(level: level, message: message, detail: detail))
    }

    /// **최근 것이 먼저**다. 목록에서 위가 최신이기를 바라기 때문이다.
    public var entries: [Entry] {
        storage.reversed()
    }

    /// 기록한 순서 그대로. 내보내기와 테스트에서 쓴다.
    public var entriesOldestFirst: [Entry] {
        storage
    }

    public var count: Int { storage.count }

    public func clear() {
        storage.removeAll()
    }

    /// 한 수준만 골라 본다 — 실패만 훑고 싶을 때.
    public func entries(atLeast level: Level) -> [Entry] {
        let order: [Level] = [.info, .warning, .error]
        guard let minimum = order.firstIndex(of: level) else { return entries }
        return entries.filter { (order.firstIndex(of: $0.level) ?? 0) >= minimum }
    }

    /// 사람이 읽을 한 줄. 목록과 클립보드 복사가 같은 모양을 쓰게 한다.
    public static func line(for entry: Entry, formatter: DateFormatter) -> String {
        let stamp = formatter.string(from: entry.date)
        let detail = entry.detail.map { " — \($0)" } ?? ""
        return "\(stamp)  \(entry.level.symbol)  \(entry.message)\(detail)"
    }

    /// 목록이 쓰는 시각 형식. 날짜는 뺀다 — 한 세션 안의 기록이라 시각만으로 충분하다.
    public static func timeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }
}
