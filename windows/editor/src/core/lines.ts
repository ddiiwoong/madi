// 줄 끝 — CodeMirror가 문서를 바이트 그대로 지키게 한다.
//
// CodeMirror는 기본으로 `\n` · `\r\n` · `\r`을 모두 줄 끝으로 읽고 `\n`으로 잇는다. 그러면 Windows에서 흔한 CRLF 파일이 열기만 해도
// LF로 바뀐다. `EditorState.lineSeparator`를 정하면 그 글자만 줄 끝으로 읽고 그것으로 잇는다 — 그래서 파일마다 고른다:
// - CRLF만 있으면 `\r\n`, CR만 있으면 `\r`.
// - 그 밖(LF만, 섞임, 줄 끝 없음)은 `\n`. 섞인 파일의 `\r`은 줄 안의 글자로 남아 다시 이을 때 그대로 나온다.
// 문서의 글은 `state.sliceDoc()`으로 꺼낸다 — `state.doc.toString()`은 정한 줄 끝과 상관없이 늘 `\n`으로 잇는다.

export type LineSeparator = "\n" | "\r\n" | "\r";

export function lineSeparatorFor(text: string): LineSeparator {
  let crlf = 0;
  let lf = 0;
  let cr = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code === 13) {
      if (text.charCodeAt(i + 1) === 10) {
        crlf++;
        i++;
      } else {
        cr++;
      }
    } else if (code === 10) {
      lf++;
    }
  }
  if (crlf > 0 && lf === 0 && cr === 0) return "\r\n";
  if (cr > 0 && lf === 0 && crlf === 0) return "\r";
  return "\n";
}

/** 사람이 읽을 이름 — 호스트 · 기록에 쓴다. */
export function lineSeparatorName(separator: LineSeparator): "LF" | "CRLF" | "CR" {
  return separator === "\r\n" ? "CRLF" : separator === "\r" ? "CR" : "LF";
}
