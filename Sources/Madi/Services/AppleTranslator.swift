import Foundation
import Translation

/// Apple Translation으로 이 Mac 안에서 번역한다(macOS 26 이상). 네트워크를 쓰지 않는다.
///
/// 구조는 Sogon의 `AppleTranslationService`를 따른다 — 설치된 언어로만 세션을 만들고,
/// 팩이 없으면 `languagePackMissing`을 던진다. **언어 팩을 여기서 받지 않는다**: 받기는
/// 사용자 동의 창이 필요하고 그 창은 SwiftUI `.translationTask`가 붙은 화면 위에만 뜬다.
/// 마디에는 그 화면이 없으므로 안내만 하고, 사용자가 시스템 설정에서 받는다.
///
/// Sogon과 다른 점은 **무엇을 넘기는가**다. Sogon은 받아쓴 말을 통째로 넘기지만 여기서는
/// `MarkdownTranslationPlan`이 가른 본문 조각만 넘긴다 — 마크업을 넘기면 구조가 깨진다.
@available(macOS 26.0, *)
enum AppleTranslator {

    enum Failure: LocalizedError, Equatable {
        case languagePackMissing(direction: TranslationDirection)
        case unsupported(direction: TranslationDirection)
        /// 번역할 글이 없다. 오류로 두는 이유: 조용히 성공을 보고하면 사용자가 같은
        /// 글이 새 창으로 열린 것을 "번역이 됐다"로 읽는다.
        case nothingToTranslate
        case other(String)

        var isLanguagePackMissing: Bool {
            if case .languagePackMissing = self { return true }
            return false
        }

        /// 설정 화면을 열어 줄 만한 실패인가. 팩이 없는 경우뿐 아니라 **지원되지 않는
        /// 경우도** 그 화면에서 무엇을 받을 수 있는지 볼 수 있다.
        var suggestsLanguageSettings: Bool {
            switch self {
            case .languagePackMissing, .unsupported: return true
            case .nothingToTranslate, .other: return false
            }
        }

        /// 무엇이 잘못됐는가. **한 문장**으로 둔다 — 무엇을 해야 하는지는
        /// `recoverySuggestion`이 말한다(경고창이 둘을 다른 크기로 그린다).
        var errorDescription: String? {
            switch self {
            case let .languagePackMissing(direction):
                "\(direction.label) 번역 언어가 이 Mac에 받아져 있지 않습니다."
            case let .unsupported(direction):
                "Apple 번역이 \(direction.label)을 지원하지 않습니다."
            case .nothingToTranslate:
                "번역할 글이 없습니다."
            case let .other(message):
                message
            }
        }

        /// 다음에 무엇을 할지. 길을 **정확한 이름으로** 적는다 — "시스템 설정에서
        /// 받으세요"만으로는 어디를 눌러야 하는지 알 수 없다.
        var recoverySuggestion: String? {
            switch self {
            case let .languagePackMissing(direction):
                """
                시스템 설정 ▸ 일반 ▸ 언어 및 지역 ▸ 번역 언어에서 \
                ‘\(direction.sourceLanguageName)’과 ‘\(direction.targetLanguageName)’을 받으십시오.
                받은 뒤 이 문서에서 ⌘⇧T를 다시 누르면 됩니다. 받는 데에는 네트워크가 필요하고, \
                한 번 받으면 그 뒤로는 인터넷 없이 기기 안에서 번역됩니다.
                """
            case .unsupported:
                """
                시스템 설정 ▸ 일반 ▸ 언어 및 지역 ▸ 번역 언어에서 이 Mac이 어떤 언어를 \
                번역할 수 있는지 볼 수 있습니다. 마디는 지금 한국어와 영어 사이만 다룹니다.
                """
            case .nothingToTranslate:
                """
                이 문서에는 번역할 글이 없습니다 — 코드 블록·수평선·표 구분선·빈 줄은 \
                일부러 건드리지 않습니다. 글의 일부만 번역하려면 그 부분을 선택하고 \
                ⌘⇧T를 누르십시오.
                """
            case .other:
                nil
            }
        }
    }

    struct Progress: Sendable {
        var completedSegments: Int
        var totalSegments: Int
        var completedCharacters: Int
        var totalCharacters: Int

        /// 조각 수가 아니라 **글자 수**로 잰다 — 조각마다 길이가 달라 수로 재면 짧은 조각이
        /// 같은 몫을 먹는다.
        var fraction: Double {
            guard totalCharacters > 0 else { return 0 }
            return min(1, Double(completedCharacters) / Double(totalCharacters))
        }
    }

