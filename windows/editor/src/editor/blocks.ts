// 블록을 그림으로 — `core/blocks.ts`가 찾은 앞머리 · 표 · 다이어그램 · 수식 · 그림을 위젯으로 갈아 끼운다. 캐럿(선택)이 블록에 닿으면
// 원문이 보인다(macOS판과 같은 약속). 위젯을 누르면 캐럿이 그 블록으로 들어간다 — 곧 원문이 된다.
//
// 줄을 통째로 갈아 끼우는 장식(`block: true`)은 ViewPlugin이 아니라 StateField가 내야 한다(CodeMirror의 규칙).

import { Facet, StateEffect, StateField, type EditorState, type Range, type Transaction } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import { renderedBlocks, type RenderedBlock } from "../core/blocks.ts";
import type { FrontMatterField } from "../core/frontmatter.ts";
import type { Table } from "../core/table.ts";
import { inlineHtml } from "../core/inline.ts";
import { imageSource } from "../core/image.ts";
import { cachedDiagram, renderDiagram, type DiagramKind, type DiagramResult } from "./diagrams.ts";

export interface BlockEnv {
  dark: boolean;
  loadsRemoteImages: boolean;
  collapsesFrontMatter: boolean;
  /**
   * PDF · 프린트로 내보내는 중 — 캐럿이 어디 있든 모두 그림으로(캐럿 줄의 표식도 숨긴다), 메타데이터는 내보내지 않는다(macOS판
   * `isRenderingForOutput`과 같다). 색은 그동안 흰 종이의 기본 테마다(`main.ts`).
   */
  output: boolean;
}

export const blockEnv = Facet.define<BlockEnv, BlockEnv>({
  combine: (values) => values[0] ?? { dark: false, loadsRemoteImages: false, collapsesFrontMatter: false, output: false },
});

/** 편집기 밖의 일 — 링크 열기, 로컬 그림 읽기(껍데기가 한다). main.ts가 채운다. */
export const blockServices = {
  openUrl: (_url: string) => {},
  loadImage: (_path: string): Promise<string> => Promise.reject(new Error("그림을 읽을 수 없습니다")),
};

/** 앞머리 카드를 접고 편다 — 사람이 머리 줄을 누를 때. */
export const setFrontMatterCollapsed = StateEffect.define<boolean>();

// MARK: 위젯

/** 누르면 그 블록으로 캐럿을 넣는다. 단추 · 링크 · 스크롤 막대는 제 일을 한다. */
function enterOnPress(dom: HTMLElement, view: EditorView): void {
  dom.addEventListener("mousedown", (event) => {
    if (event.button !== 0) return;
    const target = event.target as HTMLElement;
    const link = target.closest<HTMLElement>("a[data-url]");
    if (link && event.ctrlKey) {
      event.preventDefault();
      blockServices.openUrl(link.dataset.url!);
      return;
    }
    if (target.closest("button")) return;
    // 가로 스크롤 막대를 누른 것(넓은 표) — 칸이 아니라 그릇이 받는다.
    if (target.classList.contains("md-table-scroll") && event.offsetY > target.clientHeight) return;
    event.preventDefault();
    const pos = view.posAtDOM(dom);
    view.dispatch({ selection: { anchor: pos }, scrollIntoView: false, userEvent: "select.pointer" });
    view.focus();
  });
}

function block(kind: string): HTMLDivElement {
  const dom = document.createElement("div");
  dom.className = `md-block md-${kind}`;
  dom.dataset.kind = kind;
  return dom;
}

const visibleListItems = 8;

