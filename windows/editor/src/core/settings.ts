// 설정 — 모든 창이 함께 쓴다. 껍데기가 `%APPDATA%\Madi\settings.json`에 두고, 바뀌면 열린 창 모두에 보낸다.
// 값과 범위는 macOS판 `EditorPreferences`와 같다.

import { palettes, paletteFields, themeIds, type ThemeId } from "./palette.ts";

export type Appearance = "system" | "light" | "dark";
export type LineSpacing = "tight" | "normal" | "loose";
export type DocumentWidth = "narrow" | "normal" | "wide" | "full";
export type PrintMargin = "narrow" | "normal" | "wide";
export type PrintOrientation = "portrait" | "landscape";
/** `system`은 Windows의 기본 프린터 용지(없으면 지역에 맞춰 A4 · Letter). */
export type PrintPaper = "system" | "a4" | "letter";

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
  /** PDF 내보내기 · 프린트(둘이 같은 설정 — macOS판과 같다). */
  printMargin: PrintMargin;
  printOrientation: PrintOrientation;
  printPaper: PrintPaper;
  /** 켤 때 하루 한 번 GitHub에 새 판을 묻는다. 기본 켜짐(macOS판 — 2026-11-09 사용자가 골랐다). 보내는 것은 판을 묻는 GET 하나. */
  checksForUpdates: boolean;
  /**
   * 제목 막대 아래의 메뉴 막대(파일 · 편집 · 서식 · 보기 · 도구 · 도움말과 서식 단추 — 껍데기의 `MenuBar.cs`). 기본 꺼짐 — 메뉴는 제목 막대의
   * `…`에 다 있다(2026-11-26 사용자 — "기본값은 현재 처럼 하고, 옵션을 키면 메뉴바가 보이게"). 켜면 Alt · Alt+글자가 그 메뉴를 연다.
   */
  showsMenuBar: boolean;
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
  printMargin: "normal",
  printOrientation: "portrait",
  printPaper: "system",
  checksForUpdates: true,
  showsMenuBar: false,
};

/** 여백(pt) — macOS판 `PrintMargin.points`. */
export const printMarginPoints: Record<PrintMargin, number> = { narrow: 24, normal: 48, wide: 84 };

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
    printMargin: pick("printMargin", ["narrow", "normal", "wide"] as const, defaultSettings.printMargin),
    printOrientation: pick("printOrientation", ["portrait", "landscape"] as const, defaultSettings.printOrientation),
    printPaper: pick("printPaper", ["system", "a4", "letter"] as const, defaultSettings.printPaper),
    // 끄는 것만 받는다 — 깨진 값이 확인을 끄지 않게(기본이 켜짐).
    checksForUpdates: value.checksForUpdates !== false,
    showsMenuBar: value.showsMenuBar === true,
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
