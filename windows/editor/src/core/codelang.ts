// 코드 블록의 언어 — 펜스의 정보 글(```` ```ts ````)을 문법 색을 칠할 언어로. 이름 · 별명은 macOS판 `CodeHighlighter`와 같고,
// 거기에 TypeScript를 따로 둔다(macOS판은 JavaScript 규칙으로 함께 칠한다 — 여기서는 CodeMirror의 TypeScript 문법이 있다).
// 모르는 이름은 칠하지 않는다(고정폭 · 테마의 코드 색만). 언어 꾸러미는 그 블록이 처음 보일 때 싣는다(`editor/codelang.ts`).

export type CodeLanguage =
  | "swift" | "javascript" | "typescript" | "python" | "shell" | "json" | "rust" | "go" | "yaml" | "css" | "html" | "sql";

const aliases: Record<CodeLanguage, readonly string[]> = {
  swift: ["swift"],
  javascript: ["js", "javascript", "jsx", "mjs", "cjs"],
  typescript: ["ts", "typescript", "tsx", "mts", "cts"],
  python: ["py", "python", "python3"],
  shell: ["sh", "shell", "bash", "zsh", "console", "terminal", "ps1", "powershell", "pwsh"],
  json: ["json", "jsonc"],
  rust: ["rs", "rust"],
  go: ["go", "golang"],
  yaml: ["yml", "yaml"],
  css: ["css", "scss", "less"],
  html: ["html", "htm", "xml", "svg", "xhtml"],
  sql: ["sql", "postgresql", "psql", "mysql", "sqlite"],
};

const byAlias = new Map<string, CodeLanguage>();
for (const [language, names] of Object.entries(aliases) as [CodeLanguage, readonly string[]][]) {
  for (const name of names) byAlias.set(name, language);
}

/** 정보 글의 첫 낱말(대소문자 무시, `{.python}` · `python title="x"` 꼴도) → 언어. */
export function codeLanguage(info: string): CodeLanguage | null {
  const word = info.trim().split(/[\s{},]+/).find((part) => part !== "")?.replace(/^\./, "").toLowerCase() ?? "";
  return byAlias.get(word) ?? null;
}
