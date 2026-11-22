// PDF · 프린트의 쪽 — 용지 · 방향 · 여백(macOS판 `printInfo`와 같은 설정, 둘이 같은 값을 쓴다). 프린트 창은 이 `@page` 규칙을
// 기본값으로 삼고, PDF는 껍데기가 같은 값을 WebView2의 프린트 설정으로 넘긴다(`windows/Madi.Windows/PrintLayout.cs`).

import { printMarginPoints, type Settings } from "./settings.ts";

/** `@page` 규칙. `system` 용지는 크기를 적지 않는다(프린터의 기본 용지 — 사람이 프린트 창에서 고른 것을 덮지 않는다). */
export function pageRule(settings: Pick<Settings, "printMargin" | "printOrientation" | "printPaper">): string {
  const paper = settings.printPaper === "a4" ? "A4" : "letter";
  const size = settings.printPaper === "system" ? settings.printOrientation : `${paper} ${settings.printOrientation}`;
  return `@page { size: ${size}; margin: ${printMarginPoints[settings.printMargin]}pt; }`;
}
