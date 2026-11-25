// 코드 블록의 `복사` 단추가 베끼는 글 — macOS판 `CodeBlockCopy`와 같은 규칙(사용자 — "코드 부분 복사 버튼이 없음"). 순수 계산이다 —
// 단추는 `editor/codecopy.ts`, 클립보드는 껍데기(`copyText`).
//
// 블록은 펜스 한 쌍(```` ``` ````, `~~~`)이다. 닫는 펜스가 없으면(문서 끝까지 열린 블록) 마지막 줄까지 — 문서 끝의 빈 줄은 뺀다.
// 베낄 때는 펜스를 빼고, 줄마다 여는 펜스의 들여쓰기만큼(그보다 적으면 있는 만큼) 공백을 뺀다 — 목록 안의 블록(`  ```bash`)은 코드
// 줄도 그만큼 들여 써 있다(CommonMark도 코드의 내용에서 펜스의 들여쓰기만큼 뺀다).
//
// 인용 안의 블록(`> ```…`)은 단추를 달지 않는다 — 줄마다 붙은 `>`를 빼는 규칙이 macOS판에 없고, 붙은 채 베끼면 코드가 아니다.

import type { EditorState, Text } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";

export interface CodeBlock {
  /**
   * 회색 상자 — 여는 펜스 줄의 처음부터 끝 줄의 끝까지(줄 끝 글자는 넣지 않는다). 끝 줄은 닫는 펜스, 닫지 않은 블록이면 블록의 마지막
   * 줄이다 — 문서가 줄바꿈으로 끝나면 그 뒤의 빈 줄까지(상자가 거기까지 칠해진다).
   */
  from: number;
  to: number;
  firstLine: number;
  lastLine: number;
  /** 베끼는 줄 — 펜스와, 닫지 않은 블록 끝의 빈 줄을 뺀다. 빈 블록이면 `bodyFirst > bodyLast`. */
  bodyFirst: number;
  bodyLast: number;
  closed: boolean;
  /** 여는 펜스의 정보 문자열의 첫 낱말(`bash`, `python`). 없으면 null. */
  language: string | null;
  /** 여는 펜스 앞의 공백 수. */
  indent: number;
}

/** 이 줄(`pos`가 있는 줄)이 든 펜스 블록. 없거나 인용 안이면 null. */
export function codeBlockAt(state: EditorState, pos: number): CodeBlock | null {
  const doc = state.doc;
  const line = doc.lineAt(Math.max(0, Math.min(pos, doc.length)));
  let found: CodeBlock | null = null;
  syntaxTree(state).iterate({
    from: line.from,
    to: line.to,
    enter(node) {
      if (found) return false;
      if (node.name !== "FencedCode") return;
      const marks = node.node.getChildren("CodeMark");
      const opening = marks[0];
      if (!opening) return false;
      const first = doc.lineAt(node.from);
      const prefix = doc.sliceString(first.from, opening.from);
      // 인용 · 다른 그릇 안 — 공백 말고 다른 글자가 앞에 있다.
      if (!/^[ \t]*$/.test(prefix)) return false;
      const closed = marks.length >= 2;
      const last = doc.lineAt(closed ? marks[marks.length - 1]!.from : node.to);
      let bodyLast = closed ? last.number - 1 : last.number;
      if (!closed && bodyLast > first.number && last.length === 0) bodyLast--;
      const info = node.node.getChild("CodeInfo");
      const word = info ? doc.sliceString(info.from, info.to).trim().split(/\s+/)[0] ?? "" : "";
      found = {
        from: first.from, to: last.to, firstLine: first.number, lastLine: last.number,
        bodyFirst: first.number + 1, bodyLast, closed, language: word === "" ? null : word, indent: prefix.length,
      };
      return false;
    },
  });
  return found;
}

/** 베낄 글 — 펜스는 빼고, 줄마다 펜스의 들여쓰기만큼 앞 공백을 뺀다. 줄 끝은 `\n`(클립보드에 맞추는 일은 껍데기가 한다). */
export function codeText(doc: Text, block: CodeBlock): string {
  const lines: string[] = [];
  for (let number = block.bodyFirst; number <= block.bodyLast && number <= doc.lines; number++) {
    const text = doc.line(number).text;
    let cut = 0;
    while (cut < block.indent && (text[cut] === " " || text[cut] === "\t")) cut++;
    lines.push(text.slice(cut));
  }
  return lines.join("\n");
}
