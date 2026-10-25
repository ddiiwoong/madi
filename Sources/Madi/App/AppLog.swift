import Foundation

/// 앱 하나가 공유하는 기록.
///
/// Core에 두지 않은 이유: `ActivityLog`는 Foundation만 쓰는 순수한 조각이고 앞으로
/// 다른 플랫폼에 그대로 옮길 수 있어야 한다. 「앱에 하나뿐인 인스턴스」는 앱의 사정이지
/// 그 조각의 성질이 아니다. 그래서 수명은 여기서 정한다.
@MainActor
enum AppLog {
    static let shared = ActivityLog(capacity: 500)

    /// 기록이 바뀔 때마다 불린다. 열려 있는 기록 창이 자기를 새로 그리도록.
    static var onChange: (() -> Void)?

    static func info(_ message: String, detail: String? = nil) {
        shared.append(.info, message, detail: detail)
        onChange?()
    }

    static func warning(_ message: String, detail: String? = nil) {
        shared.append(.warning, message, detail: detail)
        onChange?()
    }

    static func error(_ message: String, detail: String? = nil) {
        shared.append(.error, message, detail: detail)
        onChange?()
    }
}
