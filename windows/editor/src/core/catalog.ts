// 명령 목록 — 명령 팔레트(Ctrl+Shift+P)가 보이는 것. macOS판은 메뉴 바를 훑지만, Windows판은 메뉴(WPF)와 편집기가 다른 프로세스라
// 편집기가 이 표 하나를 갖고 껍데기의 메뉴도 같은 이름(`id`)을 부른다. 설정 명령은 지금 값에 ✓를 단다.

import { themeIds, themeLabels } from "./palette.ts";
import {
  clampSize, defaultSettings, type Appearance, type DocumentWidth, type LineSpacing, type PrintMargin, type PrintOrientation,
  type PrintPaper, type Settings,
} from "./settings.ts";

export interface CatalogEntry {
  /** `commands` in main.ts. */
  id: string;
  arg?: string;
  title: string;
  /** 메뉴의 자리 — `보기 ▸ 테마`. 거를 때 둘째로 본다. */
  menu: string;
  shortcut?: string;
  checked?: boolean;
}

export interface CatalogContext {
  settings: Settings;
  source: boolean;
  follow: boolean;
  outline: boolean;
}

const appearances: [Appearance, string][] = [["system", "시스템 따라"], ["light", "밝게"], ["dark", "어둡게"]];
const spacings: [LineSpacing, string][] = [["tight", "좁게"], ["normal", "보통"], ["loose", "넓게"]];
const widths: [DocumentWidth, string][] = [["narrow", "좁게"], ["normal", "보통"], ["wide", "넓게"], ["full", "창 폭 전체"]];
const margins: [PrintMargin, string][] = [["narrow", "좁게"], ["normal", "보통"], ["wide", "넓게"]];
const orientations: [PrintOrientation, string][] = [["portrait", "세로"], ["landscape", "가로"]];
const papers: [PrintPaper, string][] = [["system", "시스템 기본"], ["a4", "A4"], ["letter", "Letter"]];

export function catalog(context: CatalogContext): CatalogEntry[] {
  const { settings } = context;
  return [
    { id: "new", title: "새로 만들기", menu: "파일", shortcut: "Ctrl+N" },
    { id: "open", title: "열기…", menu: "파일", shortcut: "Ctrl+O" },
    { id: "quickOpen", title: "빠른 열기…", menu: "파일", shortcut: "Ctrl+Alt+O" },
    { id: "save", title: "저장", menu: "파일", shortcut: "Ctrl+S" },
    { id: "saveAs", title: "다른 이름으로 저장…", menu: "파일", shortcut: "Ctrl+Shift+S" },
    { id: "exportPdf", title: "PDF 내보내기…", menu: "파일" },
    { id: "print", title: "프린트하기…", menu: "파일", shortcut: "Ctrl+P" },
    ...margins.map(([value, title]) =>
      ({ id: "setPrintMargin", arg: value, title, menu: "파일 ▸ 프린트 설정 ▸ 여백", checked: settings.printMargin === value })),
    ...orientations.map(([value, title]) =>
      ({ id: "setPrintOrientation", arg: value, title, menu: "파일 ▸ 프린트 설정 ▸ 방향", checked: settings.printOrientation === value })),
    ...papers.map(([value, title]) =>
      ({ id: "setPrintPaper", arg: value, title, menu: "파일 ▸ 프린트 설정 ▸ 용지", checked: settings.printPaper === value })),
    { id: "close", title: "닫기", menu: "파일", shortcut: "Ctrl+W" },
    { id: "undo", title: "실행 취소", menu: "편집", shortcut: "Ctrl+Z" },
    { id: "redo", title: "다시 실행", menu: "편집", shortcut: "Ctrl+Y" },
    { id: "selectAll", title: "모두 선택", menu: "편집", shortcut: "Ctrl+A" },
    { id: "find", title: "찾기…", menu: "편집", shortcut: "Ctrl+F" },
    { id: "toggleOutline", title: "목차", menu: "보기", shortcut: "Ctrl+Shift+O", checked: context.outline },
    { id: "toggleSource", title: "원본 보기", menu: "보기", shortcut: "Ctrl+E", checked: context.source },
    { id: "toggleFollow", title: "따라 보기", menu: "보기", shortcut: "Ctrl+Alt+L", checked: context.follow },
    ...themeIds.map((id) => ({ id: "setTheme", arg: id, title: themeLabels[id], menu: "보기 ▸ 테마", checked: settings.theme === id })),
    ...appearances.map(([value, title]) =>
      ({ id: "setAppearance", arg: value, title, menu: "보기 ▸ 모양", checked: settings.appearance === value })),
    { id: "textBigger", title: "글자 크게", menu: "보기", shortcut: "Ctrl+=" },
    { id: "textSmaller", title: "글자 작게", menu: "보기", shortcut: "Ctrl+-" },
    { id: "textStandard", title: "글자 기본 크기", menu: "보기", shortcut: "Ctrl+0" },
    ...spacings.map(([value, title]) =>
      ({ id: "setLineSpacing", arg: value, title, menu: "보기 ▸ 줄 사이", checked: settings.lineSpacing === value })),
    ...widths.map(([value, title]) =>
      ({ id: "setDocumentWidth", arg: value, title, menu: "보기 ▸ 글 폭", checked: settings.documentWidth === value })),
    { id: "pickBodyFont", title: "본문 글꼴…", menu: "보기 ▸ 글꼴" },
    { id: "pickCodeFont", title: "코드 글꼴…", menu: "보기 ▸ 글꼴" },
    { id: "toggleRemoteImages", title: "원격 그림 받기", menu: "보기", checked: settings.loadsRemoteImages },
    { id: "toggleFrontMatter", title: "문서 메타데이터 접어 두기", menu: "보기", checked: settings.collapsesFrontMatter },
    { id: "llmKeys", title: "LLM 키…", menu: "도구" },
    { id: "checkForUpdates", title: "업데이트 확인…", menu: "도움말" },
    { id: "toggleUpdateChecks", title: "하루 한 번 새 판 확인", menu: "도움말", checked: settings.checksForUpdates },
  ];
}

