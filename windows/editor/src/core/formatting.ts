// 서식 명령 — 글자 꾸밈(굵게 · 기울임 · 취소선 · 인라인 코드), 제목, 목록 · 인용, 링크, 코드 블록 · 표 · 구분선.
// macOS판 `MarkdownFormatting`을 그대로 옮겼다(규칙 · 캐럿 자리가 같다 — 시험도 macOS판의 것을 옮겼다).
//
// 모두 마크다운 원문을 고치는 순수 계산이고 편집 하나(`FormatEdit`)를 돌려준다. 고칠 것이 없으면 null. 다시 누르면 풀린다 — 굵게를
// 다시 누르면 `**`가 빠지고, 같은 단계의 제목을 다시 누르면 본문이 된다. 여러 줄을 고르면 줄마다 한다.
//
// 글은 줄 끝이 `\n`인 글(편집기의 `doc.toString()`)이다 — 넣는 글의 `\n`은 편집기가 문서의 줄 끝으로 바꿔 넣는다.

export interface Span {
  from: number;
  to: number;
}

/** `from`~`to`를 `insert`로 바꾸고 `selection`을 고른다(바꾼 뒤의 위치). */
export interface FormatEdit {
  from: number;
  to: number;
  insert: string;
  selection: Span;
}

export type InlineStyle = "bold" | "italic" | "strikethrough" | "code";
export type BlockStyle = "bullet" | "numbered" | "task" | "quote";

const markers: Record<InlineStyle, string> = { bold: "**", italic: "*", strikethrough: "~~", code: "`" };
/** 이 꾸밈이 걸렸다고 볼 표식 글자의 연속 개수. `*` 셋(`***`)은 굵게이자 기울임이다. */
const runs: Record<InlineStyle, number[]> = { bold: [2, 3], italic: [1, 3], strikethrough: [2], code: [1] };

/** 편집을 글에 적용한다 — 시험과 편집기 밖에서. */
export function applyEdit(text: string, edit: FormatEdit): string {
  return text.slice(0, edit.from) + edit.insert + text.slice(edit.to);
}

// MARK: 줄

/** `position`이 든 줄 — 줄 끝(`\n`)까지 넣는다. 끝 줄이 줄 끝 없이 끝나면 글 끝까지. */
function lineRange(text: string, position: number): Span {
  const at = Math.min(Math.max(position, 0), text.length);
  const from = text.lastIndexOf("\n", at - 1) + 1;
  const newline = text.indexOf("\n", at);
  return { from, to: newline < 0 ? text.length : newline + 1 };
}

/** 고른 범위가 닿은 줄 모두(줄 끝 넣고). 고른 것이 줄 끝에서 끝나면 그 다음 줄은 넣지 않는다. */
export function lineBlock(text: string, selection: Span): Span {
  const first = lineRange(text, selection.from);
  const lastProbe = selection.to > selection.from ? Math.max(selection.from, selection.to - 1) : selection.from;
  const last = lineRange(text, lastProbe);
  return { from: first.from, to: last.to };
}

function terminator(line: string): string {
  return line.endsWith("\r\n") ? "\r\n" : line.endsWith("\n") ? "\n" : line.endsWith("\r") ? "\r" : "";
}

/** 범위 안의 줄들(줄 끝은 빼고). 빈 범위면 그 자리의 빈 줄 하나. */
function linesIn(text: string, block: Span): Span[] {
  const body = text.slice(block.from, block.to);
  if (body === "") return [{ from: block.from, to: block.from }];
  const parts = body.split("\n");
  if (body.endsWith("\n")) parts.pop();
  const lines: Span[] = [];
  let at = block.from;
  for (const part of parts) {
    lines.push({ from: at, to: at + part.length });
    at += part.length + 1;
  }
  return lines;
}

/** 빈 줄 — 공백뿐인 줄도(macOS판 `.whitespaces`). 줄에는 줄 끝이 없다. */
const isBlank = (line: string) => line.trim() === "";

function isSpace(char: string): boolean {
  return char === " " || char === "\t" || char === "\u3000";
}

// MARK: 바꾸기 모으기

interface Change {
  from: number;
  to: number;
  insert: string;
}

/**
 * 겹치지 않는 바꾸기들을 편집 하나로 묶는다. 선택의 양 끝은 편집 전 위치로 받아 옮겨 놓는다. `[위치, true]`는 그 자리에 끼워 넣은 글의
 * 뒤로, `false`는 앞으로 간다. 바꾼 범위 안에 있던 위치는 그 범위가 바뀐 글의 끝으로 간다.
 */