class FrontMatterWidget extends WidgetType {
  readonly fields: FrontMatterField[];
  readonly collapsed: boolean;
  private readonly json: string;
  constructor(fields: FrontMatterField[], collapsed: boolean) {
    super();
    this.fields = fields;
    this.collapsed = collapsed;
    this.json = JSON.stringify(fields);
  }
  override eq(other: FrontMatterWidget): boolean {
    return other.json === this.json && other.collapsed === this.collapsed;
  }
  toDOM(view: EditorView): HTMLElement {
    // 바깥(`.md-block`)은 자리만, 테두리 · 바탕은 안쪽 카드 — 바깥에 margin을 두면 CodeMirror가 높이를 잘못 잰다(style.css).
    const dom = block("frontmatter");
    dom.dataset.state = "ready";
    const card = document.createElement("div");
    card.className = "md-card";
    dom.append(card);
    const head = document.createElement("button");
    head.type = "button";
    head.className = "md-card-head";
    head.setAttribute("aria-expanded", String(!this.collapsed));
    head.textContent = `${this.collapsed ? "▸" : "▾"} 문서 메타데이터 · ${this.fields.length}개 항목`;
    head.addEventListener("mousedown", (event) => event.preventDefault());
    head.addEventListener("click", () => view.dispatch({ effects: setFrontMatterCollapsed.of(!this.collapsed) }));
    card.append(head);
    if (this.collapsed) return dom;
    const grid = document.createElement("dl");
    grid.className = "md-card-grid";
    for (const field of this.fields) {
      const key = document.createElement("dt");
      key.textContent = field.key;
      const value = document.createElement("dd");
      if (field.value.kind === "scalar") {
        value.innerHTML = inlineHtml(field.value.text);
      } else {
        const chips = field.value.items.map((item) => {
          const chip = document.createElement("span");
          chip.className = "md-chip";
          chip.innerHTML = inlineHtml(item);
          return chip;
        });
        value.append(...chips);
        const hidden = chips.slice(visibleListItems);
        if (hidden.length > 0) {
          for (const chip of hidden) chip.hidden = true;
          const more = document.createElement("button");
          more.type = "button";
          more.className = "md-chip-more";
          const collapsedLabel = `외 ${hidden.length}개`;
          more.textContent = collapsedLabel;
          more.addEventListener("mousedown", (event) => event.preventDefault());
          more.addEventListener("click", () => {
            const expand = hidden[0]!.hidden;
            for (const chip of hidden) chip.hidden = !expand;
            more.textContent = expand ? "접기" : collapsedLabel;
            view.requestMeasure();
          });
          value.append(more);
        }
      }
      grid.append(key, value);
    }
    card.append(grid);
    enterOnPress(dom, view);
    return dom;
  }
  override ignoreEvent(): boolean {
    return true;
  }
}

class TableWidget extends WidgetType {
  readonly table: Table;
  private readonly json: string;
  constructor(table: Table) {
    super();
    this.table = table;
    this.json = JSON.stringify(table);
  }
  override eq(other: TableWidget): boolean {
    return other.json === this.json;
  }
  override get estimatedHeight(): number {
    return (this.table.rows.length + 1) * 34;
  }
  toDOM(view: EditorView): HTMLElement {
    const dom = block("table");
    dom.dataset.state = "ready";
    const scroll = document.createElement("div");
    scroll.className = "md-table-scroll";
    const table = document.createElement("table");
    const cell = (tag: "th" | "td", text: string, column: number) => {
      const element = document.createElement(tag);
      element.innerHTML = inlineHtml(text);
      const align = this.table.align[column];
      if (align) element.style.textAlign = align;
      return element;
    };
    const head = document.createElement("thead");
    const headRow = document.createElement("tr");
    this.table.header.forEach((text, column) => headRow.append(cell("th", text, column)));
    head.append(headRow);
    const body = document.createElement("tbody");
    for (const row of this.table.rows) {
      const tr = document.createElement("tr");
      row.forEach((text, column) => tr.append(cell("td", text, column)));
      body.append(tr);
    }
    table.append(head, body);
    scroll.append(table);
    dom.append(scroll);
    enterOnPress(dom, view);
    return dom;
  }
  override ignoreEvent(): boolean {
    return true;
  }
}

