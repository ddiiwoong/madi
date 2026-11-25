// 라이브 프리뷰의 규칙 — 구문 트리에서 숨길 표식 · 꾸밀 글 · 줄의 꼴을 뽑는다. DOM 없이 돌아 Node로 시험한다.
// 화면에 다는 일은 `editor/preview.ts`가 한다(CodeMirror 장식).
//
// macOS판과 같은 약속: **캐럿이 있는 줄은 원문 그대로** 보인다(표식을 숨기지 않는다). 그래야 그 줄의 구조를 고칠 수 있다.
// 꾸밈(굵게 · 제목 크기 …)은 캐럿 줄에서도 남긴다 — 표식만 드러난다.

import type { EditorState } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";

export type InlineStyle = "strong" | "emphasis" | "strike" | "code" | "link" | "done";
export type AlertKind = "note" | "tip" | "important" | "warning" | "caution";
export type LineStyle =
  | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "quote" | "code" | "fence"
  | `alert-${AlertKind}`;

export type PreviewMark =
  | { type: "hide"; from: number; to: number }
  | { type: "inline"; from: number; to: number; style: InlineStyle; url?: string }
  | { type: "line"; at: number; style: LineStyle }
  /** 글머리 표(`-` `*` `+`)를 ● ○ ■로 — 깊이마다(macOS판과 같다). */
  | { type: "bullet"; from: number; to: number; depth: number }
  /** 구분선(`---`)을 선 하나로. */
  | { type: "rule"; from: number; to: number }
  /** 할 일 `[ ]` · `[x]`를 누를 수 있는 상자로. 글머리 `- `는 숨긴다(상자만 — macOS판과 같다). */
  | { type: "task"; from: number; to: number; checked: boolean }
  /** 알림 인용(`> [!NOTE]`)의 표식을 제목(`Note`)으로. */
  | { type: "alertTitle"; from: number; to: number; kind: AlertKind };

/** 알림 인용의 첫 줄 내용(`>` 뒤)이 표식인가 — GitHub와 같다. macOS판 `GithubAlert.marker`. */
export function alertKind(content: string): AlertKind | null {
  const match = /^\s*\\?\[\\?!(note|tip|important|warning|caution)\\?\]\s*$/i.exec(content);
  return match ? (match[1]!.toLowerCase() as AlertKind) : null;
}

/** 할 일 상자를 뒤집는 바꿈 — 상자 안의 글자 하나. */
export function taskToggle(marker: string, from: number): { from: number; to: number; insert: string } | null {
  if (!/^\[[ xX]\]$/.test(marker)) return null;
  return { from: from + 1, to: from + 2, insert: marker[1] === " " ? "x" : " " };
}

export interface Range {
  from: number;
  to: number;
}

/** 선택이 닿은 줄의 번호들(1부터) — 그 줄들은 원문 그대로. */
export function caretLines(state: EditorState): Set<number> {
  const lines = new Set<number>();
  for (const range of state.selection.ranges) {
    const first = state.doc.lineAt(range.from).number;
    const last = state.doc.lineAt(range.to).number;
    for (let line = first; line <= last; line++) lines.add(line);
  }
  return lines;
}