function combine(changes: Change[], text: string, start: [number, boolean], end: [number, boolean]): FormatEdit | null {
  if (changes.length === 0) return null;
  const sorted = [...changes].sort((a, b) => a.from - b.from);
  const low = sorted[0]!.from;
  const high = Math.max(...sorted.map((change) => change.to));
  let insert = "";
  let cursor = low;
  for (const change of sorted) {
    insert += text.slice(cursor, change.from) + change.insert;
    cursor = change.to;
  }
  const moved = (point: number, afterInsertion: boolean): number => {
    let shift = 0;
    for (const change of sorted) {
      const delta = change.insert.length - (change.to - change.from);
      if (change.to < point || (change.to === point && (change.to > change.from || afterInsertion))) {
        shift += delta;
      } else if (change.from < point && point < change.to) {
        return change.from + shift + change.insert.length;
      }
    }
    return point + shift;
  };
  const from = moved(start[0], start[1]);
  const to = Math.max(from, moved(end[0], end[1]));
  return { from: low, to: high, insert, selection: { from, to } };
}

// MARK: 글자 꾸밈

function runEndingAt(symbol: string, point: number, text: string): number {
  let count = 0;
  for (let index = point - 1; index >= 0 && text[index] === symbol; index--) count++;
  return count;
}

function runStartingAt(symbol: string, point: number, text: string): number {
  let count = 0;
  for (let index = point; index < text.length && text[index] === symbol; index++) count++;
  return count;
}