class DiagramWidget extends WidgetType {
  readonly kind: DiagramKind;
  readonly source: string;
  readonly dark: boolean;
  constructor(kind: DiagramKind, source: string, dark: boolean) {
    super();
    this.kind = kind;
    this.source = source;
    // 수식은 글자색을 물려받는다 — 다크가 바뀌어도 다시 그리지 않는다.
    this.dark = kind === "mermaid" && dark;
  }
  override eq(other: DiagramWidget): boolean {
    return other.kind === this.kind && other.source === this.source && other.dark === this.dark;
  }
  override get estimatedHeight(): number {
    return this.kind === "math" ? 60 : 240;
  }
  toDOM(view: EditorView): HTMLElement {
    const dom = block(this.kind);
    const fill = (result: DiagramResult) => {
      if (result.ok) {
        dom.innerHTML = result.html;
        dom.dataset.state = "ready";
      } else {
        const title = document.createElement("div");
        title.className = "md-block-error-title";
        title.textContent = this.kind === "math" ? "수식을 그리지 못했습니다" : "다이어그램을 그리지 못했습니다";
        const detail = document.createElement("pre");
        detail.className = "md-block-error";
        detail.textContent = result.message;
        // 테두리 · 바탕은 안쪽 상자에 — 바깥(`.md-block`)은 padding뿐이어야 높이를 바르게 잰다(style.css).
        const box = document.createElement("div");
        box.className = "md-error-box";
        box.append(title, detail);
        dom.replaceChildren(box);
        dom.dataset.state = "error";
      }
    };
    const cached = cachedDiagram(this.kind, this.source, this.dark);
    if (cached) fill(cached);
    else {
      dom.dataset.state = "pending";
      dom.textContent = this.kind === "math" ? "수식을 그리는 중…" : "다이어그램을 그리는 중…";
      void renderDiagram(this.kind, this.source, this.dark).then((result) => {
        fill(result);
        view.requestMeasure();
      });
    }
    enterOnPress(dom, view);
    return dom;
  }
  override ignoreEvent(): boolean {
    return true;
  }
}

/** 로컬 그림은 껍데기가 읽어 `data:` 주소로 준다. 같은 경로는 한 번만(문서를 새로 열면 비운다). */
const images = new Map<string, Promise<string>>();
/** 받아 둔 것 — 위젯을 다시 만들 때(내보내기에서 문서 전체를 그릴 때) 기다리지 않고 바로 채운다. */
const loadedImages = new Map<string, string>();

export function forgetImages(): void {
  images.clear();
  loadedImages.clear();
}

class ImageWidget extends WidgetType {
  readonly src: string;
  readonly alt: string;
  readonly remote: boolean;
  constructor(src: string, alt: string, remote: boolean) {
    super();
    this.src = src;
    this.alt = alt;
    this.remote = remote;
  }
  override eq(other: ImageWidget): boolean {
    return other.src === this.src && other.alt === this.alt && other.remote === this.remote;
  }
  override get estimatedHeight(): number {
    return 200;
  }
  toDOM(view: EditorView): HTMLElement {
    const dom = block("image");
    const note = (text: string, state: "blocked" | "error") => {
      const span = document.createElement("span");
      span.className = "md-image-note";
      span.textContent = `${this.alt ? `${this.alt} — ` : ""}${text}`;
      dom.replaceChildren(span);
      dom.dataset.state = state;
    };
    const show = (url: string) => {
      const image = document.createElement("img");
      image.alt = this.alt;
      image.decoding = "async";
      image.addEventListener("load", () => {
        dom.dataset.state = "ready";
        view.requestMeasure();
      });
      image.addEventListener("error", () => note("그림을 보일 수 없습니다", "error"));
      image.src = url;
      dom.replaceChildren(image);
    };
    dom.dataset.state = "pending";
    const source = imageSource(this.src);
    if (!source) note(`쓸 수 없는 주소입니다: ${this.src}`, "error");
    else if (source.kind === "remote") {
      if (this.remote) show(source.url);
      else note("원격 그림은 받지 않습니다(명령 팔레트 › 원격 그림 받기)", "blocked");
    } else if (loadedImages.has(source.path)) {
      show(loadedImages.get(source.path)!);
    } else {
      let pending = images.get(source.path);
      if (!pending) {
        pending = blockServices.loadImage(source.path);
        images.set(source.path, pending);
        pending.then((url) => loadedImages.set(source.path, url), () => images.delete(source.path));
      }
      pending.then(show, (error: unknown) => note(error instanceof Error ? error.message : String(error), "error"));
    }
    enterOnPress(dom, view);
    return dom;
  }
  override ignoreEvent(): boolean {
    return true;
  }
}

