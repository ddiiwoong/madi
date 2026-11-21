import Foundation

/// 시험 번들의 첫 코드 — 번들의 Info.plist `NSPrincipalClass`(project.yml의 `INFOPLIST_KEY_NSPrincipalClass`)라 어느
/// 시험보다 먼저 만들어진다. 시험 과정 전체에 걸친 것만 여기 둔다.
///
/// - 문서 자동 저장을 끈다(`MarkdownDocument.autosavingEnabled`). 켜 두면 시험이 고친 이름 없는 문서가 사용자의
///   `~/Library/Autosave Information`에 `저장하지 않은 xctest 문서 N.md`로 쌓인다.
/// - 파일 감시를 끈다(`MarkdownDocument.watchesFiles`). 켜 두면 시험이 연 문서마다 감시가 남아, 지운 임시 폴더를 1초마다 다시
///   열어 보고 다른 시험이 그 파일을 고치면 들인다. 감시를 보는 시험(`ExternalChangeTests`)만 켠다.
@objc(MadiTestsSetup)
final class MadiTestsSetup: NSObject {
    override init() {
        super.init()
        MainActor.assumeIsolated {
            MarkdownDocument.autosavingEnabled = false
            MarkdownDocument.watchesFiles = false
        }
    }
}