const blockPrefix = /^[ \t]*(?:#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d{1,9}[.)][ \t]+)*/;

/** 고른 범위를 줄마다 자른 조각. 줄 앞의 블록 표식과 앞뒤 공백은 뺀다. 빈 조각은 버린다. */
export function inlineSegments(text: string, selection: Span): Span[] {
  const segments: Span[] = [];
  for (const line of linesIn(text, lineBlock(text, selection))) {
    let start = Math.max(line.from, selection.from);
    let end = Math.min(line.to, selection.to);
    if (end <= start) continue;
    if (start === line.from) start += blockPrefix.exec(text.slice(line.from, line.to))?.[0].length ?? 0;
    while (start < end && isSpace(text[start]!)) start++;
    while (end > start && isSpace(text[end - 1]!)) end--;
    if (end > start) segments.push({ from: start, to: end });
  }
  return segments;
}

/**
 * 고른 글을 꾸미거나 푼다.
 * - 고른 것이 없으면 표식 한 쌍을 넣고 캐럿을 가운데 둔다(`**|**`). 빈 쌍 가운데서 다시 누르면 쌍을 지운다.
 * - 고른 글이 이미 꾸며져 있으면(표식이 고른 글 바로 밖에 있든, 고른 글의 양 끝이든) 푼다.
 * - 아니면 감싼다. 고른 글 앞뒤의 공백과 줄 앞의 블록 표식(`#` `-` `1.` `>`)은 감싸지 않는다.
 * - 여러 줄이면 줄마다. 모든 줄이 꾸며져 있으면 모두 풀고, 아니면 안 꾸민 줄만 감싼다.
 */
export function toggleInline(style: InlineStyle, text: string, selection: Span): FormatEdit | null {
  const marker = markers[style];
  const width = marker.length;
  const symbol = marker[0]!;
  const allowed = runs[style];

  if (selection.from === selection.to) {
    const caret = selection.from;
    if (runEndingAt(symbol, caret, text) === width && runStartingAt(symbol, caret, text) === width) {
      return { from: caret - width, to: caret + width, insert: "", selection: { from: caret - width, to: caret - width } };
    }
    return { from: caret, to: caret, insert: marker + marker, selection: { from: caret + width, to: caret + width } };
  }

  const segments = inlineSegments(text, selection);
  if (segments.length === 0) return null;
  // 조각마다 여는 표식과 닫는 표식이 각각 조각 밖(바로 앞 · 뒤)에 있는지 안(양 끝)에 있는지 본다. 두 끝이 다를 수 있다 — 여러 줄을 감싼
  // 뒤의 선택은 첫 줄의 여는 표식 뒤에서 시작해 끝 줄의 닫는 표식 앞에서 끝난다.
  const wraps = segments.map((segment) => {
    const length = segment.to - segment.from;
    const openOutside = allowed.includes(runEndingAt(symbol, segment.from, text));
    const openInside = allowed.includes(Math.min(runStartingAt(symbol, segment.from, text), length));
    const closeOutside = allowed.includes(runStartingAt(symbol, segment.to, text));
    const closeInside = allowed.includes(Math.min(runEndingAt(symbol, segment.to, text), length));
    if (!(openOutside || openInside) || !(closeOutside || closeInside)) return null;
    const wrap = { openInside: !openOutside, closeInside: !closeOutside };
    const inside = (wrap.openInside ? width : 0) + (wrap.closeInside ? width : 0);
    return length > inside ? wrap : null; // 표식만 고른 것은 꾸민 글이 아니다
  });
  const unwrap = wraps.every((wrap) => wrap !== null);

  const changes: Change[] = [];
  const contents: Span[] = [];
  segments.forEach((segment, index) => {
    const wrap = wraps[index];
    if (!wrap) {
      changes.push({ from: segment.from, to: segment.from, insert: marker }, { from: segment.to, to: segment.to, insert: marker });
      contents.push(segment);
      return;
    }
    const open = wrap.openInside ? { from: segment.from, to: segment.from + width } : { from: segment.from - width, to: segment.from };
    const close = wrap.closeInside ? { from: segment.to - width, to: segment.to } : { from: segment.to, to: segment.to + width };
    if (unwrap) changes.push({ ...open, insert: "" }, { ...close, insert: "" });
    contents.push({ from: wrap.openInside ? segment.from + width : segment.from, to: wrap.closeInside ? segment.to - width : segment.to });
  });
  const first = contents[0]!;
  const last = contents[contents.length - 1]!;
  return combine(changes, text, [first.from, true], [last.to, false]);
}

// MARK: 줄 앞부분 고쳐 쓰기

/**
 * 고른 줄마다 줄 앞부분만 바꾼다. `transform`은 줄마다 [앞에서 지울 글자 수, 그 자리에 넣을 글]을, 그대로 둘 줄에는 null을 돌려준다.
 * 캐럿과 선택은 글과 함께 움직인다 — 지운 앞부분 안에 있던 자리는 새 앞부분 뒤로.
 */
function rewriteLines(text: string, selection: Span, transform: (lines: string[]) => ([number, string] | null)[]): FormatEdit | null {
  const ranges = linesIn(text, lineBlock(text, selection));
  const plan = transform(ranges.map((range) => text.slice(range.from, range.to)));
  const changes: Change[] = [];
  ranges.forEach((range, index) => {
    const step = plan[index];
    if (!step) return;
    const [remove, insert] = step;
    if (text.slice(range.from, range.from + remove) === insert) return;
    changes.push({ from: range.from, to: range.from + remove, insert });
  });
  return combine(changes, text, [selection.from, true], [selection.to, selection.from === selection.to]);
}

// MARK: 제목

/** 줄의 제목 단계. 제목이 아니면 0. `#글`(띄어 쓰지 않음)은 제목이 아니다. */
export function headingLevel(line: string): number {
  const hashes = /^#*/.exec(line)![0].length;
  if (hashes < 1 || hashes > 6) return 0;
  const rest = line.slice(hashes);
  return rest === "" || rest[0] === " " || rest[0] === "\t" ? hashes : 0;
}

function headingPrefixLength(line: string): number {
  const level = headingLevel(line);
  if (level === 0) return 0;
  return level + /^[ \t]*/.exec(line.slice(level))![0].length;
}

/** 줄을 제목 `level`(1~6)로, 0이면 본문으로. 고른 줄이 모두 이미 그 단계면 본문으로 되돌린다. 빈 줄은 건드리지 않는다. */
export function heading(level: number, text: string, selection: Span): FormatEdit | null {
  if (!Number.isInteger(level) || level < 0 || level > 6) return null;
  return rewriteLines(text, selection, (lines) => {
    if (lines.length === 1 && isBlank(lines[0]!)) {
      // 빈 줄 하나 — 그 줄을 제목으로 시작한다(이어서 쓰면 제목이 된다).
      return [level === 0 ? null : [lines[0]!.length, `${"#".repeat(level)} `]];
    }
    const levels = lines.filter((line) => !isBlank(line)).map(headingLevel);
    const target = level > 0 && levels.length > 0 && levels.every((value) => value === level) ? 0 : level;
    const prefix = target === 0 ? "" : `${"#".repeat(target)} `;
    return lines.map((line) => (isBlank(line) ? null : [headingPrefixLength(line), prefix]));
  });
}

// MARK: 목록 · 인용

interface ListItem {
  indent: string;
  marker: string;
  kind: BlockStyle | null;
}

const listPattern = /^([ \t]*)(?:([-*+][ \t]+\[[ xX]\][ \t]+)|([-*+][ \t]+)|(\d{1,9}[.)][ \t]+))?/;

