import Foundation
import Security

/// 비밀(API 키)을 두는 곳. 앱은 키체인, 테스트는 메모리를 쓴다.
@MainActor
protocol SecretStore: AnyObject {
    /// 저장된 값. **키체인에서 값을 꺼내므로** 꼭 필요할 때만 부른다(아래 `hasSecret`).
    func secret(for account: String) -> String?
    /// 저장돼 있는가 — 값을 꺼내지 않고 속성만 묻는다.
    func hasSecret(for account: String) -> Bool
    func setSecret(_ value: String, for account: String, label: String) throws
    func removeSecret(for account: String)
}

/// 로그인 키체인의 일반 암호 항목(`kSecClassGenericPassword`).
///
/// **왜 키체인인가**(소곤과 같은 판단): `UserDefaults`에 두면 `~/Library/Preferences`의 plist에
/// **평문**으로 남고, 같은 사용자로 도는 아무 프로세스나 읽는다. 만료 없는 자격증명을 그렇게 두지 않는다.
///
/// **왜 값을 꺼내지 않고 있는지만 묻는가**: 마디는 지금 ad-hoc 서명이라 **빌드할 때마다 서명이 바뀌고**,
/// 키체인은 항목을 만든 앱의 서명을 기억한다. 다른 서명으로 값을 꺼내면 macOS가 "키체인의 정보를
/// 쓰려고 합니다" 창을 띄운다. 속성만 묻는 것은 그 창을 띄우지 않는다 — 설정 화면은 있는지만 보이고,
/// 값은 키 확인을 누를 때만 꺼낸다. (Developer ID로 서명하면 서명이 고정되어 이 창이 사라진다.)
///
/// 접근성은 `kSecAttrAccessibleWhenUnlocked` — 사용자가 로그인해 화면을 쓰는 동안만 필요하다.
final class KeychainSecretStore: SecretStore {

    /// 앱이 쓰는 저장소. 항목의 service 이름은 번들 식별자 + `.llm-keys`다.
    static let app = KeychainSecretStore(service: (Bundle.main.bundleIdentifier ?? "dev.jinwoong.md") + ".llm-keys")

    let service: String

    init(service: String) {
        self.service = service
    }

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return String(localized: "키체인에 저장하지 못했습니다: \(text)")
        }
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func secret(for account: String) -> String? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasSecret(for account: String) -> Bool {
        var lookup = query(account)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess
    }

    func setSecret(_ value: String, for account: String, label: String) throws {
        let data = Data(value.utf8)
        // 있으면 고치고 없으면 더한다.
        let updated = SecItemUpdate(query(account) as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure(status: updated) }
        var insert = query(account)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        // 키체인 접근(앱)에서 무엇인지 알아볼 수 있게 이름을 단다.
        insert[kSecAttrLabel as String] = label
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    func removeSecret(for account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// 테스트용. 키체인에 닿지 않는다.
final class MemorySecretStore: SecretStore {
    private(set) var values: [String: String] = [:]
    /// 값을 꺼낸 횟수 — 설정 화면이 값을 함부로 꺼내지 않는지 테스트가 본다.
    private(set) var reads = 0

    func secret(for account: String) -> String? {
        reads += 1
        return values[account]
    }

    func hasSecret(for account: String) -> Bool { values[account] != nil }

    func setSecret(_ value: String, for account: String, label: String) throws {
        values[account] = value
    }

    func removeSecret(for account: String) { values[account] = nil }
}
