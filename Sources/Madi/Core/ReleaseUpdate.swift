import Foundation

// 새 판 확인의 순수 로직 — 판 번호 비교, GitHub Releases 응답 읽기, 확인 일정, 바꿔 넣을 수 있는지.
// 받기 · 체크섬 · 서명 확인 · 바꿔 넣기는 `Services/UpdateInstaller.swift`, 묻는 화면은 `App/UpdateController.swift`.
//
// 왜 직접 하는가(Sparkle을 쓰지 않는가): 마디는 Swift 의존성이 없다(README). Sparkle을 넣으면 남의 프레임워크와
// 그 안의 XPC 서비스 · 도우미 앱까지 서명해야 하고, 피드(appcast)와 EdDSA 키를 따로 지켜야 한다. 마디가 필요한
// 것은 그보다 작다 — 판이 하나뿐이고(델타 없음), 받을 곳이 GitHub Releases 하나이고, 서명은 이미 Developer ID다.
// 그래서 진짜인지는 **실행 중인 앱과 같은 개발자 팀이 서명했는가**로 가린다(2026-11-09, 사용자가 골랐다).

/// `0.1.1` 같은 판 번호. 앞의 `v`는 떼고 읽는다(태그 `v0.1.1`). 숫자 마디만 받는다 —
/// `0.2.0-beta`처럼 꼬리가 붙은 것은 판으로 읽지 않는다(미리 보기 판을 받지 않게).
public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {

    public let components: [Int]

    public init?(_ text: String) {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.first == "v" || trimmed.first == "V" { trimmed = trimmed.dropFirst() }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ ("0" ... "9").contains($0) }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// 모자란 마디는 0으로 본다 — `0.1`과 `0.1.0`은 같은 판이다.
    private static func padded(_ a: ReleaseVersion, _ b: ReleaseVersion) -> ([Int], [Int]) {
        let count = max(a.components.count, b.components.count)
        func pad(_ c: [Int]) -> [Int] { c + Array(repeating: 0, count: count - c.count) }
        return (pad(a.components), pad(b.components))
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let (a, b) = padded(lhs, rhs)
        return a.lexicographicallyPrecedes(b)
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let (a, b) = padded(lhs, rhs)
        return a == b
    }
}

/// GitHub Releases의 판 하나 — 확인에 쓰는 것만.
public struct AvailableRelease: Equatable, Sendable {
    public let version: ReleaseVersion
    public let tag: String
    /// 브라우저로 여는 릴리스 페이지.
    public let page: URL
    /// 앱을 바꿔 넣을 때 받는 ZIP(`Madi-<판>.zip`). 없으면 바꿔 넣지 못하고 페이지만 연다.
    public let archive: URL?
    /// 같은 ZIP의 API 주소(`api.github.com/…/releases/assets/<id>`, `Accept: application/octet-stream`으로 받는다).
    /// `archive`가 실패하면 이리로 받는다 — 2026-11-09에 github.com의 받기 주소가 큰 자산만 504를 줄 때 이쪽은 받혔다.
    public let archiveViaAPI: URL?
    /// ZIP의 SHA-256(소문자 16진수 64자) — GitHub가 자산마다 주는 `digest`. 없으면 바꿔 넣지 않는다.
    public let archiveSHA256: String?

    public init(version: ReleaseVersion, tag: String, page: URL, archive: URL?, archiveViaAPI: URL? = nil,
                archiveSHA256: String?) {
        self.version = version
        self.tag = tag
        self.page = page
        self.archive = archive
        self.archiveViaAPI = archiveViaAPI
        self.archiveSHA256 = archiveSHA256
    }
}

/// 확인한 결과.
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(latest: ReleaseVersion)
    case available(AvailableRelease)
}

/// 바꿔 넣지 못하는 까닭. 있으면 알리기만 하고 받는 페이지를 연다.
public enum UpdateInstallBlocker: Equatable, Sendable {
    /// 직접 빌드한 앱(ad-hoc 서명) — 받은 앱이 같은 개발자의 것인지 견줄 기준이 없다.
    case notSignedForDistribution
    /// DMG에서 바로 켰거나, 받은 폴더에서 옮기지 않고 켜서 macOS가 다른 곳에 옮겨 놓고 돌리는 중이다(App Translocation).
    case notInstalled
    /// 앱이 있는 폴더에 쓸 수 없다(관리자가 아닌 계정의 응용 프로그램 폴더 등).
    case readOnlyLocation
    /// 릴리스에 ZIP이나 그 체크섬이 없다.
    case missingArchive

    public var explanation: String {
        switch self {
        case .notSignedForDistribution:
            return String(localized: "직접 빌드한 마디라 새 판으로 바꿔 넣지 않습니다. 받는 페이지에서 받거나 다시 빌드하십시오.")
        case .notInstalled:
            return String(localized: "마디를 응용 프로그램 폴더로 옮긴 뒤에 업데이트할 수 있습니다. 디스크 이미지에서 바로 켠 마디는 바꿔 넣을 수 없습니다.")
        case .readOnlyLocation:
            return String(localized: "마디가 있는 폴더에 쓸 수 없어 바꿔 넣지 못합니다. 받는 페이지에서 받아 직접 바꿔 넣으십시오.")
        case .missingArchive:
            return String(localized: "이 판에는 앱이 바꿔 넣을 수 있는 파일이 없습니다. 받는 페이지에서 받으십시오.")
        }
    }
}

public enum ReleaseFeed {

    /// 판을 내는 저장소. `scripts/release.sh`가 올리는 곳과 같아야 한다(docs/releasing.md).
    public static let repository = "ddiiwoong/madi"

