import Foundation

/// 코드 블록의 `복사` 단추가 베끼는 글(사용자 — "코드 복사 버튼도 있으면 좋겠어"). 순수 계산이다 — 단추는
/// `CodeCopyButtonView`, 자리와 보이기는 `MarkdownEditorView`.
///
/// 블록은 **펜스 한 쌍**이다. 그리는 쪽의 회색 상자(`MarkdownStyler.codeBlockRanges`)는 이어진 코드 줄을 하나로
/// 묶어서, 닫는 펜스 바로 다음 줄에 다음 블록이 열리면 상자 하나에 블록 둘이 든다 — 단추는 블록마다 따로 단다.
public enum CodeBlockCopy {

    public struct Block: Equatable, Sendable {
        /// 여는 펜스 줄의 처음부터 닫는 펜스 줄의 끝까지. 닫는 펜스가 없으면(문서 끝까지 열린 블록) 마지막 줄의 끝까지.
        public let range: NSRange
        /// 펜스 사이의 줄들 — 마지막 줄바꿈은 빼고. 빈 블록이면 길이 0.
        public let body: NSRange
        /// 여는 펜스의 정보 문자열(`bash`, `python`). 없으면 nil.
        public let language: String?
        /// 여는 펜스 앞의 공백 수. 목록 안의 블록(`  ```bash`)은 코드 줄도 그만큼 들여 써 있다 — 베낄 때 뺀다
        /// (CommonMark도 코드의 내용에서 펜스의 들여쓰기만큼 뺀다).
        public let indent: Int
    }

    /// 문서의 펜스 블록들(위치 순). `lines`는 `MarkdownSyntax.scanLines`의 결과다.
    public static func blocks(in lines: [LineToken], text: NSString) -> [Block] {
        var blocks: [Block] = []
        var opening: LineToken?
        var firstBody: LineToken?
        var lastBody: LineToken?

        func finish(closingEnd: Int) {
            guard let open = opening else { return }
            let body: NSRange
            if let first = firstBody, let last = lastBody {
                body = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            } else {
                body = NSRange(location: NSMaxRange(open.range), length: 0)
            }
            blocks.append(Block(range: NSRange(location: open.range.location,
                                               length: closingEnd - open.range.location),
                                body: body, language: open.language,
                                indent: leadingSpaces(in: open.range, text: text)))
            opening = nil
            firstBody = nil
            lastBody = nil
        }

        for line in lines {
            switch line.kind {
            case .codeFence:
                if opening == nil {
                    opening = line
                } else {
                    finish(closingEnd: NSMaxRange(line.range))
                }
            case .codeBody where opening != nil:
                if firstBody == nil { firstBody = line }
                lastBody = line
            default:
                // 펜스 안의 줄은 모두 코드 본문이다(줄 판정). 여기 오는 것은 열린 블록 밖의 줄뿐이다.
                break
            }
        }
        if let open = opening {
            finish(closingEnd: NSMaxRange(lastBody?.range ?? open.range))
        }
        return blocks
    }

    /// 베낄 글 — 펜스는 빼고, 줄마다 펜스의 들여쓰기만큼(그보다 적으면 있는 만큼) 공백을 뺀다.
    public static func text(of block: Block, in text: NSString) -> String {
        guard block.body.length > 0, NSMaxRange(block.body) <= text.length else { return "" }
        let body = text.substring(with: block.body)
        guard block.indent > 0 else { return body }
        return body.components(separatedBy: "\n").map { line in
            var dropped = 0
            var result = Substring(line)
            while dropped < block.indent, result.first == " " {
                result = result.dropFirst()
                dropped += 1
            }
            return String(result)
        }.joined(separator: "\n")
    }

    private static func leadingSpaces(in range: NSRange, text: NSString) -> Int {
        var count = 0
        var index = range.location
        while index < NSMaxRange(range), text.character(at: index) == 0x20 {
            count += 1
            index += 1
        }
        return count
    }
}