// MARK: 장식

function touches(state: EditorState, block: RenderedBlock): boolean {
  return state.selection.ranges.some((range) => range.from <= block.to && range.to >= block.from);
}

function widgetFor(block: RenderedBlock, env: BlockEnv, collapsed: boolean): WidgetType {
  switch (block.kind) {
    case "frontmatter":
      return new FrontMatterWidget(block.fields, collapsed);
    case "table":
      return new TableWidget(block.table);
    case "mermaid":
    case "math":
      return new DiagramWidget(block.kind, block.source, env.dark);
    case "image":
      return new ImageWidget(block.src, block.alt, env.loadsRemoteImages);
  }
}

interface BlockState {
  blocks: RenderedBlock[];
  decorations: DecorationSet;
  collapsed: boolean;
}

const hiddenBlock = Decoration.replace({ block: true });

function decorate(state: EditorState, blocks: RenderedBlock[], collapsed: boolean): DecorationSet {
  const env = state.facet(blockEnv);
  const ranges: Range<Decoration>[] = [];
  for (const block of blocks) {
    if (env.output) {
      ranges.push(block.kind === "frontmatter"
        ? hiddenBlock.range(block.from, block.to)
        : Decoration.replace({ widget: widgetFor(block, env, collapsed), block: true }).range(block.from, block.to));
      continue;
    }
    if (touches(state, block)) continue;
    ranges.push(Decoration.replace({ widget: widgetFor(block, env, collapsed), block: true }).range(block.from, block.to));
  }
  return Decoration.set(ranges);
}

function needsBlocks(tr: Transaction): boolean {
  return tr.docChanged || tr.reconfigured || syntaxTree(tr.startState) !== syntaxTree(tr.state);
}

export const renderedBlockField = StateField.define<BlockState>({
  create(state) {
    const blocks = renderedBlocks(state);
    const collapsed = state.facet(blockEnv).collapsesFrontMatter;
    return { blocks, collapsed, decorations: decorate(state, blocks, collapsed) };
  },
  update(value, tr) {
    let { blocks, collapsed } = value;
    for (const effect of tr.effects) if (effect.is(setFrontMatterCollapsed)) collapsed = effect.value;
    if (tr.startState.facet(blockEnv).collapsesFrontMatter !== tr.state.facet(blockEnv).collapsesFrontMatter) {
      collapsed = tr.state.facet(blockEnv).collapsesFrontMatter;
    }
    const reparsed = needsBlocks(tr);
    if (reparsed) blocks = renderedBlocks(tr.state);
    if (!reparsed && !tr.selection && collapsed === value.collapsed) return value;
    return { blocks, collapsed, decorations: decorate(tr.state, blocks, collapsed) };
  },
  provide: (field) => EditorView.decorations.from(field, (value) => value.decorations),
});

/** 확인 실행이 보는 것 — 그림으로 바꾼 블록 수(종류별) · 그린 상태. */
export function blockReport(view: EditorView): { kinds: Record<string, number>; states: Record<string, number>; errors: string[] } {
  const kinds: Record<string, number> = {};
  const states: Record<string, number> = {};
  const errors: string[] = [];
  for (const dom of view.dom.querySelectorAll<HTMLElement>(".md-block")) {
    const kind = dom.dataset.kind ?? "?";
    kinds[kind] = (kinds[kind] ?? 0) + 1;
    const state = dom.dataset.state ?? "?";
    states[state] = (states[state] ?? 0) + 1;
    if (state === "error") errors.push(`${kind}: ${dom.textContent ?? ""}`.slice(0, 300));
  }
  return { kinds, states, errors };
}
