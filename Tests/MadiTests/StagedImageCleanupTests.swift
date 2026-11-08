import Foundation
import XCTest

/// 오래된 임시 그림 치우기(사용자 — "오래된 임시 그림도 자동으로 지워 줘").
final class StagedImageCleanupTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func file(_ name: String, daysAgo: Double) -> StagedImageCleanup.StagedFile {
        StagedImageCleanup.StagedFile(url: URL(fileURLWithPath: "/staging/\(name)"), added: now - daysAgo * day)
    }

    /// 30일이 지났고 어느 글에도 이름이 없으면 치운다. 최근 것은 글이 없어도 남긴다.
    func testOnlyOldAndUnreferencedFilesExpire() {
        let files = [file("image-old.png", daysAgo: 45), file("image-new.png", daysAgo: 3),
                     file("image-used.png", daysAgo: 60)]
        let texts = ["# 글\n\n![image-used](/Users/someone/Library/Application%20Support/Madi/Pasted%20Images/image-used.png)\n"]
        XCTAssertEqual(StagedImageCleanup.expired(files, referencedIn: texts, now: now).map(\.lastPathComponent),
                       ["image-old.png"])
    }

    /// 이름은 경로에 적힌 꼴(퍼센트 인코딩 · 한글 자모가 나뉜 꼴)로도 찾는다.
    func testReferencesAreFoundInEncodedAndDecomposedForms() {
        let files = [file("photo 1 (2).jpeg", daysAgo: 40), file("사진.png", daysAgo: 40)]
        let texts = ["![a](/x/Pasted%20Images/photo%201%20%282%29.jpeg)", "![b](/x/" + "사진.png".decomposedStringWithCanonicalMapping + ")"]
        XCTAssertTrue(StagedImageCleanup.expired(files, referencedIn: texts, now: now).isEmpty)
    }

    /// 앱이 하는 일 그대로 — 폴더에 들어온 날로 재고, 자동 저장본 · 최근 문서 · 열린 문서의 글을 본다. 휴지통 넣기를 대역으로.
    func testJanitorReadsTheFoldersAndTrashesOnlyExpired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("madi-janitor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("Pasted Images", isDirectory: true)
        let autosave = root.appendingPathComponent("Autosave Information", isDirectory: true)
        for folder in [staging, autosave] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for name in ["a.png", "b.png", "c.png", "d.png"] {
            try Data([0x89]).write(to: staging.appendingPathComponent(name))
        }
        try "![b](\(staging.appendingPathComponent("b.png").path))".write(
            to: autosave.appendingPathComponent("저장하지 않은 문서.md"), atomically: true, encoding: .utf8)
        let recent = root.appendingPathComponent("최근.md")
        try "![c](../c.png)".write(to: recent, atomically: true, encoding: .utf8)

        var trashed: [String] = []
        // 지금 넣은 파일들이므로 '지금'을 31일 뒤로 둔다.
        let result = StagedImageJanitor.run(stagingFolder: staging, openTexts: ["![d](d.png)"], autosaveFolder: autosave,
                                            recentDocuments: [recent], now: Date() + 31 * day) {
            trashed.append($0.lastPathComponent)
        }
        XCTAssertEqual(trashed, ["a.png"], "b는 자동 저장본, c는 최근 문서, d는 열린 문서가 가리킨다")
        XCTAssertEqual(result.map(\.lastPathComponent), ["a.png"])

        var none: [String] = []
        StagedImageJanitor.run(stagingFolder: staging, openTexts: [], autosaveFolder: autosave, recentDocuments: [],
                               now: Date() + 2 * day) { none.append($0.lastPathComponent) }
        XCTAssertTrue(none.isEmpty, "30일이 안 됐으면 아무것도")
    }

    /// 파일의 고친 날이 오래되어도(끌어놓은 사진은 찍은 날을 지닌다) 폴더에 들어온 날이 오늘이면 남긴다.
    func testOldModificationDateDoesNotCount() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("madi-janitor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let photo = staging.appendingPathComponent("photo.jpeg")
        try Data([0xFF]).write(to: photo)
        try FileManager.default.setAttributes([.modificationDate: Date() - 400 * day], ofItemAtPath: photo.path)
        var trashed: [URL] = []
        StagedImageJanitor.run(stagingFolder: staging, openTexts: [], autosaveFolder: nil, recentDocuments: [],
                               now: Date() + day) { trashed.append($0) }
        XCTAssertTrue(trashed.isEmpty)
    }
}
