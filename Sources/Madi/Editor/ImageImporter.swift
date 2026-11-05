import AppKit

/// 끌어놓거나 붙여 넣은 그림을 문서 옆에 두고, 그 자리를 가리키는 마크다운 줄을 돌려준다.
/// 자리와 이름의 규칙은 `ImageAttachment`에 있다.
struct ImageImporter {

    let documentURL: URL
    var fileManager: FileManager = .default

    /// 파일 하나. 문서 폴더 안이면 복사하지 않고 그 자리를, 밖이면 그림 폴더에 복사한 자리를
    /// 가리킨다. 그림 폴더에 **같은 내용의** 파일이 이미 있으면 그것을 쓴다 — 같은 그림을 두 번
    /// 끌어놓아 `사진-2.png`가 생기지 않게.
    func importFile(_ source: URL) throws -> String {
        if let relative = ImageAttachment.relativePath(of: source, fromDocument: documentURL) {
            return ImageAttachment.markdown(fileName: source.lastPathComponent, path: relative)
        }
        let folder = try assetsFolder()
        let destination = ImageAttachment.uniqueURL(for: source.lastPathComponent, in: folder) { candidate in
            fileManager.fileExists(atPath: candidate.path)
                && !fileManager.contentsEqual(atPath: candidate.path, andPath: source.path)
        }
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(at: source, to: destination)
        }
        return line(for: destination)
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
        let folder = ImageAttachment.assetsFolder(for: documentURL)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func line(for file: URL) -> String {
        let path = ImageAttachment.relativePath(of: file, fromDocument: documentURL) ?? file.path
        return ImageAttachment.markdown(fileName: file.lastPathComponent, path: path)
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
            if type == .string || type == .rtf || type == .html { return nil }
            if type == .png || type == .tiff || type == jpeg { return type }
        }
        return nil
    }
}
