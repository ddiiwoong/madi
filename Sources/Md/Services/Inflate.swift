import Compression
import Foundation

/// DEFLATE 압축 해제. **Core 밖에 둔다.**
///
/// `Compression`은 Apple 플랫폼의 프레임워크다. Core 안에서 `import`하면 Core가 그
/// 플랫폼에 묶이는데, `make core-only` 검사는 그것을 잡지 못한다 — macOS SDK에 있어
/// AppKit 없이도 컴파일되기 때문이다. 검사가 못 잡는 것은 설계로 막는다.
///
/// `ZipArchive`는 이 함수를 **받아서** 쓴다. 다른 플랫폼에서는 같은 모양의 다른 구현을
/// 넘기면 된다.
enum Inflate {

    enum Failure: Error {
        case failed
    }

    /// raw DEFLATE를 푼다. ZIP은 zlib 머리글 없는 raw 흐름을 담는다.
    ///
    /// `expectedSize`를 받는 이유: `Compression`의 버퍼 API는 결과를 담을 자리를
    /// 미리 알아야 한다. ZIP의 중앙 디렉터리가 풀린 크기를 들고 있으므로 그것을 쓴다.
    static func raw(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        guard !data.isEmpty else { throw Failure.failed }

        var output = Data(count: expectedSize)
        let written: Int = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw Failure.failed }
        return output
    }
}
