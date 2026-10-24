import Foundation

/// 코드 펜스의 정보 문자열이 가리키는 언어.
///
/// 아는 언어만 강조한다. 모르는 언어는 `nil`이 되고 코드 블록은 지금까지처럼 고정폭
/// 글꼴과 배경만 받는다 — 규칙을 모르는 언어에 C 비슷한 규칙을 억지로 대면 틀린 강조가
/// 나온다(예: `#`은 셸에서 주석이지만 C에서는 전처리기다). 모르는 채로 두는 쪽이 낫다.
public enum CodeLanguage: Sendable, Equatable, CaseIterable {
    case swift
    case javascript
    case python
    case shell
    case json

    /// 펜스의 정보 문자열(```` ```swift ````의 `swift`)을 언어로 읽는다.
    public static func named(_ raw: String?) -> CodeLanguage? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "swift": return .swift
        case "js", "javascript", "jsx", "mjs", "cjs",
             "ts", "typescript", "tsx": return .javascript
        case "py", "python", "python3": return .python
        case "sh", "shell", "bash", "zsh", "console", "terminal": return .shell
        case "json", "jsonc": return .json
        default: return nil
        }
    }
}

/// 코드를 색칠할 구간으로 나눈다.
///
/// 손으로 쓴 스캐너다. 정규식을 쓰지 않은 이유가 있다 — 문자열과 주석은 **다른 모든 것을
/// 이겨야** 하고(주석 안의 `if`는 키워드가 아니다), 이스케이프(`"\""`)와 여러 줄에 걸친
/// 구문(`/* */`, `"""`)은 줄 단위 정규식으로 맞출 수 없다. 한 번 훑으면서 "지금 무엇
/// 안에 있는지"를 들고 가는 쪽이 짧고 정확하다.
///
/// 오프셋은 **UTF-16**이다. `NSTextStorage`에 그대로 넘기기 때문이고, 그래서 주석이나
/// 문자열에 한글·이모지가 있어도 구간이 밀리지 않는다.
public enum CodeHighlighter {

    public struct Span: Equatable, Sendable {
        public enum Role: Sendable, Equatable {
            case keyword
            case type
            case string
            case comment
            case number
        }
        public let range: NSRange
        public let role: Role

        public init(range: NSRange, role: Role) {
            self.range = range
            self.role = role
        }
    }