export function previewMarks(state: EditorState, ranges: readonly Range[], caret: Set<number>): PreviewMark[] {
  const doc = state.doc;
  const marks: PreviewMark[] = [];
  const onCaretLine = (pos: number) => caret.has(doc.lineAt(pos).number);
  const hide = (from: number, to: number) => {
    if (to > from && !onCaretLine(from)) marks.push({ type: "hide", from, to });
  };
  const lineStyle = (from: number, to: number, style: LineStyle) => {
    for (let pos = from; pos <= to; ) {
      const line = doc.lineAt(pos);
      marks.push({ type: "line", at: line.from, style });
      pos = line.to + 1;
    }
  };
  const tree = syntaxTree(state);

  for (const { from, to } of ranges) {
    tree.iterate({
      from,
      to,
      enter(node) {
        const name = node.name;
        const heading = /^(?:ATX|Setext)Heading([1-6])$/.exec(name);
        if (heading) {
          lineStyle(node.from, node.from, `h${heading[1]}` as LineStyle);
          return;
        }
        switch (name) {
          case "HeaderMark": {
            if (node.node.parent?.name.startsWith("Setext")) return;
            const line = doc.lineAt(node.from);
            const leading = node.from - line.from <= 3 && /^\s*$/.test(doc.sliceString(line.from, node.from));
            if (leading) {
              // `# ` — 표식과 뒤의 띄어쓰기 하나.
              hide(node.from, doc.sliceString(node.to, node.to + 1) === " " ? node.to + 1 : node.to);
            } else {
              // 닫는 `#`들 — 앞의 띄어쓰기까지.
              hide(doc.sliceString(node.from - 1, node.from) === " " ? node.from - 1 : node.from, node.to);
            }
            return;
          }
          case "StrongEmphasis":
            marks.push({ type: "inline", from: node.from, to: node.to, style: "strong" });
            return;
          case "Emphasis":
            marks.push({ type: "inline", from: node.from, to: node.to, style: "emphasis" });
            return;
          case "Strikethrough":
            marks.push({ type: "inline", from: node.from, to: node.to, style: "strike" });
            return;
          case "InlineCode":
            marks.push({ type: "inline", from: node.from, to: node.to, style: "code" });
            return;
          case "EmphasisMark":
          case "StrikethroughMark":
            hide(node.from, node.to);
            return;
          case "CodeMark":
            if (node.node.parent?.name === "InlineCode") hide(node.from, node.to);
            return;
          case "Link":
          case "Autolink": {
            const children: { name: string; from: number; to: number }[] = [];
            for (let child = node.node.firstChild; child; child = child.nextSibling) {
              children.push({ name: child.name, from: child.from, to: child.to });
            }
            const url = children.find((child) => child.name === "URL");
            const marksOnly = children.filter((child) => child.name === "LinkMark");
            if (name === "Autolink") {
              if (url) marks.push({ type: "inline", from: url.from, to: url.to, style: "link", url: doc.sliceString(url.from, url.to) });
              for (const mark of marksOnly) hide(mark.from, mark.to);
              return false;
            }
            const open = marksOnly[0];
            const close = marksOnly[1];
            if (!open || !close || open.from !== node.from) return;
            marks.push({
              type: "inline",
              from: open.to,
              to: close.from,
              style: "link",
              ...(url ? { url: doc.sliceString(url.from, url.to) } : {}),
            });
            hide(open.from, open.to);
            hide(close.from, node.to);
            // 글 안의 굵게 · 기울임은 보되, 주소 쪽 자식(LinkMark · URL · LinkTitle)은 위에서 다뤘다.
            return;
          }
          case "LinkMark":
          case "URL":
          case "LinkTitle":
            return false;
          case "Blockquote": {
            // 알림 인용 — 첫 줄이 `[!NOTE]`이면 그 종류의 색으로, 표식은 제목으로 바꾼다.
            const first = doc.lineAt(node.from);
            const quoteMark = /^\s*>\s?/.exec(first.text);
            const kind = quoteMark ? alertKind(first.text.slice(quoteMark[0].length)) : null;
            lineStyle(node.from, node.to, kind ? `alert-${kind}` : "quote");
            if (kind && quoteMark && !onCaretLine(first.from)) {
              const at = first.from + quoteMark[0].length;
              marks.push({ type: "alertTitle", from: at, to: first.to, kind });
            }
            return;
          }
          case "QuoteMark":
            hide(node.from, doc.sliceString(node.to, node.to + 1) === " " ? node.to + 1 : node.to);
            return;
          case "FencedCode": {
            lineStyle(node.from, node.to, "code");
            // 캐럿이 블록에 닿지 않으면 울타리(```)를 숨긴다 — 여는 줄에는 언어 이름만 흐리게, 닫는 줄은 빈 줄(블록의 아래 여백)로
            // 남는다(macOS판과 같다). 블록 안에 캐럿이 있으면 원문 그대로 — 울타리를 고칠 수 있게.
            const first = doc.lineAt(node.from).number;
            const last = doc.lineAt(node.to).number;
            let touched = false;
            for (let line = first; line <= last && !touched; line++) touched = caret.has(line);
            if (!touched) {
              for (const fence of node.node.getChildren("CodeMark")) marks.push({ type: "hide", from: fence.from, to: fence.to });
            }
            return;
          }
          case "CodeInfo":
            return;
          case "ListMark": {
            const item = node.node.parent;
            const list = item?.parent;
            if (item?.getChild("Task")) {
              // 할 일 — 글머리는 숨기고 상자만.
              hide(node.from, doc.sliceString(node.to, node.to + 1) === " " ? node.to + 1 : node.to);
              return;
            }
            if (list?.name !== "BulletList" || onCaretLine(node.from)) return;
            let depth = 0;
            for (let up: typeof list | null = list; up; up = up.parent) if (up.name === "BulletList" || up.name === "OrderedList") depth++;
            marks.push({ type: "bullet", from: node.from, to: node.to, depth: depth - 1 });
            return;
          }
          case "TaskMarker": {
            const marker = doc.sliceString(node.from, node.to);
            const checked = /x/i.test(marker);
            if (!onCaretLine(node.from)) marks.push({ type: "task", from: node.from, to: node.to, checked });
            if (checked) {
              // 끝낸 일은 흐리게 · 줄을 긋는다 — 상자 뒤의 글.
              const line = doc.lineAt(node.from);
              if (node.to + 1 < line.to) marks.push({ type: "inline", from: node.to + 1, to: line.to, style: "done" });
            }
            return;
          }
          case "HorizontalRule":
            if (!onCaretLine(node.from)) marks.push({ type: "rule", from: node.from, to: node.to });
            return;
        }
        return;
      },
    });
  }

  // 펜스 줄(```)은 흐리게 — 코드 블록의 첫 줄 · 끝 줄. 펜스를 숨기면 빈 줄이 남는다.
  for (const { from, to } of ranges) {
    tree.iterate({
      from,
      to,
      enter(node) {
        if (node.name === "CodeMark" && node.node.parent?.name === "FencedCode") {
          marks.push({ type: "line", at: doc.lineAt(node.from).from, style: "fence" });
        }
      },
    });
  }
  // 보이는 구간이 둘 이상이면 걸친 마디(코드 블록 · 인용)가 두 번 나온다 — 하나만 남긴다.
  const seen = new Set<string>();
  return marks.filter((mark) => {
    const key = JSON.stringify(mark);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
