import XCTest

/// 번역 캐시 — 같은 방향의 같은 글은 번역기에 다시 보내지 않는다.
final class TranslationCacheTests: XCTestCase {

    func testStoresAndReturnsByDirectionAndText() {
        let cache = TranslationCache()
        cache.store("Hello", of: "안녕", from: "ko", to: "en")
        XCTAssertEqual(cache.translation(of: "안녕", from: "ko", to: "en"), "Hello")
        XCTAssertNil(cache.translation(of: "안녕", from: "ko", to: "ja"), "방향이 다르면 다른 열쇠다")
        XCTAssertNil(cache.translation(of: "안녕 ", from: "ko", to: "en"), "글이 한 글자라도 다르면 없다")
    }

    /// 번역기가 비어 돌려준 것은 기억하지 않는다 — 실패를 기억하면 다음 번역도 빈 자리를 받는다.
    func testDoesNotRememberABlankTranslationOfRealText() {
        let cache = TranslationCache()
        cache.store("   ", of: "안녕", from: "ko", to: "en")
        XCTAssertNil(cache.translation(of: "안녕", from: "ko", to: "en"))
        cache.store(" ", of: " ", from: "ko", to: "en")
        XCTAssertEqual(cache.translation(of: " ", from: "ko", to: "en"), " ", "빈 글의 빈 번역은 맞는 답이다")
    }

    /// 한도를 넘으면 먼저 넣은 것부터 버린다.
    func testEvictsOldestFirstWhenOverBudget() {
        let cache = TranslationCache(characterBudget: 20)
        cache.store("aaaaa", of: "11111", from: "ko", to: "en")   // 10
        cache.store("bbbbb", of: "22222", from: "ko", to: "en")   // 20
        XCTAssertEqual(cache.count, 2)
        cache.store("ccccc", of: "33333", from: "ko", to: "en")   // 30 → 첫 것을 버린다
        XCTAssertNil(cache.translation(of: "11111", from: "ko", to: "en"))
        XCTAssertEqual(cache.translation(of: "22222", from: "ko", to: "en"), "bbbbb")
        XCTAssertEqual(cache.translation(of: "33333", from: "ko", to: "en"), "ccccc")
    }

    /// 같은 열쇠를 다시 넣으면 크기를 두 번 세지 않는다 — 두 번 세면 멀쩡한 것까지 버린다.
    func testReplacingAnEntryDoesNotDoubleCount() {
        let cache = TranslationCache(characterBudget: 20)
        cache.store("aaaaa", of: "11111", from: "ko", to: "en")
        for _ in 0..<5 { cache.store("aaaaa", of: "11111", from: "ko", to: "en") }
        cache.store("bbbbb", of: "22222", from: "ko", to: "en")
        XCTAssertEqual(cache.count, 2, "다시 넣은 것을 새로 센 탓에 버렸다")
    }

    func testEntryLargerThanTheBudgetIsNotStored() {
        let cache = TranslationCache(characterBudget: 4)
        cache.store("abc", of: "def", from: "ko", to: "en")
        XCTAssertEqual(cache.count, 0)
    }

    /// 버린 자리를 오래 쌓아도 남은 것이 맞다(앞쪽 걷어 내기를 지난다).
    func testManyEvictionsKeepTheNewestEntries() {
        let cache = TranslationCache(characterBudget: 100)
        for index in 0..<5000 {
            cache.store("t\(index)", of: "s\(index)", from: "ko", to: "en")
        }
        XCTAssertEqual(cache.translation(of: "s4999", from: "ko", to: "en"), "t4999")
        XCTAssertNil(cache.translation(of: "s0", from: "ko", to: "en"))
        XCTAssertLessThanOrEqual(cache.count, 50)
    }

    func testRemoveAll() {
        let cache = TranslationCache()
        cache.store("Hello", of: "안녕", from: "ko", to: "en")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.translation(of: "안녕", from: "ko", to: "en"))
    }
}

