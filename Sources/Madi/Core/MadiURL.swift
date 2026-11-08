import Foundation

/// `madi://` 링크 — 다른 앱 · 단축어 · 셸(`open "madi://…"`)에서 마디에 일을 시키는 주소(사용자 — "madi:// 같이 입력받을
/// 수 있도록 api 형태로"). 여기는 주소를 **읽기만** 한다(순수 계산). 실행은 `URLCommandRunner`가 한다.
///
/// | 주소 | 하는 일 |
/// |---|---|
/// | `madi://open?path=…[&line=N][&search=…]` | 파일을 열고, N번째 줄로 가거나 그 낱말을 찾는다 |
/// | `madi://new?text=…[&title=…][&path=…]` | 그 글로 새 문서를 연다. `path`가 있으면 그 자리에 새 파일로 만들어 연다 |
/// | `madi://append?path=…&text=…` | 파일 끝에 글을 더한다 — **묻고 나서** |
///
/// 값은 퍼센트 부호로 적는다(공백은 `%20`). `+`는 공백이 아니라 `+` 그대로다 — 웹 폼의 약속이고 URL의 약속이 아니다.
/// `path`는 절대 경로, `~/…`, `file://…` 셋을 받는다. 마크다운 · 글 파일(`supportedExtensions`)만 받는다 — 링크는 웹
/// 페이지도 누를 수 있으므로, 확장자가 없는 설정 파일(`~/.ssh/…`) 같은 것을 고치는 길을 처음부터 막는다.
public enum MadiURL {

    public static let scheme = "madi"

