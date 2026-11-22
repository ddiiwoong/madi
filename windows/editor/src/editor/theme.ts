// 겉모양 — 설정(테마 · 라이트/다크 · 글꼴 · 크기 · 줄 사이 · 글 폭)을 문서 뿌리의 CSS 변수로 단다. 편집기의 테마(`setup.ts`의
// `look`)와 style.css는 그 변수만 읽는다 — 색을 코드에 적지 않는다.

import { cssVariables, type Settings } from "../core/settings.ts";

const systemDark = window.matchMedia("(prefers-color-scheme: dark)");

/** 지금 어둡게 그리는가 — `system`이면 Windows의 앱 모드(WebView2가 `prefers-color-scheme`로 알린다). */
export function isDark(settings: Settings): boolean {
  return settings.appearance === "dark" || (settings.appearance === "system" && systemDark.matches);
}

export function applyTheme(settings: Settings): boolean {
  const dark = isDark(settings);
  const root = document.documentElement;
  for (const [name, value] of Object.entries(cssVariables(settings, dark))) root.style.setProperty(name, value);
  // 입력 칸 · 스크롤 막대 · 찾기 칸의 기본 색이 따라온다.
  root.style.colorScheme = dark ? "dark" : "light";
  root.classList.toggle("md-dark", dark);
  root.dataset.theme = settings.theme;
  return dark;
}

/** Windows의 앱 모드가 바뀌면(설정이 `system`일 때만 뜻이 있다). */
export function onSystemAppearanceChange(handler: () => void): void {
  systemDark.addEventListener("change", handler);
}
