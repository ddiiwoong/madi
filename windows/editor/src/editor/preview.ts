// 라이브 프리뷰 — `core/marks.ts`가 뽑은 규칙을 CodeMirror 장식으로 단다. 보이는 구간만 센다.

import type { Range } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import { caretLines, previewMarks } from "../core/marks.ts";

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
