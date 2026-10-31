import AppKit
import CoreText

/// 앱에 들어 있는 글꼴(Pretendard, IBM Plex Mono)을 **이 프로세스에만** 등록한다.
///
/// 시스템에 설치하지 않는다 — 사용자의 글꼴 목록을 건드릴 이유가 없다. `ATSApplicationFontsPath`
/// 대신 코드로 등록하는 이유: 그 방식은 실패해도 아무 말이 없어, 글꼴이 빠진 빌드가 조용히 시스템
/// 글꼴로 그린다. 여기서는 빠진 파일과 실패를 기록에 남긴다.
///
/// 파일과 라이선스는 `Resources/Fonts/README.md`에 적었다(SIL OFL 1.1 — 전문을 함께 넣는다).
@MainActor
public enum BundledFonts {

    public static let bodyFamily = EditorPreferences.bundledBodyFamily
    public static let codeFamily = EditorPreferences.bundledCodeFamily

    /// 들어 있어야 하는 글꼴 파일.
    public static let fontFiles = [
        "Pretendard-Regular.otf", "Pretendard-Bold.otf",
        "IBMPlexMono-Regular.otf", "IBMPlexMono-Bold.otf",
        "IBMPlexMono-Italic.otf", "IBMPlexMono-BoldItalic.otf",
    ]
    /// 함께 나가야 하는 라이선스 전문(OFL 2조).
    public static let licenseFiles = ["OFL-Pretendard.txt", "OFL-IBMPlexMono.txt"]

    /// 글꼴 파일의 자리. 앱에서는 번들의 리소스 폴더(빌드가 하위 폴더를 풀어 둔다), 시험·도구에서는
    /// 저장소의 `Sources/Madi/Resources/Fonts`를 넘긴다.
    public static func url(of file: String, in directory: URL?) -> URL? {
        if let directory {
            let url = directory.appendingPathComponent(file)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fonts")
    }

    /// 등록한다. 등록하지 못한 파일과 까닭을 돌려준다(비었으면 전부 됐다). 여러 번 불러도 된다 —
    /// 이미 등록된 것은 실패로 세지 않는다.
    @discardableResult
    public static func register(from directory: URL? = nil) -> [(file: String, reason: String)] {
        var failures: [(file: String, reason: String)] = []
        for file in fontFiles {
            guard let url = url(of: file, in: directory) else {
                failures.append((file, "파일이 없습니다"))
                continue
            }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { continue }
            let cfError = error?.takeRetainedValue()
            // 이미 등록된 것은 성공이다 — 시험이 여러 번 부른다.
            if let cfError, CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
                continue
            }
            failures.append((file, cfError.map { CFErrorCopyDescription($0) as String } ?? "알 수 없는 오류"))
        }
        // 등록 전에 이 이름을 찾아 '없음'으로 기억해 둔 것이 있으면 버린다.
        MarkdownTheme.forgetResolvedFonts()
        return failures
    }
}
