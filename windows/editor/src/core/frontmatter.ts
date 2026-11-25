// 앞머리(front matter) — 문서 맨 위의 `---` 블록. macOS판 `FrontMatter.parse`와 같은 규칙으로 항목을 읽는다.
//
// macOS판은 앞머리를 떼어 카드로 두고 본문만 편집기에 싣는다. Windows판은 문서를 통째로 편집기에 두고, 캐럿이 앞머리 밖에 있으면
// 그 줄들을 카드 하나로 바꿔 보인다(장식). 그래서 저장하는 글은 늘 파일 그대로다.

export type FrontMatterValue = { kind: "scalar"; text: string } | { kind: "list"; items: string[] };

export interface FrontMatterField {
  key: string;
  value: FrontMatterValue;
}

export interface FrontMatter {
  /** 닫는 줄(`---` · `...`)의 번호 — 0부터. 여는 줄은 0이다. */
  closingLine: number;
  fields: FrontMatterField[];
}

const isListItem = (line: string) => {
  const trimmed = line.trim();
  return trimmed.startsWith("- ") || trimmed === "-";
};

const isIndentedContinuation = (line: string) => (line.startsWith(" ") || line.startsWith("\t")) && !isListItem(line);

function unquote(value: string): string {
  if (value.length >= 2 && ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
    return value.slice(1, -1);
  }
  return value;
}

/** 줄들(줄 끝을 뗀 것)에서. 맨 앞이 `---`가 아니거나 닫히지 않으면 null — 그냥 `---`로 시작하는 글이다. */
export function parseFrontMatter(lines: readonly string[]): FrontMatter | null {
  if (lines[0] !== "---" || lines.length < 2) return null;
  let closing = -1;
  for (let index = 1; index < lines.length; index++) {
    if (lines[index] === "---" || lines[index] === "...") {
      closing = index;
      break;
    }
  }
  if (closing < 0) return null;
  return { closingLine: closing, fields: parseFields(lines.slice(1, closing)) };
}

function parseFields(lines: readonly string[]): FrontMatterField[] {
  const fields: FrontMatterField[] = [];
  let index = 0;
  while (index < lines.length) {
    const line = lines[index]!;
    index++;
    const colon = line.indexOf(":");
    if (line.trim() === "" || line.trim().startsWith("#") || colon < 0 || /^\s/.test(line)) continue;
    const key = line.slice(0, colon).trim();
    if (key === "") continue;
    let rest = line.slice(colon + 1).trim();

    if (rest.startsWith("[") && rest.endsWith("]")) {
      const items = rest.slice(1, -1).split(",").map((item) => unquote(item.trim())).filter((item) => item !== "");
      fields.push({ key, value: { kind: "list", items } });
      continue;
    }
    if (rest === "" && index < lines.length && isListItem(lines[index]!)) {
      const items: string[] = [];
      while (index < lines.length && isListItem(lines[index]!)) {
        items.push(unquote(lines[index]!.trim().slice(1).trim()));
        index++;
      }
      fields.push({ key, value: { kind: "list", items } });
      continue;
    }
    if (rest === "|" || rest === ">" || rest === "|-" || rest === ">-") {
      const parts: string[] = [];
      while (index < lines.length && isIndentedContinuation(lines[index]!)) {
        parts.push(lines[index]!.trim());
        index++;
      }
      fields.push({ key, value: { kind: "scalar", text: parts.join(" ") } });
      continue;
    }
    const continuation: string[] = [];
    while (index < lines.length && isIndentedContinuation(lines[index]!)) {
      continuation.push(lines[index]!.trim());
      index++;
    }
    if (continuation.length > 0) rest = [rest, ...continuation].filter((part) => part !== "").join(" ");
    fields.push({ key, value: { kind: "scalar", text: unquote(rest) } });
  }
  return fields;
}
