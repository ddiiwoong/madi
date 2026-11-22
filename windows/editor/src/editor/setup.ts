// 편집기의 보기 — 원본 보기 · 따라 보기 · 파일 종류에 따라 바뀌는 확장들(Compartment)과 겉모양(테마).

import { Compartment, EditorState, type Extension, type StateEffect } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { defaultHighlightStyle, HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import type { FileKind } from "../core/kind.ts";
import type { LineSeparator } from "../core/lines.ts";
import { livePreview } from "./preview.ts";

export interface Mode {
  kind: FileKind;
  /** 원본 보기(Ctrl+E) — 쓴 그대로, 고정폭. 글 파일은 이것으로 연다. */
  source: boolean;
  /** 따라 보기(Ctrl+Alt+L) — 고칠 수 없게, 끝을 따라간다. 로그는 이것으로 연다. */
  follow: boolean;
  separator: LineSeparator;
}

const separator = new Compartment();
const language = new Compartment();
const preview = new Compartment();
const readOnly = new Compartment();
const classes = new Compartment();

/** 글 파일을 쓴 그대로 볼 때는 창 폭을 다 쓴다(macOS판 `fitsTextToWindow`). 마크다운은 읽기 좋은 폭에서 멈춘다. */
export function fitsWindow(mode: Mode): boolean {
  return mode.kind !== "markdown" && mode.source;
}

function parts(mode: Mode) {
  // 글 파일을 원본 보기로 보면 마크다운 문법을 칠하지 않는다 — 로그의 `# `는 표식이 아니라 내용이다.
  const usesMarkdown = mode.kind === "markdown" || !mode.source;
  return {
    separator: EditorState.lineSeparator.of(mode.separator),
    language: usesMarkdown ? markdown({ base: markdownLanguage }) : [],
    preview: mode.source ? [] : livePreview,
    readOnly: [EditorState.readOnly.of(mode.follow), EditorView.editable.of(!mode.follow)],
    classes: EditorView.editorAttributes.of({
      class: [mode.source ? "md-source" : "", fitsWindow(mode) ? "md-wide" : "", mode.follow ? "md-follow" : ""]
        .filter(Boolean).join(" "),
    }),
  };
}

export function modeExtensions(mode: Mode): Extension[] {
  const p = parts(mode);
  return [
    separator.of(p.separator),
    language.of(p.language),
    preview.of(p.preview),
    readOnly.of(p.readOnly),
    classes.of(p.classes),
  ];
}

export function reconfigure(mode: Mode): StateEffect<unknown>[] {
  const p = parts(mode);
  return [
    language.reconfigure(p.language),
    preview.reconfigure(p.preview),
    readOnly.reconfigure(p.readOnly),
    classes.reconfigure(p.classes),
  ];
}

// 글꼴 · 글 폭 · 꾸밈. style.css에 적으면 CodeMirror의 기본 테마(클래스 둘)에 밀린다 — 0단계에서 그랬다. 테마의 규칙은 클래스가 하나 더 붙는다.
// 글 폭은 macOS판과 같다: 본문 크기의 56배(15px에서 840px), 창이 넓으면 남는 자리를 양옆에 반씩. 제목 크기도 macOS판의 배율.
const dim = "color-mix(in srgb, CanvasText 45%, Canvas)";
const tint = "color-mix(in srgb, CanvasText 6%, Canvas)";
const mono = '"IBM Plex Mono", Consolas, monospace';

export const look = EditorView.theme({
  "&": { height: "100%" },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": { fontFamily: '"Pretendard", "Malgun Gothic", sans-serif', fontSize: "15px", lineHeight: "1.6" },
  ".cm-content": { padding: "24px max(28px, calc((100% - 840px) / 2))" },
  "&.md-wide .cm-content": { padding: "16px 28px" },
  "&.md-source .cm-scroller": { fontFamily: mono, fontSize: "14px" },
  ".cm-md-line-h1": { fontSize: "1.85em", fontWeight: "700", lineHeight: "1.3", paddingTop: "0.4em" },
  ".cm-md-line-h2": { fontSize: "1.45em", fontWeight: "700", lineHeight: "1.35", paddingTop: "0.3em" },
  ".cm-md-line-h3": { fontSize: "1.22em", fontWeight: "700" },
  ".cm-md-line-h4": { fontSize: "1.08em", fontWeight: "700" },
  ".cm-md-line-h5, .cm-md-line-h6": { fontWeight: "700" },
  ".cm-md-strong": { fontWeight: "700" },
  ".cm-md-emphasis": { fontStyle: "italic" },
  ".cm-md-strike": { textDecoration: "line-through" },
  ".cm-md-code": { fontFamily: mono, fontSize: "0.92em", background: tint, borderRadius: "3px", padding: "0 2px" },
  ".cm-md-link": { color: "LinkText", textDecoration: "underline", textUnderlineOffset: "2px" },
  ".cm-md-line-quote": { borderLeft: `3px solid ${dim}`, paddingLeft: "12px", color: "color-mix(in srgb, CanvasText 75%, Canvas)" },
  ".cm-md-line-code": { fontFamily: mono, fontSize: "14px", background: tint },
  ".cm-md-line-fence": { color: dim },
  ".cm-md-bullet": { display: "inline-block", minWidth: "0.8em", fontSize: "0.7em", verticalAlign: "0.15em" },
  ".cm-md-rule": { display: "inline-block", width: "100%", borderTop: `1px solid ${dim}`, verticalAlign: "middle" },
  ".cm-panels": { background: "Canvas", color: "CanvasText" },
  ".cm-panels-top": { borderBottom: `1px solid ${tint}` },
});

/**
 * 문법 색 — CodeMirror의 기본 색에서 제목의 밑줄만 뺐다(macOS판의 제목에는 밑줄이 없다. 1단계 CI 화면에서 밑줄이 보였다).
 * 코드 블록 안의 색은 기본 그대로다.
 */
export const highlighting = syntaxHighlighting(HighlightStyle.define(
  defaultHighlightStyle.specs.map((spec) =>
    spec.textDecoration === "underline" && spec.fontWeight === "bold" ? { ...spec, textDecoration: "none" } : spec),
));

/** CodeMirror 찾기 · 바꾸기 칸의 한국어. */
export const koreanPhrases = EditorState.phrases.of({
  "Find": "찾기",
  "Replace": "바꿀 말",
  "next": "다음",
  "previous": "이전",
  "all": "모두",
  "match case": "대소문자 구분",
  "regexp": "정규식",
  "by word": "낱말 단위",
  "replace": "바꾸기",
  "replace all": "모두 바꾸기",
  "close": "닫기",
  "current match": "지금 찾은 것",
  "replaced $ matches": "$개를 바꿨습니다",
  "replaced match on line $": "$번째 줄을 바꿨습니다",
  "on line": "줄",
  "Go to line": "줄로 가기",
  "go": "가기",
});
