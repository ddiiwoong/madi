import AppKit
import UniformTypeIdentifiers

/// 확장자마다 어떤 앱이 여는지 읽고, 마디로 바꾼다(설정 ▸ 일반 ▸ 파일 연결).
///
/// 마디는 `CFBundleDocumentTypes`로 "열 수 있다"고 **선언만** 한다. 선언은 기본 앱을
/// 정하지 않으므로, 사용자가 `.md`를 두 번 눌렀을 때 다른 앱이 열릴 수 있다. 설정에서
/// 지금 상태를 보여 주고 한 번에 바꿀 수 있어야 한다.
///
/// 기본 앱은 **자리로** 가린다(사용자 — "확장자 기본프로그램 변경 기능"). 전에는 식별자만 보아, 빌드해 둔 다른 사본
/// (`.build/release/…/Madi.app`)이 `.md`를 열고 있어도 '마디에서 열립니다'라 하고 단추를 껐다 — 이 Mac에서 실제로 그랬다.
/// 같은 식별자의 다른 사본이면 그 자리를 보여 주고 이 마디로 바꿀 수 있게 한다.
@MainActor
enum FileAssociation {

    /// 마디가 기본 앱이 될 수 있는 파일 종류.
    enum Kind: CaseIterable {
        case markdown
        case plainText

        /// 그 종류의 타입. `.md`는 확장자가 가리키는 것을 시스템에 묻는다 — `net.daringfireball.markdown`을 글자로
        /// 박아 두면, 시스템이 그 식별자를 바꾸거나 사용자 기계에 그 타입이 없을 때 조용히 틀린다.
        var type: UTType? {
            switch self {
            case .markdown: UTType(filenameExtension: "md") ?? UTType("net.daringfireball.markdown")
            case .plainText: .plainText
            }
        }

        /// 그 타입의 확장자(시스템이 둔 것). `.md · .markdown`, `.txt · .text`.
        var extensions: [String] { type?.tags[.filenameExtension] ?? [] }

        /// 사람이 읽을 이름 — 종류와 확장자. 끝이 '파일'이라 뒤에 붙는 조사가 늘 같다.
        var label: String {
            let suffix = extensions.isEmpty ? "" : "(" + extensions.map { "." + $0 }.joined(separator: " · ") + ")"
            switch self {
            case .markdown: return String(localized: "Markdown 파일\(suffix)")
            case .plainText: return String(localized: "텍스트 파일\(suffix)")
            }
        }
    }

    /// 지금 그 종류를 여는 앱.
    enum Handler: Equatable {
        /// 지금 켜진 이 마디.
        case thisApp
        /// 같은 식별자의 다른 자리 — 빌드해 둔 다른 사본, 지난 판.
        case otherCopy(URL)
        case app(name: String)
        case none
    }

    /// 지금 그 종류를 여는 앱(기본 앱 하나 — 열 수 있는 앱 목록의 첫째가 아니다).
    static func handler(for kind: Kind, appURL: URL = Bundle.main.bundleURL,
                        bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Handler {
        guard let type = kind.type, let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return .none }
        return classify(url, identifier: Bundle(url: url)?.bundleIdentifier, appURL: appURL,
                        ownIdentifier: bundleIdentifier)
    }

    /// 기본 앱의 자리를 이 마디와 견준다. 시스템에 묻는 부분과 갈라 두어 시험할 수 있다.
    static func classify(_ handler: URL, identifier: String?, appURL: URL, ownIdentifier: String?) -> Handler {
        func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        if path(handler) == path(appURL) { return .thisApp }
        if let identifier, identifier == ownIdentifier { return .otherCopy(handler) }
        return .app(name: FileManager.default.displayName(atPath: handler.path))
    }

    /// 사람이 읽을 상태 한 줄. Mark이 하는 방식을 따랐다 — 상태를 문장으로 말하고 버튼 하나로 바꾼다.
    static func statusLine(_ kind: Kind, handler: Handler) -> String {
        let label = kind.label
        switch handler {
        case .thisApp:
            return String(localized: "\(label)은 현재 마디에서 열립니다.")
        case let .otherCopy(url):
            let place = (url.path as NSString).abbreviatingWithTildeInPath
            return String(localized: "\(label)은 현재 다른 자리의 마디에서 열립니다: \(place)")
        case let .app(name):
            return String(localized: "\(label)은 현재 ‘\(name)’에서 열립니다.")
        case .none:
            return String(localized: "\(label)을 여는 기본 앱이 정해져 있지 않습니다.")
        }
    }

    /// 이 마디를 그 종류의 기본 앱으로 정한다. 시스템이 한 번 더 물을 수 있고, 거절하면 오류로 온다.
    ///
    /// 되돌리는 길을 두지 않는 이유: 시스템에 "기본 앱 없음"이라는 상태로 돌려놓는
    /// API가 없다. 바꾸려면 다른 앱을 고르는 것이고, 그건 Finder의 정보 창이 하는 일이다.
    static func makeDefault(_ kind: Kind, appURL: URL = Bundle.main.bundleURL,
                            completion: @escaping @MainActor (Error?) -> Void) {
        guard let type = kind.type else {
            completion(NSError(domain: "Madi", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "이 기계에서 그 파일 타입을 찾지 못했습니다."),
            ]))
            return
        }
        // `NSWorkspace`의 콜백은 아무 큐에서나 온다. 그 안에서 바로 UI를 만지면
        // Swift 6이 막는 것이 맞다 — 메인으로 건너와서 부른다.
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
            let failure = error
            Task { @MainActor in completion(failure) }
        }
    }
}

/// 설정 창이 파일 연결을 읽고 바꾸는 길. 시험은 가짜를 넣는다 — 진짜는 사용자의 기본 앱을 바꾼다.
@MainActor
protocol FileAssociating {
    func handler(for kind: FileAssociation.Kind) -> FileAssociation.Handler
    func makeDefault(_ kind: FileAssociation.Kind, completion: @escaping @MainActor (Error?) -> Void)
}

/// 시스템(Launch Services)에 묻고 바꾼다.
struct SystemFileAssociations: FileAssociating {
    func handler(for kind: FileAssociation.Kind) -> FileAssociation.Handler { FileAssociation.handler(for: kind) }
    func makeDefault(_ kind: FileAssociation.Kind, completion: @escaping @MainActor (Error?) -> Void) {
        FileAssociation.makeDefault(kind, completion: completion)
    }
}

/// 앱의 판 번호.
///
/// 자동 업데이트는 배포를 결정한 뒤의 일이지만 **버전 표시만은 지금 해 둔다** —
/// 사용자가 문제를 신고할 때 어느 판인지 말할 수 있어야 한다.
enum AppVersion {

    /// `0.1.0` 같은 사람이 읽는 판 번호.
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    /// 빌드 번호. 같은 판을 여러 번 빌드한 것을 가린다.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    /// `0.1.0 (3)`. 빌드 번호가 판 번호와 같으면 겹쳐 적지 않는다.
    static var display: String {
        short == build ? short : "\(short) (\(build))"
    }
}
