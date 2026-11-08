import Foundation

/// 저장하지 않은 문서에 붙여 넣어 잠시 둔 그림(`Pasted Images`) 가운데 **치울 것**을 고른다(사용자 — "오래된 임시 그림도
/// 자동으로 지워 줘"). 순수 계산이다 — 파일을 읽고 휴지통에 넣는 일은 `StagedImageJanitor`가 한다.
///
/// 치우는 그림: 폴더에 들어온 지 `maxAge`가 지났고, **어느 글에도 이름이 나오지 않는** 것. 글은 열린 문서, 저장하지 않은
/// 문서의 자동 저장본(다음에 켜면 되살아난다), 최근 문서다. 이름(`image-20261108-225639.png`)은 붙여 넣은 시각으로
/// 지어 겹치지 않으므로 이름이 나오면 그 글이 가리킨다고 본다 — 아니어도 남길 뿐이다(덜 치우는 쪽으로 틀린다).
///
/// 날짜는 **폴더에 들어온 날**이다. 파일의 고친 날은 쓰지 않는다 — 끌어놓은 파일은 원래 날짜를 지닌 채 복사되어
/// 오늘 붙인 그림이 일주일 전 것으로 보였다(실측: 11월 1일에 찍은 사진을 11월 8일에 붙였다).
public enum StagedImageCleanup {

    /// 이만큼 지난 것만 치운다.
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    public struct StagedFile: Equatable, Sendable {
        public let url: URL
        /// 폴더에 들어온 날.
        public let added: Date

        public init(url: URL, added: Date) {
            self.url = url
            self.added = added
        }
    }

    /// 치울 파일들.
    public static func expired(_ files: [StagedFile], referencedIn texts: [String], now: Date,
                               maxAge: TimeInterval = maxAge) -> [URL] {
        let old = files.filter { now.timeIntervalSince($0.added) >= maxAge }
        guard !old.isEmpty else { return [] }
        return old.filter { file in
            let name = file.url.lastPathComponent
            let forms = Set([name, ImageAttachment.encodedPath(name),
                             name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name,
                             name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping])
            return !texts.contains { text in forms.contains { text.contains($0) } }
        }.map(\.url)
    }
}
