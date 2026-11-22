import { test } from "node:test";
import assert from "node:assert/strict";
import { completePrefix, decodeText, TextStream } from "../src/core/text.ts";
import { documentBytes, openDocument, bytesForSave } from "../src/core/document.ts";

const utf8 = (text: string) => new TextEncoder().encode(text);
const bytes = (...values: number[]) => new Uint8Array(values);

test("덜 쓴 끝 — UTF-8 한 글자가 끊기면 그 바이트만 빼고, UTF-16은 짝 없는 대리 · 홀수 바이트를 뺀다", () => {
  const han = utf8("한"); // ED 95 9C
  assert.equal(completePrefix(bytes(0x61, han[0]!, han[1]!), "utf-8"), 1);
  assert.equal(completePrefix(bytes(0x61, han[0]!), "utf-8"), 1);
  assert.equal(completePrefix(bytes(0x61, ...han), "utf-8"), 4);
  assert.equal(completePrefix(bytes(0x61, 0x80), "utf-8"), 2, "깨진 바이트는 자르지 않는다 — 읽는 쪽이 거절한다");
  assert.equal(completePrefix(bytes(0x41, 0x00, 0x3d), "utf-16le"), 2);
  assert.equal(completePrefix(bytes(0x3d, 0xd8), "utf-16le"), 0, "😀의 앞쪽 대리만 있다");
  assert.equal(completePrefix(bytes(0xd8, 0x3d, 0xde, 0x00), "utf-16be"), 4);
});

test("쓰는 중인 로그를 열면 — 덜 쓴 글자 때문에 EUC-KR로 잘못 읽지 않는다. 다시 쓰면 그 바이트까지 그대로", () => {
  const file = new Uint8Array([...utf8("로그 시작\n"), 0xed, 0x95]);
  const decoded = decodeText(file);
  assert.deepEqual(decoded, { text: "로그 시작\n", encoding: "utf-8", bom: false });
  const opened = openDocument(file);
  assert.deepEqual(opened.stream.pendingBytes, bytes(0xed, 0x95));
  assert.deepEqual(documentBytes(opened.text, opened.stream), file);
});

test("붙는 바이트를 이어 읽는다 — 끊긴 글자는 다음 조각과 합쳐 한 번만", () => {
  const { stream, text } = TextStream.open(utf8("하나\n"));
  assert.equal(text, "하나\n");
  assert.equal(stream.append(bytes(0x61, 0xed, 0x95)), "a");
  assert.equal(stream.append(bytes(0x9c, 0x0a)), "한\n");
  assert.equal(stream.pendingBytes.length, 0);
  assert.throws(() => stream.append(bytes(0xff)), "UTF-8이 아닌 바이트가 붙으면 던진다 — 통째로 다시 읽는다");
});

test("UTF-16 · EUC-KR도 이어 읽는다", () => {
  const sixteen = TextStream.open(bytes(0xff, 0xfe, 0x41, 0x00));
  assert.equal(sixteen.text, "A");
  assert.equal(sixteen.stream.append(bytes(0x3d, 0xd8)), "", "앞쪽 대리만 — 기다린다");
  assert.equal(sixteen.stream.append(bytes(0x00, 0xde)), "😀");
  const legacy = TextStream.open(bytes(0xc7, 0xd1));
  assert.equal(legacy.stream.encoding, "euc-kr");
  assert.equal(legacy.stream.append(bytes(0xb1)), "", "앞 바이트만 — 기다린다");
  assert.equal(legacy.stream.append(bytes(0xdb)), "글");
});

test("저장 — UTF-8 · UTF-16은 연 꼴 그대로, EUC-KR은 UTF-8로", () => {
  const bom = openDocument(new Uint8Array([0xef, 0xbb, 0xbf, ...utf8("가\r\n")]));
  const kept = bytesForSave("가나\r\n", bom.stream);
  assert.equal(kept.encoding, "utf-8");
  assert.equal(kept.bom, true);
  assert.deepEqual(kept.bytes, new Uint8Array([0xef, 0xbb, 0xbf, ...utf8("가나\r\n")]));
  const legacy = openDocument(bytes(0xc7, 0xd1));
  const converted = bytesForSave("한", legacy.stream);
  assert.equal(converted.encoding, "utf-8");
  assert.equal(converted.bom, false);
  assert.deepEqual(converted.bytes, utf8("한"));
});
