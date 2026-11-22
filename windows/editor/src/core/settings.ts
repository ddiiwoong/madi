// 설정 — 모든 창이 함께 쓴다. 껍데기가 `%APPDATA%\Madi\settings.json`에 두고, 바뀌면 열린 창 모두에 보낸다.
// 값과 범위는 macOS판 `EditorPreferences`와 같다.

import { palettes, paletteFields, themeIds, type ThemeId } from "./palette.ts";

export type Appearance = "system" | "light" | "dark";
export type LineSpacing = "tight" | "normal" | "loose";
export type DocumentWidth = "narrow" | "normal" | "wide" | "full";

export interface Settings {
  theme: ThemeId;
  appearance: Appearance;
  /** null이면 앱에 든 Pretendard. */
  bodyFont: string | null;
  /** null이면 앱에 든 IBM Plex Mono. */
  codeFont: string | null;
  bodySize: number;
  lineSpacing: LineSpacing;
  documentWidth: DocumentWidth;
  /** 원격 그림(`https://…`)을 받는가. 기본 꺼짐 — 문서를 연 것만으로 바깥에 요청이 나가지 않게(macOS판과 같다). */
  loadsRemoteImages: boolean;
  collapsesFrontMatter: boolean;
}

export const sizeRange = { min: 10, max: 28 } as const;

export const defaultSettings: Settings = {
  theme: "standard",
  appearance: "system",
  bodyFont: null,
  codeFont: null,
  bodySize: 15,
  lineSpacing: "normal",
  documentWidth: "normal",
  loadsRemoteImages: false,
  collapsesFrontMatter: false,
};

const lineSpacingScale: Record<LineSpacing, number> = { tight: 0.22, normal: 0.42, loose: 0.7 };
const widthMultiple: Record<DocumentWidth, number | null> = { narrow: 42, normal: 56, wide: 76, full: null };

export function clampSize(size: number): number {
  if (!Number.isFinite(size)) return defaultSettings.bodySize;
  return Math.min(sizeRange.max, Math.max(sizeRange.min, Math.round(size)));
}

/** 껍데기가 준 값(손으로 고친 파일일 수 있다) — 모르는 값은 기본으로. */
export function normalizeSettings(raw: unknown): Settings {
  const value = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const pick = <T extends string>(key: string, allowed: readonly T[], fallback: T): T =>
    allowed.includes(value[key] as T) ? (value[key] as T) : fallback;
  const font = (key: string) => (typeof value[key] === "string" && (value[key] as string).trim() !== "" ? (value[key] as string) : null);
  return {
    theme: pick("theme", themeIds, defaultSettings.theme),
    appearance: pick("appearance", ["system", "light", "dark"] as const, defaultSettings.appearance),
    bodyFont: font("bodyFont"),
    codeFont: font("codeFont"),
    bodySize: clampSize(typeof value.bodySize === "number" ? value.bodySize : defaultSettings.bodySize),
    lineSpacing: pick("lineSpacing", ["tight", "normal", "loose"] as const, defaultSettings.lineSpacing),
    documentWidth: pick("documentWidth", ["narrow", "normal", "wide", "full"] as const, defaultSettings.documentWidth),
    loadsRemoteImages: value.loadsRemoteImages === true,
    collapsesFrontMatter: value.collapsesFrontMatter === true,
  };
}

const quote = (family: string) => `"${family.replace(/["\\]/g, "")}"`;

/**
 * 문서 뿌리(`:root`)에 줄 CSS 변수 — 테마의 색(라이트 · 다크 중 하나), 글꼴, 크기, 줄 높이, 글 폭. 편집기의 테마가 이것을 읽는다.
 * 줄 높이는 macOS판의 줄 사이(본문 크기 × 배율)를 CSS의 줄 높이로 옮긴 것이다(글자 높이 1.2em + 줄 사이).
 */
export function cssVariables(settings: Settings, dark: boolean): Record<string, string> {
  const palette = palettes[settings.theme];
  const variables: Record<string, string> = {};
  for (const field of paletteFields) {
    variables[`--md-${field.replace(/[A-Z]/g, (char) => `-${char.toLowerCase()}`)}`] = palette[field][dark ? 1 : 0];
  }
  const body = settings.bodyFont ? `${quote(settings.bodyFont)}, ` : "";
  const code = settings.codeFont ? `${quote(settings.codeFont)}, ` : "";
  variables["--md-font-body"] = `${body}"Pretendard", "Malgun Gothic", sans-serif`;
  variables["--md-font-code"] = `${code}"IBM Plex Mono", Consolas, monospace`;
  variables["--md-size"] = `${settings.bodySize}px`;
  variables["--md-line-height"] = (1.2 + lineSpacingScale[settings.lineSpacing]).toFixed(2);
  const multiple = widthMultiple[settings.documentWidth];
  variables["--md-width"] = multiple === null ? "100000px" : `${multiple * settings.bodySize}px`;
  return variables;
}