/// 캐시가 번역 흐름에 걸려 있는지 — Apple 번역 대신 세는 번역기를 넣는다.
@available(macOS 26.0, *)
final class TranslationCacheFlowTests: XCTestCase {

    /// 부를 때마다 센다. 번역은 글을 대문자로 바꾸고 표시를 붙인 것으로 흉내 낸다.
    private final class Counter: @unchecked Sendable {
        var calls: [String] = []
    }

    private func run(_ markdown: String, cache: TranslationCache, counter: Counter,
                     direction: TranslationDirection = .koreanToEnglish) async throws -> String {
        let plan = MarkdownTranslationPlan.make(markdown)
        let jobs = AppleTranslator.jobs(for: plan.units, extras: [])
        let translate = AppleTranslator.cachedTranslator(cache, direction: direction) { text in
            counter.calls.append(text)
            return "[" + text + "]"
        }
        let perUnit = try await AppleTranslator.translateJobs(jobs, slots: plan.units.count,
                                                              translate: translate, progress: nil)
        return try plan.assembled(with: perUnit)
    }

    private let document = """
    # 제목

    첫 문단입니다.

    둘째 문단입니다.

    - 목록 하나
    - 목록 둘
    """

    /// 전제: 이 문서는 단위가 여럿이다. 하나뿐이면 아래의 "고친 것만"이 아무것도 보지 않는다.
    func testPremiseDocumentHasSeveralUnits() {
        XCTAssertEqual(MarkdownTranslationPlan.make(document).units.count, 5)
    }

    func testSecondTranslationOfTheSameDocumentSendsNothing() async throws {
        let cache = TranslationCache()
        let counter = Counter()
        let first = try await run(document, cache: cache, counter: counter)
        XCTAssertEqual(counter.calls.count, 5)
        counter.calls = []
        let second = try await run(document, cache: cache, counter: counter)
        XCTAssertEqual(counter.calls, [], "고치지 않은 문서를 다시 보냈다")
        XCTAssertEqual(second, first, "캐시에서 꺼낸 결과가 처음 번역과 같아야 한다")
    }

    /// 한 문단을 고치면 **그 문단만** 보낸다.
    func testEditingOneParagraphSendsOnlyThatParagraph() async throws {
        let cache = TranslationCache()
        let counter = Counter()
        _ = try await run(document, cache: cache, counter: counter)
        counter.calls = []
        let edited = document.replacingOccurrences(of: "둘째 문단입니다.", with: "고친 둘째 문단입니다.")
        let result = try await run(edited, cache: cache, counter: counter)
        XCTAssertEqual(counter.calls, ["고친 둘째 문단입니다."])
        XCTAssertTrue(result.contains("[고친 둘째 문단입니다.]"))
        XCTAssertTrue(result.contains("[첫 문단입니다.]"), "고치지 않은 문단도 번역본에 있어야 한다")
    }

    func testOtherDirectionIsTranslatedAgain() async throws {
        let cache = TranslationCache()
        let counter = Counter()
        _ = try await run(document, cache: cache, counter: counter)
        counter.calls = []
        _ = try await run(document, cache: cache, counter: counter,
                          direction: TranslationDirection(source: "ko", target: "ja"))
        XCTAssertEqual(counter.calls.count, 5, "다른 방향의 번역을 꺼내 썼다")
    }

    /// 번역기가 실패하면 기억하지 않는다 — 다음 번역이 같은 실패를 꺼내 쓰면 안 된다.
    func testFailureIsNotRemembered() async throws {
        struct Boom: Error {}
        let cache = TranslationCache()
        let failing = AppleTranslator.cachedTranslator(cache, direction: .koreanToEnglish) { _ in
            throw Boom()
        }
        do {
            _ = try await failing("첫 문단입니다.")
            XCTFail("실패해야 한다")
        } catch {}
        XCTAssertEqual(cache.count, 0)
    }
}
