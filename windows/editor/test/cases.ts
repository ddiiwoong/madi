// 시험 문서 — Windows 호스트의 확인 실행(`Madi.Windows/Smoke.cs`)이 쓰는 것과 같은 바이트다. 한쪽을 바꾸면 다른 쪽도.

const utf8 = (text: string) => new TextEncoder().encode(text);
const join = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
};
const utf16le = (text: string) => {
  const out = new Uint8Array(text.length * 2);
  for (let i = 0; i < text.length; i++) {
    out[i * 2] = text.charCodeAt(i) & 0xff;
    out[i * 2 + 1] = text.charCodeAt(i) >> 8;
  }
  return out;
};

export interface Case {
  name: string;
  bytes: Uint8Array;
  encoding: string;
  bom: boolean;
  lineSeparator: "LF" | "CRLF" | "CR";
  roundTrip: "exact" | "converted";
}

export const cases: Case[] = [
  {
    name: "cp949.txt",
    // "한글 메모\r\n"을 EUC-KR(CP949)로.
    bytes: new Uint8Array([0xc7, 0xd1, 0xb1, 0xdb, 0x20, 0xb8, 0xde, 0xb8, 0xf0, 0x0d, 0x0a]),
    encoding: "euc-kr", bom: false, lineSeparator: "CRLF", roundTrip: "converted",
  },
  {
    name: "utf16le.txt",
    bytes: join(new Uint8Array([0xff, 0xfe]), utf16le("메모장 UTF-16\r\n둘째 줄 😀\r\n")),
    encoding: "utf-16le", bom: true, lineSeparator: "CRLF", roundTrip: "exact",
  },
  {
    name: "mixed.log",
    bytes: utf8("2026-11-22 10:00:01 INFO 시작\r\n2026-11-22 10:00:02 WARN 섞인 줄 끝\n끝\r"),
    encoding: "utf-8", bom: false, lineSeparator: "LF", roundTrip: "exact",
  },
  {
    name: "crlf-bom.md",
    bytes: join(new Uint8Array([0xef, 0xbb, 0xbf]), utf8("# 메모장에서 저장한 글\r\n\r\n- 줄 끝은 CRLF\r\n- 맨 앞에 BOM\r\n")),
    encoding: "utf-8", bom: true, lineSeparator: "CRLF", roundTrip: "exact",
  },
  {
    name: "lf-utf8.md",
    bytes: utf8([
      "# 마디 Windows 0단계",
      "",
      "**굵게**, *기울임*, `코드`, [링크](https://github.com/ddiiwoong/madi).",
      "",
      "- 한글 · English · 日本語 · 😀",
      "- [ ] 할 일",
      "",
      "> 인용",
      "",
      "```swift",
      "let 인사 = \"안녕\"",
      "```",
      "",
    ].join("\n")),
    encoding: "utf-8", bom: false, lineSeparator: "LF", roundTrip: "exact",
  },
];
