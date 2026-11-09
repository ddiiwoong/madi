import CryptoKit
import Foundation
import Security

/// 새 판을 묻는 곳. 화면이 부르고, 시험이 대역 세션을 넣는다.
///
/// 보내는 것은 `releases/latest` GET 하나다 — 문서 내용은 보내지 않는다. GitHub는 요청한 IP 주소와
/// User-Agent(마디의 판 번호)를 본다. 세션은 쿠키 · 캐시를 쓰지 않는다.
struct ReleaseChecker: Sendable {

    enum Failure: LocalizedError, Equatable {
        case unreachable(String)
        case status(Int)
        case unreadable(ReleaseFeed.ParseError)

        var errorDescription: String? {
            switch self {
            case let .unreachable(message): return String(localized: "GitHub에 닿지 못했습니다: \(message)")
            case let .status(code): return String(localized: "GitHub가 판 정보를 주지 않았습니다 (HTTP \(code))")
            case .unreadable: return String(localized: "GitHub가 준 판 정보를 읽지 못했습니다")
            }
        }
    }

    var session: URLSession = UpdateNetwork.session(timeout: 15)

    func latest(currentVersion: String) async throws -> AvailableRelease {
        var request = URLRequest(url: ReleaseFeed.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Madi/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.status(0) }
        guard http.statusCode == 200 else { throw Failure.status(http.statusCode) }
        do {
            return try ReleaseFeed.parse(data)
        } catch let error as ReleaseFeed.ParseError {
            throw Failure.unreadable(error)
        }
    }
}

enum UpdateNetwork {
    static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }
}

/// 새 판을 받아 확인하고 바꿔 넣는다.
///
/// 차례: 받는다 → GitHub가 준 SHA-256과 견준다 → `ditto`로 푼다 → 번들 식별자 · 판 번호를 본다 → **서명이 실행 중인
/// 앱과 같은 개발자 팀의 것인지** 본다(`ReleaseFeed.signingRequirement`) → 끌 때 바꿔 넣는다. 체크섬은 받다가
/// 깨진 것을 잡고, 서명은 남이 만든 앱을 잡는다 — 체크섬과 ZIP이 같은 곳에서 오므로 체크섬만으로는 진짜인지
/// 알 수 없다.
///
/// 받은 것은 앱과 **같은 볼륨의** 임시 폴더(`itemReplacementDirectory`)에 둔다. 그래야 바꿔 넣기가 복사가 아니라
/// 이름 바꾸기 한 번이고, 도중에 멈춰도 반쯤 바뀐 앱이 남지 않는다.
struct UpdateInstaller: Sendable {

    enum Failure: LocalizedError, Equatable {
        case download(String)
        case checksum(expected: String, actual: String)
        case unpack(String)
        case noApp
        case wrongApp(expected: String, found: String)
        case wrongVersion(expected: String, found: String)
        case signature(String)
        case replace(String)

        var errorDescription: String? {
            switch self {
            case let .download(message): return String(localized: "새 판을 받지 못했습니다: \(message)")
            case .checksum: return String(localized: "받은 파일이 GitHub가 알려 준 체크섬과 다릅니다 — 받다가 깨졌을 수 있습니다")
            case let .unpack(message): return String(localized: "받은 파일을 풀지 못했습니다: \(message)")
            case .noApp: return String(localized: "받은 파일 안에 마디가 없습니다")
            case let .wrongApp(expected, found):
                return String(localized: "받은 앱의 식별자가 다릅니다 (\(found), 기대한 것 \(expected))")
            case let .wrongVersion(expected, found):
                return String(localized: "받은 앱의 판 번호가 다릅니다 (\(found), 기대한 것 \(expected))")
            case let .signature(message):
                return String(localized: "받은 앱의 서명이 지금 마디를 만든 개발자의 것이 아닙니다: \(message)")
            case let .replace(message): return String(localized: "새 판으로 바꿔 넣지 못했습니다: \(message)")
            }
        }
    }

    var session: URLSession = UpdateNetwork.session(timeout: 60)
    var unpacker: @Sendable (URL, URL) async throws -> Void = { try await UpdateInstaller.dittoUnpack($0, $1) }

    /// 확인을 마친 새 앱과, 그것을 담은 임시 폴더(바꿔 넣은 뒤 지운다).
    struct Prepared: Equatable, Sendable {
        let app: URL
        let staging: URL
    }

