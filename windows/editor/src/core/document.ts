// 연 문서 — 파일의 바이트에서 글과, 다시 쓸 때 지킬 꼴(인코딩 · BOM · 줄 끝)을 얻는다.

import { encodeText, TextStream, type TextEncodingName } from "./text.ts";
import { lineSeparatorFor, type LineSeparator } from "./lines.ts";

export interface OpenedDocument {
  text: string;
  stream: TextStream;
  lineSeparator: LineSeparator;
}

export function openDocument(bytes: Uint8Array): OpenedDocument {
  const { stream, text } = TextStream.open(bytes);
  return { text, stream, lineSeparator: lineSeparatorFor(text) };
}

/** 편집기의 글을 연 꼴 그대로 바이트로(덜 쓴 끝 포함). 그 꼴로 쓸 수 없으면(EUC-KR 등) null. */
export function documentBytes(text: string, stream: TextStream): Uint8Array<ArrayBuffer> | null {
  const body = encodeText(text, stream);
  if (!body) return null;
  const pending = stream.pendingBytes;
  if (pending.length === 0) return body;
  const out = new Uint8Array(body.length + pending.length);
  out.set(body);
  out.set(pending, body.length);
  return out;
}

/** 저장할 바이트와 그 꼴. 연 꼴로 쓸 수 없으면 UTF-8(BOM 없이) — macOS판과 같다. */
export function bytesForSave(text: string, stream: TextStream): {
  bytes: Uint8Array<ArrayBuffer>;
  encoding: TextEncodingName;
  bom: boolean;
} {
  const same = documentBytes(text, stream);
  if (same) return { bytes: same, encoding: stream.encoding, bom: stream.bom };
  return { bytes: new TextEncoder().encode(text), encoding: "utf-8", bom: false };
}

export function base64ToBytes(base64: string): Uint8Array<ArrayBuffer> {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
