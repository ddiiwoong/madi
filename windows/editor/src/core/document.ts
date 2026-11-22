// 연 문서 — 파일의 바이트에서 글과, 다시 쓸 때 지킬 꼴(인코딩 · BOM · 줄 끝)을 얻는다.

import { decodeText, encodeText, type DecodedText } from "./text.ts";
import { lineSeparatorFor, type LineSeparator } from "./lines.ts";

export interface OpenedDocument extends DecodedText {
  lineSeparator: LineSeparator;
}

export function openDocument(bytes: Uint8Array): OpenedDocument {
  const decoded = decodeText(bytes);
  return { ...decoded, lineSeparator: lineSeparatorFor(decoded.text) };
}

/** 편집기의 글을 연 꼴 그대로 바이트로. 그 꼴로 쓸 수 없으면(EUC-KR 등) null. */
export function documentBytes(text: string, opened: OpenedDocument): Uint8Array<ArrayBuffer> | null {
  return encodeText(text, opened);
}

export function base64ToBytes(base64: string): Uint8Array<ArrayBuffer> {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
