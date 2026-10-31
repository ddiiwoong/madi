import Foundation

/// 기울임꼴이 없는 글자를 찾아 **강제로 기울일** 범위를 알려 준다.
///
/// 왜 필요한가(2026-10-25 이 Mac에서 실측):
///
/// ```
/// italic 글꼴 변환(NSFontManager .italicFontMask)
///   영문 'italic'      → 먹힘    (.SFNS-RegularItalic)
///   숫자 '12345'       → 먹힘
///   한글 '기울임'       → 안 먹힘  (.AppleSDGothicNeoI-Regular)
///   일본어 '斜体'       → 안 먹힘
///   히라가나 'かたむき'  → 안 먹힘
///   중국어 '斜体字'      → 안 먹힘
/// obliqueness 0.2
///   위 전부            → 먹힘
/// ```
///
/// 한글이 기울지 않는 이유가 처음 짐작과 달랐다. 폰트 **행렬**이 항등(c=0.0)이라
/// 그런 것이 아니다 — `.SFNS-RegularItalic`도 행렬은 항등이고, 기울기는 **글자
/// 외곽선**에 들어 있다. 한글 자리에 오는 `.AppleSDGothicNeoI-Regular`는 이름에
/// `I`가 붙어 있지만 외곽선이 기울어 있지 않다. 그래서 글꼴을 바꿔도 그림이 한
/// 픽셀도 달라지지 않는다(픽셀 비교로 확인).
///
/// 그래서 **글꼴은 그대로 바꾸고**(영문은 진짜 기울임꼴을 받는다) 기울지 않는
/// 글자에만 `obliqueness`를 더한다. 둘을 모든 글자에 함께 주면 영문이 두 번
/// 기울어 지나치게 눕는다.
///
/// 덤으로 확인한 사실: `obliqueness`는 전진폭을 바꾸지 않는다(영문 'italic'이
/// 31.92pt로 같았다). 그래서 표 열 맞추기의 너비 계산과 부딪히지 않는다.
public enum SyntheticSlant {

    /// 강제 기울임의 정도. 진짜 기울임꼴(약 12도)과 비슷하게 보이는 값이다.
    public static let obliqueness: Double = 0.2

    /// 이 글자에 기울임꼴이 없어 강제로 기울여야 하는가.
    public static func needsSlant(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        for span in unslantedSpans where value >= span.lowerBound && value <= span.upperBound {
            return true
        }
        return false
    }

    /// `range` 안에서 강제로 기울일 부분들. 이어진 글자는 한 범위로 묶는다.
    /// 강제로 기울일 범위 — 글꼴에 기울임꼴이 있는지와 설정에 따라.
    ///
    /// - `fontHasItalic`: 기울임꼴로 바꾼 글꼴이 정말 기울임꼴인가. 기울임꼴이 **없는** 글꼴
    ///   (앱에 든 Pretendard가 그렇다)에서는 영문도 기울지 않으므로, 영문까지 강제로 기울인다.
    ///   설정과 상관없이 그렇게 한다 — 안 하면 `*강조*`가 아예 보이지 않는다.
    /// - `cjk`: 설정(한글·CJK 기울임 강제 적용). 꺼져 있으면 CJK 글자는 기울이지 않는다.
    public static func ranges(in text: NSString, range: NSRange,
                              fontHasItalic: Bool, cjk: Bool) -> [NSRange] {
        let cjkRanges = ranges(in: text, range: range)
        if fontHasItalic { return cjk ? cjkRanges : [] }
        if cjk { return range.length > 0 ? [range] : [] }
        // 기울임꼴이 없고 CJK는 기울이지 않는다 — CJK가 아닌 나머지만.
        var result: [NSRange] = []
        var cursor = range.location
        for piece in cjkRanges {
            if piece.location > cursor {
                result.append(NSRange(location: cursor, length: piece.location - cursor))
            }
            cursor = NSMaxRange(piece)
        }
        if cursor < NSMaxRange(range) {
            result.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        }
        return result
    }

    public static func ranges(in text: NSString, range: NSRange) -> [NSRange] {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return [] }
        var result: [NSRange] = []
        var runStart: Int?

        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            // 서로게이트 짝(확장 한자 등)을 한 글자로 읽는다.
            var length = 1
            let unit = text.character(at: index)
            var value = UInt32(unit)
            if unit >= 0xD800, unit <= 0xDBFF, index + 1 < end {
                let low = text.character(at: index + 1)
                if low >= 0xDC00, low <= 0xDFFF {
                    value = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(low - 0xDC00)
                    length = 2
                }
            }

            let slant = Unicode.Scalar(value).map(needsSlant) ?? false
            if slant {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                result.append(NSRange(location: start, length: index - start))
                runStart = nil
            }
            index += length
        }
        if let start = runStart {
            result.append(NSRange(location: start, length: end - start))
        }
        return result
    }

    /// 기울임꼴이 없는 글자 묶음. 위의 실측이 CJK 전반에 걸쳐 같았으므로 한글만
    /// 다루지 않는다. 숫자·라틴 글자·이모지는 넣지 않는다 — 앞의 둘은 진짜
    /// 기울임꼴을 받고, 이모지는 기울이면 어색하다.
    private static let unslantedSpans: [ClosedRange<UInt32>] = [
        0x1100 ... 0x11FF,      // 한글 자모
        0x3040 ... 0x309F,      // 히라가나
        0x30A0 ... 0x30FF,      // 가타카나
        0x3130 ... 0x318F,      // 한글 호환 자모
        0x31F0 ... 0x31FF,      // 가타카나 확장
        0x3400 ... 0x4DBF,      // 한자 확장 A
        0x4E00 ... 0x9FFF,      // 한자
        0xA960 ... 0xA97F,      // 한글 자모 확장 A
        0xAC00 ... 0xD7A3,      // 한글 음절
        0xD7B0 ... 0xD7FF,      // 한글 자모 확장 B
        0xF900 ... 0xFAFF,      // 한자 호환
        0xFF00 ... 0xFF60,      // 전각 꼴
        0x20000 ... 0x2A6DF,    // 한자 확장 B
    ]
}
