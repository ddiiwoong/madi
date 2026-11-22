// 파일의 바이트 ↔ 글. DOM에 기대지 않아 Node 시험이 그대로 돈다.
//
// macOS판(`MarkdownDocument.decode`)은 UTF-8, 아니면 UTF-16, 아니면 Latin-1로 읽는다. Windows판은 둘을 바꾼다:
// - UTF-16은 BOM이 있을 때만. BOM 없는 UTF-16을 짐작하면 아무 바이트나 읽혀 버린다.
// - UTF-8이 아니면 먼저 EUC-KR(CP949)로. 한국어 Windows의 메모장 · 옛 프로그램이 쓴 파일이 이것이다. Latin-1로 읽으면 한글이
//   깨진 글자가 된다. 그것도 아니면 windows-1252(늘 읽힌다).
// 저장은 macOS판처럼 늘 UTF-8이다 — 다만 UTF-8 · UTF-16 파일은 읽은 그대로(BOM 포함) 다시 쓸 수 있어야 한다(`encodeText`).

export type TextEncodingName = "utf-8" | "utf-16le" | "utf-16be" | "euc-kr" | "windows-1252";

export interface DecodedText {
  text: string;
  encoding: TextEncodingName;
  /** 파일 앞에 BOM이 있었는가. `text`에는 넣지 않는다. */
  bom: boolean;
}

function decodeStrict(bytes: Uint8Array, label: string): string | null {
  try {
    // `ignoreBOM: true` — BOM은 위에서 이미 떼었다. 남아 있으면 글의 일부다(두 번 붙은 BOM).
    return new TextDecoder(label, { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch {
    return null;
  }
}

export function decodeText(bytes: Uint8Array): DecodedText {
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    const text = decodeStrict(bytes.subarray(3), "utf-8");
    if (text !== null) return { text, encoding: "utf-8", bom: true };
  }
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    const text = decodeStrict(bytes.subarray(2), "utf-16le");
    if (text !== null) return { text, encoding: "utf-16le", bom: true };
  }
  if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    const text = decodeStrict(bytes.subarray(2), "utf-16be");
    if (text !== null) return { text, encoding: "utf-16be", bom: true };
  }
  const utf8 = decodeStrict(bytes, "utf-8");
  if (utf8 !== null) return { text: utf8, encoding: "utf-8", bom: false };
  const korean = decodeStrict(bytes, "euc-kr");
  if (korean !== null) return { text: korean, encoding: "euc-kr", bom: false };
  return { text: new TextDecoder("windows-1252").decode(bytes), encoding: "windows-1252", bom: false };
}

/** 읽은 꼴 그대로 다시 쓴 바이트. UTF-8 · UTF-16만 쓸 수 있다 — 그 밖(EUC-KR 등)은 null: 저장하면 UTF-8로 바뀐다. */
export function encodeText(text: string, how: { encoding: TextEncodingName; bom: boolean }): Uint8Array<ArrayBuffer> | null {
  switch (how.encoding) {
    case "utf-8": {
      const body = new TextEncoder().encode(text);
      if (!how.bom) return body;
      const out = new Uint8Array(body.length + 3);
      out.set([0xef, 0xbb, 0xbf]);
      out.set(body, 3);
      return out;
    }
    case "utf-16le":
    case "utf-16be": {
      const little = how.encoding === "utf-16le";
      const start = how.bom ? 2 : 0;
      const out = new Uint8Array(start + text.length * 2);
      if (how.bom) out.set(little ? [0xff, 0xfe] : [0xfe, 0xff]);
      for (let i = 0; i < text.length; i++) {
        const unit = text.charCodeAt(i);
        out[start + i * 2] = little ? unit & 0xff : unit >> 8;
        out[start + i * 2 + 1] = little ? unit >> 8 : unit & 0xff;
      }
      return out;
    }
    default:
      return null;
  }
}
