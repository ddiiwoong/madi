import AppKit

/// 끌어놓거나 붙여 넣은 그림을 문서 옆에 두고, 그 자리를 가리키는 마크다운 줄을 돌려준다.
/// 자리와 이름의 규칙은 `ImageAttachment`에 있다.
struct ImageImporter {

    /// 저장한 문서. nil이면 아직 저장하지 않은 문서다 — 그림을 `stagingFolder`에 두고 절대 경로로 적는다. 문서를 처음
    /// 저장하면 창이 그 그림들을 문서 옆으로 옮기고 경로를 고친다(`adoptStagedImages`).
    let documentURL: URL?
    /// 저장하지 않은 문서의 그림을 잠시 두는 폴더(`~/Library/Application Support/Madi/Pasted Images`).
    var stagingFolder: URL?
    var fileManager: FileManager = .default

    init(documentURL: URL?, stagingFolder: URL? = nil, fileManager: FileManager = .default) {
        self.documentURL = documentURL
        self.stagingFolder = stagingFolder
        self.fileManager = fileManager
    }

    /// 파일 하나. 문서 폴더 안이면 복사하지 않고 그 자리를, 밖이면 그림 폴더에 복사한 자리를
    /// 가리킨다. 그림 폴더에 **같은 내용의** 파일이 이미 있으면 그것을 쓴다 — 같은 그림을 두 번
    /// 끌어놓아 `사진-2.png`가 생기지 않게.
    func importFile(_ source: URL) throws -> String {
        line(for: try importedFile(source))
    }

    /// 파일을 들여 놓은 자리(문서 폴더 안이면 그 자리 그대로).
    func importedFile(_ source: URL) throws -> URL {
        if let documentURL, ImageAttachment.relativePath(of: source, fromDocument: documentURL) != nil {
            return source
        }
        let folder = try assetsFolder()
        let destination = ImageAttachment.uniqueURL(for: source.lastPathComponent, in: folder) { candidate in
            fileManager.fileExists(atPath: candidate.path)
                && !fileManager.contentsEqual(atPath: candidate.path, andPath: source.path)
        }
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(at: source, to: destination)
        }
        return destination
    }

    /// 파일을 들여 놓고 마크다운에 적을 경로(인코딩한 것).
    func importedPath(_ source: URL) throws -> String {
        ImageAttachment.encodedPath(path(of: try importedFile(source)))
    }

    /// 파일이 아닌 그림(화면 캡처, 다른 앱에서 복사한 그림). PNG로 적는다.
    func importImage(png data: Data, date: Date = Date()) throws -> String {
        let folder = try assetsFolder()
        let destination = ImageAttachment.uniqueURL(for: ImageAttachment.pastedImageName(date: date),
                                                    in: folder) { fileManager.fileExists(atPath: $0.path) }
        try data.write(to: destination, options: .withoutOverwriting)
        return line(for: destination)
    }

    private func assetsFolder() throws -> URL {
        let folder: URL
        if let documentURL {
            folder = ImageAttachment.assetsFolder(for: documentURL)
        } else if let stagingFolder {
            folder = stagingFolder
        } else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func path(of file: URL) -> String {
        documentURL.flatMap { ImageAttachment.relativePath(of: file, fromDocument: $0) } ?? file.path
    }

    private func line(for file: URL) -> String {
        ImageAttachment.markdown(fileName: file.lastPathComponent, path: path(of: file))
    }

    /// 아직 저장하지 않은 문서에 넣어 둔 그림(`stagingRoot` 안의 파일을 가리키는 그림 링크)을 처음 저장한 문서 옆으로
    /// 들여 놓고, 그 링크의 경로를 문서 옆의 상대 경로로 고치는 편집 하나. 고칠 것이 없으면 nil.
    ///
    /// 그림은 **옮기지 않고 복사한다** — 이 편집을 실행 취소하면 링크가 임시 폴더를 다시 가리키는데, 그때 그림이 없으면
    /// 깨진다. 임시 폴더의 그림은 그대로 남는다.
    static func adoptionEdit(in text: NSString, lines: [LineToken], stagingRoot: URL, document: URL,
                             fileManager: FileManager = .default) throws -> TextEdit? {
        let root = stagingRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let importer = ImageImporter(documentURL: document, fileManager: fileManager)
        let syntax = MarkdownSyntax()
        var replacements: [(range: NSRange, path: String)] = []
        for line in lines where line.contentRange.length > 0 {
            switch line.kind {
            case .codeFence, .codeBody, .linkDefinition, .thematicBreak, .tableDelimiter, .setextUnderline, .blank:
                continue
            default:
                break
            }
            for token in syntax.scanInline(in: text, range: line.contentRange) {
                guard case let .image(raw) = token.kind, let closing = token.markerRanges.last,
                      let file = ImageReference.localURL(for: raw, relativeTo: nil),
                      file.resolvingSymlinksInPath().path.hasPrefix(prefix),
                      fileManager.fileExists(atPath: file.path) else { continue }
                // `](주소)` — 주소는 `](` 바로 뒤다(그림 패턴의 둘째 묶음).
                let address = NSRange(location: closing.location + 2, length: (raw as NSString).length)
                guard NSMaxRange(address) <= text.length, text.substring(with: address) == raw else { continue }
                replacements.append((address, try importer.importedPath(file)))
            }
        }
        guard let first = replacements.first, let last = replacements.last else { return nil }
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var replacement = ""
        var cursor = span.location
        for item in replacements {
            replacement += text.substring(with: NSRange(location: cursor, length: item.range.location - cursor))
            replacement += item.path
            cursor = NSMaxRange(item.range)
        }
        let shift = (replacement as NSString).length - span.length
        return TextEdit(range: span, replacement: replacement,
                        selection: NSRange(location: NSMaxRange(span) + shift, length: 0))
    }

    /// 저장하지 않은 문서의 그림을 두는 폴더.
    static var defaultStagingFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Madi/Pasted Images", isDirectory: true)
    }
}

