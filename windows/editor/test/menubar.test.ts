import { test } from "node:test";
import assert from "node:assert/strict";
import { AltTap, menuForAltKey } from "../src/core/menukeys.ts";
import { defaultSettings, normalizeSettings } from "../src/core/settings.ts";
import { catalog, settingsChange } from "../src/core/catalog.ts";

const key = (code: string, more: Partial<{ key: string; altKey: boolean; ctrlKey: boolean; shiftKey: boolean; isComposing: boolean }> = {}) =>
  ({ key: code === "AltLeft" || code === "AltRight" ? "Alt" : code.replace(/^Key/, "").toLowerCase(), code, altKey: false,
    ctrlKey: false, metaKey: false, shiftKey: false, ...more });

test("메뉴 막대 — 기본은 숨김, 켜고 끄는 명령, 명령 팔레트의 ✓", () => {
  assert.equal(defaultSettings.showsMenuBar, false);
  assert.equal(normalizeSettings({}).showsMenuBar, false);
  assert.equal(normalizeSettings({ showsMenuBar: "yes" }).showsMenuBar, false, "참(true)만 받는다");
  assert.equal(normalizeSettings({ showsMenuBar: true }).showsMenuBar, true);
  const on = settingsChange(defaultSettings, "toggleMenuBar");
  assert.equal(on?.showsMenuBar, true);
  assert.equal(settingsChange(on!, "toggleMenuBar")?.showsMenuBar, false);
  const entry = (settings: typeof defaultSettings) =>
    catalog({ settings, source: false, follow: false, outline: false }).find((item) => item.id === "toggleMenuBar");
  assert.deepEqual([entry(defaultSettings)?.menu, entry(defaultSettings)?.checked, entry(on!)?.checked], ["보기", false, true]);
});

test("메뉴 막대 — Alt+글자는 그 메뉴(자판의 자리로 — 한글 입력기여도), Ctrl · Shift가 끼면 아니다", () => {
  const names = ["KeyF", "KeyE", "KeyO", "KeyV", "KeyT", "KeyH"].map((code) => menuForAltKey(key(code, { altKey: true })));
  assert.deepEqual(names, ["file", "edit", "format", "view", "tools", "help"]);
  assert.equal(menuForAltKey(key("KeyF", { altKey: true, key: "ㄹ" })), "file", "한글 입력기 — key가 자모");
  assert.equal(menuForAltKey(key("KeyF")), null, "Alt 없이");
  assert.equal(menuForAltKey(key("KeyF", { altKey: true, ctrlKey: true })), null, "AltGr(Ctrl+Alt)");
  assert.equal(menuForAltKey(key("KeyF", { altKey: true, shiftKey: true })), null);
  assert.equal(menuForAltKey(key("KeyF", { altKey: true, isComposing: true })), null, "조합 중");
  assert.equal(menuForAltKey(key("KeyQ", { altKey: true })), null, "메뉴가 없는 글자");
});

test("메뉴 막대 — 왼쪽 Alt를 혼자 눌렀다 떼면 연다. 사이에 다른 것이 끼거나 오른쪽 Alt(한/영)면 아니다", () => {
  const tap = new AltTap();
  tap.down(key("AltLeft", { altKey: true }));
  assert.equal(tap.up(key("AltLeft")), true);
  assert.equal(tap.up(key("AltLeft")), false, "한 번만");

  tap.down(key("AltRight", { altKey: true }));
  assert.equal(tap.up(key("AltRight")), false, "오른쪽 Alt — 한국어 자판의 한/영");

  tap.down(key("AltLeft", { altKey: true }));
  tap.cancel(); // Alt+Tab · Alt+화살표 · Alt+끌기
  assert.equal(tap.up(key("AltLeft")), false);

  tap.down(key("AltLeft", { altKey: true, ctrlKey: true }));
  assert.equal(tap.up(key("AltLeft")), false, "Ctrl+Alt");
});
