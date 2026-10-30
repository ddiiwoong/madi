import Foundation

/// 번역한 조각을 기억한다 — 같은 방향의 같은 글은 번역기에 다시 보내지 않는다.
///
/// 왜: 한 줄을 고치고 다시 번역하면(나란히 보기의 `다시 번역`, ⌘⇧T를 또 누르기) 전에는
/// 문서 전체를 다시 보냈다. 5,966자가 23~54초였다. 번역 단위는 블록 하나(문단·제목·목록
/// 항목·표의 행)이고 자리표 번호도 단위 안에서 매기므로, 고치지 않은 블록은 글이 그대로라
/// 여기서 꺼내 쓴다.
///
/// 열쇠는 **방향과 글 그대로**다. 해시만 열쇠로 쓰면 드물게 부딪힌 두 글이 서로의 번역을
/// 받는다 — 문서가 틀리게 번역되는 것은 느린 것보다 나쁘다.
///
/// **메모리에만 둔다.** 디스크에 쓰면 사용자의 문서와 번역이 앱 밖에 남는다. 앱을 끄면
/// 사라지므로 언어 팩이 바뀐 뒤에도 옛 번역이 섞일 걱정은 한 번의 실행 안으로 줄어든다.
/// 크기는 글자 수로 묶고, 넘으면 **먼저 넣은 것부터** 버린다.
public final class TranslationCache: @unchecked Sendable {

    /// 앱 전체가 함께 쓴다. 창마다 두면 다른 창에서 같은 문서를 번역해도 다시 보낸다.
    public static let shared = TranslationCache()

    struct Key: Hashable {
        let source: String
        let target: String
        let text: String
    }

    /// 원문과 번역문을 합친 UTF-16 글자 수의 한도. 기본 200만 자(약 4MB).
    public let characterBudget: Int

    private let lock = NSLock()
    private var entries: [Key: String] = [:]
    /// 넣은 순서. 버릴 때 앞에서부터 본다. `head` 앞은 이미 버린 자리다.
    private var order: [Key] = []
    private var head = 0
    private var characters = 0

    public init(characterBudget: Int = 2_000_000) {
        self.characterBudget = characterBudget
    }

    public func translation(of text: String, from source: String, to target: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Key(source: source, target: target, text: text)]
    }

    /// 번역문을 넣는다. 비어 있지 않은 글의 번역이 비었으면 넣지 않는다 — 번역기의 실패를
    /// 기억해 두면 다음 번역도 같은 빈 자리를 받는다.
    public func store(_ translation: String, of text: String, from source: String, to target: String) {
        let blankSource = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let blankResult = translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard blankSource || !blankResult else { return }
        let size = text.utf16.count + translation.utf16.count
        guard size <= characterBudget else { return }

        lock.lock()
        defer { lock.unlock() }
        let key = Key(source: source, target: target, text: text)
        if let old = entries[key] {
            characters -= text.utf16.count + old.utf16.count
        } else {
            order.append(key)
        }
        entries[key] = translation
        characters += size
        evictIfNeeded()
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries = [:]
        order = []
        head = 0
        characters = 0
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// 한도를 넘으면 오래된 것부터 버린다. 잠금 안에서 부른다.
    private func evictIfNeeded() {
        while characters > characterBudget, head < order.count {
            let key = order[head]
            head += 1
            if let value = entries.removeValue(forKey: key) {
                characters -= key.text.utf16.count + value.utf16.count
            }
        }
        // 버린 자리가 쌓이면 한 번에 걷어 낸다 — 앞에서 하나씩 지우면 매번 배열 전체가 밀린다.
        if head > 1024, head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
    }
}
