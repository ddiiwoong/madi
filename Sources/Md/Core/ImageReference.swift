import Foundation

/// 마크다운의 그림 경로를 **로컬 파일**로 푼다.
///
/// 원격 주소는 일부러 풀지 않는다. 문서를 열었을 뿐인데 앱이 바깥으로 요청을 보내는
/// 것은 사용자가 시키지 않은 일이고, 문서에 적힌 주소가 추적용일 수도 있다. 원격
/// 그림은 `nil`이 되고 그 자리에는 원문이 그대로 남는다.
public enum ImageReference {

    /// 받아오지 않는 주소 체계.
    public static func isRemote(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("//") { return true }        // 체계 상대 주소
        for scheme in ["http:", "https:", "ftp:", "data:", "about:", "javascript:"]
        where value.hasPrefix(scheme) {
            return true
        }
        return false
    }

    /// 로컬 파일 주소. 풀 수 없으면 nil.
    ///
    /// - Parameters:
    ///   - raw: 마크다운에 적힌 경로. 퍼센트 인코딩(`my%20image.png`)을 푼다.
    ///   - documentURL: 문서 파일의 위치. 상대 경로의 기준이다. 저장하지 않은 문서는
    ///     기준이 없으므로 상대 경로를 풀 수 없다.
    public static func localURL(for raw: String, relativeTo documentURL: URL?) -> URL? {
        var path = raw.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !isRemote(path) else { return nil }

        // `<a.png>` 처럼 꺾쇠로 감싼 형태를 허용한다.
        if path.hasPrefix("<"), path.hasSuffix(">"), path.count > 2 {
            path = String(path.dropFirst().dropLast())
        }
        // 조각(`#`)과 질의(`?`)는 파일 경로에 뜻이 없다.
        if let hash = path.firstIndex(of: "#") { path = String(path[path.startIndex ..< hash]) }
        if let question = path.firstIndex(of: "?") { path = String(path[path.startIndex ..< question]) }
        guard !path.isEmpty else { return nil }

        if path.lowercased().hasPrefix("file:") {
            return URL(string: path)?.standardizedFileURL
        }

        // 퍼센트 인코딩을 푼다. 풀어서 비면 원래 글자를 쓴다.
        let decoded = path.removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 } ?? path

        if decoded.hasPrefix("~") {
            return URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath)
                .standardizedFileURL
        }
        if decoded.hasPrefix("/") {
            return URL(fileURLWithPath: decoded).standardizedFileURL
        }
        // 상대 경로는 문서가 있는 폴더를 기준으로 한다.
        guard let documentURL else { return nil }
        return URL(fileURLWithPath: decoded,
                   relativeTo: documentURL.deletingLastPathComponent()).standardizedFileURL
    }

    /// 보여 줄 크기. 폭이 넘치면 비율을 지키며 줄인다. 원래보다 **키우지는 않는다** —
    /// 작은 그림을 늘리면 뭉개진다.
    public static func displaySize(for pixels: CGSize, maxWidth: Double,
                                   maxHeight: Double = 420) -> CGSize {
        guard pixels.width > 0, pixels.height > 0, maxWidth > 0 else { return .zero }
        let widthScale = min(1, maxWidth / Double(pixels.width))
        let heightScale = min(1, maxHeight / Double(pixels.height))
        let scale = min(widthScale, heightScale)
        return CGSize(width: (Double(pixels.width) * scale).rounded(),
                      height: (Double(pixels.height) * scale).rounded())
    }
}
