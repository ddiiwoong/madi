// 파일의 바이트 ↔ 글. DOM에 기대지 않아 Node 시험이 그대로 돈다.
//
// macOS판(`MarkdownDocument.decode`)은 UTF-8, 아니면 UTF-16, 아니면 Latin-1로 읽는다. Windows판은 둘을 바꾼다:
// - UTF-16은 BOM이 있을 때만. BOM 없는 UTF-16을 짐작하면 아무 바이트나 읽혀 버린다.
// - UTF-8이 아니면 먼저 EUC-KR(CP949)로. 한국어 Windows의 메모장 · 옛 프로그램이 쓴 파일이 이것이다. Latin-1로 읽으면 한글이
//   깨진 글자가 된다. 그것도 아니면 windows-1252(늘 읽힌다).
//
// 쓰는 중인 파일(로그)은 끝이 글자 하나의 가운데에서 끊길 수 있다. 그 덜 쓴 바이트는 글로 내지 않고 들고 있다가(`pending`) 다음에
// 붙는 바이트와 이어 읽는다 — 덜 쓴 한 글자 때문에 파일 전체가 EUC-KR로 잘못 읽히지 않게(macOS판의 `completeUTF8Prefix`와 같다).

export type TextEncodingName = "utf-8" | "utf-16le" | "utf-16be" | "euc-kr" | "windows-1252";

export interface DecodedText {
  text: string;
  encoding: TextEncodingName;
  /** 파일 앞에 BOM이 있었는가. `text`에는 넣지 않는다. */
  bom: boolean;
}

const empty = new Uint8Array(0);

function strict(label: string): TextDecoder {
  // `ignoreBOM: true` — BOM은 이미 떼었다. 남아 있으면 글의 일부다(두 번 붙은 BOM).
  return new TextDecoder(label, { fatal: true, ignoreBOM: true });
}

function decodeStrict(bytes: Uint8Array, label: string): string | null {
  try {
    return strict(label).decode(bytes);
  } catch {
    return null;
  }
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  if (a.length === 0) return b;
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
}

/** 끝의 덜 쓴 글자를 뺀 길이. 끝이 올바른 글자의 시작이 아니면(깨진 바이트) 자르지 않는다 — 읽는 쪽이 거절한다. */
export function completePrefix(bytes: Uint8Array, encoding: "utf-8" | "utf-16le" | "utf-16be"): number {
  const length = bytes.length;
  if (encoding === "utf-8") {
    for (let back = 1; back <= Math.min(4, length); back++) {
      const byte = bytes[length - back]!;
      if ((byte & 0xc0) === 0x80) continue; // 이어지는 바이트 — 더 앞을 본다
      const need = byte < 0x80 ? 1 : (byte & 0xe0) === 0xc0 ? 2 : (byte & 0xf0) === 0xe0 ? 3 : (byte & 0xf8) === 0xf0 ? 4 : 1;
      return back < need ? length - back : length;
    }
    return length;
  }
  let even = length - (length % 2);
  if (even >= 2) {
    const unit = encoding === "utf-16le" ? bytes[even - 2]! | (bytes[even - 1]! << 8) : (bytes[even - 2]! << 8) | bytes[even - 1]!;
    if (unit >= 0xd800 && unit <= 0xdbff) even -= 2; // 짝을 기다리는 앞쪽 대리
  }
  return even;
}

/**
 * 한 파일을 읽어 나가는 상태 — 처음 연 바이트와 그 뒤로 붙는 바이트(로그)를 같은 꼴로 이어 읽는다.
 * UTF-8 · UTF-16은 덜 쓴 끝을 `pending`으로 들고, EUC-KR은 브라우저의 이어 읽기(`stream: true`)에 맡긴다.
 */
export class TextStream {
  readonly encoding: TextEncodingName;
  readonly bom: boolean;
  private pending: Uint8Array = empty;
  private readonly legacy: TextDecoder | null;

  private constructor(encoding: TextEncodingName, bom: boolean) {
    this.encoding = encoding;
    this.bom = bom;
    this.legacy = encoding === "euc-kr" ? new TextDecoder("euc-kr", { fatal: true }) : null;
  }

  /** 새 문서(저장한 적 없음) — UTF-8, BOM 없이. */
  static fresh(encoding: TextEncodingName = "utf-8", bom = false): TextStream {
    return new TextStream(encoding, bom);
  }

  static open(bytes: Uint8Array): { stream: TextStream; text: string } {
    const tryUnicode = (encoding: "utf-8" | "utf-16le" | "utf-16be", body: Uint8Array, bom: boolean) => {
      const stream = new TextStream(encoding, bom);
      const text = stream.unicode(body);
      return text === null ? null : { stream, text };
    };
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      const opened = tryUnicode("utf-8", bytes.subarray(3), true);
      if (opened) return opened;
    }
    if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
      const opened = tryUnicode("utf-16le", bytes.subarray(2), true);
      if (opened) return opened;
    }
    if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
      const opened = tryUnicode("utf-16be", bytes.subarray(2), true);
      if (opened) return opened;
    }
    const utf8 = tryUnicode("utf-8", bytes, false);
    if (utf8) return utf8;
    try {
      const stream = new TextStream("euc-kr", false);
      return { stream, text: stream.legacy!.decode(bytes, { stream: true }) };
    } catch {
      return { stream: new TextStream("windows-1252", false), text: new TextDecoder("windows-1252").decode(bytes) };
    }
  }

  /** 끝에 붙은 바이트를 글로. 그 꼴로 읽을 수 없는 바이트면 던진다 — 부르는 쪽이 파일을 통째로 다시 읽는다. */
  append(bytes: Uint8Array): string {
    switch (this.encoding) {
      case "utf-8":
      case "utf-16le":
      case "utf-16be": {
        const text = this.unicode(concat(this.pending, bytes));
        if (text === null) throw new Error(`${this.encoding}로 읽을 수 없는 바이트가 붙었다`);
        return text;
      }
      case "euc-kr":
        return this.legacy!.decode(bytes, { stream: true });
      case "windows-1252":
        return new TextDecoder("windows-1252").decode(bytes);
    }
  }

  /** 아직 글로 내지 않은 끝의 바이트(덜 쓴 글자). 저장할 때 뒤에 붙여 파일을 그대로 둔다. */
  get pendingBytes(): Uint8Array {
    return this.pending;
  }

  private unicode(bytes: Uint8Array): string | null {
    const encoding = this.encoding as "utf-8" | "utf-16le" | "utf-16be";
    const end = completePrefix(bytes, encoding);
    const text = decodeStrict(bytes.subarray(0, end), encoding);
    if (text === null) return null;
    this.pending = bytes.slice(end);
    return text;
  }
}

/** 한 번에 읽는다 — 시험과 처음 여는 곳에서. 덜 쓴 끝은 글에 넣지 않는다. */
export function decodeText(bytes: Uint8Array): DecodedText {
  const { stream, text } = TextStream.open(bytes);
  return { text, encoding: stream.encoding, bom: stream.bom };
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
