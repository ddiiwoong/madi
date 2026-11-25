// 목차 — 문서의 제목들. 코드 블록 안의 `# `는 제목이 아니다(구문 트리가 가린다).

import type { EditorState } from "@codemirror/state";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { frontMatterSpan } from "./blocks.ts";

export interface Heading {
  level: number;
  title: string;
  /** 제목 줄의 시작. */
  from: number;
}

export function outline(state: EditorState, timeout = 200): Heading[] {
  const tree = ensureSyntaxTree(state, state.doc.length, timeout) ?? syntaxTree(state);
  const headings: Heading[] = [];
  // 앞머리(YAML)는 건너뛴다 — 마크다운으로 읽으면 `key: 값` 줄 밑의 닫는 `---`가 제목 밑줄(Setext)이 되어 `title: …`이 목차의 첫
  // 제목이 됐고, 다른 이름으로 저장할 때의 이름(첫 제목)도 그것이었다.
  const front = frontMatterSpan(state.doc);
  tree.iterate({
    from: front ? front.to + 1 : 0,
    enter(node) {
      if (front && node.from <= front.to) return node.name === "Document" ? undefined : false;
      const atx = /^ATXHeading([1-6])$/.exec(node.name);
      const setext = /^SetextHeading([12])$/.exec(node.name);
      if (!atx && !setext) return;
      const line = state.doc.lineAt(node.from);
      const raw = atx ? line.text.replace(/^\s{0,3}#{1,6}\s*/, "").replace(/\s+#+\s*$/, "") : line.text.trim();
      headings.push({ level: Number((atx ?? setext)![1]), title: raw.trim(), from: line.from });
      return false;
    },
  });
  return headings;
}
