import Foundation

/// 끌어놓거나 붙여 넣은 그림을 문서에 넣는 규칙 — 어디에 두고, 무엇이라 적는가.
///
/// **그림은 문서 옆의 `<문서 이름>.assets` 폴더에 복사한다**(Typora와 같은 자리). 문서와
/// 그림이 한 곳에 모이므로 폴더째 옮기거나 `이미지 포함 내보내기`로 묶기 쉽고, 문서마다
/// 폴더가 따로라 다른 문서의 그림과 이름이 부딪히지 않는다. 문서 폴더 **안에 이미 있는**
/// 그림은 복사하지 않고 그 자리를 가리킨다 — 같은 파일이 두 벌 생기면 어느 쪽을 고쳐야
/// 하는지 알 수 없다.
///
/// 파일을 다루지 않는다(그건 `ImageImporter`가 한다). 여기는 이름과 경로와 글만 계산한다.
public enum ImageAttachment {

    /// 그림으로 받는 확장자. 마디가 그릴 수 있는 것(`NSImage`가 읽는 것)이다.
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg",
    ]

    public static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// 문서의 그림 폴더 — `노트.md` 옆의 `노트.assets`.
    public static func assetsFolder(for document: URL) -> URL {
        let stem = document.deletingPathExtension().lastPathComponent
        return document.deletingLastPathComponent()
            .appendingPathComponent(stem + ".assets", isDirectory: true)
    }

    /// 폴더 안에서 겹치지 않는 파일 자리. 이미 있으면 `이름-2.png`, `이름-3.png` …
    public static func uniqueURL(for fileName: String, in folder: URL,
                                 exists: (URL) -> Bool) -> URL {
        let first = folder.appendingPathComponent(fileName)
        guard exists(first) else { return first }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(base)-\(number)" : "\(base)-\(number).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    /// 문서 폴더 기준의 상대 경로. 문서 폴더 밖이면 nil.
    ///
    /// 심볼릭 링크를 푼 뒤에 견준다 — `/var`와 `/private/var`처럼 같은 폴더가 두 이름으로
    /// 불리면 안에 있는 파일을 밖에 있다고 판정한다.
    public static func relativePath(of file: URL, fromDocument document: URL) -> String? {
        let folder = document.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let target = file.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        guard target.hasPrefix(prefix), target.count > prefix.count else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    /// 마크다운에 적을 경로. 링크 주소를 깨뜨리는 글자만 퍼센트 인코딩한다 — 공백, 괄호,
    /// 꺾쇠, `%` 자신. 한글 같은 글자는 그대로 둔다(읽을 수 있어야 하고, 렌더러가 받는다).
    /// 마디의 그림 경로 풀이(`ImageReference.localURL`)가 인코딩을 다시 푼다.
    public static func encodedPath(_ path: String) -> String {
        var out = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "%": out += "%25"
            case " ": out += "%20"
            case "(": out += "%28"
            case ")": out += "%29"
            case "<": out += "%3C"
            case ">": out += "%3E"
            case "\t": out += "%09"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// 그림의 대체 글 — 확장자를 뗀 파일 이름. 대체 글을 깨뜨리는 대괄호는 뺀다.
    public static func altText(for fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }

    /// `![대체 글](경로)` 한 줄.
    public static func markdown(fileName: String, path: String) -> String {
        "![\(altText(for: fileName))](\(encodedPath(path)))"
    }

    /// 붙여 넣은 그림(파일이 아닌 그림 데이터)의 이름 — `image-20261105-165012.png`.
    public static func pastedImageName(date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "image-\(parts.year ?? 0)\(two(parts.month))\(two(parts.day))-"
            + "\(two(parts.hour))\(two(parts.minute))\(two(parts.second)).png"
    }

    /// 그림 줄들을 `range` 자리에 넣는 편집. **그림은 자기 줄이어야 보이므로**(글 사이에 끼인
    /// 그림은 원문으로 남는다) 앞뒤가 글이면 줄을 바꿔 준다. 캐럿은 마지막 그림 줄의 끝으로.
    public static func insertion(_ lines: [String], replacing range: NSRange, in text: NSString) -> TextEdit {
        let start = range.location
        let end = NSMaxRange(range)
        func isBreak(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }
        let before = start > 0 && !isBreak(text.character(at: start - 1)) ? "\n" : ""
        let after = end < text.length && !isBreak(text.character(at: end)) ? "\n" : ""
        let body = lines.joined(separator: "\n")
        let replacement = before + body + after
        let caret = start + ((before + body) as NSString).length
        return TextEdit(range: range, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }
}
