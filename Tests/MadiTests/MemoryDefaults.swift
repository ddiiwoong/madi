import Foundation
import XCTest

/// 디스크에 쓰지 않는 `UserDefaults` — 테스트가 설정 저장소 자리에 넣는다.
///
/// **왜**: 전에는 테스트마다 `madi.tests.<UUID>` 이름의 스위트 저장소를 만들고 끝에
/// `removePersistentDomain`으로 치웠다. 그런데 **한 번이라도 쓴 도메인은 지워도 빈 plist가
/// `~/Library/Preferences`에 남는다**(실측: 쓰고 `removePersistentDomain` · 키를 하나씩 지우기 ·
/// 빈 도메인으로 덮기 모두 42바이트 파일이 남았다. 쓰지 않고 지우기만 하면 남지 않았다).
/// 이름이 테스트마다 달라 실행할 때마다 수십 개씩 쌓여 1,700개를 넘었다.
///
/// 읽기는 진짜 저장소처럼 **전역 도메인으로 떨어진다**(`AppleLanguages` 같은 시스템 값). 그래야
/// "앱 도메인만 읽어야 한다"를 지키는 시험이 진짜 저장소에서와 같은 함정을 본다 — 전역 값이 섞인
/// `dictionaryRepresentation()`을 읽는 결함을 잡는다. 쓰기는 이 객체 안에만 남는다.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {

    /// `persistentDomain(forName:)`이 이 객체의 값을 돌려줄 이름.
    let name: String
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init(name: String = "madi.tests.memory") {
        self.name = name
        // nil은 프로세스의 표준 검색 목록이다. 아래에서 읽기·쓰기를 모두 가로채므로 거기에 쓰지 않는다.
        super.init(suiteName: nil)!
    }

    private var global: [String: Any] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
    }

    override func object(forKey key: String) -> Any? {
        lock.withLock { values[key] } ?? global[key]
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    override func removeObject(forKey key: String) {
        lock.withLock { values[key] = nil }
    }

    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        guard domainName == name else { return nil }
        return lock.withLock { values }
    }

    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        guard domainName == name else { return }
        lock.withLock { values = domain }
    }

    override func removePersistentDomain(forName domainName: String) {
        guard domainName == name else { return }
        lock.withLock { values = [:] }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        global.merging(lock.withLock { values }) { _, mine in mine }
    }
}

/// 테스트가 사용자의 디스크에 흔적을 남기지 않는지.
final class TestStorageHygieneTests: XCTestCase {

    /// 메모리 저장소에 쓴 것은 표준 저장소(이 테스트 프로세스의 도메인)에 닿지 않는다. 가로채기가
    /// 하나라도 빠지면 거기에 쓰이고 디스크에 남는다.
    func testMemoryDefaultsNeverReachesTheRealStore() {
        let key = "madi.hygiene.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }   // 결함이 있었을 때의 뒤처리
        let defaults = MemoryDefaults(name: "madi.hygiene")

        defaults.set("값", forKey: key)
        defaults.set(true, forKey: key + ".bool")
        defaults.set(15.5, forKey: key + ".double")
        XCTAssertEqual(defaults.string(forKey: key), "값")
        XCTAssertTrue(defaults.bool(forKey: key + ".bool"))
        XCTAssertEqual(defaults.double(forKey: key + ".double"), 15.5)
        XCTAssertEqual(defaults.persistentDomain(forName: "madi.hygiene")?.count, 3)

        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertNil(UserDefaults.standard.object(forKey: key + ".bool"))

        defaults.removeObject(forKey: key)
        XCTAssertNil(defaults.string(forKey: key))
    }

    /// 읽기는 전역 도메인으로 떨어진다 — 진짜 저장소처럼. 앱 도메인만 읽어야 하는 코드가
    /// 전역 값을 잘못 읽는 결함을 시험이 볼 수 있어야 한다.
    func testReadsFallBackToTheGlobalDomainLikeTheRealStore() {
        let defaults = MemoryDefaults()
        let systemLanguages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"]
        XCTAssertEqual(defaults.object(forKey: "AppleLanguages") as? [String], systemLanguages as? [String])
        XCTAssertNil(defaults.persistentDomain(forName: defaults.name)?["AppleLanguages"])
    }

    /// 테스트 코드가 디스크에 쓰는 저장소를 다시 만들지 않는다. 만들면 `~/Library/Preferences`에
    /// 지워지지 않는 파일이 생긴다(위 `MemoryDefaults`의 설명). 이 검사 자신이 걸리지 않게 낱말을
    /// 나눠 적는다.
    func testNoTestCreatesAPersistentSuite() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let pattern = "UserDefaults" + "(suiteName:"
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "전제: 테스트 파일을 읽었다")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains(pattern),
                           "디스크에 쓰는 저장소를 만든다 — MemoryDefaults를 쓴다: \(file.lastPathComponent)")
        }
    }
}
