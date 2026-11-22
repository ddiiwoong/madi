import { EditorState, type Extension } from "@codemirror/state";
import { EditorView, drawSelection, highlightSpecialChars, keymap } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { defaultHighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { base64ToBytes, documentBytes, openDocument, sha256Hex } from "./core/document.ts";
import { lineSeparatorName, type LineSeparator } from "./core/lines.ts";
import { hasHost, onHostMessage, post } from "./bridge.ts";
import { welcome } from "./welcome.ts";

function extensions(separator: LineSeparator): Extension[] {
  return [
    // 줄 끝을 파일에 맞춘다 — 안 그러면 CRLF가 열기만 해도 LF가 된다(`core/lines.ts`).
    EditorState.lineSeparator.of(separator),
    history(),
    drawSelection(),
    highlightSpecialChars(),
    EditorView.lineWrapping,
    keymap.of([...defaultKeymap, ...historyKeymap]),
    markdown(),
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    EditorView.contentAttributes.of({ lang: "ko", spellcheck: "false" }),
    layout,
  ];
}

// 글꼴과 글 폭은 CodeMirror의 테마로 준다. style.css에 적었더니 CodeMirror의 기본 테마(`.ͼ1 .cm-scroller` — 클래스 둘)에 밀려
// 고정폭 기본 글꼴 · 여백 없음으로 그려졌다(Windows CI의 editor.png).
// 글 폭은 macOS판과 같다: 본문 크기의 56배(15px에서 840px), 창이 넓으면 남는 자리를 양옆에 반씩(`MarkdownTheme.textInsets`).
const layout = EditorView.theme({
  "&": { height: "100%" },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": {
    fontFamily: '"Pretendard", "Malgun Gothic", sans-serif',
    fontSize: "15px",
    lineHeight: "1.6",
  },
  ".cm-content": { padding: "24px max(28px, calc((100% - 840px) / 2))" },
});

const parent = document.getElementById("editor");
if (!parent) throw new Error("편집기를 놓을 자리(#editor)가 없다");

const view = new EditorView({
  state: EditorState.create({ doc: welcome, extensions: extensions("\n") }),
  parent,
});
view.focus();

onHostMessage((message) => {
  if (message.type !== "open") return;
  void open(message.path, message.bytes);
});

async function open(path: string, base64: string): Promise<void> {
  try {
    const bytes = base64ToBytes(base64);
    const opened = openDocument(bytes);
    view.setState(EditorState.create({ doc: opened.text, extensions: extensions(opened.lineSeparator) }));
    view.focus();
    // 연 글을 다시 바이트로 — 편집기를 지나도 파일이 그대로인지 확인한다(호스트가 따로 한 번 더 견준다).
    const back = documentBytes(view.state.sliceDoc(), opened);
    const sha = back ? await sha256Hex(back) : null;
    const original = await sha256Hex(bytes);
    post({
      type: "opened",
      path,
      encoding: opened.encoding,
      bom: opened.bom,
      lineSeparator: lineSeparatorName(opened.lineSeparator),
      lines: view.state.doc.lines,
      chars: view.state.doc.length,
      roundTrip: sha === null ? "converted" : sha === original ? "exact" : "different",
      sha256: sha,
    });
  } catch (error) {
    post({ type: "error", path, message: error instanceof Error ? error.message : String(error) });
  }
}

async function loaded(family: string): Promise<boolean> {
  try {
    return (await document.fonts.load(`15px "${family}"`, "한글 abc")).length > 0;
  } catch {
    return false;
  }
}

if (hasHost) {
  void (async () => {
    const fonts = { pretendard: await loaded("Pretendard"), plexMono: await loaded("IBM Plex Mono") };
    const style = getComputedStyle(view.contentDOM);
    post({
      type: "ready",
      userAgent: navigator.userAgent,
      fonts,
      editorFont: style.fontFamily,
      editorPaddingLeft: style.paddingLeft,
    });
  })();
}
