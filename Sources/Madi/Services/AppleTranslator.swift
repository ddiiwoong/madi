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
        /// 원문과 대상이 같은 언어다.
        case sameLanguage(language: String)
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
            case .nothingToTranslate, .sameLanguage, .other: return false
            }
        }

        /// 무엇이 잘못됐는가. **한 문장**으로 둔다 — 무엇을 해야 하는지는
        /// `recoverySuggestion`이 말한다(경고창이 둘을 다른 크기로 그린다).
        var errorDescription: String? {
            switch self {
            case let .languagePackMissing(direction):
                String(localized: "\(direction.label) 번역 언어가 이 Mac에 받아져 있지 않습니다.")
            case let .unsupported(direction):
                String(localized: "Apple 번역이 \(direction.label)을 지원하지 않습니다.")
            case .nothingToTranslate:
                String(localized: "번역할 글이 없습니다.")
            case let .sameLanguage(language):
                String(localized: "원문과 번역할 언어가 모두 \(language)입니다.")
            case let .other(message):
                message
            }
        }

        /// 다음에 무엇을 할지. 길을 **정확한 이름으로** 적는다 — "시스템 설정에서
        /// 받으세요"만으로는 어디를 눌러야 하는지 알 수 없다.
        var recoverySuggestion: String? {
            switch self {
            case let .languagePackMissing(direction):
                String(localized: """
                시스템 설정 ▸ 일반 ▸ 언어 및 지역 ▸ 번역 언어에서 \
                ‘\(direction.sourceLanguageName)’과 ‘\(direction.targetLanguageName)’을 받으십시오.
                받은 뒤 이 문서에서 ⌘⇧T를 다시 누르면 됩니다. 받는 데에는 네트워크가 필요하고, \
                한 번 받으면 그 뒤로는 인터넷 없이 기기 안에서 번역됩니다.
                """)
            case .unsupported:
                String(localized: """
                시스템 설정 ▸ 일반 ▸ 언어 및 지역 ▸ 번역 언어에서 이 Mac이 어떤 언어를 \
                번역할 수 있는지 볼 수 있습니다. 다른 언어로 옮기려면 도구 ▸ 번역 언어 \
                선택…(⌥⌘⇧T)에서 고르십시오.
                """)
            case .nothingToTranslate:
                String(localized: """
                이 문서에는 번역할 글이 없습니다 — 코드 블록·수평선·표 구분선·빈 줄은 \
                일부러 건드리지 않습니다. 글의 일부만 번역하려면 그 부분을 선택하고 \
                ⌘⇧T를 누르십시오.
                """)
            case .sameLanguage:
                String(localized: """
                도구 ▸ 번역 언어 선택…(⌥⌘⇧T)에서 다른 언어를 고르십시오. 같은 언어로는 \
                옮길 것이 없습니다.
                """)
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

    /// 한국어와 오갈 수 있는 언어들. 언어 선택 메뉴가 이것으로 만들어진다.
    ///
    /// **목록을 손으로 적지 않는다.** 시스템이 `supportedLanguages`로 알려 주고(이 Mac에서
    /// 47개를 돌려줬다), 손으로 적으면 OS가 언어를 더해도 마디는 모른다.
    ///
    /// 두 가지를 다듬는다. 첫째, 목록에 **지역 변종이 섞여 있다**(`en`이 여덟 번,
    /// `zh`가 세 번 나왔다) — 기본 언어 코드로 모은다. 둘째, 한국어를 한쪽에 둔 쌍이
    /// 실제로 되는지 **물어서 가린다** — `supportedLanguages`에 있다고 한국어와 짝이
    /// 되는 것은 아니다.
    ///
    /// 돌려주는 것은 코드와 **받아져 있는지**다. 받아지지 않은 언어도 목록에 남기고
    /// 화면에서 표시한다 — 고를 수 있어야 그 언어의 안내(받는 길)를 볼 수 있다.
    static func supportedLanguagesWithKorean() async -> [TranslationDirection.Language] {
        let availability = LanguageAvailability()
        let korean = Locale.Language(identifier: "ko")

        var codes: Set<String> = []
        for language in await availability.supportedLanguages {
            guard let code = language.languageCode?.identifier, code != "ko" else { continue }
            codes.insert(code)
        }

        var result: [TranslationDirection.Language] = []
        for code in codes {
            let language = Locale.Language(identifier: code)
            let out = await availability.status(from: korean, to: language)
            let into = await availability.status(from: language, to: korean)
            // 어느 방향도 지원되지 않으면 목록에 둘 이유가 없다.
            guard out != .unsupported || into != .unsupported else { continue }
            result.append(TranslationDirection.Language(code: code,
                                            name: TranslationDirection.name(of: code),
                                            outboundInstalled: out == .installed,
                                            inboundInstalled: into == .installed))
        }
        // 이름으로 정렬한다 — 코드 순(`ar`, `da`, `de`…)은 한국어 화면에서 뜻이 없다.
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
            /// 원문과 대상이 같은 언어다. 사용자가 그렇게 고를 수 있다.
            case sameLanguage
        }

        let plan: MarkdownTranslationPlan
        let direction: TranslationDirection
        let state: State
    }

    /// - Parameters:
    ///   - markdown: 번역할 글.
    ///   - direction: 쓸 방향. `nil`이면 글에서 짐작한다(`TranslationDirection.resolve`).
    ///     사용자가 메뉴에서 고른 경우에는 그 값이 들어온다 — 짐작이 틀렸을 때
    ///     사용자가 고칠 수 있어야 하고, 그것이 문자 기반 짐작을 받아들일 수 있는 이유다.
    ///   - preferredTarget: 짐작할 때 쓸 기본 대상 언어(원문이 한국어일 때).
    ///   - installed: 언어 팩이 받아져 있는가를 묻지 않고 정한다. 테스트가 쓴다(시스템에 묻지 않고
    ///     번역기 대역으로 창의 번역 흐름을 시험한다). nil이면 시스템에 묻는다.
    static func preflight(markdown: String,
                          direction requested: TranslationDirection? = nil,
                          preferredTarget: String = "en",
                          installed: Bool? = nil) async -> Preflight {
        let plan = MarkdownTranslationPlan.make(markdown)
        let units = plan.units
        guard !units.isEmpty else {
            // 방향을 꾸며 내지 않는다. 전에는 여기서 `.englishToKorean`을 돌려줘
            // 부르는 쪽이 "번역했습니다 (영어 → 한국어)"라고 **거짓 보고**했다 —
            // 코드만 있는 문서를 번역하면 같은 글이 새 창으로 열리면서 성공 문구가 떴다.
            let fallback = requested
                ?? .resolve(markdown, preferredTarget: preferredTarget)
            return Preflight(plan: plan, direction: fallback, state: .nothingToTranslate)
        }

        let direction = requested
            ?? .resolve(units.map(\.text).joined(separator: " "), preferredTarget: preferredTarget)
        // 원문과 대상이 같으면 번역이 아니다. 사용자가 그렇게 고를 수 있으므로 가린다.
        guard !direction.isTrivial else {
            return Preflight(plan: plan, direction: direction, state: .sameLanguage)
        }

        if let installed {
            return Preflight(plan: plan, direction: direction, state: installed ? .ready : .needsLanguagePack)
        }
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
        let result = try await translate(await preflight(markdown: markdown), progress: progress)
        return (result.text, result.direction)
    }

    /// 이미 잰 결과로 번역한다. 가용성 판정이 **한 곳**(`preflight`)에만 있어서
    /// 미리 재는 쪽과 실제로 번역하는 쪽의 판단이 갈릴 수 없다.
    ///
    /// `extras`는 본문 밖에서 함께 옮길 짧은 글이다(front matter의 `title`·`description`).
    /// 마크업이 없는 평문이라 계획을 거치지 않고 같은 세션으로 하나씩 옮긴다 — 같은 방향,
    /// 같은 진행 막대. 결과의 `extras`는 같은 순서다.
    static func translate(
        _ preflight: Preflight,
        extras: [String] = [],
        cache: TranslationCache = .shared,
        progress: (@Sendable (Progress) -> Void)? = nil,
        translator: (@Sendable (String) async throws -> String)? = nil
    ) async throws -> (text: String, direction: TranslationDirection, extras: [String], repairs: Repairs) {
        let plan = preflight.plan
        let units = plan.units
        let direction = preflight.direction

        switch preflight.state {
        case .ready: break
        case .nothingToTranslate: throw Failure.nothingToTranslate
        case .sameLanguage: throw Failure.sameLanguage(language: direction.sourceLanguageName)
        case .needsLanguagePack: throw Failure.languagePackMissing(direction: direction)
        case .unsupported: throw Failure.unsupported(direction: direction)
        }

        let jobs = jobs(for: units, extras: extras)

        /// 번역기 호출 하나 — 번역기의 실패를 마디의 실패로 바꾼다. 캐시는 아래 `cached`가
        /// 먼저 본다. 대역(`translator`)이 들어오면 Apple 번역 세션을 만들지 않는다.
        let translateOne: (String) async throws -> String
        if let translator {
            translateOne = { text in
                try Task.checkCancellation()
                return try await translator(text)
            }
        } else {
            let session = TranslationSession(
                installedSource: Locale.Language(identifier: direction.sourceIdentifier),
                target: Locale.Language(identifier: direction.targetIdentifier)
            )
            translateOne = { text in
                try Task.checkCancellation()
                do {
                    return try await session.translate(text).targetText
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    throw map(error, direction: direction)
                }
            }
        }
        let cached = cachedTranslator(cache, direction: direction, translate: translateOne)

        var perUnit = try await translateJobs(jobs, slots: units.count + extras.count,
                                              translate: cached, progress: progress)
        let translatedExtras = Array(perUnit[units.count...])
        perUnit.removeLast(extras.count)

        // 자리표를 잃은 단위와 칸 구조를 지키지 못한 표 행을 다시 번역한다(`repairs`).
        let repairs = try await self.repairs(plan: plan, translations: perUnit,
                                             wordSpacing: direction.targetUsesWordSpaces, translate: cached)

        return (try plan.assembled(with: perUnit, replacing: repairs.replacing), direction,
                translatedExtras, repairs)
    }

    /// 단위를 조각으로 펼친다. 조각 하나가 번역기 호출 하나이고 진행 보고 한 번이다.
    /// 덧붙인 글(`extras`)은 단위 번호 뒤에 이어 번호를 매긴다.
    static func jobs(for units: [MarkdownTranslationPlan.Unit],
                     extras: [String]) -> [(unit: Int, chunk: String)] {
        var jobs: [(unit: Int, chunk: String)] = []
        for (index, unit) in units.enumerated() {
            for chunk in TranslationChunker.split(unit.text) {
                jobs.append((index, chunk))
            }
        }
        for (index, extra) in extras.enumerated() {
            jobs.append((units.count + index, extra))
        }
        return jobs
    }

    /// 캐시를 먼저 보고, 없을 때만 번역기를 부르고 그 결과를 넣는 번역기.
    static func cachedTranslator(
        _ cache: TranslationCache,
        direction: TranslationDirection,
        translate: @escaping (String) async throws -> String
    ) -> (String) async throws -> String {
        let source = direction.sourceIdentifier
        let target = direction.targetIdentifier
        return { text in
            if let hit = cache.translation(of: text, from: source, to: target) { return hit }
            let translated = try await translate(text)
            cache.store(translated, of: text, from: source, to: target)
            return translated
        }
    }

    /// 조각을 차례로 번역해 칸(`slots`)마다 이어 붙인다. 번역기를 받아 쓰므로 Apple 번역
    /// 없이도 시험할 수 있다.
    ///
    /// 차례로 한다. Sogon이 같은 실행 안에서 네 방식을 견줘 봤을 때 병렬이 일관되게
    /// 빠르지 않았고(노이즈와 가를 수 없었다), 단순한 쪽이 취소와 진행 보고가 쉽다.
    static func translateJobs(
        _ jobs: [(unit: Int, chunk: String)],
        slots: Int,
        translate: (String) async throws -> String,
        progress: (@Sendable (Progress) -> Void)?
    ) async throws -> [String] {
        let totalCharacters = jobs.reduce(0) { $0 + $1.chunk.count }
        var state = Progress(completedSegments: 0, totalSegments: jobs.count,
                             completedCharacters: 0, totalCharacters: totalCharacters)
        progress?(state)

        var perSlot = [String](repeating: "", count: slots)
        for job in jobs {
            try Task.checkCancellation()
            perSlot[job.unit] += try await translate(job.chunk)
            state.completedSegments += 1
            state.completedCharacters += job.chunk.count
            progress?(state)
        }
        return perSlot
    }

    /// 다시 번역한 결과.
    struct Repairs: Equatable, Sendable {
        /// 단위 번호 → **이미 복원된** 글.
        var replacing: [Int: String] = [:]
        /// 자리표를 잃어 다른 꼴로 다시 번역한 단위 수.
        var reformed = 0
        /// 다른 꼴로도 안 돼 글 조각마다 따로 번역한 단위 수(문맥을 잃었다).
        var split = 0
        /// 칸마다 다시 번역한 표 행 수.
        var tableRows = 0

        var isEmpty: Bool { replacing.isEmpty }
    }

    /// 번역문이 온전하지 않은 단위를 다시 번역한다. 번역기를 받아 쓰므로 Apple 번역 없이도 시험할 수 있다.
    ///
    /// - 자리표를 잃었거나 여는 것과 닫는 것의 순서가 뒤집힌 단위(`Unit.isIntact`): **다른 꼴의
    ///   자리표**로 다시 번역한다 — 잃는 문장이 꼴마다 다르다(실측, `TokenForm`). 그래도 안 되면 자리표
    ///   없이 글 조각마다 따로 번역한다(`Unit.runTexts`). 그대로 두면 링크 글이 사라지고 `[^1][](url)`
    ///   같은 조각이 문장 끝에 붙는다.
    /// - 칸 구조를 지키지 못한 표 행(`keepsStructure`): 그 행만 칸마다 다시 번역한다. 칸도 같은 검사를
    ///   거친다.
    static func repairs(
        plan: MarkdownTranslationPlan,
        translations: [String],
        wordSpacing: Bool = true,
        translate: (String) async throws -> String
    ) async throws -> Repairs {
        var result = Repairs()
        for (index, unit) in plan.units.enumerated() where index < translations.count {
            let translated = translations[index]
            if let fallback = unit.cellFallback {
                guard !(unit.keepsStructure(translated) && unit.isIntact(translated)) else { continue }
                var cells: [String] = []
                var cellRepairs: [Int: String] = [:]
                for (cellIndex, cell) in fallback.units.enumerated() {
                    let cellText = try await chunked(cell.text, translate: translate)
                    cells.append(cellText)
                    if !cell.isIntact(cellText) {
                        let fixed = try await repaired(cell, wordSpacing: wordSpacing, translate: translate)
                        cellRepairs[cellIndex] = fixed.text
                        if fixed.split { result.split += 1 } else { result.reformed += 1 }
                    }
                }
                result.replacing[index] = try fallback.assembled(with: cells, replacing: cellRepairs)
                result.tableRows += 1
                continue
            }
            guard !unit.isIntact(translated) else { continue }
            let fixed = try await repaired(unit, wordSpacing: wordSpacing, translate: translate)
            result.replacing[index] = fixed.text
            if fixed.split { result.split += 1 } else { result.reformed += 1 }
        }
        return result
    }

    /// 표 행의 칸 구조만 고친 결과(단위 번호 → 복원된 행). `repairs`의 한 부분이다.
    static func structureRepairs(
        plan: MarkdownTranslationPlan,
        translations: [String],
        translate: (String) async throws -> String
    ) async throws -> [Int: String] {
        try await repairs(plan: plan, translations: translations, translate: translate).replacing
    }

    /// 자리표를 잃은 단위 하나 — 다른 꼴로 다시, 그래도 안 되면 조각마다.
    static func repaired(
        _ unit: MarkdownTranslationPlan.Unit,
        wordSpacing: Bool,
        translate: (String) async throws -> String
    ) async throws -> (text: String, split: Bool) {
        for form in unit.alternateForms {
            let translated = try await chunked(unit.text(in: form), translate: translate)
            if unit.isIntact(translated, form: form) {
                return (unit.restored(from: translated, form: form), false)
            }
        }
        var runs: [String] = []
        for run in unit.runTexts {
            runs.append(try await chunked(run, translate: translate))
        }
        return (unit.reassembled(runs: runs, wordSpacing: wordSpacing), true)
    }

    /// 긴 글은 조각으로 나눠 번역하고 잇는다(`TranslationChunker`).
    static func chunked(_ text: String, translate: (String) async throws -> String) async throws -> String {
        var out = ""
        for chunk in TranslationChunker.split(text) {
            try Task.checkCancellation()
            out += try await translate(chunk)
        }
        return out
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
