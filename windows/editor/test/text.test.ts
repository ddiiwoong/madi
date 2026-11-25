import { test } from "node:test";
import assert from "node:assert/strict";
import { decodeText, encodeText } from "../src/core/text.ts";

const bytes = (...values: number[]) => new Uint8Array(values);

test("UTF-8 — BOM은 떼어 기억하고 다시 쓸 때 붙인다", () => {
  const plain = decodeText(new TextEncoder().encode("한글"));
  assert.deepEqual(plain, { text: "한글", encoding: "utf-8", bom: false });
  const withBom = decodeText(bytes(0xef, 0xbb, 0xbf, 0xed, 0x95, 0x9c));
  assert.deepEqual(withBom, { text: "한", encoding: "utf-8", bom: true });
  assert.deepEqual(encodeText("한", withBom), bytes(0xef, 0xbb, 0xbf, 0xed, 0x95, 0x9c));
  assert.deepEqual(decodeText(new Uint8Array()), { text: "", encoding: "utf-8", bom: false });
});

test("두 번 붙은 BOM — 뒤의 것은 글의 일부로 남는다", () => {
  const doubled = decodeText(bytes(0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf, 0x41));
  assert.equal(doubled.text, "\ufeffA");
  assert.deepEqual(encodeText(doubled.text, doubled), bytes(0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf, 0x41));
});

test("UTF-16은 BOM이 있을 때만 — 리틀 · 빅 엔디언, 이모지(대리 쌍)도 그대로", () => {
  const little = bytes(0xff, 0xfe, 0x5c, 0xd5, 0x3d, 0xd8, 0x00, 0xde);
  const decoded = decodeText(little);
  assert.deepEqual(decoded, { text: "한😀", encoding: "utf-16le", bom: true });
  assert.deepEqual(encodeText(decoded.text, decoded), little);
  const big = bytes(0xfe, 0xff, 0xd5, 0x5c);
  assert.deepEqual(decodeText(big), { text: "한", encoding: "utf-16be", bom: true });
  assert.deepEqual(encodeText("한", { encoding: "utf-16be", bom: true }), big);
});

test("UTF-8이 아니면 EUC-KR(CP949) — 한국어 Windows의 옛 파일. 다시 쓸 수는 없다(저장은 UTF-8)", () => {
  const legacy = decodeText(bytes(0xc7, 0xd1, 0xb1, 0xdb));
  assert.deepEqual(legacy, { text: "한글", encoding: "euc-kr", bom: false });
  assert.equal(encodeText(legacy.text, legacy), null);
});

test("둘 다 아니면 windows-1252 — 늘 읽힌다", () => {
  // 0xFF는 UTF-8에도 EUC-KR에도 없는 바이트다. (0x80은 안 된다 — Node(ICU)의 EUC-KR은 그것을 U+0080으로 읽는다.)
  assert.deepEqual(decodeText(bytes(0xff, 0x41)), { text: "ÿA", encoding: "windows-1252", bom: false });
});
