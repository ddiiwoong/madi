import { test } from "node:test";
import assert from "node:assert/strict";
import { codeLanguage } from "../src/core/codelang.ts";
import { appendPiece } from "../src/core/append.ts";
import { pageRule } from "../src/core/output.ts";
import { defaultSettings, normalizeSettings } from "../src/core/settings.ts";
import { catalog, settingsChange } from "../src/core/catalog.ts";

test("코드 블록의 언어 — macOS판의 이름 · 별명, 모르는 것은 칠하지 않는다", () => {
  assert.equal(codeLanguage("swift"), "swift");
  assert.equal(codeLanguage("TS"), "typescript");
  assert.equal(codeLanguage("tsx title=\"a.tsx\""), "typescript");
  assert.equal(codeLanguage("{.python}"), "python");
  assert.equal(codeLanguage("console"), "shell");
  assert.equal(codeLanguage("pwsh"), "shell");
  assert.equal(codeLanguage("jsonc"), "json");
  assert.equal(codeLanguage("svg"), "html");
  assert.equal(codeLanguage("psql"), "sql");
  assert.equal(codeLanguage(""), null);
  assert.equal(codeLanguage("mermaid"), null, "그림으로 그리는 블록은 문법 색이 아니다");
  assert.equal(codeLanguage("brainfuck"), null);
});

test("링크로 끝에 더하기 — 목록은 이어 붙이고, 문단은 빈 줄 하나로 띄운다(macOS판 appendEdit)", () => {
  assert.equal(appendPiece("- 셋", "# 링크\n\n- 하나\n- 둘\n"), "- 셋\n");
  assert.equal(appendPiece("- 셋", "- 하나\n- 둘"), "\n- 셋\n");
  assert.equal(appendPiece("1. 셋", "- 하나\n"), "1. 셋\n", "번호 목록도 목록이다");
  assert.equal(appendPiece("- 셋", "- 하나\n\n"), "- 셋\n", "이미 빈 줄로 끝나면 그대로");
  assert.equal(appendPiece("글", "문단\n"), "\n글\n");
  assert.equal(appendPiece("글", "문단"), "\n\n글\n");
  assert.equal(appendPiece("글\n", "문단\n\n"), "글\n");
  assert.equal(appendPiece("- 셋", "문단\n"), "\n- 셋\n", "문단 뒤의 목록은 띄운다");
  assert.equal(appendPiece("글", ""), "글\n");
});

test("프린트의 쪽 — 용지 · 방향 · 여백(pt), 시스템 용지는 크기를 적지 않는다", () => {
  assert.equal(pageRule(defaultSettings), "@page { size: portrait; margin: 48pt; }");
  assert.equal(pageRule({ printPaper: "a4", printOrientation: "landscape", printMargin: "wide" }), "@page { size: A4 landscape; margin: 84pt; }");
  assert.equal(pageRule({ printPaper: "letter", printOrientation: "portrait", printMargin: "narrow" }), "@page { size: letter portrait; margin: 24pt; }");
});

test("설정 — 프린트 설정 · 새 판 확인(기본 켜짐, 꺼짐만 받는다)", () => {
  assert.equal(defaultSettings.checksForUpdates, true);
  assert.equal(normalizeSettings({}).checksForUpdates, true);
  assert.equal(normalizeSettings({ checksForUpdates: "no" }).checksForUpdates, true, "깨진 값이 확인을 끄지 않는다");
  assert.equal(normalizeSettings({ checksForUpdates: false }).checksForUpdates, false);
  const odd = normalizeSettings({ printMargin: "huge", printOrientation: "landscape", printPaper: "a3" });
  assert.deepEqual([odd.printMargin, odd.printOrientation, odd.printPaper], ["normal", "landscape", "system"]);
  assert.equal(settingsChange(defaultSettings, "setPrintPaper", "a4")?.printPaper, "a4");
  assert.equal(settingsChange(defaultSettings, "setPrintMargin", "huge")?.printMargin, "normal");
  assert.equal(settingsChange(defaultSettings, "toggleUpdateChecks")?.checksForUpdates, false);
  const entries = catalog({ settings: defaultSettings, source: false, follow: false, outline: false });
  assert.equal(entries.find((entry) => entry.id === "print")?.shortcut, "Ctrl+P", "Ctrl+P는 프린트(macOS판 ⌘P)");
  assert.equal(entries.find((entry) => entry.id === "quickOpen")?.shortcut, "Ctrl+Alt+O", "빠른 열기는 macOS판 ⌥⌘O 자리");
  assert.equal(entries.find((entry) => entry.id === "toggleUpdateChecks")?.checked, true);
  assert.deepEqual(entries.filter((entry) => entry.id === "setPrintPaper" && entry.checked).map((entry) => entry.title), ["시스템 기본"]);
  // Store판(MSIX)은 Store가 업데이트한다 — 새 판 확인 명령이 없다. 다른 명령은 그대로.
  const packaged = catalog({ settings: defaultSettings, source: false, follow: false, outline: false, packaged: true });
  assert.deepEqual(packaged.filter((entry) => /Update/.test(entry.id)).map((entry) => entry.id), []);
  assert.equal(packaged.length, entries.length - 2);
  // LLM 키는 숨겼다 — 교정이 없어 키를 둘 곳만 있었다(2026-11-28, 사용자). 명령 팔레트에도 없다.
  assert.deepEqual(entries.filter((entry) => /llm|LLM/.test(`${entry.id} ${entry.title}`)).map((entry) => entry.id), []);
});
