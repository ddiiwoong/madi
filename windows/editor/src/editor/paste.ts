// 서식 있는 글 붙여 넣기 — 클립보드에 HTML이 있으면 마크다운으로 옮겨 넣는다(`core/richpaste.ts`). 옮길 것이 없으면 CodeMirror가 하던
// 대로 글만. Ctrl+Shift+V는 늘 글만(서식 없이 붙여넣기 — Windows 앱들의 약속, Chromium의 "일반 텍스트로 붙여넣기"와 같은 키).
//
// 글로만 붙이는 자리: 코드 블록 · 인라인 코드 · HTML 블록 · 앞머리 안(코드에 `**`가 끼면 안 된다), 마크다운이 아닌 파일(.txt · .log).
// 표의 줄 안에는 한 줄 글만(`|`는 이스케이프) — 여러 줄이면 표가 깨지므로 글만.

import { EditorSelection, type EditorState, type Extension } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import type { SyntaxNode } from "@lezer/common";
import { htmlToMarkdown, placePasted } from "../core/richpaste.ts";
import { frontMatterSpan } from "../core/blocks.ts";
import { normalizeLineBreaks } from "../core/lines.ts";

const codeNodes = new Set(["FencedCode", "CodeBlock", "InlineCode", "HTMLBlock", "CommentBlock"]);

type Where = "code" | "table" | "text";

function placeOf(state: EditorState): Where {
  const front = frontMatterSpan(state.doc);
  const tree = syntaxTree(state);
  let where: Where = "text";
  for (const range of state.selection.ranges) {
    if (front && range.from <= front.to && range.to >= front.from) return "code";
    for (let node: SyntaxNode | null = tree.resolveInner(range.from, -1); node; node = node.parent) {
      if (codeNodes.has(node.name)) return "code";
      if (node.name === "Table") where = "table";
    }
  }
  return where;
}

/** 옮긴 마크다운을 고른 자리마다. 블록은 제 줄에(`placePasted`), 줄 끝은 문서의 것으로. */
export function insertMarkdown(view: EditorView, markdown: string): void {
  const { state } = view;
  const transaction = state.changeByRange((range) => {
    const before = state.doc.sliceString(state.doc.lineAt(range.from).from, range.from);
    const after = state.doc.sliceString(range.to, state.doc.lineAt(range.to).to);
    const insert = state.toText(normalizeLineBreaks(placePasted(markdown, before, after), state.lineBreak));
    return { changes: { from: range.from, to: range.to, insert }, range: EditorSelection.cursor(range.from + insert.length) };
  });
  view.dispatch(state.update(transaction, { userEvent: "input.paste", scrollIntoView: true }));
}

/** 마크다운 문서일 때만(`isMarkdown`) — 글 파일 · 로그에 마크다운 표식을 넣지 않는다. */
export function richPaste(isMarkdown: () => boolean): Extension {
  let plainOnly = false;
  return EditorView.domEventHandlers({
    keydown(event) {
      // Ctrl+Shift+V — 이 키가 일으키는 붙여 넣기는 같은 차례 안에 온다. 오지 않았으면(클립보드가 비었다) 다음 Ctrl+V까지 끌지 않는다.
      if (event.ctrlKey && event.shiftKey && !event.altKey && event.code === "KeyV") {
        plainOnly = true;
        setTimeout(() => {
          plainOnly = false;
        }, 0);
      }
      return false;
    },
    paste(event, view) {
      if (plainOnly) {
        plainOnly = false;
        return false;
      }
      const html = event.clipboardData?.getData("text/html") ?? "";
      if (html === "" || !isMarkdown() || view.state.readOnly) return false;
      const where = placeOf(view.state);
      if (where === "code") return false;
      // DOMParser의 문서는 그리지 않는 문서다 — 스크립트가 돌지 않고 그림도 받지 않는다.
      let markdown = htmlToMarkdown(new DOMParser().parseFromString(html, "text/html").body);
      if (markdown === null) return false;
      if (where === "table") {
        if (markdown.includes("\n")) return false;
        markdown = markdown.replace(/(?<!\\)\|/g, "\\|");
      }
      event.preventDefault();
      insertMarkdown(view, markdown);
      return true;
    },
  });
}
