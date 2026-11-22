// `madi://append`가 문서 끝에 넣을 글 — macOS판 `MadiURL.appendEdit`와 같은 규칙. 끝 문단과는 빈 줄 하나로 띄운다. 다만 문서가
// 목록 항목으로 끝나고 더할 글도 목록 항목으로 시작하면 줄바꿈 하나로만 잇는다 — `- [ ] 우유`를 할 일 목록에 더하면 같은 목록의
// 다음 항목이어야 한다(빈 줄을 두면 목록이 느슨해져 항목 사이가 벌어진다). 더한 글은 줄바꿈으로 맺는다.
//
// 줄 끝은 `\n`으로 센다 — 편집기의 글(`sliceDoc`)은 문서의 줄 끝과 상관없이 `\n`이고, 쓸 때 문서의 줄 끝으로 돌아간다.

const listItem = /^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]/;

export function appendPiece(text: string, body: string): string {
  let piece = text.endsWith("\n") ? text : `${text}\n`;
  const lastLine = body.split("\n").filter((line) => line !== "").at(-1) ?? "";
  const firstLine = text.split("\n")[0] ?? "";
  const continuesList = listItem.test(lastLine) && listItem.test(firstLine);
  if (body === "") return piece;
  if (continuesList && !body.endsWith("\n\n")) {
    if (!body.endsWith("\n")) piece = `\n${piece}`;
  } else if (body.endsWith("\n\n")) {
    // 이미 빈 줄로 끝난다.
  } else if (body.endsWith("\n")) {
    piece = `\n${piece}`;
  } else {
    piece = `\n\n${piece}`;
  }
  return piece;
}
