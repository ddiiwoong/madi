// 그림으로 바꿔 보이는 블록 — 앞머리 카드, 표, 다이어그램(Mermaid), 수식(KaTeX), 그림. 캐럿이 블록 안에 있으면 원문이 보인다
// (macOS판과 같은 약속 — 블록 전체가 그림 ↔ 원문으로 바뀐다). 그리는 일은 `editor/blocks.ts`.
//
// 다이어그램 · 수식의 모양은 macOS판 `RenderedBlock`과 같다:
// - ```` ```mermaid ```` 펜스, ```` ```math ```` · ```` ```katex ```` 펜스
// - `$$`만 있는 줄로 열고 닫는 블록(빈 줄을 만나면 블록이 아니다 — 짝 없는 `$$`가 문서 끝까지를 삼키지 않게), 한 줄짜리 `$$ … $$`
// 그림은 한 줄이 그림 하나(`![설명](자리)`)일 때다.

import type { EditorState, Text } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import { parseFrontMatter, type FrontMatterField } from "./frontmatter.ts";
import { parseTable, type Table } from "./table.ts";

interface Span {
  /** 첫 줄의 시작 · 끝 줄의 끝(줄 끝 글자는 넣지 않는다). */
  from: number;
  to: number;
  firstLine: number;
  lastLine: number;
}

export type RenderedBlock =
  | (Span & { kind: "frontmatter"; fields: FrontMatterField[] })
  | (Span & { kind: "table"; table: Table })
  | (Span & { kind: "mermaid" | "math"; source: string })
  | (Span & { kind: "image"; src: string; alt: string });

function span(doc: Text, first: number, last: number): Span {
  return { from: doc.line(first).from, to: doc.line(last).to, firstLine: first, lastLine: last };
}

function lineTexts(doc: Text, first: number, last: number): string[] {
  const lines: string[] = [];
  for (let number = first; number <= last; number++) lines.push(doc.line(number).text);
  return lines;
}

const imageLine = /^\s*!\[([^\]]*)\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)\s*$/;

/** 앞머리 — 맨 위의 `---`부터 닫는 줄까지. 닫는 줄을 찾느라 문서 끝까지 읽지 않는다(500줄). 없으면 null. */
export function frontMatterSpan(doc: Text): (Span & { fields: FrontMatterField[] }) | null {
  if (doc.lines < 2 || doc.line(1).text !== "---") return null;
  const front = parseFrontMatter(lineTexts(doc, 1, Math.min(doc.lines, 500)));
  return front ? { ...span(doc, 1, front.closingLine + 1), fields: front.fields } : null;
}

/**
 * 파일을 열었을 때의 캐럿 — 앞머리가 있으면 그 다음 줄의 처음(카드로 보이게 — macOS판은 앞머리를 편집기 밖의 카드로 떼어 낸다), 없으면
 * 문서의 처음. 캐럿이 맨 처음이면 앞머리가 원문으로 펼쳐진 채 열렸다(사용자 — "프론트매터 보여주는것도 아래 --- 부분이 이상해").
 */
export function openingCaret(doc: Text): number {
  const front = frontMatterSpan(doc);
  return front ? Math.min(front.to + 1, doc.length) : 0;
}

export function renderedBlocks(state: EditorState): RenderedBlock[] {
  const doc = state.doc;
  const blocks: RenderedBlock[] = [];

  const front = frontMatterSpan(doc);
  if (front) blocks.push({ kind: "frontmatter", ...front });
  const frontEnd = blocks[0]?.to ?? -1;

  // 맨 위 단계의 블록만 본다 — 목록 · 인용 안의 표나 코드 블록은 원문 그대로(macOS판도 그 자리에서는 그리지 않는다).
  for (let node = syntaxTree(state).topNode.firstChild; node; node = node.nextSibling) {
    if (node.from <= frontEnd) continue;
    const first = doc.lineAt(node.from).number;
    const last = doc.lineAt(Math.max(node.from, node.to - 1)).number;
    switch (node.name) {
      case "Table": {
        const table = parseTable(lineTexts(doc, first, last));
        if (table) blocks.push({ kind: "table", ...span(doc, first, last), table });
        break;
      }
      case "FencedCode": {
        const info = node.getChild("CodeInfo");
        const word = info ? doc.sliceString(info.from, info.to).trim().split(/\s+/)[0]!.toLowerCase() : "";
        const kind = word === "mermaid" ? "mermaid" : word === "math" || word === "katex" ? "math" : null;
        // 닫는 펜스가 있어야 한다 — 쓰는 중인 블록을 그리려 하지 않는다.
        if (!kind || node.getChildren("CodeMark").length < 2 || last - first < 1) break;
        blocks.push({ kind, ...span(doc, first, last), source: lineTexts(doc, first + 1, last - 1).join("\n") });
        break;
      }
      case "Paragraph": {
        const text = doc.line(first).text.trim();
        if (first === last) {
          const image = imageLine.exec(doc.line(first).text);
          if (image) {
            const src = image[2]!.replace(/^<|>$/g, "");
            blocks.push({ kind: "image", ...span(doc, first, first), src, alt: image[1]! });
            break;
          }
        }
        if (!text.startsWith("$$")) break;
        if (text !== "$$") {
          // 한 줄짜리 `$$ x $$`
          if (first === last && text.length > 4 && text.endsWith("$$")) {
            blocks.push({ kind: "math", ...span(doc, first, first), source: text.slice(2, -2).trim() });
          }
          break;
        }
        for (let close = first + 1; close <= last; close++) {
          if (doc.line(close).text.trim() === "$$") {
            blocks.push({ kind: "math", ...span(doc, first, close), source: lineTexts(doc, first + 1, close - 1).join("\n") });
            break;
          }
        }
        break;
      }
    }
  }
  return blocks;
}
