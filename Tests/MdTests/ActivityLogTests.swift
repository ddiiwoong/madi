import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

final class ActivityLogTests: XCTestCase {

    func testNewestFirstIsWhatTheListShows() {
        let log = ActivityLog()
        log.append(.info, "첫째")
        log.append(.info, "둘째")
        log.append(.error, "셋째")
        XCTAssertEqual(log.entries.map(\.message), ["셋째", "둘째", "첫째"])
        XCTAssertEqual(log.entriesOldestFirst.map(\.message), ["첫째", "둘째", "셋째"])
    }

    func testTheRingDropsTheOldestNotTheNewest() {
        // 오래 켜 둔 창이 기억을 무한정 먹지 않게 한다. 버릴 것은 **오래된** 쪽이다 —
        // 최근 실패를 버리면 기록의 뜻이 없다.
        let log = ActivityLog(capacity: 3)
        for index in 1 ... 10 { log.append(.info, "\(index)") }
        XCTAssertEqual(log.count, 3)
        XCTAssertEqual(log.entries.map(\.message), ["10", "9", "8"])
    }

    func testCapacityIsNeverZeroOrNegative() {
        // 0이면 append가 모든 것을 버려 조용히 아무것도 기록하지 않는다.
        XCTAssertEqual(ActivityLog(capacity: 0).capacity, 1)
        XCTAssertEqual(ActivityLog(capacity: -5).capacity, 1)
        let log = ActivityLog(capacity: 0)
        log.append(.error, "남아야 한다")
        XCTAssertEqual(log.count, 1)
    }

    func testFilteringByLevelKeepsOrderAndRaisesTheFloor() {
        let log = ActivityLog()
        log.append(.info, "알림")
        log.append(.warning, "주의")
        log.append(.error, "실패")
        XCTAssertEqual(log.entries(atLeast: .error).map(\.message), ["실패"])
        XCTAssertEqual(log.entries(atLeast: .warning).map(\.message), ["실패", "주의"])
        XCTAssertEqual(log.entries(atLeast: .info).count, 3)
    }

    func testDetailIsOptionalAndSurvives() {
        let log = ActivityLog()
        log.append(.error, "번역하지 못했습니다", detail: "언어 팩이 없습니다")
        XCTAssertEqual(log.entries.first?.detail, "언어 팩이 없습니다")
        log.append(.info, "저장했습니다")
        XCTAssertNil(log.entries.first?.detail)
    }

    func testClearEmptiesTheLog() {
        let log = ActivityLog()
        log.append(.info, "하나")
        log.clear()
        XCTAssertEqual(log.count, 0)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testTheRenderedLineCarriesTimeLevelMessageAndDetail() {
        let formatter = ActivityLog.timeFormatter()
        let date = Date(timeIntervalSince1970: 0)
        let entry = ActivityLog.Entry(date: date, level: .error,
                                      message: "실패했습니다", detail: "까닭")
        let line = ActivityLog.line(for: entry, formatter: formatter)
        XCTAssertTrue(line.contains("✕"), line)
        XCTAssertTrue(line.contains("실패했습니다"), line)
        XCTAssertTrue(line.contains("까닭"), line)
        XCTAssertTrue(line.contains(formatter.string(from: date)), line)
    }

    func testEveryLevelHasADistinctSymbol() {
        let symbols = Set(ActivityLog.Level.allCases.map(\.symbol))
        XCTAssertEqual(symbols.count, ActivityLog.Level.allCases.count,
                       "수준끼리 기호가 겹치면 목록에서 구별이 안 된다")
    }
}
