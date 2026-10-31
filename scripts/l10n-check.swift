// 영어 표가 소스와 맞는지 본다 — `make l10n-check`가 부른다.
//
//   swift scripts/l10n-check.swift <.stringsdata 폴더> <en.lproj/Localizable.strings>
//
// 첫 인자는 `swiftc -emit-localized-strings`가 쓴 폴더다. 키를 손으로 모으지 않고
// 컴파일러에게 받는다 — 보간(`\(n)`)이 `%lld`가 되는지 `%@`가 되는지, `%`가 `%%`로
// 바뀌는지를 컴파일러만 정확히 안다. 손으로 적은 키는 한 글자만 달라도 조용히 한국어가
// 나온다.
//
// 세 가지를 잡는다.
//   - 빠진 키: 소스에 있는데 표에 없다 → 영어 화면에 한국어가 나온다.
//   - 남은 키: 표에 있는데 소스에 없다 → 문장을 고친 뒤 옛 번역이 남았다.
//   - 형식 지정자가 다른 키: `%@`·`%lld`의 종류·순서가 다르면 실행 중에 엉뚱한 값이
//     들어가거나 죽는다.
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("쓰는 법: l10n-check.swift <stringsdata 폴더> <Localizable.strings>\n".utf8))
    exit(2)
}

/// 소스의 키 → (개발 언어 값, 나온 곳들).
///
/// 나온 곳을 **모두** 적는다. 저장 프로퍼티의 초깃값에 쓴 문장은 컴파일러가 제 파일에
/// 줄 번호 없이 한 번, `main.swift:51`(엉뚱한 곳)에 한 번 더 적는다(Xcode 27.1 실측).
/// 하나만 고르면 그 엉뚱한 곳을 가리킬 수 있다.
var source: [String: (value: String, places: Set<String>)] = [:]
let folder = URL(fileURLWithPath: arguments[1])
let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
for file in files where file.pathExtension == "stringsdata" {
    guard let data = try? Data(contentsOf: file),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tables = object["tables"] as? [String: [[String: Any]]] else { continue }
    let name = ((object["source"] as? String) ?? file.lastPathComponent) as NSString
    for (table, entries) in tables {
        guard table == "Localizable" else {
            print("다른 표를 쓰는 문장이 있습니다: \(table) — 이 검사는 Localizable만 봅니다")
            exit(1)
        }
        for entry in entries {
            guard let key = entry["key"] as? String else { continue }
            let line = (entry["location"] as? [String: Any])?["startingLine"] as? Int
            let place = name.lastPathComponent + (line.map { ":\($0)" } ?? "")
            let value = entry["value"] as? String ?? key
            source[key, default: (value, [])].places.insert(place)
        }
    }
}
guard !source.isEmpty else {
    print("키를 하나도 못 읽었습니다 — \(arguments[1])에 .stringsdata가 없습니다")
    exit(1)
}

guard let table = NSDictionary(contentsOfFile: arguments[2]) as? [String: String] else {
    print("표를 읽지 못했습니다: \(arguments[2]) — .strings 문법이 깨졌을 수 있습니다(plutil -lint)")
    exit(1)
}

/// 형식 지정자를 순서대로. 자리 지정(`%2$@`)이 있으면 그 자리로 정렬한다. `%%`는 뺀다.
func specifiers(_ text: String) -> [String] {
    let pattern = #"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaA%])"#
    let regex = try! NSRegularExpression(pattern: pattern)
    var found: [(position: Int, spec: String)] = []
    var next = 1
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let conversion = String(text[Range(match.range(at: 3), in: text)!])
        if conversion == "%" { continue }
        let length = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
        let position = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? next
        next = position + 1
        found.append((position, length + conversion))
    }
    return found.sorted { $0.position < $1.position }.map(\.spec)
}

func places(_ key: String) -> String {
    source[key]!.places.sorted().joined(separator: ", ")
}

var problems = 0
for key in source.keys.sorted() where table[key] == nil {
    print("빠짐   \(places(key))  \(key.debugDescription)")
    problems += 1
}
for key in table.keys.sorted() where source[key] == nil {
    print("남음   \(key.debugDescription)")
    problems += 1
}
for (key, entry) in source.sorted(by: { $0.key < $1.key }) {
    guard let translated = table[key] else { continue }
    let want = specifiers(entry.value), got = specifiers(translated)
    if want != got {
        print("지정자 \(places(key))  \(key.debugDescription)  원문 \(want) ≠ 번역 \(got)")
        problems += 1
    }
}

if problems > 0 {
    print("l10n-check: 문제 \(problems)개")
    exit(1)
}
print("l10n-check: 키 \(source.count)개, 영어 표와 맞습니다")