/// 대지(붙여넣기·끌어놓기)에서 그림을 꺼낸다.
enum ImagePasteboard {

    /// 그림 파일들. 파일이 아닌 주소(웹 주소)는 받지 않는다 — 바깥에서 받아오는 일이 된다.
    static func imageFiles(in pasteboard: NSPasteboard) -> [URL] {
        fileURLs(in: pasteboard).filter(ImageAttachment.isImage)
    }

    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self],
                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// 대지의 그림 데이터를 PNG로. 쓰지 않는 경우가 둘이다.
    ///
    /// - 파일이 함께 있다: Finder에서 파일을 복사하면 **파일 아이콘**이 그림으로 따라온다.
    ///   그림이 아닌 파일을 붙여 넣었는데 아이콘이 문서에 들어가면 안 된다.
    /// - 글이 그림보다 앞에 있다: 대지의 종류 순서는 보낸 앱이 매긴 우선순위다. 웹 페이지나
    ///   문서를 복사하면 글과 함께 그림이 실리는데, 글 편집기에 붙여 넣는 사람은 글을 원한다.
    ///   다만 **글이 그림 자신뿐**이면 그림이다 — 브라우저의 '이미지 복사'는 그림 앞에 `<img>` 하나뿐인 HTML이나
    ///   그림 주소 한 줄을 싣는다(사용자 — "이미지를 복붙하면 자동으로 링크 및 첨부되도록").
    static func pngData(in pasteboard: NSPasteboard) -> Data? {
        guard fileURLs(in: pasteboard).isEmpty, let type = leadingImageType(in: pasteboard),
              let data = pasteboard.data(forType: type) else { return nil }
        if type == .png { return data }
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 넣을 그림이 있는가 — 끌어놓는 동안 '복사' 표시를 낼지 정한다. 데이터를 바꾸지 않는다.
    static func holdsImages(_ pasteboard: NSPasteboard) -> Bool {
        !imageFiles(in: pasteboard).isEmpty
            || (fileURLs(in: pasteboard).isEmpty && leadingImageType(in: pasteboard) != nil)
    }

    private static let jpeg = NSPasteboard.PasteboardType("public.jpeg")

    private static func leadingImageType(in pasteboard: NSPasteboard) -> NSPasteboard.PasteboardType? {
        for type in pasteboard.types ?? [] {
            if type == .png || type == .tiff || type == jpeg { return type }
            if type == .rtf || type == .rtfd { return nil }
            if type == .html {
                if htmlHasText(pasteboard.string(forType: .html) ?? "") { return nil }
                continue
            }
            if type == .string {
                if !isJustAnAddress(pasteboard.string(forType: .string) ?? "") { return nil }
                continue
            }
        }
        return nil
    }

    /// HTML에 보이는 글이 있는가 — 태그와 공백을 빼고 남는 것. `<meta …><img src="…">`뿐이면 없다.
    static func htmlHasText(_ html: String) -> Bool {
        var text = html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for entity in ["&nbsp;", "&#160;", "&#xa0;"] { text = text.replacingOccurrences(of: entity, with: " ") }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 글이 주소 하나뿐인가(비었거나) — 그림을 복사할 때 함께 실리는 그림 주소.
    static func isJustAnAddress(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard !trimmed.contains(where: \.isWhitespace) else { return false }
        let lower = trimmed.lowercased()
        return ["http://", "https://", "file://", "data:image/"].contains { lower.hasPrefix($0) }
    }
}
