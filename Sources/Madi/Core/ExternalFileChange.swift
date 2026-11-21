import Foundation

/// 바깥(다른 앱, 로그를 쓰는 프로그램, `git pull`)에서 바뀐 파일을 어떻게 들일지 정한다 — 화면과 파일 감시 없이, 바이트와 글만으로.
///
/// 왜(사용자 — "로그 같이 실시간으로 변하는 것에 대한 리로드 전략", 고른 감시: `DispatchSource`): 전에는 열어 둔 파일이 바깥에서
/// 바뀌어도 다시 읽지 않았다(확인용 사본에서 셸로 한 줄 덧붙이고 7초를 기다려도, 다른 앱에 갔다 와도 그대로였다). 로그는 대개 끝에
/// 붙기만 하므로 **붙은 바이트만** 읽어 끝에 붙이고, 그 밖의 변경(줄어듦 · 가운데가 바뀜 · 통째로 바꿔 넣음)은 통째로 읽어 **다른
/// 가운데만** 갈아 끼운다. 그래야 문서 전체를 다시 칠하지 않고(22만 자에서 한 번에 0.17초), 캐럿 · 고른 것 · 읽던 자리가 남는다.

/// 디스크의 파일을 마지막으로 맞춰 본 모습 — 읽거나 쓴 바이트의 길이, 끝 조각, 전체의 지문, 수정 시각.
///
/// 앞부분이 그대로인지는 **끝 조각**(마지막 4KB)으로 본다 — `tail -f`도 앞을 다시 보지 않는다. 끝 조각이 같고 파일이 길어졌으면
/// 붙은 것이다. 지문은 같은 길이로 바뀐 것(바꿔 쓰기)과 수정 시각만 바뀐 것(`touch`)을 가른다.
public struct DiskBaseline: Equatable, Sendable {
    public static let tailSize = 4096

    /// 들인 바이트 수. 끝에 덜 쓴 UTF-8 글자가 있으면 그 앞까지다 — 나머지는 다음에 다시 읽는다.
    public let length: Int
    public let tail: Data
    /// 들인 바이트 전체의 FNV-1a 64. 이어서 셀 수 있어 붙은 바이트만으로 갱신된다. 보안용이 아니다 — 바뀌었는지만 본다.
    public let fingerprint: UInt64
    public let modificationDate: Date?

    public init(data: Data, modificationDate: Date?) {
        self.init(length: data.count, tail: Data(data.suffix(Self.tailSize)),
                  fingerprint: ExternalFileChange.fnv1a(data), modificationDate: modificationDate)
    }

    init(length: Int, tail: Data, fingerprint: UInt64, modificationDate: Date?) {
        self.length = length
        self.tail = tail
        self.fingerprint = fingerprint
        self.modificationDate = modificationDate
    }

    /// 끝에 `bytes`가 붙은 모습.
    public func appending(_ bytes: Data, modificationDate: Date?) -> DiskBaseline {
        DiskBaseline(length: length + bytes.count, tail: Data((tail + bytes).suffix(Self.tailSize)),
                     fingerprint: ExternalFileChange.fnv1a(bytes, seed: fingerprint), modificationDate: modificationDate)
    }

    func with(modificationDate: Date?) -> DiskBaseline {
        DiskBaseline(length: length, tail: tail, fingerprint: fingerprint, modificationDate: modificationDate)
    }
}

/// 디스크에서 본 것.
public enum DiskChange: Equatable, Sendable {
    /// 그대로다(수정 시각만 바뀌었거나, 끝에 덜 쓴 글자 하나뿐). 새 기준을 쓴다.
    case unchanged(DiskBaseline)
    /// 끝에 `text`가 붙었다 — 앞부분은 그대로다.
    case appended(text: String, baseline: DiskBaseline)
    /// 그 밖의 변경. `data`가 지금 파일 전체다.
    case replaced(data: Data, baseline: DiskBaseline)
}

public enum ExternalFileChange {