    /// 마디가 여는 파일 — 마크다운과 글.
    public static let supportedExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "txt", "text"]

    public enum Command: Equatable, Sendable {
        /// 파일을 연다. `line`은 파일의 줄 번호(1부터, front matter 포함), `search`는 찾을 낱말.
        case open(file: URL, line: Int?, search: String?)
        /// 새 문서. `title`이 있으면 맨 위에 `# 제목`을 둔다. `file`이 없으면 저장하지 않은 채 열고(제목은 저장할 때의
        /// 이름으로 제안), 있으면 그 자리에 새 파일로 만들어 연다(사용자 — "새 글 쓰는 것도"). 있는 파일은 덮어쓰지 않는다.
        case new(text: String, title: String?, file: URL? = nil)
        /// 파일 끝에 글을 더한다.
        case append(file: URL, text: String)
    }

    public enum Failure: Error, Equatable, Sendable {
        case notMadi
        case noAction
        case unknownAction(String)
        case missing(String)
        case relativePath(String)
        case unsupportedFile(String)
        case badLine(String)

        /// 사용자에게 보일 문장.
        public var message: String {
            switch self {
            case .notMadi:
                return String(localized: "madi:// 주소가 아닙니다.")
            case .noAction:
                return String(localized: "명령이 없습니다 — madi://open?path=… 처럼 씁니다.")
            case .unknownAction(let action):
                return String(localized: "모르는 명령입니다: \(action) — open · new · append 중 하나를 씁니다.")
            case .missing(let name):
                return String(localized: "'\(name)' 값이 없습니다.")
            case .relativePath(let path):
                return String(localized: "경로는 /로 시작하는 절대 경로나 ~/로 적습니다: \(path)")
            case .unsupportedFile(let path):
                return String(localized: "마크다운 · 글 파일(.md · .markdown · .txt 등)만 엽니다: \(path)")
            case .badLine(let value):
                return String(localized: "줄 번호는 1 이상의 정수입니다: \(value)")
            }
        }
    }

    /// 받은 글을 주소로. 사람이 셸에 적은 대로 한글 · 공백 · `#` · `[ ]`가 그대로 섞인 주소(`madi://new?text=회의%20메모`)도
    /// 받는다 — Foundation의 `URL(string:)`은 그런 글을 고쳐 읽으면서 이미 적힌 `%`까지 다시 싸 버려(`%20` → `%2520`) 값에
    /// `%20` 글자가 그대로 남는다. 그래서 여기서 먼저 ASCII 밖의 글자와 URL에 못 쓰는 글자만 싸고, 이미 적힌 `%XX`는 둔다.
    /// 뒤에 16진 두 자리가 없는 `%`(`100%`)는 `%25`로 싼다. `#`도 싼다 — 마디는 조각(fragment)을 쓰지 않으므로 `#`은 늘
    /// 글의 일부다(`text=# 제목`).
    public static func url(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var encoded = ""
        let scalars = Array(trimmed.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%" {
                let isEscape = index + 2 < scalars.count
                    && scalars[index + 1].properties.isASCIIHexDigit && scalars[index + 2].properties.isASCIIHexDigit
                encoded += isEscape ? "%" : "%25"
            } else if scalar.isASCII, scalar.value > 0x20, scalar.value < 0x7F,
                      !"\"#<>[\\]^`{|}".unicodeScalars.contains(scalar) {
                encoded.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 { encoded += String(format: "%%%02X", byte) }
            }
            index += 1
        }
        return URL(string: encoded)
    }

    /// 주소를 읽는다. `home`은 `~/`를 풀 집 폴더다(시험이 바꾼다).
    public static func parse(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> Result<Command, Failure> {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.notMadi)
        }
        // `madi://open?…`는 명령이 host 자리에, `madi:open?…` · `madi:///open?…`은 경로 자리에 온다.
        let action = (components.host?.isEmpty == false ? components.host
                      : components.path.split(separator: "/").first.map(String.init)) ?? ""
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }

        switch action.lowercased() {
        case "open":
            let file: URL
            switch fileURL(values["path"], home: home) {
            case .success(let resolved): file = resolved
            case .failure(let failure): return .failure(failure)
            }
            var line: Int?
            if let raw = values["line"] {
                guard let number = Int(raw), number >= 1 else { return .failure(.badLine(raw)) }
                line = number
            }
            let search = values["search"].flatMap { $0.isEmpty ? nil : $0 }
            return .success(.open(file: file, line: line, search: search))

        case "new":
            let text = values["text"] ?? ""
            let title = values["title"].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            var file: URL?
            if values["path"] != nil {
                switch fileURL(values["path"], home: home) {
                case .success(let resolved): file = resolved
                case .failure(let failure): return .failure(failure)
                }
            }
            return .success(.new(text: text, title: title, file: file))

        case "append":
            let file: URL
            switch fileURL(values["path"], home: home) {
            case .success(let resolved): file = resolved
            case .failure(let failure): return .failure(failure)
            }
            guard let text = values["text"], !text.isEmpty else { return .failure(.missing("text")) }
            return .success(.append(file: file, text: text))

        case "":
            return .failure(.noAction)
        default:
            return .failure(.unknownAction(action))
        }
    }

    /// `path` 값을 파일 주소로. 절대 경로 · `~/…` · `file://…`만 받고, `..`를 풀어 실제로 가리키는 자리로 본 뒤 확장자를
    /// 따진다(`/글/../.ssh/x` 같은 꼴이 확장자 검사를 지나치지 않게 — 검사는 푼 경로에 한다).
    static func fileURL(_ raw: String?, home: URL) -> Result<URL, Failure> {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.missing("path")) }
        let url: URL
        if raw.lowercased().hasPrefix("file://") {
            guard let parsed = URL(string: raw), parsed.isFileURL else { return .failure(.relativePath(raw)) }
            url = parsed
        } else if raw == "~" || raw.hasPrefix("~/") {
            url = home.appendingPathComponent(String(raw.dropFirst(raw == "~" ? 1 : 2)))
        } else if raw.hasPrefix("/") {
            url = URL(fileURLWithPath: raw)
        } else {
            return .failure(.relativePath(raw))
        }
        let standardized = url.standardizedFileURL
        guard supportedExtensions.contains(standardized.pathExtension.lowercased()) else {
            return .failure(.unsupportedFile(standardized.path))
        }
        return .success(standardized)
    }

    // MARK: 새 문서의 글

    /// `new`가 여는 글. `title`이 있으면 맨 위에 `# 제목`과 빈 줄. 파일로 만들 때(`asFile`)는 끝을 줄바꿈으로 맺는다
    /// (빈 파일은 그대로 비운다) — 제목만 주면 `# 제목\n\n`이라 캐럿이 그 아래 빈 줄에서 바로 쓰기 시작한다.
    public static func newDocumentText(_ text: String, title: String?, asFile: Bool) -> String {
        var composed = title.map { "# \($0)\n\n\(text)" } ?? text
        if asFile, !composed.isEmpty, !composed.hasSuffix("\n") { composed += "\n" }
        return composed
    }

    // MARK: 끝에 더하기

    /// `append`가 본문 끝에 넣을 편집. 끝 문단과는 빈 줄 하나로 띄운다. 다만 본문이 목록 항목으로 끝나고 더할 글도
    /// 목록 항목으로 시작하면 줄바꿈 하나로만 잇는다 — `- [ ] 우유`를 할 일 목록에 더하면 같은 목록의 다음 항목이
    /// 되어야 한다(빈 줄을 두면 목록이 느슨해져 항목 사이가 벌어진다). 캐럿은 더한 글 뒤.
    public static func appendEdit(_ text: String, to body: String) -> TextEdit {
        var piece = text.hasSuffix("\n") ? text : text + "\n"
        let lastLine = body.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let continuesList = isListItem(lastLine) && isListItem(firstLine)
        if body.isEmpty {
            // 빈 문서 — 그대로.
        } else if continuesList && !body.hasSuffix("\n\n") {
            if !body.hasSuffix("\n") { piece = "\n" + piece }
        } else if body.hasSuffix("\n\n") {
            // 이미 빈 줄로 끝난다.
        } else if body.hasSuffix("\n") {
            piece = "\n" + piece
        } else {
            piece = "\n\n" + piece
        }
        let end = (body as NSString).length
        return TextEdit(range: NSRange(location: end, length: 0), replacement: piece,
                        selection: NSRange(location: end + (piece as NSString).length, length: 0))
    }

    private static let listItemPattern = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]"#)

    private static func isListItem(_ line: String) -> Bool {
        listItemPattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    // MARK: 줄 번호

    /// 파일의 `line`번째 줄(1부터)이 본문(front matter를 뺀 편집기의 글)에서 몇 번째 줄인지. front matter 안이면 1.
    /// `frontMatterLines`는 본문 앞에 있는 줄 수다.
    public static func bodyLine(forFileLine line: Int, frontMatterLines: Int) -> Int {
        max(1, line - frontMatterLines)
    }

    /// 글에서 `line`번째 줄(1부터)의 시작 위치(UTF-16). 줄이 모자라면 마지막 줄의 시작.
    public static func location(ofLine line: Int, in text: NSString) -> Int {
        var start = 0
        for _ in 1..<max(line, 1) {
            let range = text.lineRange(for: NSRange(location: start, length: 0))
            let next = NSMaxRange(range)
            // 마지막 줄을 지나면 멈춘다. 글이 줄바꿈으로 끝나면 그 뒤의 빈 자리가 마지막 줄이다.
            let endsWithNewline = !LineEditing.terminator(of: text.substring(with: range)).isEmpty
            if next == start || (next >= text.length && !endsWithNewline) { break }
            start = next
        }
        return min(start, text.length)
    }
}