function listItem(line: string): ListItem {
  const match = listPattern.exec(line)!;
  const indent = match[1] ?? "";
  if (match[2]) return { indent, marker: match[2], kind: "task" };
  if (match[3]) return { indent, marker: match[3], kind: "bullet" };
  if (match[4]) return { indent, marker: match[4], kind: "numbered" };
  return { indent, marker: "", kind: null };
}

/** 줄을 목록(글머리 · 번호 · 할 일)이나 인용으로, 모두 이미 그것이면 푼다. 다른 목록이면 바꾼다. 번호는 같은 들여쓰기마다 1부터 다시 센다. */
export function toggleBlock(block: BlockStyle, text: string, selection: Span): FormatEdit | null {
  if (block === "quote") return toggleQuote(text, selection);
  return rewriteLines(text, selection, (lines) => {
    if (lines.length === 1 && isBlank(lines[0]!)) {
      const marker = block === "bullet" ? "- " : block === "numbered" ? "1. " : "- [ ] ";
      return [[lines[0]!.length, marker]];
    }
    const items = lines.filter((line) => !isBlank(line)).map(listItem);
    const all = items.length > 0 && items.every((item) => item.kind === block);
    let counters = new Map<number, number>(); // 들여쓰기 폭 → 다음 번호
    return lines.map((line): [number, string] | null => {
      if (isBlank(line)) return null;
      const item = listItem(line);
      const oldPrefix = item.indent.length + item.marker.length;
      if (all) return [oldPrefix, item.indent];
      switch (block) {
        case "bullet":
          return [oldPrefix, `${item.indent}- `];
        case "task":
          // 이미 할 일이면 체크 상태를 그대로 둔다.
          return item.kind === "task" ? null : [oldPrefix, `${item.indent}- [ ] `];
        case "numbered": {
          const depth = item.indent.length;
          counters = new Map([...counters].filter(([key]) => key <= depth));
          const number = counters.get(depth) ?? 1;
          counters.set(depth, number + 1);
          return [oldPrefix, `${item.indent}${number}. `];
        }
      }
    });
  });
}

/** 인용 — 모든 글 줄이 `>`로 시작하면 한 겹 벗기고, 아니면 `> `를 붙인다. 글 줄 사이의 빈 줄은 `>`가 되어 한 덩이로 남는다. */
function toggleQuote(text: string, selection: Span): FormatEdit | null {
  return rewriteLines(text, selection, (lines) => {
    if (lines.length === 1 && isBlank(lines[0]!)) return [[lines[0]!.length, "> "]];
    const filled = lines.flatMap((line, index) => (isBlank(line) ? [] : [index]));
    if (filled.length === 0) return lines.map(() => null);
    const firstFilled = filled[0]!;
    const lastFilled = filled[filled.length - 1]!;
    const quoted = filled.every((index) => lines[index]!.startsWith(">"));
    return lines.map((line, index): [number, string] | null => {
      if (quoted) return line.startsWith(">") ? [line.startsWith("> ") ? 2 : 1, ""] : null;
      if (isBlank(line)) return index > firstFilled && index < lastFilled ? [line.length, ">"] : null;
      return line.startsWith(">") ? null : [0, "> "];
    });
  });
}

// MARK: 링크

export function isAddress(value: string): boolean {
  if (/\s/.test(value)) return false;
  const lower = value.toLowerCase();
  return ["http://", "https://", "mailto:", "www."].some((prefix) => lower.startsWith(prefix) && lower.length > prefix.length);
}

/** 링크. 고른 것이 없으면 `[]()`, 고른 글이 주소면 `[](주소)`(캐럿은 `[]` 안), 아니면 `[글]()`(캐럿은 `()` 안). 여러 줄은 안 된다. */
export function link(text: string, selection: Span): FormatEdit | null {
  const selected = text.slice(selection.from, selection.to);
  if (/[\n\r\u2028\u2029\u0085]/.test(selected)) return null;
  const start = selection.from;
  if (selected === "" || isAddress(selected)) {
    return { from: selection.from, to: selection.to, insert: `[](${selected})`, selection: { from: start + 1, to: start + 1 } };
  }
  const caret = start + selected.length + 3;
  return { from: selection.from, to: selection.to, insert: `[${selected}]()`, selection: { from: caret, to: caret } };
}

// MARK: 코드 블록 · 표 · 구분선