    static func availability(for direction: TranslationDirection) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: Locale.Language(identifier: direction.sourceIdentifier),
                                           to: Locale.Language(identifier: direction.targetIdentifier))
    }

    /// 마크다운을 번역해 **원래 구조 그대로** 돌려준다.
    ///
    /// 방향은 번역할 본문 전체에서 한 번 정한다(마커를 뺀 글로 판단하므로 영어 코드가 많은
    /// 한국어 문서에서도 방향이 뒤집히지 않는다).
    ///
    /// 번역을 시작하기 전에 **한 번 재는 것**.
    ///
    /// 왜 가르는가: 전에는 진행 시트를 먼저 띄우고 그 안에서 언어 팩을 확인했다. 팩이
    /// 없으면 시트가 떴다가 곧 사라지고 경고창이 떠서, 사용자가 무엇이 일어났는지
    /// 읽기 전에 화면이 두 번 바뀌었다. 재는 일은 싸고(순수 계산 + 가용성 조회 한 번)
    /// 시트를 띄우기 전에 할 수 있다.
    ///
    /// 계획(`plan`)을 함께 돌려주는 이유는 **두 번 만들지 않기 위해서**다. 계획을 만드는
    /// 것은 문서 전체를 훑는 일이라 큰 문서에서 두 번 하면 그만큼 느리다.
    struct Preflight {
        enum State: Equatable {
            /// 바로 번역할 수 있다.
            case ready
            /// 번역할 글이 없다(코드 블록·수평선·빈 줄만 있는 문서).
            case nothingToTranslate
            /// 언어 팩을 받으면 된다.
            case needsLanguagePack
            /// 이 Mac에서 이 방향은 지원되지 않는다.
            case unsupported
        }

        let plan: MarkdownTranslationPlan
        let direction: TranslationDirection
        let state: State
    }

    static func preflight(markdown: String) async -> Preflight {
        let plan = MarkdownTranslationPlan.make(markdown)
        let units = plan.units
        guard !units.isEmpty else {
            // 방향을 꾸며 내지 않는다. 전에는 여기서 `.englishToKorean`을 돌려줘
            // 부르는 쪽이 "번역했습니다 (영어 → 한국어)"라고 **거짓 보고**했다 —
            // 코드만 있는 문서를 번역하면 같은 글이 새 창으로 열리면서 성공 문구가 떴다.
            return Preflight(plan: plan, direction: .resolve(markdown), state: .nothingToTranslate)
        }

        let direction = TranslationDirection.resolve(units.map(\.text).joined(separator: " "))
        let state: Preflight.State
        switch await availability(for: direction) {
        case .installed: state = .ready
        case .supported: state = .needsLanguagePack
        case .unsupported: state = .unsupported
        @unknown default: state = .ready
        }
        return Preflight(plan: plan, direction: direction, state: state)
    }

    /// 단위가 길면 `TranslationChunker`로 더 나눈다 — 마크업 없는 긴 문단은 단위 하나가
    /// 수천 자가 되고, 그 문단이 끝날 때까지 진행이 멈춘 듯 보인다.
    static func translate(
        markdown: String,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> (text: String, direction: TranslationDirection) {
        try await translate(await preflight(markdown: markdown), progress: progress)
    }

    /// 이미 잰 결과로 번역한다. 가용성 판정이 **한 곳**(`preflight`)에만 있어서
    /// 미리 재는 쪽과 실제로 번역하는 쪽의 판단이 갈릴 수 없다.
    static func translate(
        _ preflight: Preflight,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> (text: String, direction: TranslationDirection) {
        let plan = preflight.plan
        let units = plan.units
        let direction = preflight.direction

        switch preflight.state {
        case .ready: break
        case .nothingToTranslate: throw Failure.nothingToTranslate
        case .needsLanguagePack: throw Failure.languagePackMissing(direction: direction)
        case .unsupported: throw Failure.unsupported(direction: direction)
        }

        let session = TranslationSession(
            installedSource: Locale.Language(identifier: direction.sourceIdentifier),
            target: Locale.Language(identifier: direction.targetIdentifier)
        )

        // 단위를 조각으로 펼친다. 조각 하나가 번역기 호출 하나이고 진행 보고 한 번이다.
        var jobs: [(unit: Int, chunk: String)] = []
        for (index, unit) in units.enumerated() {
            for chunk in TranslationChunker.split(unit.text) {
                jobs.append((index, chunk))
            }
        }

        let totalCharacters = jobs.reduce(0) { $0 + $1.chunk.count }
        var state = Progress(completedSegments: 0, totalSegments: jobs.count,
                             completedCharacters: 0, totalCharacters: totalCharacters)
        progress?(state)

        var perUnit = [String](repeating: "", count: units.count)

        // 차례로 한다. Sogon이 같은 실행 안에서 네 방식을 견줘 봤을 때 병렬이 일관되게
        // 빠르지 않았고(노이즈와 가를 수 없었다), 단순한 쪽이 취소와 진행 보고가 쉽다.
        for job in jobs {
            try Task.checkCancellation()
            do {
                perUnit[job.unit] += try await session.translate(job.chunk).targetText
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw map(error, direction: direction)
            }
            state.completedSegments += 1
            state.completedCharacters += job.chunk.count
            progress?(state)
        }

        return (try plan.assembled(with: perUnit), direction)
    }

    static func map(_ error: Error, direction: TranslationDirection) -> Error {
        if TranslationError.notInstalled ~= error { return Failure.languagePackMissing(direction: direction) }
        if TranslationError.unsupportedLanguagePairing ~= error
            || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error {
            return Failure.unsupported(direction: direction)
        }
        return Failure.other(error.localizedDescription)
    }
}
