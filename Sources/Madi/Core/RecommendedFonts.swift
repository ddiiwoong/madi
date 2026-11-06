import Foundation

/// 글꼴 고르개 맨 위에 두는 추천 글꼴 — 한국어 글에 잘 맞고 **누구나 무료로 쓸 수 있는** 것.
///
/// 이 Mac에 있으면 그대로 고르고, 없으면 공식 배포 페이지를 연다(받아 설치하면 고르개가 바로
/// 다시 채워진다 — `NSFont.fontSetChangedNotification`). 시스템 글꼴 목록은 수백 개라 그 사이에서
/// 한국어 글꼴을 찾기 어렵다.
///
/// 주소는 배포처의 페이지다(2026-11-06에 열리는 것을 확인했다). 파일을 직접 받지 않는다 —
/// 마디가 바깥에서 내려받아 설치하는 일은 사용자가 시킨 일보다 크다.
public struct RecommendedFont: Equatable, Sendable {

    public enum Use: Equatable, Sendable {
        /// 본문·제목에 쓰는 글꼴.
        case text
        /// 코드에 쓰는 고정폭.
        case code
    }

    public enum Source: Equatable, Sendable {
        /// 앱에 들어 있다(`BundledFonts`).
        case bundled
        /// macOS에 들어 있다.
        case system
        /// 받아서 설치한다 — 이 페이지에서.
        case download(URL)
    }

    /// 고르개에 보이고 설정에 저장되는 이름(`NSFontManager`의 패밀리 이름).
    public let family: String
    /// 같은 글꼴이 설치될 수 있는 다른 이름. 배포처마다 패밀리 이름이 다르다(`Nanum Myeongjo` ·
    /// `NanumMyeongjo`).
    public let aliases: [String]
    public let use: Use
    /// 모양의 갈래 — 고딕 · 명조 · 고정폭.
    public let style: String
    public let source: Source

    public init(family: String, aliases: [String] = [], use: Use, style: String, source: Source) {
        self.family = family
        self.aliases = aliases
        self.use = use
        self.style = style
        self.source = source
    }

    /// 이 Mac에 설치된 이름. 없으면 nil.
    public func installedName(isInstalled: (String) -> Bool) -> String? {
        ([family] + aliases).first(where: isInstalled)
    }

    /// 받을 곳. 앱이나 macOS에 들어 있으면 nil.
    public var downloadPage: URL? {
        if case let .download(url) = source { return url }
        return nil
    }
}

public enum RecommendedFonts {

    private static func page(_ string: String) -> RecommendedFont.Source {
        guard let url = URL(string: string) else { preconditionFailure("invalid built-in URL") }
        return .download(url)
    }

    /// 고딕 → 명조 순, 갈래 안에서는 앱·macOS에 있는 것이 먼저다.
    public static let all: [RecommendedFont] = [
        RecommendedFont(family: EditorPreferences.bundledBodyFamily, use: .text,
                        style: String(localized: "고딕"), source: .bundled),
        RecommendedFont(family: "Apple SD Gothic Neo", use: .text,
                        style: String(localized: "고딕"), source: .system),
        RecommendedFont(family: "Nanum Gothic", aliases: ["NanumGothic", "나눔고딕"], use: .text,
                        style: String(localized: "고딕"), source: page("https://fonts.google.com/specimen/Nanum+Gothic")),
        RecommendedFont(family: "Noto Sans KR", use: .text,
                        style: String(localized: "고딕"), source: page("https://fonts.google.com/noto/specimen/Noto+Sans+KR")),
        RecommendedFont(family: "IBM Plex Sans KR", use: .text,
                        style: String(localized: "고딕"), source: page("https://fonts.google.com/specimen/IBM+Plex+Sans+KR")),
        RecommendedFont(family: "AppleMyungjo", use: .text,
                        style: String(localized: "명조"), source: .system),
        RecommendedFont(family: "Nanum Myeongjo", aliases: ["NanumMyeongjo", "나눔명조"], use: .text,
                        style: String(localized: "명조"),
                        source: page("https://fonts.google.com/specimen/Nanum+Myeongjo")),
        RecommendedFont(family: "Noto Serif KR", use: .text,
                        style: String(localized: "명조"), source: page("https://fonts.google.com/noto/specimen/Noto+Serif+KR")),

        RecommendedFont(family: EditorPreferences.bundledCodeFamily, use: .code,
                        style: String(localized: "고정폭"), source: .bundled),
        RecommendedFont(family: "Menlo", use: .code, style: String(localized: "고정폭"), source: .system),
        RecommendedFont(family: "D2Coding", use: .code, style: String(localized: "한글 고정폭"),
                        source: page("https://github.com/naver/d2codingfont")),
        RecommendedFont(family: "JetBrains Mono", use: .code, style: String(localized: "고정폭"),
                        source: page("https://www.jetbrains.com/lp/mono/")),
    ]

    public static func list(for use: RecommendedFont.Use) -> [RecommendedFont] {
        all.filter { $0.use == use }
    }
}
