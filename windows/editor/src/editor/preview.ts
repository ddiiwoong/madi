// 라이브 프리뷰 — `core/marks.ts`가 뽑은 규칙을 CodeMirror 장식으로 단다. 보이는 구간만 센다.

import type { Range } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import { caretLines, previewMarks, taskToggle, type AlertKind } from "../core/marks.ts";

const bulletGlyphs = ["●", "○", "■"];

class BulletWidget extends WidgetType {
  readonly depth: number;
  constructor(depth: number) {
    super();
    this.depth = depth;
  }
  override eq(other: BulletWidget): boolean {
    return other.depth === this.depth;
  }
  toDOM(): HTMLElement {
    const span = document.createElement("span");
    span.className = "cm-md-bullet";
    span.textContent = bulletGlyphs[this.depth % bulletGlyphs.length]!;
    return span;
  }
}

class RuleWidget extends WidgetType {
  override eq(): boolean {
    return true;
  }
  toDOM(): HTMLElement {
    const span = document.createElement("span");
    span.className = "cm-md-rule";
    return span;
  }
}

/** 할 일 상자 — 누르면 `[ ]` ↔ `[x]`(파일의 글자 하나를 바꾼다). 고칠 수 없는 보기(따라 보기)에서는 누르지 않는다. */
class TaskWidget extends WidgetType {
  readonly checked: boolean;
  constructor(checked: boolean) {
    super();
    this.checked = checked;
  }
  override eq(other: TaskWidget): boolean {
    return other.checked === this.checked;
  }
  toDOM(view: EditorView): HTMLElement {
    const box = document.createElement("span");
    box.className = `cm-md-task${this.checked ? " cm-md-task-done" : ""}`;
    box.setAttribute("role", "checkbox");
    box.setAttribute("aria-checked", String(this.checked));
    box.textContent = this.checked ? "✓" : "";
    box.addEventListener("mousedown", (event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      if (view.state.readOnly) return;
      const pos = view.posAtDOM(box);
      const change = taskToggle(view.state.sliceDoc(pos, pos + 3), pos);
      if (change) view.dispatch({ changes: change, userEvent: "input.toggle" });
    });
    return box;
  }
  override ignoreEvent(): boolean {
    return true;
  }
}

const alertTitles: Record<AlertKind, string> = { note: "Note", tip: "Tip", important: "Important", warning: "Warning", caution: "Caution" };

/** 알림 인용의 표식(`[!NOTE]`) 자리에 제목(`Note`). GitHub처럼 첫 글자만 크게. */
class AlertTitleWidget extends WidgetType {
  readonly kind: AlertKind;
  constructor(kind: AlertKind) {
    super();
    this.kind = kind;
  }
  override eq(other: AlertTitleWidget): boolean {
    return other.kind === this.kind;
  }
  toDOM(): HTMLElement {
    const span = document.createElement("span");
    span.className = `cm-md-alert-title cm-md-alert-${this.kind}`;
    span.textContent = alertTitles[this.kind];
    return span;
  }
}

const hidden = Decoration.replace({});
const rule = Decoration.replace({ widget: new RuleWidget() });

function decorations(view: EditorView): DecorationSet {
  const ranges: Range<Decoration>[] = [];
  for (const mark of previewMarks(view.state, view.visibleRanges, caretLines(view.state))) {
    switch (mark.type) {
      case "hide":
        ranges.push(hidden.range(mark.from, mark.to));
        break;
      case "inline":
        ranges.push(Decoration.mark({ class: `cm-md-${mark.style}` }).range(mark.from, mark.to));
        break;
      case "line":
        ranges.push(Decoration.line({ class: `cm-md-line-${mark.style}` }).range(mark.at));
        break;
      case "bullet":
        ranges.push(Decoration.replace({ widget: new BulletWidget(mark.depth) }).range(mark.from, mark.to));
        break;
      case "rule":
        ranges.push(rule.range(mark.from, mark.to));
        break;
      case "task":
        ranges.push(Decoration.replace({ widget: new TaskWidget(mark.checked) }).range(mark.from, mark.to));
        break;
      case "alertTitle":
        ranges.push(Decoration.replace({ widget: new AlertTitleWidget(mark.kind) }).range(mark.from, mark.to));
        break;
    }
  }
  return Decoration.set(ranges, true);
}

export const livePreview = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    count = 0;
    constructor(view: EditorView) {
      this.decorations = decorations(view);
      this.count = this.decorations.size;
    }
    update(update: ViewUpdate) {
      if (
        update.docChanged || update.viewportChanged || update.selectionSet
        || syntaxTree(update.startState) !== syntaxTree(update.state)
      ) {
        this.decorations = decorations(update.view);
        this.count = this.decorations.size;
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

/** 그 자리의 링크 주소 — Ctrl+클릭이 연다. */
export function linkAt(view: EditorView, pos: number): string | null {
  for (let node: ReturnType<typeof syntaxTree>["topNode"] | null = syntaxTree(view.state).resolveInner(pos, 1); node; node = node.parent) {
    if (node.name === "Link" || node.name === "Autolink") {
      const url = node.getChild("URL");
      return url ? view.state.sliceDoc(url.from, url.to) : null;
    }
  }
  return null;
}