    /// 지금 파일이 기준과 어떻게 다른가. `read`는 파일의 바이트 구간을 읽는다(파일이 그사이 줄었으면 덜 돌려줘도 된다).
    ///
    /// - Parameter appendsAsUTF8: 붙은 바이트를 UTF-8로 읽어도 되는가. 문서를 UTF-16 · Latin-1로 읽었으면 false — 그때는 늘
    ///   통째로 읽는다(UTF-16의 `a`는 `61 00`이라 UTF-8로도 읽혀 버린다).
    public static func detect(baseline: DiskBaseline, size: Int, modificationDate: Date?, appendsAsUTF8: Bool = true,
                              read: (Range<Int>) throws -> Data) rethrows -> DiskChange {
        if size == baseline.length, let modificationDate, modificationDate == baseline.modificationDate {
            return .unchanged(baseline)
        }
        if appendsAsUTF8, size > baseline.length {
            let tailStart = baseline.length - baseline.tail.count
            if try read(tailStart ..< baseline.length) == baseline.tail {
                let added = try read(baseline.length ..< size)
                let complete = completeUTF8Prefix(of: added)
                // 덜 쓴 글자 하나뿐(또는 그사이 줄어 읽은 것이 없다) — 기준을 옮기지 않으면 다음에 그 바이트부터 다시 읽는다.
                if complete == 0 { return .unchanged(baseline) }
                let bytes = Data(added.prefix(complete))
                if let text = String(data: bytes, encoding: .utf8) {
                    return .appended(text: text, baseline: baseline.appending(bytes, modificationDate: modificationDate))
                }
                // 올바른 UTF-8이 아니다 — 통째로 읽어 문서를 읽는 규칙(UTF-8 · UTF-16 · Latin-1)에 맡긴다.
            }
        }
        let data = try read(0 ..< size)
        let fresh = DiskBaseline(data: data, modificationDate: modificationDate)
        if fresh.length == baseline.length, fresh.fingerprint == baseline.fingerprint { return .unchanged(fresh) }
        return .replaced(data: data, baseline: fresh)
    }

    /// 끝에 걸린 덜 쓴 UTF-8 글자를 뗀 길이 — 쓰는 쪽이 한 글자를 두 번에 나눠 쓴 사이에 읽을 수 있다(한글은 3바이트).
    public static func completeUTF8Prefix(of data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        guard !bytes.isEmpty else { return 0 }
        var index = bytes.count - 1
        var continuation = 0
        while index >= 0, continuation < 3, bytes[index] & 0xC0 == 0x80 {
            index -= 1
            continuation += 1
        }
        // 이어지는 바이트뿐 — 올바른 UTF-8이 아니다. 자르지 않고 해독기에 맡긴다.
        guard index >= 0 else { return data.count }
        let lead = bytes[index]
        let needed = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        let have = bytes.count - index
        return have < needed ? data.count - have : data.count
    }

    public static let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    public static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    /// FNV-1a 64. `seed`에 앞의 지문을 주면 이어서 센다.
    public static func fnv1a(_ data: Data, seed: UInt64 = fnvOffsetBasis) -> UInt64 {
        var hash = seed
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                hash ^= UInt64(byte)
                hash = hash &* fnvPrime
            }
        }
        return hash
    }
}

/// 옛 글을 새 글로 만드는 가장 작은 갈아 끼우기 — 앞뒤가 같은 부분은 두고 다른 가운데만. 자리는 UTF-16이다(텍스트 뷰와 같다).
public struct TextSplice: Equatable, Sendable {
    /// 옛 글에서 갈아 끼울 곳.
    public let range: NSRange
    public let replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    /// 두 글 사이의 갈아 끼우기. 같으면 nil. 짝을 이룬 UTF-16(이모지 같은 글자)을 가운데서 자르지 않는다.
    public static func between(_ old: String, _ new: String) -> TextSplice? {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        guard a != b else { return nil }
        let shorter = min(a.count, b.count)
        var prefix = 0
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let replacement = String(decoding: b[prefix ..< (b.count - suffix)], as: UTF16.self)
        return TextSplice(range: NSRange(location: prefix, length: a.count - prefix - suffix), replacement: replacement)
    }

    /// 옛 글의 선택을 갈아 끼운 뒤의 자리로. 갈아 끼운 곳 앞은 그대로, 뒤는 길이 차만큼 옮기고, 안쪽은 갈아 끼운 곳의 처음으로.
    public func adjusted(_ selection: NSRange) -> NSRange {
        let delta = (replacement as NSString).length - range.length
        let end = NSMaxRange(range)
        func move(_ index: Int) -> Int {
            if index <= range.location { return index }
            if index >= end { return index + delta }
            return range.location
        }
        let start = move(selection.location)
        let stop = max(start, move(NSMaxRange(selection)))
        return NSRange(location: start, length: stop - start)
    }

    /// 글 끝에 붙이기인가(`length`는 옛 글의 길이).
    public func isAppend(toLength length: Int) -> Bool {
        range.location == length && range.length == 0
    }
}
