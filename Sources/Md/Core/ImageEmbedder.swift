import Foundation

/// 문서의 로컬 그림을 `data:` 주소로 바꿔 **단일 파일**로 만든다.
///
/// 파일을 읽는 일은 `loader`로 분리했다. 그래야 변환 규칙을 파일 없이 테스트할 수 있고,
/// 테스트가 디스크 상태에 흔들리지 않는다.
public enum ImageEmbedder {

    public enum SkipReason: String, Sendable {
        /// 원격 주소. 받아오지 않는다(네트워크를 쓰지 않는다는 원칙).
        case remote
        /// 이미 `data:`로 박혀 있다.
        case alreadyEmbedded
        /// 경로를 풀 수 없다(저장하지 않은 문서의 상대 경로 등).
        case unresolved
        /// 읽지 못했다.
        case unreadable
        /// 확장자로 종류를 알 수 없다.
        case unknownType
        /// 너무 크다.
        case tooLarge

        public var message: String {
            switch self {
            case .remote: return "원격 주소는 포함하지 않습니다"
            case .alreadyEmbedded: return "이미 포함되어 있습니다"
            case .unresolved: return "경로를 풀 수 없습니다"
            case .unreadable: return "읽지 못했습니다"
            case .unknownType: return "그림 종류를 알 수 없습니다"
            case .tooLarge: return "너무 커서 건너뛰었습니다"
            }
        }
    }

    public struct Skip: Equatable, Sendable {
        public let path: String
        public let reason: SkipReason
    }

    public struct Outcome: Equatable, Sendable {
        public let markdown: String
        public let embedded: Int
        public let skipped: [Skip]
    }

    /// 한 그림의 크기 상한. base64는 원본의 약 4/3이 되므로 8MB 그림이 11MB 글이 된다.
    public static let defaultMaxBytes = 8 * 1024 * 1024

    /// 확장자 → MIME. **모르는 확장자는 건너뛴다.** 엉뚱한 MIME을 붙이면 어떤
    /// 뷰어에서도 열리지 않는 파일이 되고, 그것은 원문을 그대로 두는 것보다 나쁘다.
    public static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "avif": return "image/avif"
        case "ico": return "image/x-icon"
        default: return nil
        }
    }

    /// 문서의 그림을 포함시킨다.
    ///
    /// **코드 블록 안의 그림 문법은 건드리지 않는다.** 코드 블록은 보여 주기 위한 예시
    /// 이고, 그 안의 `![a](b.png)`를 base64로 바꾸면 사용자가 적어 둔 예시가 망가진다.
    public static func embed(in markdown: String, documentURL: URL?,
                             maxBytes: Int = defaultMaxBytes,
                             loader: (URL) -> Data?) -> Outcome {
        let text = markdown as NSString
        let syntax = MarkdownSyntax()
        var replacements: [(range: NSRange, value: String)] = []
        var skipped: [Skip] = []
        var embedded = 0

        for line in syntax.scanLines(in: text) {
            // 코드 블록과 펜스는 건너뛴다.
            switch line.kind {
            case .codeFence, .codeBody: continue
            default: break
            }
            guard line.contentRange.length > 0 else { continue }

            for token in syntax.scanInline(in: text, range: line.contentRange) {
                guard case let .image(raw) = token.kind else { continue }
                guard let urlRange = rangeOfURL(raw, in: token, text: text) else { continue }

                if raw.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("data:") {
                    skipped.append(Skip(path: raw, reason: .alreadyEmbedded))
                    continue
                }
                if ImageReference.isRemote(raw) {
                    skipped.append(Skip(path: raw, reason: .remote))
                    continue
                }
                guard let url = ImageReference.localURL(for: raw, relativeTo: documentURL) else {
                    skipped.append(Skip(path: raw, reason: .unresolved))
                    continue
                }
                guard let mime = mimeType(forExtension: url.pathExtension) else {
                    skipped.append(Skip(path: raw, reason: .unknownType))
                    continue
                }
                guard let data = loader(url) else {
                    skipped.append(Skip(path: raw, reason: .unreadable))
                    continue
                }
                guard data.count <= maxBytes else {
                    skipped.append(Skip(path: raw, reason: .tooLarge))
                    continue
                }

                replacements.append((urlRange,
                                     "data:\(mime);base64,\(data.base64EncodedString())"))
                embedded += 1
            }
        }

        // **뒤에서부터** 바꾼다. 앞에서부터 바꾸면 뒤쪽 범위가 어긋난다.
        let result = NSMutableString(string: markdown)
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: replacement.range, with: replacement.value)
        }
        return Outcome(markdown: result as String, embedded: embedded, skipped: skipped)
    }

    /// 토큰 안에서 주소가 놓인 자리.
    ///
    /// 닫는 마커(`](주소)`) 안에서만 찾는다. 대체 글(`![주소처럼 보이는 글](...)`)에
    /// 같은 글자가 있을 수 있어 토큰 전체에서 찾으면 엉뚱한 자리를 바꾼다.
    static func rangeOfURL(_ raw: String, in token: InlineToken, text: NSString) -> NSRange? {
        guard let closing = token.markerRanges.last, closing.length > 0,
              NSMaxRange(closing) <= text.length else { return nil }
        let marker = text.substring(with: closing) as NSString
        let local = marker.range(of: raw)
        guard local.location != NSNotFound else { return nil }
        return NSRange(location: closing.location + local.location, length: local.length)
    }
}
