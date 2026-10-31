import Foundation

/// ZIP 컨테이너를 읽는다. EPUB이 ZIP이므로 EPUB을 읽는 첫 조각이다.
///
/// **구조만 읽고 압축 해제는 받아서 쓴다.** 왜 그렇게 나눴는가: 압축 해제는 플랫폼마다
/// 다른 것을 쓴다(macOS는 `Compression` 프레임워크). 그것을 여기서 `import`하면 Core가
/// 그 플랫폼에 묶인다. `make core-only` 검사는 이것을 **잡지 못한다** — `Compression`은
/// macOS SDK에 있어 AppKit 없이도 컴파일되기 때문이다. 검사가 못 잡는 것은 설계로
/// 막아야 하므로, 압축 해제를 넘겨받는 함수로 둔다.
///
/// 지원하는 저장 방식은 0(무압축)과 8(DEFLATE)뿐이다. ZIP 규격에는 더 있지만 현실의
/// EPUB은 이 둘만 쓰고, 모르는 방식을 조용히 잘못 읽는 것보다 거절하는 쪽이 낫다.
public struct ZipArchive {

    public enum Method: Equatable, Sendable {
        case stored
        case deflate
        case unsupported(UInt16)

        init(_ raw: UInt16) {
            switch raw {
            case 0: self = .stored
            case 8: self = .deflate
            default: self = .unsupported(raw)
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let method: Method
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let crc32: UInt32
        /// 로컬 헤더의 자리. 자료가 어디서 시작하는지 알려면 이 헤더를 봐야 한다.
        let localHeaderOffset: Int

        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    public enum Failure: Error, Equatable {
        /// 끝에 중앙 디렉터리 표지가 없다. ZIP이 아니다.
        case notAZip
        /// 파일이 중간에서 끊겼다.
        case truncated(String)
        /// 4GB를 넘는 ZIP64. 읽지 않는다 — 잘못 읽는 것보다 거절하는 쪽이 낫다.
        case zip64Unsupported
        case badEntry(String)
        case unsupportedMethod(name: String, method: UInt16)
        case inflateFailed(String)
        /// 압축을 풀었는데 검사 합이 맞지 않는다. 파일이 상했다.
        case checksumMismatch(String)
    }

    public let entries: [Entry]
    private let bytes: Data

    // MARK: 읽기

    public init(data: Data) throws {
        self.bytes = data
        guard data.count >= 22 else { throw Failure.notAZip }

        let eocd = try Self.findEndOfCentralDirectory(in: data)
        let count = Int(Self.uint16(data, eocd + 10))
        let directorySize = Int(Self.uint32(data, eocd + 12))
        let directoryOffset = Int(Self.uint32(data, eocd + 16))

        // ZIP64는 이 자리에 0xFFFF/0xFFFFFFFF를 넣어 둔다.
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF,
              directoryOffset != 0xFFFF_FFFF else { throw Failure.zip64Unsupported }
        guard directoryOffset >= 0, directoryOffset + directorySize <= data.count else {
            throw Failure.truncated(String(localized: "중앙 디렉터리"))
        }

        var found: [Entry] = []
        var cursor = directoryOffset
        let directoryEnd = directoryOffset + directorySize

        while found.count < count, cursor + 46 <= directoryEnd {
            guard Self.uint32(data, cursor) == 0x0201_4B50 else {
                throw Failure.badEntry(String(localized: "중앙 디렉터리 표지가 어긋났습니다 (\(cursor))"))
            }
            let method = Self.uint16(data, cursor + 10)
            let crc = Self.uint32(data, cursor + 16)
            let compressed = Self.uint32(data, cursor + 20)
            let uncompressed = Self.uint32(data, cursor + 24)
            let nameLength = Int(Self.uint16(data, cursor + 28))
            let extraLength = Int(Self.uint16(data, cursor + 30))
            let commentLength = Int(Self.uint16(data, cursor + 32))
            let localOffset = Self.uint32(data, cursor + 42)

            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF,
                  localOffset != 0xFFFF_FFFF else { throw Failure.zip64Unsupported }
            let nameStart = cursor + 46
            guard nameStart + nameLength <= directoryEnd else {
                throw Failure.truncated(String(localized: "항목 이름"))
            }

            let nameBytes = data.subdata(in: nameStart ..< (nameStart + nameLength))
            // EPUB은 이름을 UTF-8로 쓴다. 아니면 되는 대로 읽는다(이름을 잃는 것보다 낫다).
            let name = String(data: nameBytes, encoding: .utf8)
                ?? String(decoding: nameBytes)

            found.append(Entry(name: name, method: Method(method),
                               compressedSize: Int(compressed),
                               uncompressedSize: Int(uncompressed),
                               crc32: crc, localHeaderOffset: Int(localOffset)))
            cursor = nameStart + nameLength + extraLength + commentLength
        }

        guard found.count == count else {
            throw Failure.badEntry(String(localized: "항목이 \(count)개라는데 \(found.count)개만 읽혔습니다"))
        }
        self.entries = found
    }

    public func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// 첫 항목. EPUB 검사에 쓴다 — 규격이 `mimetype`을 맨 앞에 **무압축으로** 두라고 한다.
    public var firstEntry: Entry? { entries.first }

    // MARK: 자료 꺼내기

    /// 항목의 내용. `inflate`는 DEFLATE 자료와 풀린 크기를 받아 풀어 준다.
    ///
    /// 압축 해제를 받아서 쓰는 이유는 위 설명에 있다. 무압축 항목은 `inflate`를
    /// 부르지 않으므로, 구조만 확인할 때는 아무 함수나 넘겨도 된다.
    public func contents(of entry: Entry,
                         inflate: (Data, Int) throws -> Data) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count else { throw Failure.truncated(entry.name) }
        guard Self.uint32(bytes, header) == 0x0403_4B50 else {
            throw Failure.badEntry(String(localized: "로컬 헤더 표지가 어긋났습니다: \(entry.name)"))
        }
        let nameLength = Int(Self.uint16(bytes, header + 26))
        let extraLength = Int(Self.uint16(bytes, header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= bytes.count else {
            throw Failure.truncated(entry.name)
        }
        let raw = bytes.subdata(in: start ..< (start + entry.compressedSize))

        let result: Data
        switch entry.method {
        case .stored:
            result = raw
        case .deflate:
            do {
                result = try inflate(raw, entry.uncompressedSize)
            } catch {
                throw Failure.inflateFailed(entry.name)
            }
        case let .unsupported(method):
            throw Failure.unsupportedMethod(name: entry.name, method: method)
        }

        guard result.count == entry.uncompressedSize else {
            throw Failure.inflateFailed(entry.name)
        }
        // 검사 합을 본다. 상한 파일을 조용히 읽어 넘기면 그 뒤가 전부 틀어진다.
        // 빈 파일은 CRC가 0이고 내용도 비어 있어 그대로 맞는다 — 빠져나갈 구멍을
        // 따로 두지 않는다(구멍을 두면 검사가 느슨해진다).
        guard CRC32.checksum(result) == entry.crc32 else {
            throw Failure.checksumMismatch(entry.name)
        }
        return result
    }

    public func contents(named name: String,
                         inflate: (Data, Int) throws -> Data) throws -> Data? {
        guard let entry = entry(named: name) else { return nil }
        return try contents(of: entry, inflate: inflate)
    }

    // MARK: 바이트 읽기

    /// 끝에서 거꾸로 중앙 디렉터리 표지를 찾는다.
    ///
    /// 왜 거꾸로인가: 표지 뒤에 최대 65,535바이트의 주석이 붙을 수 있어 자리가 고정이
    /// 아니다. 그리고 앞에서 찾으면 압축된 자료 안의 같은 바이트열에 걸린다.
    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        let signature: UInt32 = 0x0605_4B50
        let maximumComment = 65_535
        let lowest = max(0, data.count - 22 - maximumComment)
        var index = data.count - 22
        while index >= lowest {
            if uint32(data, index) == signature {
                // 주석 길이가 실제 남은 바이트와 맞아야 진짜 표지다.
                let commentLength = Int(uint16(data, index + 20))
                if index + 22 + commentLength == data.count { return index }
            }
            index -= 1
        }
        throw Failure.notAZip
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}

private extension String {
    /// UTF-8이 아닌 이름을 되는 대로 읽는다.
    init(decoding bytes: Data) {
        self = String(decoding: bytes, as: UTF8.self)
    }
}

/// ZIP이 쓰는 CRC-32. 압축을 푼 결과가 상하지 않았는지 본다.
///
/// 직접 쓴 이유: zlib의 `crc32`를 쓰면 Core가 그 라이브러리에 묶인다. 표를 한 번
/// 만들어 쓰는 20줄짜리라 가져올 이유가 없다.
public enum CRC32 {

    private static let table: [UInt32] = {
        (0 ..< 256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
