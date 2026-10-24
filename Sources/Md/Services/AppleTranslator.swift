import Foundation
import Translation

/// Apple Translation으로 이 Mac 안에서 번역한다(macOS 26 이상). 네트워크를 쓰지 않는다.
///
/// 구조는 Sogon의 `AppleTranslationService`를 따른다 — 설치된 언어로만 세션을 만들고,
/// 팩이 없으면 `languagePackMissing`을 던진다. **언어 팩을 여기서 받지 않는다**: 받기는
/// 사용자 동의 창이 필요하고 그 창은 SwiftUI `.translationTask`가 붙은 화면 위에만 뜬다.
/// Md에는 그 화면이 없으므로 안내만 하고, 사용자가 시스템 설정에서 받는다.
///
/// Sogon과 다른 점은 **무엇을 넘기는가**다. Sogon은 받아쓴 말을 통째로 넘기지만 여기서는
/// `MarkdownTranslationPlan`이 가른 본문 조각만 넘긴다 — 마크업을 넘기면 구조가 깨진다.
@available(macOS 26.0, *)
enum AppleTranslator {

    enum Failure: LocalizedError, Equatable {
        case languagePackMissing(direction: TranslationDirection)
        case unsupported(direction: TranslationDirection)
        case other(String)

        var isLanguagePackMissing: Bool {
            if case .languagePackMissing = self { return true }
            return false
        }

        var errorDescription: String? {
            switch self {
            case let .languagePackMissing(direction):
                "\(direction.label) 언어 팩이 이 Mac에 없습니다. 시스템 설정 → 일반 → 언어 및 지역 → 번역 언어에서 받으세요."
            case let .unsupported(direction):
                "Apple 번역이 \(direction.label)을 지원하지 않습니다."
            case let .other(message):
                message
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
    static func translate(
        markdown: String,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> (text: String, direction: TranslationDirection) {
        let plan = MarkdownTranslationPlan.make(markdown)
        let pieces = plan.translatableTexts
        guard !pieces.isEmpty else { return (markdown, .englishToKorean) }

        let direction = TranslationDirection.resolve(pieces.joined(separator: " "))

        switch await availability(for: direction) {
        case .installed: break
        case .supported: throw Failure.languagePackMissing(direction: direction)
        case .unsupported: throw Failure.unsupported(direction: direction)
        @unknown default: break
        }

        let session = TranslationSession(
            installedSource: Locale.Language(identifier: direction.sourceIdentifier),
            target: Locale.Language(identifier: direction.targetIdentifier)
        )

        let totalCharacters = plan.translatableCharacterCount
        var state = Progress(completedSegments: 0, totalSegments: pieces.count,
                             completedCharacters: 0, totalCharacters: totalCharacters)
        progress?(state)

        var translated: [String] = []
        translated.reserveCapacity(pieces.count)

        // 차례로 한다. Sogon이 같은 실행 안에서 네 방식을 견줘 봤을 때 병렬이 일관되게
        // 빠르지 않았고(노이즈와 가를 수 없었다), 단순한 쪽이 취소와 진행 보고가 쉽다.
        for piece in pieces {
            try Task.checkCancellation()
            do {
                translated.append(try await session.translate(piece).targetText)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw map(error, direction: direction)
            }
            state.completedSegments += 1
            state.completedCharacters += piece.count
            progress?(state)
        }

        return (try plan.assembled(with: translated), direction)
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