    /// 받아서 확인까지. `current`는 지금 앱의 자리, `teamIdentifier`는 실행 중인 앱의 팀 ID다.
    func prepare(_ release: AvailableRelease, replacing current: URL, bundleIdentifier: String,
                 teamIdentifier: String) async throws -> Prepared {
        guard let archive = release.archive, let expected = release.archiveSHA256 else {
            throw Failure.download(UpdateInstallBlocker.missingArchive.explanation)
        }
        let staging: URL
        do {
            staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: current, create: true)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        do {
            let app = try await prepare(release, archive: archive, expectedSHA256: expected, staging: staging,
                                        bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier)
            return Prepared(app: app, staging: staging)
        } catch {
            // 실패하면 받은 것을 남기지 않는다.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func prepare(_ release: AvailableRelease, archive: URL, expectedSHA256 expected: String, staging: URL,
                         bundleIdentifier: String, teamIdentifier: String) async throws -> URL {
        let zip = staging.appendingPathComponent(ReleaseFeed.archiveName(forTag: release.tag))
        do {
            try await download(archive, to: zip)
        } catch let first as Failure {
            // 받기 주소가 실패하면 같은 자산을 API 주소로 한 번 더 — 체크섬과 서명은 어느 쪽이든 똑같이 본다.
            guard let viaAPI = release.archiveViaAPI, !Task.isCancelled else { throw first }
            try await download(viaAPI, to: zip, accept: "application/octet-stream")
        }
        let actual = try Self.sha256(of: zip)
        guard actual == expected else { throw Failure.checksum(expected: expected, actual: actual) }

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try await unpacker(zip, unpacked)
        try? FileManager.default.removeItem(at: zip)
        let app = try Self.singleApp(in: unpacked)
        try Self.verify(app: app, bundleIdentifier: bundleIdentifier, version: release.version,
                        teamIdentifier: teamIdentifier)
        return app
    }

    private func download(_ url: URL, to destination: URL, accept: String? = nil) async throws {
        var request = URLRequest(url: url)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        do {
            let (temporary, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw Failure.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download(error.localizedDescription)
        }
    }

    /// 바꿔 넣는다. 같은 볼륨 안의 맞바꾸기라 한 번에 된다 — 옛 앱은 지워진다. 그다음 받아 둔 임시 폴더를 치운다.
    static func install(_ newApp: URL, over current: URL, staging: URL? = nil) throws {
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp, backupItemName: nil, options: [])
        } catch {
            throw Failure.replace(error.localizedDescription)
        }
        if let staging { try? FileManager.default.removeItem(at: staging) }
    }

    /// 앱(`pid`)이 끝나면 새 앱을 연다. 끝나기를 1분까지 기다린다(`ReleaseFeed.relaunchScript`).
    static func relaunch(_ app: URL, after pid: Int32, opener: String = "/usr/bin/open") throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ReleaseFeed.relaunchScript, "madi-relaunch", String(pid), app.path, opener]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: 조각

    static func sha256(of file: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `ditto -x -k` — release.sh가 `ditto -c -k --keepParent`로 묶은 것을 그대로 푼다(확장 속성 · 서명 그대로).
    static func dittoUnpack(_ zip: URL, _ destination: URL) async throws {
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, destination.path])
    }

    static func run(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: Failure.unpack(error.localizedDescription))
            }
        }
        guard status == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(300), as: UTF8.self)
            throw Failure.unpack(message.isEmpty ? "exit \(status)" : message)
        }
    }

    /// 푼 폴더 맨 위의 `.app` 하나.
    static func singleApp(in folder: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let apps = entries.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw Failure.noApp }
        return app
    }

    /// 번들 식별자 · 판 번호 · 서명.
    static func verify(app: URL, bundleIdentifier: String, version: ReleaseVersion, teamIdentifier: String) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let foundIdentifier = info["CFBundleIdentifier"] as? String ?? ""
        guard foundIdentifier == bundleIdentifier else {
            throw Failure.wrongApp(expected: bundleIdentifier, found: foundIdentifier)
        }
        let foundVersion = info["CFBundleShortVersionString"] as? String ?? ""
        guard ReleaseVersion(foundVersion) == version else {
            throw Failure.wrongVersion(expected: version.description, found: foundVersion)
        }
        try checkSignature(of: app, bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier)
    }

    static func checkSignature(of app: URL, bundleIdentifier: String, teamIdentifier: String) throws {
        guard let text = ReleaseFeed.signingRequirement(bundleIdentifier: bundleIdentifier,
                                                        teamIdentifier: teamIdentifier) else {
            throw Failure.signature(String(localized: "기준이 될 서명 정보가 맞지 않습니다"))
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure.signature(String(localized: "서명을 읽지 못했습니다"))
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw Failure.signature(String(localized: "서명 조건을 만들지 못했습니다"))
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            // CFError의 설명은 "OSStatus error -67050" 같은 꼴이라, 그 번호의 문장을 먼저 쓴다.
            let cfError = error?.takeRetainedValue()
            let reason = (SecCopyErrorMessageString(status, nil) as String?) ?? cfError?.localizedDescription
                ?? "OSStatus \(status)"
            throw Failure.signature("\(reason) (\(status))")
        }
    }

    // MARK: 서명 정보

    /// 실행 중인 앱의 팀 ID. 직접 빌드한 앱(ad-hoc)이면 없다.
    static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    static func teamIdentifier(ofAppAt url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return teamIdentifier(of: code)
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              ReleaseFeed.isTeamIdentifier(team) else { return nil }
        return team
    }
}
