// 서식 있는 글을 마크다운으로 — 다른 앱(Word · 한글 · Google 문서 · 웹 페이지 · Excel)에서 복사한 것을 붙여 넣을 때(사용자 — "외부
// 서식있는 문서를 복사하면 다 풀려서 붙여짐"). 클립보드의 HTML(`text/html`)을 읽어 제목 · 목록(할 일 포함) · 인용 · 표 · 코드 · 구분선 ·
// 굵게 · 기울임 · 취소선 · 인라인 코드 · 링크 · 그림(웹 주소만)을 마크다운으로 옮긴다. 밑줄 · 색 · 크기는 마크다운에 없어 버린다.
//
// 옮기지 않고 null을 돌려주는 때 — 그러면 늘 하던 대로 글(`text/plain`)만 붙는다:
// - 서식이 하나도 없다(그냥 글). 옮기면 `*` 같은 글자에 `\`만 붙는다.
// - 코드 편집기(VS Code · Visual Studio · JetBrains · 터미널)에서 복사했다 — 색만 입힌 고정폭 글 한 덩이다.
//
// DOM을 바로 받지 않고 그 일부(`PasteNode`)만 본다 — 편집기는 `DOMParser`의 문서를, 시험은 `@lezer/html`로 지은 나무를 준다.
// 굵게 · 기울임은 태그와 인라인 스타일을 함께 본다: Google 문서는 `<span style="font-weight:700">`으로 굵게 하고 전체를
// `<b style="font-weight:normal">`로 감싼다(태그만 보면 다 굵어진다). Word의 목록은 `<ul>`이 아니라 `mso-list` 스타일의 문단이다.

export interface PasteNode {
  readonly nodeType: number;
  readonly nodeName: string;
  readonly nodeValue: string | null;
  readonly childNodes: ArrayLike<PasteNode>;
  getAttribute?(name: string): string | null;
}

const ELEMENT = 1;
const TEXT = 3;

interface Style {
  bold: boolean;
  italic: boolean;
  strike: boolean;
  code: boolean;
  href: string | null;
}

interface Context extends Style {
  /** 굵게를 적지 않는다 — 제목 · 표의 머리 줄은 이미 굵다(Word는 머리 칸의 글을 `<b>`로 감싼다). */
  plainBold: boolean;
  /** 감싼 요소가 알려 준 코드 블록의 언어(GitHub — `<div class="highlight-source-js"><pre>`). */
  language: string | null;
}

type Run =
  | { kind: "text"; text: string; style: Style }
  | { kind: "image"; markdown: string; style: Style }
  | { kind: "break" };

/** Word의 목록 문단 하나 — 이어진 것끼리 모아 목록 하나로 쓴다. */
interface WordItem {
  kind: "word";
  /** Word의 목록 번호(`l0` · `l1`) — 다르면 다른 목록이다(글머리 목록 다음의 번호 목록이 3.부터 이어지지 않게). */
  list: string;
  level: number;
  ordered: boolean;
  text: string;
}

type Entry = string | WordItem;

const SKIP = new Set([
  "head", "style", "script", "noscript", "template", "meta", "link", "title", "iframe", "object", "embed", "svg", "canvas",
  "button", "select", "option", "datalist", "textarea", "input", "video", "audio", "map", "area", "colgroup", "col",
]);
/** 글 덩이를 감싸기만 하는 블록 — 안의 것을 차례로. 표의 칸은 레이아웃 표(메일)를 풀 때만 여기로 온다. */
const CONTAINERS = new Set([
  "html", "body", "div", "p", "section", "article", "main", "header", "footer", "aside", "nav", "figure", "figcaption",
  "address", "center", "details", "summary", "dl", "dt", "dd", "fieldset", "form", "hgroup", "legend", "caption",
  "thead", "tbody", "tfoot", "tr", "td", "th",
]);
const BLOCKS = new Set(["ul", "ol", "li", "blockquote", "pre", "table", "hr", "h1", "h2", "h3", "h4", "h5", "h6"]);
const CODE_TAGS = new Set(["code", "kbd", "samp", "tt"]);
const BASE: Context = { bold: false, italic: false, strike: false, code: false, href: null, plainBold: false, language: null };

/** 붙여 넣을 마크다운. 옮길 것이 없으면(서식 없음 · 코드 편집기에서 복사) null. */
export function htmlToMarkdown(root: PasteNode): string | null {
  if (isCodeCopy(root)) return null;
  const converter = new Converter();
  const text = converter.blocks(root, BASE).join("\n\n").trim();
  return converter.formatted && text !== "" ? text : null;
}

/**
 * 붙여 넣을 자리에 맞춘 글 — 블록(여러 줄 · 제목 · 목록 · 표 …)은 제 줄에 놓는다: 캐럿 앞에 글이 있으면 빈 줄 하나를 두고 시작하고, 뒤에
 * 글이 있으면 빈 줄 하나를 두고 끝낸다. 한 줄 글(굵은 낱말 하나)은 그 자리에 그대로.
 */
