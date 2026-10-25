import Foundation

/// EPUB 한 권의 구조. ZIP 위에 얹힌다.
///
/// 읽는 것은 구조뿐이다 — 화면에 어떻게 보일지는 여기서 정하지 않는다.
///
/// 목차를 **두 가지 방식으로** 읽는다. EPUB 3은 `nav` 속성이 붙은 XHTML을 쓰고
/// EPUB 2는 NCX 파일을 쓴다. 한쪽만 다루면 안 되는 이유를 실측으로 확인했다 —
/// 이 Mac에 있던 실제 책(2026년에 나온 책이다)이 `version="2.0"`에 `toc.ncx`였다.
public struct EpubBook {

    // MARK: 담는 것

    public struct Metadata: Equatable, Sendable {
        public var title: String?
        public var creators: [String] = []
        public var language: String?
        public var identifier: String?
        public var publisher: String?
        public var date: String?
    }

    public struct ManifestItem: Equatable, Sendable {
        public let id: String
        /// ZIP 안에서의 **전체 경로**. OPF 기준 상대 경로를 이미 풀어 둔 것이다.
        public let path: String
        public let mediaType: String
        /// EPUB 3의 `properties`. 목차를 찾을 때 `nav`가 들었는지 본다.
        public let properties: [String]

        public var isNavigationDocument: Bool { properties.contains("nav") }
        public var isNCX: Bool { mediaType == "application/x-dtbncx+xml" }
    }

    public struct TocEntry: Equatable, Sendable {
        public let title: String
        /// ZIP 안에서의 전체 경로. 조각(`#`)은 떼어 둔다.
        public let path: String
        /// 원래 적혀 있던 조각. 챕터 안의 자리를 가리킨다.
        public let fragment: String?
        public let children: [TocEntry]
    }

    public enum Failure: Error, Equatable {
        /// `mimetype`이 없거나 내용이 다르다.
        case notAnEpub(String)
        /// DRM이 걸려 있다. **읽을 수 없다** — 깨진 글자를 보여 주는 대신 이렇게 말한다.
        case drmProtected(scheme: String)
        case missingContainer
        case missingOPF(String)
        case malformedXML(String)
        /// 읽는 순서가 비어 있다. 구조는 있지만 보여 줄 것이 없다.
        case emptySpine
    }

    public let metadata: Metadata
    /// id로 찾는 manifest.
    public let manifest: [String: ManifestItem]
    /// 읽는 순서.
    public let spine: [ManifestItem]
    public let toc: [TocEntry]
    /// OPF가 있던 자리. 다른 경로를 풀 때의 기준이다.
    public let opfPath: String
    /// `mimetype`이 규격대로 맨 앞에 무압축으로 있었는가.
    ///
    /// 규격은 그렇게 요구하지만 현실의 책이 어기기도 한다. 어겼다고 거절하면 읽을 수
    /// 있는 책을 못 읽게 되므로, 거절하지 않고 **알려만** 준다.
    public let isSpecCompliant: Bool

    // MARK: 열기

    public static func open(_ archive: ZipArchive,
                            inflate: (Data, Int) throws -> Data) throws -> EpubBook {
        // 1. EPUB인가.
        guard let mimetypeData = try archive.contents(named: "mimetype", inflate: inflate),
              let mimetype = String(data: mimetypeData, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw Failure.notAnEpub("mimetype 항목이 없습니다") }
        guard mimetype == "application/epub+zip" else {
            throw Failure.notAnEpub("mimetype이 '\(mimetype)'입니다")
        }
        let compliant = archive.firstEntry?.name == "mimetype"
            && archive.firstEntry?.method == .stored

        // 2. DRM이 걸렸으면 **정직하게 거절한다.** 암호화된 바이트를 억지로 그리면
        //    깨진 글자가 나오고, 사용자는 앱이 고장 난 줄 안다.
        if let encryption = try archive.contents(named: "META-INF/encryption.xml",
                                                 inflate: inflate) {
            throw Failure.drmProtected(scheme: describeEncryption(encryption))
        }

        // 3. container.xml → OPF 경로.
        guard let containerData = try archive.contents(named: "META-INF/container.xml",
                                                       inflate: inflate)
        else { throw Failure.missingContainer }
        let container = try document(containerData, "META-INF/container.xml")
        guard let opfPath = try container
            .nodes(forXPath: "//*[local-name()='rootfile']/@full-path")
            .compactMap(\.stringValue).first.map(decodePath)
        else { throw Failure.missingOPF("container.xml에 rootfile이 없습니다") }

        guard let opfData = try archive.contents(named: opfPath, inflate: inflate) else {
            throw Failure.missingOPF(opfPath)
        }
        let opf = try document(opfData, opfPath)
        // OPF 안의 경로는 **OPF가 있는 폴더** 기준이다.
        let base = (opfPath as NSString).deletingLastPathComponent

        // 4. metadata.
        let metadata = readMetadata(opf)

        // 5. manifest.
        var items: [String: ManifestItem] = [:]
        for node in try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let element = node as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue else { continue }
            let properties = (element.attribute(forName: "properties")?.stringValue ?? "")
                .split(whereSeparator: \.isWhitespace).map(String.init)
            items[id] = ManifestItem(
                id: id,
                path: resolve(href, against: base),
                mediaType: element.attribute(forName: "media-type")?.stringValue ?? "",
                properties: properties
            )
        }

