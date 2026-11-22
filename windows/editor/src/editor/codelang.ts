// 코드 블록의 문법 색 — 마크다운 문법이 펜스 안을 그 언어로 다시 읽게 한다(`markdown({ codeLanguages })`). 언어 꾸러미는 따로 묶여
// (esbuild의 나눠 묶기, `dist/chunks/`) 그 언어의 블록이 처음 보일 때 싣는다. 색은 테마의 것(`setup.ts`의 `highlighting`).

import { LanguageDescription, LanguageSupport, StreamLanguage } from "@codemirror/language";
import { codeLanguage, type CodeLanguage } from "../core/codelang.ts";

const loaders: Record<CodeLanguage, () => Promise<LanguageSupport>> = {
  javascript: () => import("@codemirror/lang-javascript").then((m) => m.javascript({ jsx: true })),
  typescript: () => import("@codemirror/lang-javascript").then((m) => m.javascript({ jsx: true, typescript: true })),
  python: () => import("@codemirror/lang-python").then((m) => m.python()),
  json: () => import("@codemirror/lang-json").then((m) => m.json()),
  rust: () => import("@codemirror/lang-rust").then((m) => m.rust()),
  go: () => import("@codemirror/lang-go").then((m) => m.go()),
  yaml: () => import("@codemirror/lang-yaml").then((m) => m.yaml()),
  css: () => import("@codemirror/lang-css").then((m) => m.css()),
  html: () => import("@codemirror/lang-html").then((m) => m.html()),
  sql: () => import("@codemirror/lang-sql").then((m) => m.sql()),
  // Swift · 셸은 CodeMirror 5의 모드(`legacy-modes`)를 줄 단위 읽기로 쓴다.
  swift: () => import("@codemirror/legacy-modes/mode/swift").then((m) => new LanguageSupport(StreamLanguage.define(m.swift))),
  shell: () => import("@codemirror/legacy-modes/mode/shell").then((m) => new LanguageSupport(StreamLanguage.define(m.shell))),
};

const descriptions = new Map<CodeLanguage, LanguageDescription>();

/** `markdown({ codeLanguages })`에 준다 — 모르는 이름이면 null(칠하지 않는다). */
export function codeLanguageFor(info: string): LanguageDescription | null {
  const language = codeLanguage(info);
  if (!language) return null;
  let description = descriptions.get(language);
  if (!description) {
    description = LanguageDescription.of({ name: language, load: loaders[language] });
    descriptions.set(language, description);
  }
  return description;
}
