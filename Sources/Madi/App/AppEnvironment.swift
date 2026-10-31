import AppKit
import UniformTypeIdentifiers

/// 마크다운 파일을 어떤 앱이 여는지 읽고 바꾼다.
///
/// 마디는 `CFBundleDocumentTypes`로 "열 수 있다"고 **선언만** 한다. 선언은 기본 앱을
/// 정하지 않으므로, 사용자가 `.md`를 두 번 눌렀을 때 다른 앱이 열릴 수 있다. 설정에서
/// 지금 상태를 보여 주고 한 번에 바꿀 수 있어야 한다.
@MainActor
enum FileAssociation {

    /// 마크다운 문서의 타입. `.md` 확장자가 가리키는 것을 시스템에 묻는다 —
    /// `net.daringfireball.markdown`을 글자로 박아 두면, 시스템이 그 식별자를 바꾸거나
    /// 사용자 기계에 그 타입이 없을 때 조용히 틀린다.
    static var markdownType: UTType? {
        UTType(filenameExtension: "md") ?? UTType("net.daringfireball.markdown")
    }

    /// 지금 `.md`를 여는 앱의 이름. 정해진 것이 없으면 nil.
    static var currentHandlerName: String? {
        guard let type = markdownType,
              let url = NSWorkspace.shared.urlsForApplications(toOpen: type).first
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// 마디가 이미 기본 앱인가.
    static var isMadiDefault: Bool {
        guard let type = markdownType,
              let handler = NSWorkspace.shared.urlsForApplications(toOpen: type).first,
              let own = Bundle.main.bundleIdentifier,
              let bundle = Bundle(url: handler)
        else { return false }
        return bundle.bundleIdentifier == own
    }

    /// 사람이 읽을 상태 한 줄. Mark이 하는 방식을 따랐다 — 상태를 문장으로 말하고
    /// 버튼 하나로 바꾼다.
    static var statusLine: String {
        if isMadiDefault { return String(localized: "Markdown 파일은 현재 마디에서 열립니다.") }
        if let name = currentHandlerName {
            return String(localized: "Markdown 파일은 현재 ‘\(name)’에서 열립니다.")
        }
        return String(localized: "Markdown 파일을 여는 기본 앱이 정해져 있지 않습니다.")
    }

    /// 마디를 기본 앱으로 등록한다.
    ///
    /// 되돌리는 길을 두지 않는 이유: 시스템에 "기본 앱 없음"이라는 상태로 돌려놓는
    /// API가 없다. 바꾸려면 다른 앱을 고르는 것이고, 그건 Finder의 정보 창이 하는 일이다.
    static func makeMadiDefault(completion: @escaping @MainActor (Error?) -> Void) {
        guard let type = markdownType else {
            completion(NSError(domain: "Madi", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "이 기계에서 Markdown 파일 타입을 찾지 못했습니다."),
            ]))
            return
        }
        // `NSWorkspace`의 콜백은 아무 큐에서나 온다. 그 안에서 바로 UI를 만지면
        // Swift 6이 막는 것이 맞다 — 메인으로 건너와서 부른다.
        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: type) { error in
            let failure = error
            Task { @MainActor in completion(failure) }
        }
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
