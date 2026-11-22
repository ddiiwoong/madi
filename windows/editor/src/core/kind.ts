// 파일이 마크다운인가, 글(텍스트 · 로그)인가 — 확장자로 가린다. macOS판 `TextFileKind`와 같다.
//
// 글 파일을 마크다운으로 그리면 내용이 바뀌어 보인다(로그의 `# ` 줄이 제목, `**`가 사라짐). 그래서 마크다운이 아닌 파일은
// 원본 보기로 연다 — 쓴 그대로, 고정폭 글꼴로, 창 폭을 다 써서. 로그는 따라 보기로 연다.

export type FileKind = "markdown" | "plainText" | "log";

export const markdownExtensions = new Set(["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]);
export const plainTextExtensions = new Set(["txt", "text"]);
export const logExtensions = new Set(["log"]);

/** 열기 창이 거르는 확장자 — 위 셋을 합친 것. */
export const openableExtensions = new Set([...markdownExtensions, ...plainTextExtensions, ...logExtensions]);

/** 이름(경로)의 확장자로. 저장하지 않은 새 문서(`null`)는 마크다운, 모르는 확장자는 글이다. */
export function fileKind(name: string | null): FileKind {
  if (name === null) return "markdown";
  const base = name.split(/[\\/]/).pop() ?? name;
  const dot = base.lastIndexOf(".");
  const ext = dot > 0 ? base.slice(dot + 1).toLowerCase() : "";
  if (markdownExtensions.has(ext)) return "markdown";
  if (logExtensions.has(ext)) return "log";
  return "plainText";
}