    /// `code` 전체를 훑어 색칠할 구간을 돌려준다. 구간은 겹치지 않고 위치 순이다.
    ///
    /// **블록 전체를 한 번에** 넘겨야 한다. 줄 하나씩 넘기면 `/* */`나 `"""`처럼 줄을
    /// 넘나드는 구문에서 틀린다.
    public static func spans(in code: String, language: CodeLanguage) -> [Span] {
        let rules = Rules.of(language)
        let chars = Array(code)
        var spans: [Span] = []
        var index = 0
        var offset = 0      // UTF-16 오프셋

        func advance(_ count: Int = 1) {
            var remaining = count
            while remaining > 0, index < chars.count {
                offset += chars[index].utf16.count
                index += 1
                remaining -= 1
            }
        }

        /// `index` 위치에서 `needle`이 시작하는가.
        func matches(_ needle: String) -> Bool {
            let needleChars = Array(needle)
            guard index + needleChars.count <= chars.count else { return false }
            for (step, character) in needleChars.enumerated() where chars[index + step] != character {
                return false
            }
            return true
        }

        func emit(_ start: Int, _ role: Span.Role) {
            guard offset > start else { return }
            spans.append(Span(range: NSRange(location: start, length: offset - start), role: role))
        }

        while index < chars.count {
            let character = chars[index]

            // 1. 블록 주석. 가장 먼저 본다 — 주석 안에서는 아무것도 해석하지 않는다.
            if let block = rules.blockComment, matches(block.open) {
                let start = offset
                advance(block.open.count)
                var depth = 1
                while index < chars.count {
                    if rules.nestedBlockComments, matches(block.open) {
                        depth += 1
                        advance(block.open.count)
                        continue
                    }
                    if matches(block.close) {
                        advance(block.close.count)
                        depth -= 1
                        if depth == 0 { break }
                        continue
                    }
                    advance()
                }
                emit(start, .comment)
                continue
            }

            // 2. 줄 주석.
            if let marker = rules.lineComments.first(where: { matches($0) }) {
                let start = offset
                advance(marker.count)
                while index < chars.count, chars[index] != "\n" { advance() }
                emit(start, .comment)
                continue
            }

            // 3. 삼중 인용 문자열(여러 줄).
            if let triple = rules.tripleQuotes.first(where: { matches($0) }) {
                let start = offset
                advance(triple.count)
                while index < chars.count {
                    if rules.escapes, chars[index] == "\\" { advance(2); continue }
                    if matches(triple) { advance(triple.count); break }
                    advance()
                }
                emit(start, .string)
                continue
            }

            // 4. 보통 문자열.
            if rules.stringDelimiters.contains(character) {
                let start = offset
                let delimiter = character
                let spansLines = rules.multilineDelimiters.contains(delimiter)
                advance()
                while index < chars.count {
                    if rules.escapes, chars[index] == "\\" { advance(2); continue }
                    if chars[index] == delimiter { advance(); break }
                    // 닫히지 않은 문자열은 줄 끝에서 멈춘다. 안 그러면 따옴표 하나가
                    // 블록의 나머지 전부를 문자열로 만든다(치는 중에 늘 생기는 일이다).
                    if chars[index] == "\n", !spansLines { break }
                    advance()
                }
                emit(start, .string)
                continue
            }

            // 5. 숫자. 식별자 안의 숫자(`utf8`의 8)는 제외한다.
            if character.isNumber, index == 0 || !isIdentifier(chars[index - 1]) {
                let start = offset
                while index < chars.count, isNumberBody(chars[index]) { advance() }
                emit(start, .number)
                continue
            }

            // 6. 식별자 → 키워드 / 타입 / 그냥 글자.
            if isIdentifierStart(character) {
                let start = offset
                var word = ""
                while index < chars.count, isIdentifier(chars[index]) {
                    word.append(chars[index])
                    advance()
                }
                if rules.keywords.contains(word) {
                    emit(start, .keyword)
                } else if rules.types.contains(word) {
                    emit(start, .type)
                } else if rules.capitalizedAreTypes, let first = word.first, first.isUppercase {
                    emit(start, .type)
                }
                continue
            }

            advance()
        }

        return spans
    }

    // MARK: 글자 분류

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    private static func isNumberBody(_ character: Character) -> Bool {
        character.isHexDigit || character == "." || character == "_"
            || character == "x" || character == "X"
            || character == "e" || character == "E"
    }

    // MARK: 언어 규칙
    //
    // 언어를 더하려면 여기에 항목 하나를 쓰고 `CodeLanguage`에 이름을 더하면 된다.
    // 스캐너는 건드리지 않는다.

    private struct Rules {
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var nestedBlockComments = false
        var tripleQuotes: [String] = []
        var stringDelimiters: Set<Character> = []
        /// 줄을 넘나들 수 있는 문자열 구분자(JS의 템플릿 리터럴 등).
        var multilineDelimiters: Set<Character> = []
        var escapes = true
        var keywords: Set<String> = []
        var types: Set<String> = []
        /// 대문자로 시작하는 식별자를 타입으로 볼지. 그 관례가 통하는 언어에서만 켠다.
        var capitalizedAreTypes = false