/** 설정 명령 하나를 값으로 — 모르는 명령이면 null(설정 명령이 아니다). */
export function settingsChange(settings: Settings, id: string, arg?: string): Settings | null {
  switch (id) {
    case "setTheme":
      return themeIds.includes(arg as never) ? { ...settings, theme: arg as Settings["theme"] } : settings;
    case "setAppearance":
      return appearances.some(([value]) => value === arg) ? { ...settings, appearance: arg as Appearance } : settings;
    case "setLineSpacing":
      return spacings.some(([value]) => value === arg) ? { ...settings, lineSpacing: arg as LineSpacing } : settings;
    case "setDocumentWidth":
      return widths.some(([value]) => value === arg) ? { ...settings, documentWidth: arg as DocumentWidth } : settings;
    case "textBigger":
      return { ...settings, bodySize: clampSize(settings.bodySize + 1) };
    case "textSmaller":
      return { ...settings, bodySize: clampSize(settings.bodySize - 1) };
    case "textStandard":
      return { ...settings, bodySize: defaultSettings.bodySize };
    case "setBodyFont":
      return { ...settings, bodyFont: arg?.trim() ? arg : null };
    case "setCodeFont":
      return { ...settings, codeFont: arg?.trim() ? arg : null };
    case "toggleRemoteImages":
      return { ...settings, loadsRemoteImages: !settings.loadsRemoteImages };
    case "toggleFrontMatter":
      return { ...settings, collapsesFrontMatter: !settings.collapsesFrontMatter };
    case "setPrintMargin":
      return margins.some(([value]) => value === arg) ? { ...settings, printMargin: arg as PrintMargin } : settings;
    case "setPrintOrientation":
      return orientations.some(([value]) => value === arg) ? { ...settings, printOrientation: arg as PrintOrientation } : settings;
    case "setPrintPaper":
      return papers.some(([value]) => value === arg) ? { ...settings, printPaper: arg as PrintPaper } : settings;
    case "toggleUpdateChecks":
      return { ...settings, checksForUpdates: !settings.checksForUpdates };
    default:
      return null;
  }
}
