import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { EditorState } from "@codemirror/state";
import { base64ToBytes, documentBytes, openDocument, sha256Hex } from "../src/core/document.ts";
import { lineSeparatorName } from "../src/core/lines.ts";
import { cases } from "./cases.ts";

test("시험 문서마다 — 열고, CodeMirror에 싣고, 연 꼴로 다시 쓰면 파일과 같다(EUC-KR은 바뀐다)", async () => {
  for (const sample of cases) {
    const base64 = Buffer.from(sample.bytes).toString("base64");
    const bytes = base64ToBytes(base64);
    assert.deepEqual(bytes, sample.bytes, `${sample.name}: base64를 지나도 같다`);
    const opened = openDocument(bytes);
    assert.equal(opened.stream.encoding, sample.encoding, sample.name);
    assert.equal(opened.stream.bom, sample.bom, sample.name);
    assert.equal(lineSeparatorName(opened.lineSeparator), sample.lineSeparator, sample.name);
    const state = EditorState.create({ doc: opened.text, extensions: EditorState.lineSeparator.of(opened.lineSeparator) });
    const back = documentBytes(state.sliceDoc(), opened.stream);
    if (sample.roundTrip === "exact") {
      assert.ok(back, sample.name);
      assert.deepEqual(back, sample.bytes, `${sample.name}: 바이트가 그대로`);
      assert.equal(await sha256Hex(back), createHash("sha256").update(sample.bytes).digest("hex"), sample.name);
    } else {
      assert.equal(back, null, `${sample.name}: 그 꼴로는 쓸 수 없다`);
    }
  }
});
