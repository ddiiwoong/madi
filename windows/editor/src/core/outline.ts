// 목차 — 문서의 제목들. 코드 블록 안의 `# `는 제목이 아니다(구문 트리가 가린다).

import type { EditorState } from "@codemirror/state";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";

export interface Heading {
  level: number;
  title: string;
  /** 제목 줄의 시작. */
  from: number;
}

export function outline(state: EditorState, timeout = 200): Heading[] {
  const tree = ensureSyntaxTree(state, state.doc.length, timeout) ?? syntaxTree(state);
  const headings: Heading[] = [];
  tree.iterate({
    enter(node) {
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