    /// 맨 마지막 판(초안 · 미리 보기 판은 GitHub가 빼고 준다).
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// 하루에 한 번. 로그인 없는 GitHub API는 IP마다 시간에 60번이라 넉넉하다.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    public enum ParseError: Error, Equatable {
        case notJSON
        case missingField(String)
        case notAVersion(String)
        case notAFinalRelease
        case unexpectedAddress(String)
    }

    /// `releases/latest`의 응답을 읽는다. 주소는 모두 https · github.com이어야 한다 — 받은 글이 다른 곳(또는
    /// `file:` 같은 것)을 가리키면 열지도 받지도 않는다.
    public static func parse(_ data: Data) throws -> AvailableRelease {
        guard let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any] else {
            throw ParseError.notJSON
        }
        guard let tag = json["tag_name"] as? String else { throw ParseError.missingField("tag_name") }
        guard let version = ReleaseVersion(tag) else { throw ParseError.notAVersion(tag) }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { throw ParseError.notAFinalRelease }
        guard let pageText = json["html_url"] as? String else { throw ParseError.missingField("html_url") }
        guard let page = URL(string: pageText), isGitHub(page, pathPrefix: "/\(repository)/releases") else {
            throw ParseError.unexpectedAddress(pageText)
        }
        // ZIP 이름은 태그에서 `v`만 뗀 그대로다 — release.sh가 `Madi-<MARKETING_VERSION>.zip`으로 올린다.
        let wanted = archiveName(forTag: tag)
        var archive: URL?
        var viaAPI: URL?
        var digest: String?
        for asset in json["assets"] as? [[String: Any]] ?? [] where asset["name"] as? String == wanted {
            guard let text = asset["browser_download_url"] as? String, let url = URL(string: text),
                  isGitHub(url, pathPrefix: "/\(repository)/releases/download/") else {
                throw ParseError.unexpectedAddress(asset["browser_download_url"] as? String ?? "")
            }
            archive = url
            if let text = asset["url"] as? String {
                guard let url = URL(string: text),
                      isGitHub(url, host: "api.github.com", pathPrefix: "/repos/\(repository)/releases/assets/") else {
                    throw ParseError.unexpectedAddress(text)
                }
                viaAPI = url
            }
            digest = sha256(fromDigest: asset["digest"] as? String)
        }
        return AvailableRelease(version: version, tag: tag, page: page, archive: archive, archiveViaAPI: viaAPI,
                                archiveSHA256: digest)
    }

    public static func archiveName(forTag tag: String) -> String {
        let bare = tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag
        return "Madi-\(bare).zip"
    }

    /// `sha256:<16진수 64자>` → 소문자 16진수. 다른 꼴이면 없음.
    static func sha256(fromDigest digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy({ ("0" ... "9").contains($0) || ("a" ... "f").contains($0) }) else { return nil }
        return hex
    }

    static func isGitHub(_ url: URL, host: String = "github.com", pathPrefix: String) -> Bool {
        url.scheme == "https" && url.host == host && url.port == nil && url.user == nil
            && url.path.hasPrefix(pathPrefix)
    }

    public static func compare(current: ReleaseVersion, with latest: AvailableRelease) -> UpdateCheckResult {
        latest.version > current ? .available(latest) : .upToDate(latest: latest.version)
    }

    /// 켤 때 확인할 차례인가. 시계를 되돌려 지난번 확인이 앞날이 되면 다시 잰다.
    public static func isCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= checkInterval || elapsed < 0
    }

    /// 바꿔 넣을 수 있는가. `teamIdentifier`는 실행 중인 앱의 서명에서 읽은 팀 ID(ad-hoc이면 없음).
    /// `onReadOnlyVolume`은 DMG를 붙인 채 그 안에서 켠 경우다.
    public static func installBlocker(appPath: String, onReadOnlyVolume: Bool, parentIsWritable: Bool,
                                      teamIdentifier: String?, release: AvailableRelease) -> UpdateInstallBlocker? {
        guard let team = teamIdentifier, isTeamIdentifier(team) else { return .notSignedForDistribution }
        if appPath.contains("/AppTranslocation/") || onReadOnlyVolume { return .notInstalled }
        guard parentIsWritable else { return .readOnlyLocation }
        guard release.archive != nil, release.archiveSHA256 != nil else { return .missingArchive }
        return nil
    }

    /// Apple의 팀 ID는 대문자 · 숫자 10자다. 서명 요구 조건 글에 끼워 넣기 전에 꼴을 본다.
    public static func isTeamIdentifier(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { ("A" ... "Z").contains($0) || ("0" ... "9").contains($0) }
    }

    /// 받은 앱이 지켜야 하는 서명 조건(`codesign`의 요구 조건 언어). 같은 번들 식별자, Apple이 발급한 인증서,
    /// 그 인증서의 팀이 실행 중인 앱과 같다. 팀 ID와 식별자는 꼴을 본 뒤에만 넣는다.
    public static func signingRequirement(bundleIdentifier: String, teamIdentifier: String) -> String? {
        guard isTeamIdentifier(teamIdentifier), !bundleIdentifier.isEmpty,
              bundleIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        return "identifier \"\(bundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// 바꿔 넣은 뒤 앱이 끝나기를 기다렸다가 새 앱을 여는 셸 글. 인수: `$1` 끝나기를 기다릴 pid, `$2` 열 앱,
    /// `$3` 여는 명령(`/usr/bin/open`). 1분이 지나도 끝나지 않으면 열지 않는다 — 끄기를 취소한 앱이 나중에
    /// 꺼질 때 저절로 다시 켜지지 않게.
    public static let relaunchScript = """
        i=0; while /bin/kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 300 ] && exit 0; /bin/sleep 0.2; done; exec "$3" "$2"
        """
}
