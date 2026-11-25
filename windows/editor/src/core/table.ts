// GFM 표 — 줄들에서 칸과 열 맞춤을 읽는다. 그리는 일은 `editor/blocks.ts`.

export type Align = "left" | "center" | "right" | null;

export interface Table {
  header: string[];
  align: Align[];
  rows: string[][];
}

/** 한 줄을 칸으로. 앞뒤의 `|`는 떼고, `\|`와 `` `…` `` 안의 `|`는 칸을 나누지 않는다. 칸 안의 `\|`는 그대로 둔다(그릴 때 푼다). */
export function splitRow(line: string): string[] {
  let text = line.trim();
  if (text.startsWith("|")) text = text.slice(1);
  if (text.endsWith("|") && !text.endsWith("\\|")) text = text.slice(0, -1);
  const cells: string[] = [];
  let current = "";
  let inCode = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i]!;
    if (char === "\\" && text[i + 1] === "|") {
      current += "\\|";
      i++;
      continue;
    }
    if (char === "`") inCode = !inCode;
    if (char === "|" && !inCode) {
      cells.push(current.trim());
      current = "";
      continue;
    }
    current += char;
  }
  cells.push(current.trim());
  return cells;
}

/** 구분 줄(`|:---|---:|`)의 칸마다 맞춤. 구분 줄이 아니면 null. */
export function parseAlign(line: string): Align[] | null {
  const cells = splitRow(line);
  if (cells.length === 0) return null;
  const aligns: Align[] = [];
  for (const cell of cells) {
    if (!/^:?-+:?$/.test(cell)) return null;
    const left = cell.startsWith(":");
    const right = cell.endsWith(":");
    aligns.push(left && right ? "center" : right ? "right" : left ? "left" : null);
  }
  return aligns;
}

/** 표의 줄들(머리 · 구분 · 행). 열 수는 머리를 따른다 — 모자란 칸은 비우고 넘치는 칸은 버린다(GFM과 같다). */
export function parseTable(lines: readonly string[]): Table | null {
  if (lines.length < 2) return null;
  const header = splitRow(lines[0]!);
  const align = parseAlign(lines[1]!);
  if (!align) return null;
  const width = header.length;
  const fit = (cells: string[]) => Array.from({ length: width }, (_, index) => cells[index] ?? "");
  return {
    header,
    align: Array.from({ length: width }, (_, index) => align[index] ?? null),
    rows: lines.slice(2).map((line) => fit(splitRow(line))),
  };
}
