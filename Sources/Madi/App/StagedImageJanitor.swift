import Foundation

/// 오래된 임시 그림을 **휴지통으로** 옮긴다 — 고르는 규칙은 `StagedImageCleanup`. 앱이 켜질 때 한 번 돈다(`main.swift`).
///
/// 지우지 않고 휴지통에 넣는다: 규칙이 놓친 글(최근 목록에서 밀려난 오래된 문서)이 그 그림을 가리켜도 되살릴 수 있게.
enum StagedImageJanitor {

    /// 휴지통에 넣은 파일들. 파일을 읽으므로 메인 스레드 밖에서 부른다.
    ///
    /// - Parameters:
    ///   - openTexts: 지금 열린 문서의 글(메인 스레드에서 모아 넘긴다).
    ///   - autosaveFolder: 저장하지 않은 문서의 자동 저장본이 있는 폴더 — 그 안의 `.md`를 읽는다.
    ///   - recentDocuments: 최근 문서 — 크지 않은 것만 읽는다.
    @discardableResult
    static func run(stagingFolder: URL, openTexts: [String], autosaveFolder: URL?, recentDocuments: [URL],
                    now: Date = Date(), fileManager: FileManager = .default,
                    trash: (URL) throws -> Void) -> [URL] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .isRegularFileKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: stagingFolder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles]) else { return [] }
        let files = entries.compactMap { url -> StagedImageCleanup.StagedFile? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let added = values?.addedToDirectoryDate ?? values?.creationDate
            else { return nil }
            return StagedImageCleanup.StagedFile(url: url, added: added)
        }
        // 오래된 것이 없으면 글을 읽지도 않는다.
        guard files.contains(where: { now.timeIntervalSince($0.added) >= StagedImageCleanup.maxAge }) else { return [] }

        var texts = openTexts
        if let autosaveFolder,
           let saved = try? fileManager.contentsOfDirectory(at: autosaveFolder, includingPropertiesForKeys: nil) {
            texts += saved.filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }
                .compactMap(readSmall)
        }
        texts += recentDocuments.compactMap(readSmall)

        var trashed: [URL] = []
        for url in StagedImageCleanup.expired(files, referencedIn: texts, now: now) {
            do {
                try trash(url)
                trashed.append(url)
            } catch {
                continue
            }
        }
        return trashed
    }

    /// 8MB 아래의 글 파일만 읽는다 — 이름을 찾는 데 큰 파일을 통째로 들일 까닭이 없다.
    private static func readSmall(_ url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 8_000_000 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 앱에서 쓰는 휴지통 넣기.
    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