export function placePasted(markdown: string, before: string, after: string): string {
  const block = markdown.includes("\n") || /^(#{1,6} |[-+*] |\d+[.)] |> |```|~~~|\| |---$)/.test(markdown);
  if (!block) return markdown;
  return (before.trim() === "" ? "" : "\n\n") + markdown + (after.trim() === "" ? "" : "\n\n");
}

class Converter {
  /** 마크다운 서식을 하나라도 썼는가 — 아니면 옮기지 않는다. */
  formatted = false;

  /** 요소 안의 블록들. 인라인 요소가 블록을 품어도(Google 문서의 `<b>`) 그 스타일을 안고 들어간다. */
  blocks(parent: PasteNode, context: Context): string[] {
    const entries: Entry[] = [];
    let runs: Run[] = [];
    const flush = () => {
      const text = this.paragraph(runs);
      if (text !== "") entries.push(text);
      runs = [];
    };
    const visit = (node: PasteNode, outer: Context): void => {
      if (node.nodeType === TEXT) {
        runs.push({ kind: "text", text: node.nodeValue ?? "", style: styleOf(outer) });
        return;
      }
      if (node.nodeType !== ELEMENT) return;
      const tag = tagOf(node);
      if (SKIP.has(tag) || hidden(node)) return;
      const inner = styled(node, tag, outer);
      if (CONTAINERS.has(tag) || BLOCKS.has(tag)) {
        flush();
        entries.push(...this.block(node, tag, inner));
        return;
      }
      if (tag === "br") {
        runs.push({ kind: "break" });
        return;
      }
      if (tag === "img") {
        const markdown = image(node);
        if (markdown) runs.push({ kind: "image", markdown, style: styleOf(inner) });
        return;
      }
      for (const child of childrenOf(node)) visit(child, inner);
    };
    for (const child of childrenOf(parent)) visit(child, context);
    flush();
    return this.groupWordLists(entries);
  }

  private block(node: PasteNode, tag: string, context: Context): Entry[] {
    const level = /^h([1-6])$/.exec(tag);
    if (level) return this.heading(node, Number(level[1]), context);
    switch (tag) {
      case "ul":
      case "ol":
        return nonEmpty(this.list(node, tag === "ol", context));
      case "li":
        return nonEmpty(this.items([[node]], false, 1, context));
      case "blockquote":
        return nonEmpty(this.quote(node, context));
      case "pre":
        return nonEmpty(this.code(node, context));
      case "table":
        return this.table(node, context);
      case "hr":
        this.formatted = true;
        return ["---"];
    }
    if (tag === "p" || tag === "div") {
      const item = this.wordItem(node, context);
      if (item) return [item];
      if (/\bMsoTitle\b/.test(attr(node, "class") ?? "")) return this.heading(node, 1, context);
    }
    return this.blocks(node, context);
  }

  private heading(node: PasteNode, level: number, context: Context): string[] {
    let text = this.inlineText(node, { ...context, plainBold: true });
    if (text === "") return [];
    // Word의 번호 붙은 제목(`<h1 style="mso-list:l0 level1 lfo1">`) — 번호(`1.` · `1.1` · `가.`)는 표식 칸에 있어 글에서 빠진다. 되살린다.
    const marker = /level\d/i.test(cssOf(node).get("mso-list") ?? "") ? findDescendant(node, isWordMarker) : null;
    const number = marker ? plainText(marker).replace(/[\s\u00a0]+/g, " ").trim() : "";
    if (/[\p{L}\p{N}]/u.test(number)) text = `${number} ${text}`;
    this.formatted = true;
    return [`${"#".repeat(level)} ${text}`];
  }

  /** `<ul>` · `<ol>`. 목록 바로 안의 목록(Google 문서)은 앞 항목의 하위 목록이다. */
  private list(node: PasteNode, ordered: boolean, context: Context): string {
    const items: PasteNode[][] = [];
    for (const child of childrenOf(node)) {
      if (child.nodeType !== ELEMENT) continue;
      const tag = tagOf(child);
      if (SKIP.has(tag) || hidden(child)) continue;
      const last = items.at(-1);
      if ((tag === "ul" || tag === "ol") && last) last.push(child);
      else items.push([child]);
    }
    const start = Number.parseInt(attr(node, "start") ?? "1", 10);
    return this.items(items, ordered, Number.isFinite(start) && start >= 0 ? start : 1, context);
  }

  private items(items: PasteNode[][], ordered: boolean, start: number, context: Context): string {
    if (items.length === 0) return "";
    this.formatted = true;
    return items.map(([head, ...nested], index) => {
      const inner = styled(head!, tagOf(head!), context);
      const blocks = [...this.blocks(head!, inner), ...nested.map((list) => this.list(list, tagOf(list) === "ol", context))]
        .filter((block) => block !== "");
      return listItem(ordered ? `${start + index}.` : "-", taskOf(head!), blocks);
    }).join("\n");
  }

  private quote(node: PasteNode, context: Context): string {
    const body = this.blocks(node, context).join("\n\n");
    if (body === "") return "";
    this.formatted = true;
    return body.split("\n").map((line) => (line === "" ? ">" : `> ${line}`)).join("\n");
  }

  /** `<pre>` — 안에 `<code>`가 있으면 그것만(ChatGPT는 `<pre>` 안에 언어 이름 · "Copy code" 단추를 둔다). */
  private code(node: PasteNode, context: Context): string {
    const code = findDescendant(node, (child) => tagOf(child) === "code") ?? node;
    const text = preText(code).replace(/\r\n?/g, "\n").replace(/\u00a0/g, " ").replace(/\n$/, "");
    if (text.trim() === "") return "";
    const language = languageOf(code) ?? languageOf(node) ?? context.language ?? "";
    const longest = Math.max(0, ...(text.match(/`+/g) ?? []).map((ticks) => ticks.length));
    const fence = "`".repeat(Math.max(3, longest + 1));
    this.formatted = true;
    return `${fence}${language}\n${text}\n${fence}`;
  }

  /**
   * GFM 표 — 첫 줄이 머리(GFM은 머리가 있어야 한다 — Word · Excel의 표는 `<th>`가 없어도 첫 줄이 머리다). 합친 칸(colspan · rowspan)은
   * 빈 칸으로 채운다. 칸 하나 · 줄 하나뿐이면(Excel의 한 칸 · 한 줄) 표가 아니라 글. 레이아웃 표(메일 — `role="presentation"`, 칸 안에
   * 또 표)는 풀어서 글로.
   */
  private table(node: PasteNode, context: Context): Entry[] {
    if (attr(node, "role") === "presentation" || findDescendant(node, (child) => tagOf(child) === "table")) {
      return this.blocks(node, context);
    }
    const rows = tableRows(node);
    // 머리 칸(`<th>`) 없는 한 줄 — 머리만 있는 표가 된다. 메일의 레이아웃 표이거나 Excel의 한 줄이다(글로 — Excel은 탭으로 나눈 글이 붙는다).
    if (rows.length === 1 && !rowCells(rows[0]!).some((cell) => tagOf(cell) === "th")) return this.blocks(node, context);
    const grid: string[][] = [];
    const aligns: string[] = [];
    const covered = new Map<number, number>(); // 열 → 위 칸의 rowspan이 아직 덮는 줄 수
    rows.forEach((row, rowIndex) => {
      const cells: string[] = [];
      let column = 0;
      const skipCovered = () => {
        while ((covered.get(column) ?? 0) > 0) {
          covered.set(column, covered.get(column)! - 1);
          cells[column++] = "";
        }
      };
      for (const cell of rowCells(row)) {
        // 칸 자체의 스타일도 — Google 스프레드시트는 굵은 칸을 `<td style="font-weight:bold">`로 준다.
        const text = this.cellText(cell, styled(cell, tagOf(cell), { ...context, plainBold: rowIndex === 0 }));
        const across = clamp(attr(cell, "colspan"), 50);
        const down = clamp(attr(cell, "rowspan"), 1000);
        for (let part = 0; part < across; part++) {
          skipCovered();
          if (rowIndex === 0) aligns[column] = alignOf(cell);
          cells[column] = part === 0 ? text : "";
          if (down > 1) covered.set(column, down - 1);
          column++;
        }
      }
      for (const [at, left] of covered) {
        if (at >= column && left > 0) {
          covered.set(at, left - 1);
          cells[at] = "";
        }
      }
      grid.push(cells);
    });
    const width = Math.max(0, ...grid.map((cells) => cells.length));
    if (width === 0 || grid.every((cells) => cells.every((cell) => !cell))) return [];
    if (grid.length === 1 && width === 1) return this.blocks(rowCells(rows[0]!)[0]!, context);
    this.formatted = true;
    const line = (cells: string[]) => `| ${Array.from({ length: width }, (_, index) => cells[index] ?? "").join(" | ")} |`;
    const rule = `| ${Array.from({ length: width }, (_, index) => aligns[index] ?? "---").join(" | ")} |`;
    return [[line(grid[0]!), rule, ...grid.slice(1).map(line)].join("\n")];
  }

  /** 칸 안의 글 한 줄 — 칸 안의 문단 · 줄바꿈은 띄어쓰기로. `|`는 칸을 나누지 않게(코드 조각 안은 마디의 표가 나누지 않는다). */
  private cellText(cell: PasteNode, context: Context): string {
    return this.inlineText(cell, context).replace(/(`+)[^`]*?\1|\|/g, (match) => (match === "|" ? "\\|" : match));
  }

  /** 요소의 글을 한 줄로 — 안의 블록 경계와 줄바꿈은 띄어쓰기(제목 · 표의 칸). 줄 머리가 아니므로 줄 머리 표식은 이스케이프하지 않는다. */
  private inlineText(node: PasteNode, context: Context): string {
    const runs: Run[] = [];
    const visit = (child: PasteNode, outer: Context): void => {
      if (child.nodeType === TEXT) {
        runs.push({ kind: "text", text: child.nodeValue ?? "", style: styleOf(outer) });
        return;
      }
      if (child.nodeType !== ELEMENT) return;
      const tag = tagOf(child);
      if (SKIP.has(tag) || hidden(child)) return;
      const inner = styled(child, tag, outer);
      if (tag === "img") {
        const markdown = image(child);
        if (markdown) runs.push({ kind: "image", markdown, style: styleOf(inner) });
        return;
      }
      const gap = tag === "br" || CONTAINERS.has(tag) || BLOCKS.has(tag);
      if (gap) runs.push({ kind: "text", text: " ", style: styleOf(outer) });
      for (const grandchild of childrenOf(child)) visit(grandchild, inner);
      if (gap) runs.push({ kind: "text", text: " ", style: styleOf(outer) });
    };
    for (const child of childrenOf(node)) visit(child, context);
    return this.inline(runs).replace(/\s*\n\s*/g, " ").trim();
  }

  /** 문단 — 줄마다 앞뒤 공백을 떼고, 빈 줄은 하나로, 줄 머리의 표식(`#` · `-` · `1.` · `>` …)은 이스케이프. */
  private paragraph(runs: Run[]): string {
    if (runs.length === 0) return "";
    const lines: string[] = [];
    for (const line of this.inline(runs).split("\n").map((text) => text.trim())) {
      if (line === "" && (lines.length === 0 || lines.at(-1) === "")) continue;
      lines.push(line);
    }
    while (lines.at(-1) === "") lines.pop();
    return lines.map(escapeLineStart).join("\n");
  }

  /**
   * 글 조각들을 한 줄의 마크다운으로. 표식은 스타일이 바뀌는 자리에만 단다(`<b>a</b><b>b</b>`가 `**a****b**`가 되지 않게) — 열 때는 오래
   * 갈 것을 바깥에(덜 닫고 다시 열게), 닫고 여는 표식은 공백 바깥에(`** 굵게**`는 굵게가 아니다). 같은 스타일의 이웃은 먼저 합쳐 이스케이프를
   * 이은 글에서 본다.
   */
  private inline(runs: Run[]): string {
    const segments = normalizeRuns(runs);
    const tokens: Token[] = [];
    const stack: string[] = [];
    let pending = "";
    const closeWhile = (keep: (key: string) => boolean) => {
      while (stack.some((key) => !keep(key))) {
        const key = stack.pop()!;
        tokens.push({ kind: "close", key, mark: closeMark(key) });
      }
    };
    const flushPending = () => {
      if (pending !== "") tokens.push({ kind: "text", text: pending, plain: true });
      pending = "";
    };
    segments.forEach((segment, index) => {
      if (segment.kind === "break") {
        closeWhile(() => false);
        flushPending();
        tokens.push({ kind: "text", text: "\n", plain: false });
        return;
      }
      let lead = "";
      let trail = "";
      let core: string;
      let plain = false;
      if (segment.kind === "text") {
        const parts = /^( *)(.*?)( *)$/s.exec(segment.text)!;
        if (parts[2] === "") {
          pending += segment.text;
          return;
        }
        lead = parts[1]!;
        trail = parts[3]!;
        plain = !segment.style.code;
        core = plain ? escapeInline(parts[2]!) : codeSpan(parts[2]!);
      } else {
        core = segment.markdown;
      }
      if (!plain) this.formatted = true;
      const target = keysOf(segment.style);
      closeWhile((key) => target.includes(key));
      pending += lead;
      flushPending();
      const opening = target.filter((key) => !stack.includes(key))
        .sort((a, b) => lasting(segments, index, b) - lasting(segments, index, a) || rank(a) - rank(b));
      for (const key of opening) {
        stack.push(key);
        tokens.push({ kind: "open", key, mark: openMark(key) });
        this.formatted = true;
      }
      tokens.push({ kind: "text", text: core, plain });
      pending = trail;
    });
    closeWhile(() => false);
    flushPending();
    fixFlanking(tokens);
    return tokens.map((token) => (token.kind === "text" ? token.text : token.mark)).join("");
  }

  /** Word의 목록 문단(`mso-list: l0 level2 lfo1`) — 단계와 번호 꼴(앞의 표식 `1.` · `a)` · `·` · `o` · `§`)을 읽는다. */
  private wordItem(node: PasteNode, context: Context): WordItem | null {
    const list = cssOf(node).get("mso-list");
    const level = list ? /level(\d+)/i.exec(list) : null;
    if (!level) return null;
    const marker = findDescendant(node, isWordMarker);
    const sign = marker ? plainText(marker).replace(/[\s\u00a0]/g, "") : "";
    return {
      kind: "word",
      list: /\bl\d+\b/i.exec(list!)?.[0].toLowerCase() ?? "",
      level: Math.max(1, Number(level[1])),
      ordered: /^\(?((\d+\.)*\d+|[a-z]{1,4}|[가-힣])[.)]$|^[\u2460-\u2473]$/i.test(sign),
      text: this.blocks(node, context).join(" "),
    };
  }

  private groupWordLists(entries: Entry[]): string[] {
    const out: string[] = [];
    let items: WordItem[] = [];
    const flush = () => {
      if (items.length > 0) out.push(this.wordList(items));
      items = [];
    };
    for (const entry of entries) {
      if (typeof entry === "string") {
        flush();
        out.push(entry);
      } else {
        if (items.length > 0 && items[0]!.list !== entry.list) flush();
        items.push(entry);
      }
    }
    flush();
    return out;
  }

  /** 이어진 Word 목록 문단 → 목록. 하위 단계는 윗 항목의 글 자리만큼 들여 쓴다(`1. `이면 3칸, `- `이면 2칸 — CommonMark). */
  private wordList(items: WordItem[]): string {
    this.formatted = true;
    const stack: { level: number; indent: number; count: number; content: number; ordered: boolean }[] = [];
    return items.map((item) => {
      while (stack.length > 0 && stack.at(-1)!.level > item.level) stack.pop();
      let top = stack.at(-1);
      if (!top || top.level < item.level) {
        top = { level: item.level, indent: top?.content ?? 0, count: 0, content: 0, ordered: item.ordered };
        stack.push(top);
      }
      // 같은 단계에서 꼴이 바뀌면(글머리 → 번호) 마크다운에서는 새 목록 — 번호를 1부터.
      if (top.ordered !== item.ordered) {
        top.ordered = item.ordered;
        top.count = 0;
      }
      top.count++;
      const marker = item.ordered ? `${top.count}.` : "-";
      top.content = top.indent + marker.length + 1;
      return " ".repeat(top.indent) + listItem(marker, "", item.text === "" ? [] : [item.text]).replace(/\n(?=.)/g, `\n${" ".repeat(top.indent)}`);
    }).join("\n");
  }
}

// MARK: 목록 항목

/** 항목 하나 — 첫 블록은 표식 줄에, 나머지는 표식 폭만큼 들여 쓴다. 하위 목록은 빈 줄 없이(촘촘한 목록). */
function listItem(marker: string, task: string, blocks: readonly string[]): string {
  const pad = " ".repeat(marker.length + 1);
  const indent = (text: string) => text.split("\n").map((line) => (line === "" ? "" : pad + line)).join("\n");
  if (blocks.length === 0) return task ? `${marker} ${task.trimEnd()}` : marker;
  const [first, ...rest] = blocks as [string, ...string[]];
  let out: string;
  if (isList(first)) {
    out = `${marker}\n${indent(first)}`;
  } else {
    // 할 일이 아닌 항목이 `[ ]`로 시작하면 할 일 상자가 된다.
    const head = !task && /^\[[ xX]\](\s|$)/.test(first) ? `\\${first}` : first;
    out = `${marker} ${task}${indent(head).slice(pad.length)}`;
  }
  for (const block of rest) out += `${isList(block) ? "\n" : "\n\n"}${indent(block)}`;
  return out;
}

function isList(block: string): boolean {
  return /^([-+*]|\d+[.)])( |$)/.test(block);
}

/** 할 일 상자 — GitHub(`<input type=checkbox>`), Google 문서(`role="checkbox"`), Notion(`checkbox-on` · `checkbox-off`). */
function taskOf(item: PasteNode): string {
  if (attr(item, "role") === "checkbox") return attr(item, "aria-checked") === "true" ? "[x] " : "[ ] ";
  const first = leadingElement(item);
  if (!first) return "";
  if (tagOf(first) === "input" && (attr(first, "type") ?? "").toLowerCase() === "checkbox") {
    return attr(first, "checked") !== null ? "[x] " : "[ ] ";
  }
  const classes = attr(first, "class") ?? "";
  if (/\bcheckbox-on\b/.test(classes)) return "[x] ";
  if (/\bcheckbox-off\b/.test(classes)) return "[ ] ";
  return "";
}

/** 항목의 글보다 앞에 오는 요소(감싼 `<p>` · `<span>` · `<label>` · `<div>` 안까지) — 글이 먼저 나오면 null. */
function leadingElement(node: PasteNode): PasteNode | null {
  for (const child of childrenOf(node)) {
    if (child.nodeType === TEXT) {
      if ((child.nodeValue ?? "").trim() !== "") return null;
      continue;
    }
    if (child.nodeType !== ELEMENT) continue;
    const tag = tagOf(child);
    if (tag === "input" || /\bcheckbox-(on|off)\b/.test(attr(child, "class") ?? "")) return child;
    if (["p", "span", "label", "div"].includes(tag)) return leadingElement(child);
    return null;
  }
  return null;
}

// MARK: 인라인 표식

type Token = { kind: "text"; text: string; plain: boolean } | { kind: "open" | "close"; key: string; mark: string };

const RANK = ["link", "strike", "bold", "italic"];

function keysOf(style: Style): string[] {
  const keys: string[] = [];
  if (style.href !== null) keys.push(`link ${style.href}`);
  if (style.strike) keys.push("strike");
  if (style.bold) keys.push("bold");
  if (style.italic) keys.push("italic");
  return keys;
}

function rank(key: string): number {
  return RANK.indexOf(key.split(" ")[0]!);
}

function openMark(key: string): string {
  return key.startsWith("link ") ? "[" : key === "strike" ? "~~" : key === "bold" ? "**" : "*";
}

function closeMark(key: string): string {
  return key.startsWith("link ") ? `](${key.slice(5)})` : openMark(key);
}

/** `index`부터 이 스타일이 몇 조각 이어지는가(공백만인 조각은 건너뛴다, 줄바꿈에서 끝난다). */
function lasting(segments: readonly Run[], index: number, key: string): number {
  let count = 0;
  for (let at = index; at < segments.length; at++) {
    const segment = segments[at]!;
    if (segment.kind === "break") break;
    if (segment.kind === "text" && segment.text.trim() === "") continue;
    if (!keysOf(segment.style).includes(key)) break;
    count++;
  }
  return count;
}

/** 공백을 HTML처럼 하나로 접고(문단의 앞은 버린다), 같은 스타일의 이웃 글은 합친다. */
function normalizeRuns(runs: readonly Run[]): Run[] {
  const out: Run[] = [];
  let afterSpace = true;
  for (const run of runs) {
    if (run.kind === "break") {
      out.push(run);
      afterSpace = true;
      continue;
    }
    if (run.kind === "image") {
      out.push(run);
      afterSpace = false;
      continue;
    }
    let text = run.text.replace(/[ \t\n\r\f\u00a0]+/g, " ");
    if (afterSpace) text = text.replace(/^ /, "");
    if (text === "") continue;
    afterSpace = text.endsWith(" ");
    const last = out.at(-1);
    if (last?.kind === "text" && sameStyle(last.style, run.style)) out[out.length - 1] = { ...last, text: last.text + text };
    else out.push({ kind: "text", text, style: run.style });
  }
  return out;
}

function sameStyle(a: Style, b: Style): boolean {
  return a.bold === b.bold && a.italic === b.italic && a.strike === b.strike && a.code === b.code && a.href === b.href;
}

/**
 * 표식 앞뒤의 문장 부호 — CommonMark는 문장 부호 바로 뒤의 닫는 `**`를, 뒤에 글자(한글 조사)가 붙으면 닫는 표식으로 읽지 않는다
 * (`**마디(Madi)**는`이 굵게가 되지 않는다). 그럴 때는 그 문장 부호를 표식 바깥으로 옮긴다(`**마디(Madi**)는`) — 괄호 하나가 덜 굵다.
 * 여는 쪽도 같다(`는**(중요)**` → `는(**중요)**`).
 */
function fixFlanking(tokens: Token[]): void {
  for (let start = 0; start < tokens.length; start++) {
    if (tokens[start]!.kind === "text" || !isEmphasis(tokens[start]!)) continue;
    let end = start;
    while (end < tokens.length && tokens[end]!.kind !== "text" && isEmphasis(tokens[end]!)) end++;
    const group = tokens.slice(start, end);
    const prev = tokens[start - 1];
    const next = tokens[end];
    const before = charBefore(tokens, start);
    const after = charAfter(tokens, end);
    if (group.some((token) => token.kind === "close") && !rightFlanking(before, after) && isPunct(before) && !isSpace(after)
      && prev?.kind === "text" && prev.plain) {
      const moved = /[\p{P}\p{S}]+$/u.exec(prev.text)?.[0] ?? "";
      if (moved !== "" && moved.length < prev.text.length && !moved.includes("\\")) {
        prev.text = prev.text.slice(0, -moved.length);
        if (next?.kind === "text" && next.plain) next.text = moved + next.text;
        else tokens.splice(end, 0, { kind: "text", text: moved, plain: true });
      }
    } else if (group.some((token) => token.kind === "open") && !leftFlanking(before, after) && isPunct(after) && !isSpace(before)
      && next?.kind === "text" && next.plain) {
      const moved = /^[\p{P}\p{S}]+/u.exec(next.text)?.[0] ?? "";
      if (moved !== "" && moved.length < next.text.length && !moved.includes("\\")) {
        next.text = next.text.slice(moved.length);
        if (prev?.kind === "text" && prev.plain) prev.text += moved;
        else {
          tokens.splice(start, 0, { kind: "text", text: moved, plain: true });
          end++;
        }
      }
    }
    start = end - 1;
  }
}

function isEmphasis(token: Token): boolean {
  return token.kind !== "text" && !token.key.startsWith("link ");
}

function charBefore(tokens: readonly Token[], index: number): string {
  for (let at = index - 1; at >= 0; at--) {
    const token = tokens[at]!;
    const text = token.kind === "text" ? token.text : token.mark;
    if (text !== "") return text.at(-1)!;
  }
  return "";
}

function charAfter(tokens: readonly Token[], index: number): string {
  for (let at = index; at < tokens.length; at++) {
    const token = tokens[at]!;
    const text = token.kind === "text" ? token.text : token.mark;
    if (text !== "") return text[0]!;
  }
  return "";
}

const isSpace = (char: string) => char === "" || /\s/.test(char);
const isPunct = (char: string) => /[\p{P}\p{S}]/u.test(char);
const leftFlanking = (before: string, after: string) => !isSpace(after) && (!isPunct(after) || isSpace(before) || isPunct(before));
const rightFlanking = (before: string, after: string) => !isSpace(before) && (!isPunct(before) || isSpace(after) || isPunct(after));

// MARK: 이스케이프

const isWordChar = (char: string) => /[\p{L}\p{N}]/u.test(char);

/**
 * 글 속의 마크다운 표식 글자 — 뜻이 생길 때만 `\`를 붙인다(마디의 편집기는 `\`를 감추지 않는다). 양옆이 공백인 `*`(`5 * 3`), 낱말
 * 속의 `_`(`snake_case`), 한 개짜리 `~`(`3~5개`), 문장 부호가 뒤따르지 않는 `\`(`C:\Users`)는 그대로.
 */
function escapeInline(text: string): string {
  let out = "";
  for (let index = 0; index < text.length; index++) {
    const char = text[index]!;
    const before = text[index - 1] ?? "";
    const after = text[index + 1] ?? "";
    switch (char) {
      case "\\":
        out += after === "" || /[!-/:-@[-`{-~]/.test(after) ? "\\\\" : "\\";
        break;
      case "*":
        out += /\s/.test(before) && /\s/.test(after) ? "*" : "\\*";
        break;
      case "_":
        out += isWordChar(before) && isWordChar(after) ? "_" : "\\_";
        break;
      case "`":
        out += "\\`";
        break;
      case "]":
        out += after === "(" || after === "[" ? "\\]" : "]";
        break;
      case "~":
        out += after === "~" || before === "~" ? "\\~" : "~";
        break;
      case "<":
        out += /[A-Za-z/!?]/.test(after) ? "\\<" : "<";
        break;
      case "&":
        out += /^&(#\d+|#x[\da-f]+|[a-z][a-z\d]*);/i.test(text.slice(index)) ? "\\&" : "&";
        break;
      default:
        out += char;
    }
  }
  return out;
}

/** 줄 머리에서 블록이 되는 글(`# ` · `- ` · `+ ` · `> ` · `1. ` · `===` · `$$` · `[a]: `)을 글로. */
function escapeLineStart(line: string): string {
  if (/^(#{1,6}|[-+])(\s|$)/.test(line) || /^(>|\$\$|=+\s*$|-+\s*$|\[[^\]]*\]:)/.test(line)) return `\\${line}`;
  return line.replace(/^(\d{1,9})([.)])(\s|$)/, "$1\\$2$3");
}

function codeSpan(text: string): string {
  const longest = Math.max(0, ...(text.match(/`+/g) ?? []).map((ticks) => ticks.length));
  const ticks = "`".repeat(longest + 1);
  const pad = text.startsWith("`") || text.endsWith("`") ? " " : "";
  return `${ticks}${pad}${text}${pad}${ticks}`;
}

// MARK: 요소 읽기

function childrenOf(node: PasteNode): PasteNode[] {
  return Array.from(node.childNodes);
}

function tagOf(node: PasteNode): string {
  return node.nodeName.toLowerCase();
}

function attr(node: PasteNode, name: string): string | null {
  return node.getAttribute?.(name) ?? null;
}

function nonEmpty(text: string): string[] {
  return text === "" ? [] : [text];
}

/** 인라인 스타일(`style="font-weight:700; mso-list:Ignore"`) — 이름은 소문자, 값은 앞뒤 따옴표 · `!important`를 뗀다(한글은 `"bold"`로 쓴다). */
function cssOf(node: PasteNode): Map<string, string> {
  const css = new Map<string, string>();
  for (const declaration of (attr(node, "style") ?? "").split(";")) {
    const colon = declaration.indexOf(":");
    if (colon < 0) continue;
    const name = declaration.slice(0, colon).trim().toLowerCase();
    const value = declaration.slice(colon + 1).replace(/!important/i, "").trim().replace(/^["']|["']$/g, "").toLowerCase();
    if (name !== "") css.set(name, value);
  }
  return css;
}

function hidden(node: PasteNode): boolean {
  if (attr(node, "hidden") !== null) return true;
  const css = cssOf(node);
  return css.get("display") === "none" || css.get("visibility") === "hidden" || css.get("mso-hide") === "all" || isWordMarker(node);
}

/** Word 목록의 표식 글자(`·` · `1.`) — 목록으로 옮기면서 따로 읽고, 글에서는 뺀다. */
function isWordMarker(node: PasteNode): boolean {
  return /^ignore$/i.test(cssOf(node).get("mso-list") ?? "");
}

function styleOf(context: Context): Style {
  return { bold: context.bold && !context.plainBold, italic: context.italic, strike: context.strike, code: context.code, href: context.href };
}

/** 요소가 바꾸는 스타일 — 태그 다음에 인라인 스타일(그것이 이긴다 — Google 문서의 `<b style="font-weight:normal">`). */
function styled(node: PasteNode, tag: string, outer: Context): Context {
  const next = { ...outer };
  switch (tag) {
    case "b":
    case "strong":
      next.bold = true;
      break;
    case "i":
    case "em":
      next.italic = true;
      break;
    case "s":
    case "strike":
    case "del":
      next.strike = true;
      break;
    case "a": {
      const href = safeHref(attr(node, "href"));
      if (href) next.href = href;
      break;
    }
    case "font": {
      const face = attr(node, "face");
      if (face) next.code = isMono(face);
      break;
    }
  }
  if (CODE_TAGS.has(tag)) next.code = true;
  const css = cssOf(node);
  const weight = css.get("font-weight");
  if (weight && /^(bold|bolder|[6-9]00)$/.test(weight)) next.bold = true;
  else if (weight && /^(normal|lighter|[1-5]00)$/.test(weight)) next.bold = false;
  const fontStyle = css.get("font-style");
  if (fontStyle && /^(italic|oblique)/.test(fontStyle)) next.italic = true;
  else if (fontStyle === "normal") next.italic = false;
  // 취소선은 더하기만 — CSS에서 `text-decoration: none`은 바깥 요소의 선을 지우지 못한다.
  if ((css.get("text-decoration-line") ?? css.get("text-decoration") ?? "").includes("line-through")) next.strike = true;
  const family = css.get("font-family");
  if (family && !CODE_TAGS.has(tag)) next.code = isMono(family);
  const language = languageOf(node);
  if (language !== null) next.language = language;
  return next;
}

/** 고정폭 글꼴(첫 글꼴로 본다) — Word · Google 문서는 코드를 글꼴로 적는다. */
function isMono(family: string): boolean {
  const first = (family.split(",")[0] ?? "").trim().replace(/^["']|["']$/g, "").toLowerCase();
  return /mono|code|consolas|courier|menlo|monaco|lucida console|d2coding|inconsolata|^hack$/.test(first);
}

/** 코드의 언어 — `language-js` · `lang-js` · `highlight-source-js`(GitHub). 이름이 없거나 그냥 글이면 null. */
function languageOf(node: PasteNode): string | null {
  const match = /(?:^|\s)(?:language|lang|highlight-source)-([\w+#.-]+)/.exec(attr(node, "class") ?? "");
  if (!match) return null;
  const name = match[1]!.toLowerCase();
  return ["none", "plaintext", "plain", "text", "nohighlight"].includes(name) ? "" : name;
}

/** 링크 주소 — 스크립트 · `data:`는 버린다. 공백 · 괄호는 `%`로(마크다운의 주소가 끝나지 않게). */
function safeHref(href: string | null): string | null {
  const url = (href ?? "").replace(/[\t\n\r]/g, "").trim();
  if (url === "" || url === "#" || /^(javascript|vbscript|data):/i.test(url)) return null;
  return url.replace(/[ ()<>]/g, (char) => `%${char.charCodeAt(0).toString(16).toUpperCase()}`);
}

/** 그림 — 웹 주소(`http` · `https`)만. Word의 그림은 지워질 임시 파일(`file:///…/msohtmlclip1/…`)이고, `data:`는 글이 수 MB가 된다. */
function image(node: PasteNode): string | null {
  const src = (attr(node, "src") ?? "").trim();
  if (!/^https?:\/\//i.test(src)) return null;
  const alt = (attr(node, "alt") ?? "").replace(/[\s\u00a0]+/g, " ").trim().replace(/[[\]\\]/g, "\\$&");
  return `![${alt}](${safeHref(src)})`;
}

function alignOf(cell: PasteNode): string {
  const align = (attr(cell, "align") ?? cssOf(cell).get("text-align") ?? "").toLowerCase();
  return align === "center" ? ":---:" : align === "right" ? "---:" : "---";
}

function clamp(value: string | null, max: number): number {
  const number = Number.parseInt(value ?? "1", 10);
  return Number.isFinite(number) ? Math.min(Math.max(number, 1), max) : 1;
}

function tableRows(table: PasteNode): PasteNode[] {
  const rows: PasteNode[] = [];
  for (const child of childrenOf(table)) {
    const tag = child.nodeType === ELEMENT ? tagOf(child) : "";
    if (tag === "tr") rows.push(child);
    else if (tag === "thead" || tag === "tbody" || tag === "tfoot") rows.push(...childrenOf(child).filter((row) => row.nodeType === ELEMENT && tagOf(row) === "tr"));
  }
  return rows;
}

function rowCells(row: PasteNode): PasteNode[] {
  return childrenOf(row).filter((cell) => cell.nodeType === ELEMENT && (tagOf(cell) === "td" || tagOf(cell) === "th") && !hidden(cell));
}

function findDescendant(node: PasteNode, test: (child: PasteNode) => boolean): PasteNode | null {
  for (const child of childrenOf(node)) {
    if (child.nodeType !== ELEMENT) continue;
    if (test(child)) return child;
    const found = findDescendant(child, test);
    if (found) return found;
  }
  return null;
}

function plainText(node: PasteNode): string {
  if (node.nodeType === TEXT) return node.nodeValue ?? "";
  return childrenOf(node).map(plainText).join("");
}

/** `<pre>`의 글 — `<br>`과 줄 단위 블록(`<div>` 한 줄씩 그리는 사이트)은 줄바꿈. */
function preText(node: PasteNode): string {
  let out = "";
  const visit = (child: PasteNode) => {
    if (child.nodeType === TEXT) {
      out += child.nodeValue ?? "";
      return;
    }
    if (child.nodeType !== ELEMENT) return;
    const tag = tagOf(child);
    if (SKIP.has(tag)) return;
    if (tag === "br") {
      out += "\n";
      return;
    }
    for (const grandchild of childrenOf(child)) visit(grandchild);
    if ((tag === "div" || tag === "p" || tag === "li" || tag === "tr") && !out.endsWith("\n")) out += "\n";
  };
  for (const child of childrenOf(node)) visit(child);
  return out;
}

/** 코드 편집기 · 터미널에서 복사한 것 — 고정폭 · 공백 그대로(`white-space: pre`)인 덩이 하나, 또는 `<pre>` 하나뿐. */
function isCodeCopy(root: PasteNode): boolean {
  const content = meaningful(root);
  if (content.length !== 1 || content[0]!.nodeType !== ELEMENT) return false;
  const only = content[0]!;
  if (tagOf(only) === "pre") return true;
  const css = cssOf(only);
  return /^pre/.test(css.get("white-space") ?? "") && isMono(css.get("font-family") ?? "");
}

function meaningful(node: PasteNode): PasteNode[] {
  const out: PasteNode[] = [];
  for (const child of childrenOf(node)) {
    if (child.nodeType === TEXT) {
      if ((child.nodeValue ?? "").trim() !== "") out.push(child);
      continue;
    }
    if (child.nodeType !== ELEMENT) continue;
    const tag = tagOf(child);
    if (SKIP.has(tag)) continue;
    if (tag === "html" || tag === "body") out.push(...meaningful(child));
    else out.push(child);
  }
  return out;
}
