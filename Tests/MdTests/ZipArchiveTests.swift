import Compression
import XCTest
// Core sources are compiled into this bundle directly; no module import needed.

/// 실제 `/usr/bin/zip`이 만든 파일로 시험한다. 손으로 만든 바이트로 시험하면
/// "내가 쓴 것을 내가 읽는다"가 되어, 표준 도구가 쓴 것을 읽는다는 증거가 되지 않는다.
final class ZipArchiveTests: XCTestCase {

    private var folder: URL!

    /// 테스트가 쓰는 압축 해제. Core는 이것을 **받아서** 쓴다(플랫폼에 묶이지 않도록).
    private func inflate(_ data: Data, _ size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written: Int = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw CocoaError(.fileReadCorruptFile) }
        return output
    }

    /// 로컬 헤더를 직접 읽어 **자료가 실제로 시작하는 자리**를 구한다.
    ///
    /// 처음에는 `헤더 + 30 + 이름길이`로 어림했는데, 로컬 헤더에는 extra 필드가
    /// 더 붙어서 그 자리는 아직 헤더 안이었다. 그래서 바이트를 뒤집어도 자료가
    /// 멀쩡했고 검사 합이 걸리지 않아 **테스트가 거짓으로 통과**했다.
    private func dataStart(of entry: ZipArchive.Entry, in data: Data) -> Int {
        func uint16(_ offset: Int) -> Int {
            Int(data[data.startIndex + offset]) | (Int(data[data.startIndex + offset + 1]) << 8)
        }
        let header = entry.localHeaderOffset
        return header + 30 + uint16(header + 26) + uint16(header + 28)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        try super.tearDownWithError()
    }

    /// `zip`을 돌려 파일을 만든다. 없으면 테스트를 건너뛴다.
    private func makeZip(_ arguments: [String], files: [String: String]) throws -> Data {
        for (name, contents) in files {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else {
            throw XCTSkip("/usr/bin/zip이 없습니다")
        }
        let output = folder.appendingPathComponent("out.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder
        process.arguments = ["-q"] + arguments + ["out.zip"] + files.keys.sorted()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("zip이 \(process.terminationStatus)로 끝났습니다")
        }
        return try Data(contentsOf: output)
    }

    // MARK: 표준 도구가 쓴 것을 읽는다

    func testReadsADeflatedArchive() throws {
        // 긴 글이어야 실제로 압축된다(짧은 글은 zip이 그냥 저장한다).
        let body = String(repeating: "압축될 만큼 긴 한국어 본문입니다. ", count: 200)
        let data = try makeZip([], files: ["글.txt": body, "메모.txt": "짧은 메모"])
        let archive = try ZipArchive(data: data)

        XCTAssertEqual(archive.entries.count, 2)
        XCTAssertEqual(Set(archive.entries.map(\.name)), ["글.txt", "메모.txt"])

        let read = try archive.contents(named: "글.txt", inflate: inflate)
        XCTAssertEqual(String(data: read!, encoding: .utf8), body)
    }

    func testReadsAStoredArchiveWithoutInflating() throws {
        let data = try makeZip(["-0"], files: ["a.txt": "저장만 된 내용"])
        let archive = try ZipArchive(data: data)
        XCTAssertEqual(archive.entries.first?.method, .stored)

        // 무압축 항목은 압축 해제를 부르지 않아야 한다.
        var called = false
        let read = try archive.contents(named: "a.txt") { _, _ in
            called = true
            return Data()
        }
        XCTAssertFalse(called, "무압축인데 압축 해제를 불렀다")
        XCTAssertEqual(String(data: read!, encoding: .utf8), "저장만 된 내용")
    }

    func testKoreanFileNamesSurvive() throws {
        let data = try makeZip([], files: ["그림/한국어 이름.txt": "내용"])
        let archive = try ZipArchive(data: data)
        XCTAssertTrue(archive.entries.contains { $0.name == "그림/한국어 이름.txt" },
                      "이름: \(archive.entries.map(\.name))")
    }

    func testArchiveCommentDoesNotHideTheDirectory() throws {
        // 중앙 디렉터리 표지 뒤에 주석이 붙을 수 있어 자리가 고정이 아니다.
        var data = try makeZip([], files: ["a.txt": "내용"])
        // zip -z는 입력을 받으므로, 주석을 직접 붙여 같은 상황을 만든다.
        let comment = Data("주석입니다".utf8)
        let lengthOffset = data.count - 2
        data[lengthOffset] = UInt8(comment.count & 0xFF)
        data[lengthOffset + 1] = UInt8((comment.count >> 8) & 0xFF)
        data.append(comment)

        let archive = try ZipArchive(data: data)
        XCTAssertEqual(archive.entries.count, 1)
    }

    func testEpubShapedArchiveHasMimetypeFirstAndStored() throws {
        // EPUB 규격은 `mimetype`을 맨 앞에 무압축으로 두라고 한다. 그것으로 빠르게 가린다.
        let data = try makeZip(["-0", "-X"], files: ["mimetype": "application/epub+zip"])
        let archive = try ZipArchive(data: data)
        XCTAssertEqual(archive.firstEntry?.name, "mimetype")
        XCTAssertEqual(archive.firstEntry?.method, .stored)
        let read = try archive.contents(named: "mimetype", inflate: inflate)
        XCTAssertEqual(String(data: read!, encoding: .utf8), "application/epub+zip")
    }

    // MARK: 거절해야 하는 것

    func testNonZipDataIsRefused() {
        XCTAssertThrowsError(try ZipArchive(data: Data("ZIP이 아닙니다".utf8))) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .notAZip)
        }
        XCTAssertThrowsError(try ZipArchive(data: Data())) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .notAZip)
        }
    }

    func testTruncatedArchiveIsRefusedNotMisread() throws {
        let data = try makeZip([], files: ["a.txt": "내용"])
        // 끝을 잘라 내면 중앙 디렉터리 표지가 사라진다.
        let cut = data.prefix(data.count / 2)
        XCTAssertThrowsError(try ZipArchive(data: Data(cut)))
    }

    func testCorruptedContentIsCaughtByTheChecksum() throws {
        let body = String(repeating: "검사 합을 시험할 긴 본문입니다. ", count: 200)
        var data = try makeZip([], files: ["글.txt": body])
        let archive = try ZipArchive(data: data)
        guard let entry = archive.entry(named: "글.txt") else { return XCTFail("항목 없음") }

        // 압축된 자료 가운데 한 바이트를 뒤집는다.
        let middle = dataStart(of: entry, in: data) + entry.compressedSize / 2
        guard middle < data.count else { throw XCTSkip("자료가 너무 짧습니다") }
        data[middle] ^= 0xFF

        let broken = try ZipArchive(data: data)
        // 압축 해제가 실패하거나, 풀렸더라도 검사 합이 걸러야 한다.
        XCTAssertThrowsError(try broken.contents(named: "글.txt", inflate: inflate),
                             "상한 자료가 그대로 읽혔다")
    }

    // MARK: CRC-32

    func testCrc32MatchesTheStandardCheckValue() {
        // 규격이 정한 확인값이다. 직접 쓴 구현이 맞는지 이것으로 못박는다.
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testCrc32OfEmptyDataIsZero() {
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testCrc32ChangesWithContent() {
        XCTAssertNotEqual(CRC32.checksum(Data("가".utf8)), CRC32.checksum(Data("나".utf8)))
    }

    func testStoredEntryChecksumIsAlsoVerified() throws {
        var data = try makeZip(["-0"], files: ["a.txt": "무압축 내용입니다"])
        let archive = try ZipArchive(data: data)
        guard let entry = archive.entry(named: "a.txt") else { return XCTFail("항목 없음") }
        let start = dataStart(of: entry, in: data)
        guard start < data.count else { throw XCTSkip("자료가 짧습니다") }
        data[start] ^= 0xFF

        let broken = try ZipArchive(data: data)
        XCTAssertThrowsError(try broken.contents(named: "a.txt", inflate: inflate)) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .checksumMismatch("a.txt"))
        }
    }

    // MARK: 없는 항목

    func testMissingEntryIsNilNotAnError() throws {
        let data = try makeZip([], files: ["a.txt": "내용"])
        let archive = try ZipArchive(data: data)
        XCTAssertNil(archive.entry(named: "없음.txt"))
        XCTAssertNil(try archive.contents(named: "없음.txt", inflate: inflate))
    }
}
