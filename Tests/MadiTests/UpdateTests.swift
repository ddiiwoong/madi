import AppKit
import XCTest

/// 새 판 확인과 업데이트 — 판 번호, GitHub 응답 읽기, 일정, 바꿔 넣을 수 있는지(`ReleaseFeed`), 묻기 · 받기 · 확인
/// (`ReleaseChecker` · `UpdateInstaller`), 화면의 흐름(`UpdateController`). 네트워크에 나가지 않는다(`StubURLProtocol`).
///
/// 진짜 서명이 **통과하는** 길은 여기서 재지 않는다 — 배포용 Developer ID로 서명한 앱이 시험 기계마다 있지 않다.
/// 그 길은 실제 릴리스를 받아 바꿔 넣는 확인으로 쟀다(TODO '끝난 것 ▸ 업데이트').
final class ReleaseFeedTests: XCTestCase {

    /// `releases/latest`의 실제 응답(v0.1.0, 2026-11-09)에서 쓰는 필드만 남긴 것.
    static let latestJSON = #"""
    {
      "tag_name": "v0.1.0", "name": "마디 0.1.0", "draft": false, "prerelease": false,
      "html_url": "https://github.com/ddiiwoong/madi/releases/tag/v0.1.0",
      "body": "첫 판입니다.",
      "assets": [
        {"name": "Madi-0.1.0.dmg",
         "browser_download_url": "https://github.com/ddiiwoong/madi/releases/download/v0.1.0/Madi-0.1.0.dmg",
         "digest": "sha256:18976e0c63a4d42745981bd504f2ee29d6c6f9c44dfa5fff79e3678cffd40882"},
        {"name": "Madi-0.1.0.zip",
         "url": "https://api.github.com/repos/ddiiwoong/madi/releases/assets/724521038",
         "browser_download_url": "https://github.com/ddiiwoong/madi/releases/download/v0.1.0/Madi-0.1.0.zip",
         "digest": "sha256:70df2ec8863e7cd74b6bfd9fe58608d739012ffe89cfa220d56d17f4f1336f35"},
        {"name": "SHA256SUMS",
         "browser_download_url": "https://github.com/ddiiwoong/madi/releases/download/v0.1.0/SHA256SUMS",
         "digest": "sha256:99a84103db42e212247808aa0ac5e247a7dfb0050edcb80d78b6d0f0a5dec2cc"}
      ]
    }
    """#

    static func json(tag: String = "v0.1.0", draft: Bool = false, prerelease: Bool = false,
                     page: String = "https://github.com/ddiiwoong/madi/releases/tag/v0.1.0",
                     zipName: String? = nil, zipURL: String? = nil,
                     apiURL: String = "https://api.github.com/repos/ddiiwoong/madi/releases/assets/1",
                     digest: String? = "sha256:70df2ec8863e7cd74b6bfd9fe58608d739012ffe89cfa220d56d17f4f1336f35") -> Data {
        let bare = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let name = zipName ?? "Madi-\(bare).zip"
        let url = zipURL ?? "https://github.com/ddiiwoong/madi/releases/download/\(tag)/\(name)"
        var asset: [String: Any] = ["name": name, "browser_download_url": url, "url": apiURL]
        if let digest { asset["digest"] = digest }
        let object: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease, "html_url": page,
                                     "assets": [asset]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testVersionsReadOnlyPlainNumbers() {
        XCTAssertEqual(ReleaseVersion("0.1.1")?.components, [0, 1, 1])
        XCTAssertEqual(ReleaseVersion("v0.1.1")?.components, [0, 1, 1])
        XCTAssertEqual(ReleaseVersion(" 2.0 \n")?.components, [2, 0])
        for bad in ["", "v", "0.2.0-beta", "1..2", "a.b", "1.2.3.4.5", "1.-2", "١.٢", "+1.0", "1.0 "+"x"] {
            XCTAssertNil(ReleaseVersion(bad), bad)
        }
    }

    /// 마디는 숫자로 견준다 — `0.10.0`이 `0.9.0`보다 새 판이다(글자로 견주면 거꾸로다).
    func testVersionsCompareNumerically() throws {
        let v = { (text: String) in ReleaseVersion(text)! }
        XCTAssertLessThan(v("0.1.0"), v("0.1.1"))
        XCTAssertLessThan(v("0.1.1"), v("0.2"))
        XCTAssertLessThan(v("0.9.0"), v("0.10.0"))
        XCTAssertEqual(v("0.1"), v("0.1.0"))
        XCTAssertFalse(v("0.1.0") < v("0.1"))
        XCTAssertEqual(v("v1.2.3").description, "1.2.3")
    }

    func testReadsTheRealLatestResponse() throws {
        let release = try ReleaseFeed.parse(Data(Self.latestJSON.utf8))
        XCTAssertEqual(release.version, ReleaseVersion("0.1.0"))
        XCTAssertEqual(release.tag, "v0.1.0")
        XCTAssertEqual(release.page.absoluteString, "https://github.com/ddiiwoong/madi/releases/tag/v0.1.0")
        XCTAssertEqual(release.archive?.lastPathComponent, "Madi-0.1.0.zip", "DMG가 아니라 ZIP을 고른다")
        XCTAssertEqual(release.archiveViaAPI?.absoluteString,
                       "https://api.github.com/repos/ddiiwoong/madi/releases/assets/724521038", "ZIP의 API 주소")
        XCTAssertEqual(release.archiveSHA256, "70df2ec8863e7cd74b6bfd9fe58608d739012ffe89cfa220d56d17f4f1336f35")
    }

    func testRefusesDraftsPreviewsAndOtherAddresses() {
        XCTAssertThrowsError(try ReleaseFeed.parse(Self.json(prerelease: true))) {
            XCTAssertEqual($0 as? ReleaseFeed.ParseError, .notAFinalRelease)
        }
        XCTAssertThrowsError(try ReleaseFeed.parse(Self.json(draft: true)))
        XCTAssertThrowsError(try ReleaseFeed.parse(Self.json(tag: "v0.2.0-beta"))) {
            XCTAssertEqual($0 as? ReleaseFeed.ParseError, .notAVersion("v0.2.0-beta"))
        }
        for page in ["http://github.com/ddiiwoong/madi/releases/tag/v0.1.0", "file:///etc/passwd",
                     "https://github.com.evil.example/ddiiwoong/madi/releases", "https://github.com/someone/madi/releases"] {
            XCTAssertThrowsError(try ReleaseFeed.parse(Self.json(page: page)), page) {
                XCTAssertEqual($0 as? ReleaseFeed.ParseError, .unexpectedAddress(page))
            }
        }
        for zip in ["https://example.com/Madi-0.1.0.zip", "http://github.com/ddiiwoong/madi/releases/download/v0.1.0/Madi-0.1.0.zip",
                    "https://github.com/someone/madi/releases/download/v0.1.0/Madi-0.1.0.zip"] {
            XCTAssertThrowsError(try ReleaseFeed.parse(Self.json(zipURL: zip)), zip)
        }
        for api in ["https://api.github.com/repos/someone/madi/releases/assets/1", "http://api.github.com/repos/ddiiwoong/madi/releases/assets/1",
                    "https://api.github.com.example/repos/ddiiwoong/madi/releases/assets/1"] {
            XCTAssertThrowsError(try ReleaseFeed.parse(Self.json(apiURL: api)), api)
        }
        XCTAssertThrowsError(try ReleaseFeed.parse(Data("<html>".utf8))) {
            XCTAssertEqual($0 as? ReleaseFeed.ParseError, .notJSON)
        }
    }

    /// ZIP이나 체크섬이 없으면 판은 읽되 바꿔 넣지 않는다 — 알리고 페이지만 연다.
    func testMissingArchiveOrDigestStillReadsButBlocksInstall() throws {
        let noZip = try ReleaseFeed.parse(Self.json(zipName: "Madi.dmg"))
        XCTAssertNil(noZip.archive)
        let noDigest = try ReleaseFeed.parse(Self.json(digest: nil))
        XCTAssertNotNil(noDigest.archive)
        XCTAssertNil(noDigest.archiveSHA256)
        XCTAssertNil(try ReleaseFeed.parse(Self.json(digest: "md5:abc")).archiveSHA256)
        XCTAssertNil(try ReleaseFeed.parse(Self.json(digest: "sha256:XYZ")).archiveSHA256)
        for release in [noZip, noDigest] {
            XCTAssertEqual(ReleaseFeed.installBlocker(appPath: "/Applications/Madi.app", onReadOnlyVolume: false,
                                                      parentIsWritable: true, teamIdentifier: "ABCDE12345",
                                                      release: release), .missingArchive)
        }
    }

    func testCompareAndSchedule() throws {
        let latest = try ReleaseFeed.parse(Self.json(tag: "v0.1.1"))
        XCTAssertEqual(ReleaseFeed.compare(current: ReleaseVersion("0.1.0")!, with: latest), .available(latest))
        XCTAssertEqual(ReleaseFeed.compare(current: ReleaseVersion("0.1.1")!, with: latest),
                       .upToDate(latest: ReleaseVersion("0.1.1")!))
        XCTAssertEqual(ReleaseFeed.compare(current: ReleaseVersion("0.2.0")!, with: latest),
                       .upToDate(latest: ReleaseVersion("0.1.1")!), "직접 빌드한 더 새 판에 옛 판을 권하지 않는다")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ReleaseFeed.isCheckDue(lastCheck: nil, now: now))
        XCTAssertFalse(ReleaseFeed.isCheckDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(ReleaseFeed.isCheckDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertTrue(ReleaseFeed.isCheckDue(lastCheck: now.addingTimeInterval(3600), now: now), "시계를 되돌렸으면")
    }

    func testInstallBlockers() throws {
        let release = try ReleaseFeed.parse(Self.json(tag: "v0.1.1"))
        func blocker(_ path: String = "/Applications/Madi.app", readOnly: Bool = false, writable: Bool = true,
                     team: String? = "ABCDE12345") -> UpdateInstallBlocker? {
            ReleaseFeed.installBlocker(appPath: path, onReadOnlyVolume: readOnly, parentIsWritable: writable,
                                       teamIdentifier: team, release: release)
        }
        XCTAssertNil(blocker())
        XCTAssertEqual(blocker(team: nil), .notSignedForDistribution)
        XCTAssertEqual(blocker(team: "abc"), .notSignedForDistribution)
        XCTAssertEqual(blocker("/private/var/folders/x/AppTranslocation/1234/d/Madi.app"), .notInstalled)
        XCTAssertEqual(blocker("/Volumes/Madi 0.1.1/Madi.app", readOnly: true), .notInstalled)
        XCTAssertNil(blocker("/Volumes/External/Applications/Madi.app"), "다른 디스크의 응용 프로그램 폴더는 된다")
        XCTAssertEqual(blocker(writable: false), .readOnlyLocation)
        for blocker in [UpdateInstallBlocker.notSignedForDistribution, .notInstalled, .readOnlyLocation, .missingArchive] {
            XCTAssertFalse(blocker.explanation.isEmpty)
        }
    }

    /// 서명 조건 글 — 팀 ID와 식별자는 꼴을 본 뒤에만 넣는다(따옴표로 조건을 바꿔 쓰지 못하게).
    func testSigningRequirementText() {
        XCTAssertEqual(ReleaseFeed.signingRequirement(bundleIdentifier: "dev.jinwoong.md", teamIdentifier: "ABCDE12345"),
                       #"identifier "dev.jinwoong.md" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#)
        XCTAssertNil(ReleaseFeed.signingRequirement(bundleIdentifier: "dev.jinwoong.md", teamIdentifier: "ABCDE1234"))
        XCTAssertNil(ReleaseFeed.signingRequirement(bundleIdentifier: "dev.jinwoong.md", teamIdentifier: #"A" or true or "B"#))
        XCTAssertNil(ReleaseFeed.signingRequirement(bundleIdentifier: #"x" or anchor apple or identifier "y"#,
                                                    teamIdentifier: "ABCDE12345"))
        XCTAssertNil(ReleaseFeed.signingRequirement(bundleIdentifier: "", teamIdentifier: "ABCDE12345"))
        XCTAssertEqual(ReleaseFeed.archiveName(forTag: "v0.1.1"), "Madi-0.1.1.zip")
    }
}

/// 묻기 · 받기 · 확인 — 대역 네트워크로.
final class UpdateInstallerTests: XCTestCase {

    private var session: URLSession!
    private var folder: URL!

    override func setUp() {
        StubURLProtocol.reply = (200, Data())
        StubURLProtocol.failure = nil
        StubURLProtocol.seen = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("madi-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCheckerAsksGitHubOnceAndReadsTheAnswer() async throws {
        StubURLProtocol.reply = (200, Data(ReleaseFeedTests.latestJSON.utf8))
        let release = try await ReleaseChecker(session: session).latest(currentVersion: "0.1.1")
        XCTAssertEqual(release.version, ReleaseVersion("0.1.0"))
        XCTAssertEqual(StubURLProtocol.seen.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.seen.first)
        XCTAssertEqual(request.url, ReleaseFeed.latestURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody, "보내는 것은 묻는 GET 하나 — 본문이 없다")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Madi/0.1.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    func testCheckerFailures() async {
        let checker = ReleaseChecker(session: session)
        StubURLProtocol.reply = (404, Data())
        await assertThrows(try await checker.latest(currentVersion: "0.1.1"), .status(404))
        StubURLProtocol.reply = (200, Data("<html>".utf8))
        await assertThrows(try await checker.latest(currentVersion: "0.1.1"), .unreadable(.notJSON))
        StubURLProtocol.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await checker.latest(currentVersion: "0.1.1")
            XCTFail("닿지 못했으면 실패해야 한다")
        } catch let failure as ReleaseChecker.Failure {
            guard case .unreachable = failure else { return XCTFail("\(failure)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    private func assertThrows(_ body: @autoclosure () async throws -> AvailableRelease, _ expected: ReleaseChecker.Failure,
                              line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("실패해야 한다", line: line)
        } catch {
            XCTAssertEqual(error as? ReleaseChecker.Failure, expected, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, line: line)
        }
    }

    func testSHA256OfAFile() throws {
        let file = folder.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try UpdateInstaller.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    private func release(sha: String) -> AvailableRelease {
        AvailableRelease(version: ReleaseVersion("0.1.1")!, tag: "v0.1.1",
                         page: URL(string: "https://github.com/ddiiwoong/madi/releases/tag/v0.1.1")!,
                         archive: URL(string: "https://github.com/ddiiwoong/madi/releases/download/v0.1.1/Madi-0.1.1.zip")!,
                         archiveSHA256: sha)
    }

    /// 받다가 깨진 것(체크섬이 다름)은 풀기 전에 멈춘다.
    func testChecksumMismatchStopsBeforeUnpacking() async throws {
        StubURLProtocol.reply = (200, Data("not the zip".utf8))
        let unpacked = UnpackSpy()
        var installer = UpdateInstaller(session: session)
        installer.unpacker = { _, _ in unpacked.called() }
        let current = try FakeApp.make(in: folder.appendingPathComponent("Applications"), identifier: "dev.jinwoong.md",
                                       version: "0.1.0")
        do {
            _ = try await installer.prepare(release(sha: String(repeating: "0", count: 64)), replacing: current,
                                            bundleIdentifier: "dev.jinwoong.md", teamIdentifier: "ABCDE12345")
            XCTFail("체크섬이 다르면 실패해야 한다")
        } catch {
            guard case .checksum? = error as? UpdateInstaller.Failure else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(unpacked.count, 0)
    }

    /// 체크섬이 맞아도 받은 앱의 식별자 · 판 · 서명을 차례로 본다. 서명이 없는 앱은 마지막 관문에서 멈춘다.
    func testUnpackedAppIsCheckedForIdentifierVersionAndSignature() async throws {
        let body = Data("zip bytes".utf8)
        StubURLProtocol.reply = (200, body)
        let sha = try { () throws -> String in
            let file = folder.appendingPathComponent("body")
            try body.write(to: file)
            return try UpdateInstaller.sha256(of: file)
        }()
        let current = try FakeApp.make(in: folder.appendingPathComponent("Applications"), identifier: "dev.jinwoong.md",
                                       version: "0.1.0")
        func attempt(identifier: String, version: String) async -> UpdateInstaller.Failure? {
            var installer = UpdateInstaller(session: session)
            installer.unpacker = { _, destination in
                try FakeApp.make(in: destination, identifier: identifier, version: version)
            }
            do {
                _ = try await installer.prepare(release(sha: sha), replacing: current, bundleIdentifier: "dev.jinwoong.md",
                                                teamIdentifier: "ABCDE12345")
                return nil
            } catch {
                return error as? UpdateInstaller.Failure
            }
        }
        let wrongApp = await attempt(identifier: "com.example.other", version: "0.1.1")
        XCTAssertEqual(wrongApp, .wrongApp(expected: "dev.jinwoong.md", found: "com.example.other"))
        let wrongVersion = await attempt(identifier: "dev.jinwoong.md", version: "0.1.0")
        XCTAssertEqual(wrongVersion, .wrongVersion(expected: "0.1.1", found: "0.1.0"))
        let unsigned = await attempt(identifier: "dev.jinwoong.md", version: "0.1.1")
        guard case .signature? = unsigned else { return XCTFail("\(String(describing: unsigned))") }
    }

    /// 받기 주소가 실패하면(2026-11-09에 실제로 504) 같은 자산을 API 주소로 받는다. 체크섬은 그대로 본다.
    func testFallsBackToTheAPIAddressWhenTheDownloadAddressFails() async throws {
        let body = Data("zip via api".utf8)
        let file = folder.appendingPathComponent("body")
        try body.write(to: file)
        let sha = try UpdateInstaller.sha256(of: file)
        let browser = "https://github.com/ddiiwoong/madi/releases/download/v0.1.1/Madi-0.1.1.zip"
        let api = "https://api.github.com/repos/ddiiwoong/madi/releases/assets/9"
        RoutedURLProtocol.routes = [browser: (504, Data("Gateway Time-out".utf8)), api: (200, body)]
        RoutedURLProtocol.seen = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutedURLProtocol.self]
        var installer = UpdateInstaller(session: URLSession(configuration: configuration))
        installer.unpacker = { _, destination in
            try FakeApp.make(in: destination, identifier: "com.example.after-download", version: "0.1.1")
        }
        let release = AvailableRelease(version: ReleaseVersion("0.1.1")!, tag: "v0.1.1",
                                       page: URL(string: "https://github.com/ddiiwoong/madi/releases/tag/v0.1.1")!,
                                       archive: URL(string: browser)!, archiveViaAPI: URL(string: api)!, archiveSHA256: sha)
        let current = try FakeApp.make(in: folder.appendingPathComponent("Applications"), identifier: "dev.jinwoong.md",
                                       version: "0.1.0")
        do {
            _ = try await installer.prepare(release, replacing: current, bundleIdentifier: "dev.jinwoong.md",
                                            teamIdentifier: "ABCDE12345")
            XCTFail("가짜 앱이라 식별자에서 멈춰야 한다")
        } catch {
            // 식별자까지 왔다는 것은 API 주소로 받아 체크섬이 맞았다는 뜻이다.
            XCTAssertEqual(error as? UpdateInstaller.Failure,
                           .wrongApp(expected: "dev.jinwoong.md", found: "com.example.after-download"))
        }
        XCTAssertEqual(RoutedURLProtocol.seen.map { $0.url?.absoluteString ?? "" }, [browser, api])
        XCTAssertEqual(RoutedURLProtocol.seen.last?.value(forHTTPHeaderField: "Accept"), "application/octet-stream")

        // 둘 다 실패하면 받지 못한 것으로 끝난다.
        RoutedURLProtocol.routes = [browser: (504, Data()), api: (502, Data())]
        do {
            _ = try await installer.prepare(release, replacing: current, bundleIdentifier: "dev.jinwoong.md",
                                            teamIdentifier: "ABCDE12345")
            XCTFail("둘 다 실패하면 실패해야 한다")
        } catch {
            XCTAssertEqual(error as? UpdateInstaller.Failure, .download("HTTP 502"))
        }
    }

    /// 제대로 서명된 앱이라도 **다른 개발자**의 것이면 받지 않는다 — Apple이 서명한 계산기로 잰다.
    func testValidlySignedAppFromAnotherDeveloperIsRefused() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: calculator.path))
        let identifier = Bundle(url: calculator)?.bundleIdentifier ?? "com.apple.calculator"
        XCTAssertThrowsError(try UpdateInstaller.checkSignature(of: calculator, bundleIdentifier: identifier,
                                                                teamIdentifier: "ABCDE12345")) {
            guard case .signature? = $0 as? UpdateInstaller.Failure else { return XCTFail("\($0)") }
        }
        XCTAssertNil(UpdateInstaller.teamIdentifier(ofAppAt: calculator), "Apple의 앱에는 팀 ID가 없다")
    }

    /// 직접 빌드한 앱(ad-hoc)에는 팀 ID가 없다 — 그래서 바꿔 넣지 않는다.
    func testAdHocSignedAppHasNoTeam() throws {
        let app = try FakeApp.make(in: folder, identifier: "dev.jinwoong.md", version: "0.1.1", executable: true)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        XCTAssertNil(UpdateInstaller.teamIdentifier(ofAppAt: app))
        XCTAssertThrowsError(try UpdateInstaller.checkSignature(of: app, bundleIdentifier: "dev.jinwoong.md",
                                                                teamIdentifier: "ABCDE12345"))
    }

    /// 바꿔 넣기 — 같은 자리에 새 앱이 있고 받아 둔 것은 옮겨져 없다.
    func testInstallSwapsTheAppInPlace() throws {
        let current = try FakeApp.make(in: folder.appendingPathComponent("Applications"), identifier: "dev.jinwoong.md",
                                       version: "0.1.0")
        let staged = try FakeApp.make(in: folder.appendingPathComponent("staging"), identifier: "dev.jinwoong.md",
                                      version: "0.1.1")
        try UpdateInstaller.install(staged, over: current)
        XCTAssertEqual(Bundle(url: current)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "0.1.1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertThrowsError(try UpdateInstaller.install(staged, over: current), "받아 둔 것이 없으면 실패")
    }

    /// 다시 열기 — 앱(pid)이 끝난 **뒤에야** 연다.
    func testRelaunchWaitsForTheProcessToExit() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.6"]
        try sleeper.run()
        let marker = folder.appendingPathComponent("opened")
        try UpdateInstaller.relaunch(marker, after: sleeper.processIdentifier, opener: "/usr/bin/touch")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "아직 끝나지 않았다")
        sleeper.waitUntilExit()
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}

/// 화면의 흐름 — 알림은 대역(`presentAlert`)이 받는다.
@MainActor
final class UpdateControllerTests: XCTestCase {

    private var defaults: MemoryDefaults!
    private var store: PreferenceStore!
    private var alerts: [NSAlert] = []
    private var answers: [Int] = []
    private var opened: [URL] = []
    private var terminated = 0

    override func setUp() async throws {
        StubURLProtocol.reply = (200, Data())
        StubURLProtocol.failure = nil
        StubURLProtocol.seen = []
        defaults = MemoryDefaults()
        store = PreferenceStore(defaults: defaults)
        alerts = []
        answers = []
        opened = []
        terminated = 0
    }

    private func controller(team: String? = "ABCDE12345", version: String = "0.1.0",
                            app: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Madi.app"))
        -> UpdateController {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let controller = UpdateController(store: store, checker: ReleaseChecker(session: session),
                                          installer: UpdateInstaller(session: session))
        controller.teamIdentifier = { team }
        controller.currentVersion = version
        controller.appURL = app
        controller.bundleIdentifier = "dev.jinwoong.md"
        controller.presentAlert = { [unowned self] alert in
            alerts.append(alert)
            return answers.isEmpty ? 2 : answers.removeFirst()
        }
        controller.openURL = { [unowned self] in opened.append($0) }
        controller.terminate = { [unowned self] in terminated += 1 }
        return controller
    }

    func testLaunchChecksOnlyWhenOnSignedAndDue() {
        let now = Date()
        XCTAssertTrue(controller().shouldCheckAtLaunch(now: now))
        XCTAssertFalse(controller(team: nil).shouldCheckAtLaunch(now: now), "직접 빌드한 마디는 켤 때 묻지 않는다")
        store.lastUpdateCheck = now.addingTimeInterval(-3600)
        XCTAssertFalse(controller().shouldCheckAtLaunch(now: now), "하루에 한 번")
        store.lastUpdateCheck = nil
        var preferences = store.current
        preferences.checksForUpdates = false
        store.save(preferences)
        XCTAssertFalse(controller().shouldCheckAtLaunch(now: now), "설정에서 끄면")
        XCTAssertEqual(StubURLProtocol.seen.count, 0)
    }

    func testCheckingPreferenceIsStoredAndResettable() {
        XCTAssertTrue(store.current.checksForUpdates, "기본은 켜짐")
        var preferences = store.current
        preferences.checksForUpdates = false
        store.save(preferences)
        XCTAssertFalse(PreferenceStore(defaults: defaults).current.checksForUpdates)
        store.reset()
        XCTAssertTrue(store.current.checksForUpdates)
    }

    func testManualCheckSaysUpToDate() async {
        StubURLProtocol.reply = (200, ReleaseFeedTests.json(tag: "v0.1.0"))
        await controller(version: "0.1.0").check(interactive: true)
        XCTAssertEqual(alerts.map(\.messageText), [String(localized: "마디가 최신입니다")])
        XCTAssertNotNil(store.lastUpdateCheck)
    }

    func testLaunchCheckStaysQuietWhenUpToDateOrOffline() async {
        StubURLProtocol.reply = (200, ReleaseFeedTests.json(tag: "v0.1.0"))
        await controller(version: "0.1.0").check(interactive: false)
        StubURLProtocol.failure = URLError(.notConnectedToInternet)
        await controller(version: "0.1.0").check(interactive: false)
        XCTAssertTrue(alerts.isEmpty)
        StubURLProtocol.failure = URLError(.notConnectedToInternet)
        await controller(version: "0.1.0").check(interactive: true)
        XCTAssertEqual(alerts.map(\.messageText), [String(localized: "새 판을 확인하지 못했습니다")])
    }

    func testNewerReleaseOffersUpdateNotesOrLater() async throws {
        StubURLProtocol.reply = (200, ReleaseFeedTests.json(tag: "v0.1.1"))
        answers = [1]   // 바뀐 점 보기
        let parent = FileManager.default.temporaryDirectory
        await controller(app: parent.appendingPathComponent("Madi.app")).check(interactive: false)
        let alert = try XCTUnwrap(alerts.first)
        XCTAssertTrue(alert.messageText.contains("0.1.1"))
        XCTAssertEqual(alert.buttons.map(\.title), [String(localized: "업데이트하고 다시 열기"),
                                                   String(localized: "바뀐 점 보기"), String(localized: "나중에")])
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/ddiiwoong/madi/releases/tag/v0.1.0"])
        XCTAssertEqual(terminated, 0)
    }

    /// 직접 빌드한 마디에는 바꿔 넣는 단추 대신 받는 페이지를 준다.
    func testBlockedInstallOffersTheDownloadPage() async throws {
        StubURLProtocol.reply = (200, ReleaseFeedTests.json(tag: "v0.1.1"))
        answers = [0]
        await controller(team: nil).check(interactive: true)
        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(alert.buttons.map(\.title), [String(localized: "받는 페이지 열기"), String(localized: "나중에")])
        XCTAssertTrue(alert.informativeText.contains(UpdateInstallBlocker.notSignedForDistribution.explanation))
        XCTAssertEqual(opened.count, 1)
    }

    /// 끌 때 바꿔 넣고, 누른 지 얼마 안 됐으면 다시 연다. 오래전에 누른 것은 바꿔 넣기만.
    func testPendingUpdateInstallsAtQuitAndRelaunchesOnlyWhenRecent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("madi-quit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (age, expectRelaunch) in [(10.0, true), (UpdateController.relaunchWindow + 1, false)] {
            let target = try FakeApp.make(in: root.appendingPathComponent("Applications-\(age)"),
                                          identifier: "dev.jinwoong.md", version: "0.1.0")
            let staged = try FakeApp.make(in: root.appendingPathComponent("staged-\(age)"),
                                          identifier: "dev.jinwoong.md", version: "0.1.1")
            let updater = controller(app: target)
            let now = Date()
            updater.setPendingForTesting(.init(newApp: staged, target: target, requestedAt: now.addingTimeInterval(-age)))
            var relaunched: [URL] = []
            updater.installPendingUpdate(now: now) { relaunched.append($0) }
            XCTAssertEqual(Bundle(url: target)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "0.1.1")
            XCTAssertEqual(relaunched, expectRelaunch ? [target] : [])
            XCTAssertNil(updater.pending)
            XCTAssertNil(store.updateInstallFailure)
        }
    }

    /// 끄는 중의 실패는 적어 두었다가 다음에 켤 때 한 번 알린다.
    func testInstallFailureIsReportedAtNextLaunch() throws {
        let updater = controller()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("madi-missing-\(UUID().uuidString)")
        updater.setPendingForTesting(.init(newApp: missing.appendingPathComponent("new.app"),
                                           target: missing.appendingPathComponent("Madi.app"), requestedAt: Date()))
        var relaunched = 0
        updater.installPendingUpdate { _ in relaunched += 1 }
        XCTAssertEqual(relaunched, 0, "바꿔 넣지 못했으면 다시 열지 않는다")
        XCTAssertNotNil(store.updateInstallFailure)
        store.lastUpdateCheck = Date()          // 켤 때의 확인은 건너뛴다 — 알림 하나만 본다
        controller().launched()
        XCTAssertEqual(alerts.map(\.messageText), [String(localized: "지난번 업데이트가 끝나지 못했습니다")])
        XCTAssertNil(store.updateInstallFailure, "한 번만 알린다")
    }

    func testMenuItemReachesTheController() throws {
        let menu = AppMenu.mainMenu()
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        let item = try XCTUnwrap(appMenu.items.first { $0.action == #selector(UpdateController.checkForUpdates(_:)) })
        XCTAssertTrue(item.target === UpdateController.shared)
        XCTAssertEqual(item.title, String(localized: "업데이트 확인…"))
    }
}

/// 서명 없는 가짜 앱 꾸러미.
enum FakeApp {
    @discardableResult
    static func make(in folder: URL, identifier: String, version: String, executable: Bool = false) throws -> URL {
        let app = folder.appendingPathComponent("Madi.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "Madi", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let binary = contents.appendingPathComponent("MacOS/Madi")
        if executable {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        } else {
            try Data().write(to: binary)
        }
        return app
    }
}

/// 주소마다 응답을 정해 두는 URL 프로토콜. 네트워크에 나가지 않는다.
final class RoutedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.append(request)
        let reply = Self.routes[request.url?.absoluteString ?? ""] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 풀기가 불렸는지 센다.
final class UnpackSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func called() { lock.withLock { calls += 1 } }
    var count: Int { lock.withLock { calls } }
}