        static func of(_ language: CodeLanguage) -> Rules {
            switch language {
            case .swift:
                return Rules(
                    lineComments: ["//"],
                    blockComment: ("/*", "*/"),
                    nestedBlockComments: true,          // Swift는 블록 주석이 중첩된다
                    tripleQuotes: ["\"\"\""],
                    stringDelimiters: ["\""],
                    keywords: [
                        "actor", "any", "as", "associatedtype", "async", "await", "borrowing",
                        "break", "case", "catch", "class", "consuming", "continue", "convenience",
                        "default", "defer", "deinit", "didSet", "do", "dynamic", "else", "enum",
                        "extension", "fallthrough", "false", "fileprivate", "final", "for", "func",
                        "get", "guard", "if", "import", "in", "indirect", "infix", "init", "inout",
                        "internal", "is", "lazy", "let", "mutating", "nil", "none", "nonisolated",
                        "open", "operator", "override", "postfix", "precedencegroup", "prefix",
                        "private", "protocol", "public", "repeat", "required", "rethrows", "return",
                        "sending", "self", "Self", "set", "some", "static", "struct", "subscript",
                        "super", "switch", "throw", "throws", "true", "try", "typealias", "unowned",
                        "var", "weak", "where", "while", "willSet", "yield",
                    ],
                    types: [
                        "Any", "AnyObject", "Array", "Bool", "Character", "Dictionary", "Double",
                        "Error", "Float", "Int", "Never", "Optional", "Result", "Sendable", "Set",
                        "String", "Substring", "Task", "UInt", "Void",
                    ],
                    capitalizedAreTypes: true
                )

            case .javascript:
                return Rules(
                    lineComments: ["//"],
                    blockComment: ("/*", "*/"),
                    stringDelimiters: ["\"", "'", "`"],
                    multilineDelimiters: ["`"],          // 템플릿 리터럴은 줄을 넘는다
                    keywords: [
                        "abstract", "any", "as", "async", "await", "boolean", "break", "case",
                        "catch", "class", "const", "constructor", "continue", "debugger",
                        "declare", "default", "delete", "do", "else", "enum", "export", "extends",
                        "false", "finally", "for", "from", "function", "get", "if", "implements",
                        "import", "in", "instanceof", "interface", "let", "new", "null", "number",
                        "of", "private", "protected", "public", "readonly", "return", "satisfies",
                        "set", "static", "string", "super", "switch", "symbol", "this", "throw",
                        "true", "try", "type", "typeof", "undefined", "unknown", "var", "void",
                        "while", "with", "yield",
                    ],
                    types: [
                        "Array", "Boolean", "Date", "Error", "JSON", "Map", "Math", "Number",
                        "Object", "Promise", "RegExp", "Set", "String", "Symbol", "WeakMap",
                    ],
                    capitalizedAreTypes: true
                )

            case .python:
                return Rules(
                    lineComments: ["#"],
                    blockComment: nil,
                    tripleQuotes: ["\"\"\"", "'''"],    // 독스트링
                    stringDelimiters: ["\"", "'"],
                    keywords: [
                        "False", "None", "True", "and", "as", "assert", "async", "await", "break",
                        "class", "continue", "def", "del", "elif", "else", "except", "finally",
                        "for", "from", "global", "if", "import", "in", "is", "lambda", "match",
                        "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with",
                        "yield",
                    ],
                    types: [
                        "bool", "bytes", "dict", "float", "frozenset", "int", "list", "object",
                        "set", "str", "tuple", "type",
                    ]
                )

            case .shell:
                return Rules(
                    lineComments: ["#"],
                    blockComment: nil,
                    stringDelimiters: ["\"", "'"],
                    keywords: [
                        "case", "cd", "do", "done", "echo", "elif", "else", "esac", "exit",
                        "export", "fi", "for", "function", "if", "in", "local", "return", "set",
                        "shift", "source", "then", "unset", "until", "while",
                    ]
                )

            case .json:
                // 주석도 키워드도 거의 없다. 문자열·숫자·리터럴 셋뿐이다.
                return Rules(
                    stringDelimiters: ["\""],
                    keywords: ["true", "false", "null"]
                )
            }
        }
    }
}
