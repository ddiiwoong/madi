import Foundation

/// 파일이 마크다운인가, 글(텍스트 · 로그)인가 — 확장자로 가린다(사용자 — "txt, log도 볼 수 있도록").
///
/// 글 파일을 마크다운으로 그리면 내용이 바뀌어 보인다. 로그의 `# 주석` 줄이 제목이 되고, `---` 바로 위 줄이 큰 제목이 되고,
/// `**`와 `_`가 사라지고 글이 굵어졌다(확인용 사본으로 `.log`를 열어 봄). `---`로 시작하는 `.txt`는 앞머리 카드로 빠졌다. 그래서
/// 마크다운이 아닌 파일은 앞머리를 가르지 않고 **원본 보기**로 연다 — 쓴 그대로, 고정폭 글꼴로. 원본 보기를 끄면 마크다운으로
/// 그린다(마크다운으로 적은 `.txt`).
public enum TextFileKind: Equatable, Sendable {
    case markdown
    case plainText
    /// 로그. 글 파일과 같이 그리고, **따라 보기**로 연다 — 고칠 수 없게 하고 끝을 따라간다.
    case log

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]
    public static let plainTextExtensions: Set<String> = ["txt", "text"]
    public static let logExtensions: Set<String> = ["log"]

    /// 폴더 · 빠른 열기가 보이고 `madi://`가 받는 파일 — 위 셋을 합친 것.
    public static let openableExtensions = markdownExtensions.union(plainTextExtensions).union(logExtensions)

    /// 확장자로. 저장하지 않은 새 문서(`nil`)는 마크다운이다. 모르는 확장자(열기 창으로 연 `.csv`, 확장자 없는 파일)는 글이다 —
    /// 마디는 글 파일(`public.plain-text`)을 열 수 있다고 선언하고, 마크다운이라고 적힌 것만 마크다운으로 그린다.
    public init(url: URL?) {
        guard let url else {
            self = .markdown
            return
        }
        let ext = url.pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if Self.logExtensions.contains(ext) {
            self = .log
        } else {
            self = .plainText
        }
    }

    /// 마크다운으로 그리는가 — 앞머리를 가르고, 원본 보기를 끈 채 연다.
    public var rendersMarkdown: Bool { self == .markdown }

    /// 따라 보기로 여는가.
    public var followsByDefault: Bool { self == .log }
}