/** 코드 블록. 고른 줄을 울타리로 감싸고 캐럿을 여는 울타리 뒤에(언어 이름을 바로 쓴다). 빈 줄에서는 빈 블록, 이미 감싼 줄은 푼다. */
export function codeBlock(text: string, selection: Span): FormatEdit | null {
  const block = lineBlock(text, selection);
  const blockText = text.slice(block.from, block.to);
  const ending = terminator(blockText);
  const body = blockText.slice(0, blockText.length - ending.length);
  const lines = body.split("\n");
  const first = lines[0]!;
  const last = lines[lines.length - 1]!;
  if (lines.length >= 2 && first.trim().startsWith("```") && last.trim() === "```") {
    const inner = lines.slice(1, -1).join("\n");
    return {
      from: block.from, to: block.to, insert: inner === "" ? ending : inner + ending,
      selection: { from: block.from, to: block.from + inner.length },
    };
  }
  if (body.trim() === "" && !body.includes("\n")) {
    return { from: block.from, to: block.to, insert: `\`\`\`\n\n\`\`\`${ending}`, selection: { from: block.from + 4, to: block.from + 4 } };
  }
  return {
    from: block.from, to: block.to, insert: `\`\`\`\n${body}\n\`\`\`${ending}`,
    selection: { from: block.from + 3, to: block.from + 3 },
  };
}

/** 표 — 열 둘, 머리와 빈 행 하나. 첫 머리 칸의 글을 골라 두어 바로 덮어 쓴다. */
export function table(text: string, selection: Span, columnTitle: (column: number) => string = (column) => `열 ${column}`): FormatEdit {
  const first = columnTitle(1);
  const body = `| ${first} | ${columnTitle(2)} |\n| --- | --- |\n|  |  |`;
  return insertBlock(body, text, selection, { from: 2, to: 2 + first.length });
}

/** 구분선(`---`). 앞 줄이 글이면 빈 줄을 하나 둔다 — 글 바로 아래의 `---`는 구분선이 아니라 제목 2다. */
export function rule(text: string, selection: Span): FormatEdit {
  return insertBlock("---", text, selection, { from: 3, to: 3 });
}

/** 블록을 캐럿 줄에 넣는다. 캐럿 줄이 비었으면 그 자리에, 글이 있으면 그 아래에. 위아래의 글 줄과는 빈 줄 하나로 띄운다. */
function insertBlock(body: string, text: string, selection: Span, select: Span): FormatEdit {
  const location = Math.min(selection.from, text.length);
  const line = lineRange(text, location);
  const lineText = text.slice(line.from, line.to);
  const ending = terminator(lineText);
  const content = { from: line.from, to: line.to - ending.length };
  const blank = isBlank(text.slice(content.from, content.to));
  const filledAt = (start: number) => {
    if (start < 0 || start >= text.length) return false;
    const other = lineRange(text, start);
    return text.slice(other.from, other.to).trim() !== "";
  };
  let range: Span;
  let lead = "";
  let trail = "";
  if (blank) {
    range = content;
    if (filledAt(line.from - 1)) lead = "\n";
    if (ending !== "" && filledAt(line.to)) trail = "\n";
  } else if (ending === "") {
    range = { from: line.to, to: line.to }; // 마지막 줄 — 줄 끝이 없다
    lead = "\n\n";
  } else {
    range = { from: line.to, to: line.to };
    lead = "\n";
    trail = filledAt(line.to) ? "\n\n" : "\n";
  }
  const start = range.from + lead.length;
  return { ...range, insert: lead + body + trail, selection: { from: start + select.from, to: start + select.to } };
}

// MARK: 명령 이름 — 편집기 · 메뉴 · 명령 팔레트가 함께 쓴다

export type FormatCommand =
  | InlineStyle | BlockStyle | "link" | "codeBlock" | "table" | "rule" | `heading${0 | 1 | 2 | 3 | 4 | 5 | 6}`;

export function formatEdit(command: string, text: string, selection: Span): FormatEdit | null {
  const heading_ = /^heading([0-6])$/.exec(command);
  if (heading_) return heading(Number(heading_[1]), text, selection);
  switch (command) {
    case "bold":
    case "italic":
    case "strikethrough":
    case "code":
      return toggleInline(command, text, selection);
    case "bullet":
    case "numbered":
    case "task":
    case "quote":
      return toggleBlock(command, text, selection);
    case "link":
      return link(text, selection);
    case "codeBlock":
      return codeBlock(text, selection);
    case "table":
      return table(text, selection);
    case "rule":
      return rule(text, selection);
    default:
      return null;
  }
}
