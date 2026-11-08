import Foundation

/// 시험 번들의 첫 코드 — 번들의 Info.plist `NSPrincipalClass`(project.yml의 `INFOPLIST_KEY_NSPrincipalClass`)라 어느
/// 시험보다 먼저 만들어진다. 시험 과정 전체에 걸친 것만 여기 둔다.
///
/// - 문서 자동 저장을 끈다(`MarkdownDocument.autosavingEnabled`). 켜 두면 시험이 고친 이름 없는 문서가 사용자의
///   `~/Library/Autosave Information`에 `저장하지 않은 xctest 문서 N.md`로 쌓인다.
@objc(MadiTestsSetup)
final class MadiTestsSetup: NSObject {
    override init() {
        super.init()
        MainActor.assumeIsolated { MarkdownDocument.autosavingEnabled = false }
    }
}