        // 6. spine.
        var order: [ManifestItem] = []
        for node in try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']") {
            guard let element = node as? XMLElement,
                  let idref = element.attribute(forName: "idref")?.stringValue,
                  let item = items[idref] else { continue }
            order.append(item)
        }
        guard !order.isEmpty else { throw Failure.emptySpine }

        // 7. 목차 — EPUB 3의 nav를 먼저 보고, 없으면 EPUB 2의 NCX를 본다.
        let spineTocID = (try? opf.nodes(forXPath: "//*[local-name()='spine']/@toc"))?
            .compactMap(\.stringValue).first
        let toc = readToc(archive: archive, inflate: inflate, items: items,
                          spineTocID: spineTocID)

        return EpubBook(metadata: metadata, manifest: items, spine: order, toc: toc,
                        opfPath: opfPath, isSpecCompliant: compliant)
    }

    // MARK: 조각들

    private static func document(_ data: Data, _ name: String) throws -> XMLDocument {
        do {
            return try XMLDocument(data: data, options: [])
        } catch {
            // 어긋난 마크업이 흔하다. 느슨하게 한 번 더 시도한다.
            do {
                return try XMLDocument(data: data, options: [.documentTidyXML])
            } catch {
                throw Failure.malformedXML(name)
            }
        }
    }

    private static func readMetadata(_ opf: XMLDocument) -> Metadata {
        func texts(_ localName: String) -> [String] {
            let path = "//*[local-name()='metadata']/*[local-name()='\(localName)']"
            return ((try? opf.nodes(forXPath: path)) ?? [])
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        var metadata = Metadata()
        metadata.title = texts("title").first
        metadata.creators = texts("creator")
        metadata.language = texts("language").first
        metadata.identifier = texts("identifier").first
        metadata.publisher = texts("publisher").first
        metadata.date = texts("date").first
        return metadata
    }

    /// 어떤 암호화인지 한 줄로. 사용자에게 "왜 못 읽는지"를 말해 주기 위한 것이다.
    private static func describeEncryption(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "알 수 없는 방식" }
        if text.contains("adobe.com/adept") { return "Adobe ADEPT" }
        if text.contains("apple.com") || text.contains("FairPlay") { return "Apple FairPlay" }
        if text.contains("idpf.org/2008/embedding") {
            // 글꼴만 난독화한 경우다. 본문은 읽을 수 있지만 글꼴이 깨진다.
            return "글꼴 난독화(IDPF)"
        }
        return "알 수 없는 방식"
    }

    // MARK: 목차

    private static func readToc(archive: ZipArchive,
                                inflate: (Data, Int) throws -> Data,
                                items: [String: ManifestItem],
                                spineTocID: String?) -> [TocEntry] {
        // EPUB 3: properties에 nav가 붙은 항목.
        if let nav = items.values.first(where: \.isNavigationDocument),
           let data = try? archive.contents(named: nav.path, inflate: inflate),
           let parsed = try? navigationEntries(data, base: folder(of: nav.path)),
           !parsed.isEmpty {
            return parsed
        }
        // EPUB 2: spine의 toc 속성이 가리키는 NCX. 없으면 media-type으로 찾는다.
        let ncx = spineTocID.flatMap { items[$0] } ?? items.values.first(where: \.isNCX)
        if let ncx,
           let data = try? archive.contents(named: ncx.path, inflate: inflate),
           let parsed = try? ncxEntries(data, base: folder(of: ncx.path)) {
            return parsed
        }
        return []
    }

    /// EPUB 3의 목차. `epub:type="toc"`가 붙은 `nav` 안의 중첩 목록이다.
    static func navigationEntries(_ data: Data, base: String) throws -> [TocEntry] {
        let doc = try document(data, "nav")
        // `epub:type`은 이름공간 붙은 속성이라 local-name으로 찾는다.
        let navs = try doc.nodes(forXPath: "//*[local-name()='nav']")
        let tocNav = navs.first { node in
            guard let element = node as? XMLElement else { return false }
            return element.attributes?.contains {
                $0.localName == "type" && ($0.stringValue ?? "").contains("toc")
            } ?? false
        } ?? navs.first

        guard let list = try (tocNav as? XMLElement)?
            .nodes(forXPath: "./*[local-name()='ol']").first as? XMLElement
        else { return [] }
        return listEntries(list, base: base)
    }

    private static func listEntries(_ list: XMLElement, base: String) -> [TocEntry] {
        var result: [TocEntry] = []
        for case let item as XMLElement in (list.children ?? []) where item.localName == "li" {
            let anchor = (try? item.nodes(forXPath: "./*[local-name()='a']").first) as? XMLElement
            let title = (anchor?.stringValue ?? item.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = anchor?.attribute(forName: "href")?.stringValue ?? ""
            let nested = (try? item.nodes(forXPath: "./*[local-name()='ol']").first) as? XMLElement
            let children = nested.map { listEntries($0, base: base) } ?? []
            guard !title.isEmpty || !children.isEmpty else { continue }
            let (path, fragment) = split(raw, base: base)
            result.append(TocEntry(title: title, path: path, fragment: fragment,
                                   children: children))
        }
        return result
    }

    /// EPUB 2의 목차. `navMap` 안의 `navPoint`가 중첩된다.
    static func ncxEntries(_ data: Data, base: String) throws -> [TocEntry] {
        let doc = try document(data, "ncx")
        guard let map = try doc.nodes(forXPath: "//*[local-name()='navMap']").first as? XMLElement
        else { return [] }
        return navPoints(in: map, base: base)
    }

    private static func navPoints(in parent: XMLElement, base: String) -> [TocEntry] {
        var result: [TocEntry] = []
        for case let point as XMLElement in (parent.children ?? [])
        where point.localName == "navPoint" {
            let title = ((try? point.nodes(forXPath:
                "./*[local-name()='navLabel']/*[local-name()='text']"))?.first?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = ((try? point.nodes(forXPath: "./*[local-name()='content']/@src"))?
                .first?.stringValue) ?? ""
            let children = navPoints(in: point, base: base)
            guard !title.isEmpty || !children.isEmpty else { continue }
            let (path, fragment) = split(raw, base: base)
            result.append(TocEntry(title: title, path: path, fragment: fragment,
                                   children: children))
        }
        return result
    }

    // MARK: 경로

    private static func folder(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// `a.xhtml#절` 을 경로와 조각으로 가른다.
    private static func split(_ raw: String, base: String) -> (String, String?) {
        let decoded = decodePath(raw)
        guard let hash = decoded.firstIndex(of: "#") else {
            return (resolve(decoded, against: base), nil)
        }
        let path = String(decoded[decoded.startIndex ..< hash])
        let fragment = String(decoded[decoded.index(after: hash)...])
        return (resolve(path, against: base), fragment.isEmpty ? nil : fragment)
    }

    /// 퍼센트 인코딩을 푼다. EPUB의 경로는 URL 규칙을 따르므로 `그림%20하나.png`가 온다.
    private static func decodePath(_ raw: String) -> String {
        raw.removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 } ?? raw
    }

    /// 상대 경로를 ZIP 안의 전체 경로로. `..`도 접는다.
    static func resolve(_ href: String, against base: String) -> String {
        if href.hasPrefix("/") { return String(href.dropFirst()) }
        let combined = base.isEmpty ? href : base + "/" + href
        var stack: [String] = []
        for part in combined.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(part))
            }
        }
        return stack.joined(separator: "/")
    }
}
