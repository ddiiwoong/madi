// 편집기 — 문서 하나의 수명: 열기 · 고친 상태 · 저장(자동 저장 포함) · 바깥 변경 · 보기(원본 · 따라 · 목차).

import { Annotation, EditorSelection, EditorState, Prec, type Text, Transaction } from "@codemirror/state";
import { EditorView, drawSelection, highlightSpecialChars, keymap, placeholder } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, redo, selectAll, undo } from "@codemirror/commands";
import { findNext, openSearchPanel, search, searchKeymap, SearchQuery, setSearchQuery } from "@codemirror/search";
import { base64ToBytes, bytesForSave, bytesToBase64, documentBytes, openDocument, sha256Hex } from "./core/document.ts";
import { lineSeparatorName, normalizeLineBreaks } from "./core/lines.ts";
import { formatEdit } from "./core/formatting.ts";
import { TextStream, type TextEncodingName } from "./core/text.ts";
import { appendSplice, countNewLines, docSplice } from "./core/splice.ts";
import { fileKind, type FileKind } from "./core/kind.ts";
import { outline } from "./core/outline.ts";
import { ask, hasHost, onHostMessage, post, postDroppedFiles, type HostMessage } from "./bridge.ts";
import { normalizeSettings, type Settings } from "./core/settings.ts";
import { themeLabels } from "./core/palette.ts";
import { catalog, settingsChange } from "./core/catalog.ts";
import { appendPiece } from "./core/append.ts";
import { pageRule } from "./core/output.ts";
import { highlighting, koreanPhrases, look, modeExtensions, reconfigure, reconfigureEnvironment, type Mode } from "./editor/setup.ts";
import { linkAt, livePreview } from "./editor/preview.ts";
import { blockReport, blockServices, forgetImages, type BlockEnv } from "./editor/blocks.ts";
import { applyTheme, onSystemAppearanceChange } from "./editor/theme.ts";
import { Picker, type PickItem } from "./editor/picker.ts";
import { ConflictBand, NewLinesPill, OutlinePanel, Toast } from "./editor/ui.ts";
import { FormatBar } from "./editor/formatbar.ts";
import { cssVariables } from "./core/settings.ts";

declare global {
  interface Window {
    /** 껍데기가 페이지를 띄우기 전에 넣어 둔 설정 — 첫 화면부터 그 테마로(밝게 그렸다가 바뀌지 않게). */
    madiSettings?: unknown;
    /** 껍데기에 대한 것 — `packaged`면 Microsoft Store판(MSIX). */
    madiHost?: { packaged?: boolean };
  }
}

const params = new URLSearchParams(location.search);
const smoke = params.has("smoke");
/** 고친 뒤 이만큼 쉬면 저장한다(이름 있는 문서). macOS판의 자동 저장처럼 — 닫을 때 묻지 않는다. */
const autosaveDelay = Number(params.get("autosave") ?? 1500);
const untitled = "제목 없음";

/** 바깥(디스크)에서 들인 바꿈 — 고친 것으로 세지 않고, 자동 저장을 부르지 않는다. */
const fromDisk = Annotation.define<boolean>();

interface DocumentInfo {
  path: string | null;
  name: string;
  kind: FileKind;
  stream: TextStream;
}

let info: DocumentInfo = { path: null, name: untitled, kind: "markdown", stream: TextStream.fresh() };
let mode: Mode = { kind: "markdown", source: false, follow: false, separator: "\n" };
let savedDoc: Text;
/** 저장을 보냈을 때의 글과 그 꼴 — `saved`가 오면 그것이 디스크의 글이다. */
let saving: { doc: Text; encoding: TextEncodingName; bom: boolean; autosave: boolean } | null = null;
let conflict = false;
let autosaveTimer: number | undefined;
let lastAtEnd = true;
let settings: Settings = normalizeSettings(window.madiSettings ?? null);
let dark = applyTheme(settings);
/** 제목 막대(껍데기가 그린다)의 색 — 편집기와 한 판이게. 테마가 바뀔 때마다 보낸다. */
function postChrome(): void {
  const colors = cssVariables(settings, dark);
  post({
    type: "chrome", dark, background: colors["--md-background"]!, text: colors["--md-text"]!, dim: colors["--md-dim"]!,
    rule: colors["--md-rule"]!, accent: colors["--md-link"]!,
  });
}
/** PDF · 프린트로 내보내는 중(`enterOutput`) — 흰 종이에 기본 테마, 캐럿 줄도 꾸민 대로, 문서 전체를 그린다. */
let outputting = false;

function environment(): BlockEnv {
  return {
    dark, loadsRemoteImages: settings.loadsRemoteImages, collapsesFrontMatter: settings.collapsesFrontMatter, output: outputting,
  };
}

const status = new Toast();
const formatBar = new FormatBar((command) => applyFormat(command));
const band = new ConflictBand(() => post({ type: "reload" }), () => save());
const pill = new NewLinesPill(() => scrollToEnd());
const outlinePanel = new OutlinePanel((heading) => {
  view.dispatch({
    selection: EditorSelection.cursor(heading.from),
    effects: EditorView.scrollIntoView(heading.from, { y: "start", yMargin: 24 }),
  });
  view.focus();
});

const picker = new Picker();

const commands: Record<string, (arg?: string) => void> = {
  new: () => post({ type: "command", name: "new" }),
  open: () => post({ type: "command", name: "open" }),
  close: () => post({ type: "command", name: "close" }),
  save: () => save(),
  saveAs: () => saveAs(),
  keepMine: () => save(),
  reload: () => post({ type: "reload" }),
  toggleSource: () => setMode({ source: !mode.source }),
  toggleFollow: () => setMode({ follow: !mode.follow }),
  toggleOutline: () => setOutline(!outlinePanel.shown),
  find: () => openSearchPanel(view),
  undo: () => undo(view),
  redo: () => redo(view),
  selectAll: () => selectAll(view),
  quickOpen: () => quickOpen(),
  commandPalette: () => commandPalette(),
  pickBodyFont: () => pickFont("body"),
  pickCodeFont: () => pickFont("code"),
  // 껍데기가 하는 것 — 저장 창 · PDF 쓰기 · LLM 키 창 · 새 판 확인.
  exportPdf: () => post({ type: "command", name: "exportPdf" }),
  llmKeys: () => post({ type: "command", name: "llmKeys" }),
  checkForUpdates: () => post({ type: "command", name: "checkForUpdates" }),
  print: () => void printDocument(),
  docInfo: () => status.say(documentInfo()),
  menu: () => post({ type: "command", name: "menu" }),
  // `madi://` 링크(껍데기가 읽어 보낸다) — 줄로 가기 · 찾기 · 끝에 더하기 · 끝으로.
  goToLine: (arg) => goToLine(Number(arg)),
  search: (arg) => startSearch(arg ?? ""),
  appendText: (arg) => appendText(arg ?? ""),
  caretEnd: () => {
    view.dispatch({ selection: EditorSelection.cursor(view.state.doc.length), scrollIntoView: true });
  },
};
// 설정 명령(테마 · 모양 · 글자 크기 · 줄 사이 · 글 폭 · 글꼴 · 원격 그림 · 앞머리 접기) — 값은 `core/catalog.ts`가 정한다.
// 서식(`core/formatting.ts`) — 막대 · 단축키 · 메뉴 · 명령 팔레트가 같은 이름을 부른다.
for (const id of [
  "bold", "italic", "strikethrough", "code", "link", "bullet", "numbered", "task", "quote", "codeBlock", "table", "rule",
  "heading0", "heading1", "heading2", "heading3", "heading4", "heading5", "heading6",
]) {
  commands[id] = () => applyFormat(id);
}
for (const id of [
  "setTheme", "setAppearance", "setLineSpacing", "setDocumentWidth", "textBigger", "textSmaller", "textStandard",
  "setBodyFont", "setCodeFont", "toggleRemoteImages", "toggleFrontMatter",
  "setPrintMargin", "setPrintOrientation", "setPrintPaper", "toggleUpdateChecks",
]) {
  commands[id] = (arg) => {
    const next = settingsChange(settings, id, arg);
    if (next) changeSettings(next);
  };
}

const shortcuts = Prec.highest(keymap.of([
  { key: "Mod-n", run: () => (commands.new!(), true) },
  { key: "Mod-o", run: () => (commands.open!(), true) },
  { key: "Mod-s", run: () => (commands.save!(), true) },
  { key: "Mod-Shift-s", run: () => (commands.saveAs!(), true) },
  { key: "Mod-w", run: () => (commands.close!(), true) },
  { key: "Mod-e", run: () => (commands.toggleSource!(), true) },
  { key: "Mod-Alt-l", run: () => (commands.toggleFollow!(), true) },
  { key: "Mod-Shift-o", run: () => (commands.toggleOutline!(), true) },
  // Ctrl+P는 프린트(Windows의 약속이고 macOS판의 ⌘P와 같다). 빠른 열기는 macOS판의 ⌥⌘O 자리.
  { key: "Mod-p", run: () => (commands.print!(), true) },
  { key: "Mod-Alt-o", run: () => (commands.quickOpen!(), true) },
  { key: "Mod-Shift-p", run: () => (commands.commandPalette!(), true) },
  { key: "Mod-=", run: () => (commands.textBigger!(), true) },
  { key: "Mod-+", run: () => (commands.textBigger!(), true) },
  { key: "Mod--", run: () => (commands.textSmaller!(), true) },
  { key: "Mod-0", run: () => (commands.textStandard!(), true) },
  // 서식 — macOS판의 단축키를 Ctrl로(⌘B → Ctrl+B …). 본문은 Ctrl+Alt+0(Ctrl+0은 글자 기본 크기).
  { key: "Mod-b", run: () => (commands.bold!(), true) },
  { key: "Mod-i", run: () => (commands.italic!(), true) },
  { key: "Mod-Shift-x", run: () => (commands.strikethrough!(), true) },
  { key: "Mod-Shift-c", run: () => (commands.code!(), true) },
  { key: "Mod-k", run: () => (commands.link!(), true) },
  { key: "Mod-Shift-8", run: () => (commands.bullet!(), true) },
  { key: "Mod-Shift-7", run: () => (commands.numbered!(), true) },
  { key: "Mod-Shift-9", run: () => (commands.task!(), true) },
  { key: "Mod-Alt-q", run: () => (commands.quote!(), true) },
  { key: "Mod-Alt-c", run: () => (commands.codeBlock!(), true) },
  { key: "Mod-Alt-0", run: () => (commands.heading0!(), true) },
  ...[1, 2, 3, 4, 5, 6].map((level) => ({ key: `Mod-${level}`, run: () => (commands[`heading${level}`]!(), true) })),
  // 메뉴 막대가 없다 — F10은 Windows의 약속대로 메뉴(제목 막대의 …)를 연다.
  { key: "F10", run: () => (commands.menu!(), true) },
]));

function baseExtensions() {
  return [
    shortcuts,
    history(),
    drawSelection(),
    highlightSpecialChars(),
    EditorView.lineWrapping,
    search({ top: true }),
    keymap.of([...searchKeymap, ...defaultKeymap, ...historyKeymap]),
    highlighting,
    placeholder("여기에 쓰기 시작합니다"),
    koreanPhrases,
    look,
    EditorView.contentAttributes.of({ lang: "ko", spellcheck: "false" }),
    // 붙여 넣기 · 끌어다 놓기의 줄 끝을 문서의 줄 끝으로 — Windows의 클립보드는 CRLF라 LF 문서에 \r이 섞였다.
    EditorView.clipboardInputFilter.of((text, state) => normalizeLineBreaks(text, state.lineBreak)),
    EditorView.updateListener.of((update) => {
      if (update.docChanged) {
        const byUser = update.transactions.some((tr) => tr.docChanged && !tr.annotation(fromDisk));
        if (byUser) scheduleAutosave();
        scheduleOutline();
      }
      if (update.docChanged || update.transactions.some((tr) => tr.reconfigured)) postState();
      if (update.selectionSet || update.docChanged || update.geometryChanged || update.focusChanged || update.viewportChanged) {
        formatBar.schedule();
      }
    }),
    EditorView.domEventHandlers({
      // Ctrl+클릭 — 링크를 기본 브라우저로(호스트가 http · https · mailto만 연다). 그냥 클릭은 캐럿을 놓는다(그 줄이 원문이 된다).
      mousedown(event, view) {
        if (!event.ctrlKey || event.button !== 0) return false;
        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        const url = pos === null ? null : linkAt(view, pos);
        if (!url) return false;
        post({ type: "openUrl", url });
        event.preventDefault();
        return true;
      },
    }),
  ];
}

function makeState(text: string): EditorState {
  return EditorState.create({ doc: text, extensions: [baseExtensions(), modeExtensions(mode, environment())] });
}

const parent = document.getElementById("editor");
if (!parent) throw new Error("편집기를 놓을 자리(#editor)가 없다");
const view = new EditorView({ state: makeState(""), parent });
savedDoc = view.state.doc;
view.focus();

formatBar.attach(view);

blockServices.openUrl = (url) => post({ type: "openUrl", url });
blockServices.loadImage = async (path) => {
  const reply = await ask<"image">({ type: "loadImage", path });
  if (!reply.ok) throw new Error(reply.message);
  return reply.dataUrl;
};

view.scrollDOM.addEventListener("scroll", () => {
  lastAtEnd = isAtEnd();
  if (lastAtEnd) pill.hide();
});
// 창 크기가 바뀌어도 따라 보기는 끝에 남는다(줄이 다시 감겨 글의 길이가 바뀐다 — macOS판에서 겪었다).
new ResizeObserver(() => {
  if (mode.follow && lastAtEnd) scrollToEnd();
}).observe(view.scrollDOM);

// 끌어다 놓은 파일은 연다 — CodeMirror가 글로 넣지 않게 먼저 받는다.
window.addEventListener("dragover", (event) => {
  if (event.dataTransfer?.types.includes("Files")) event.preventDefault();
}, true);
window.addEventListener("drop", (event) => {
  const files = event.dataTransfer?.files;
  if (!files || files.length === 0) return;
  event.preventDefault();
  event.stopPropagation();
  postDroppedFiles(files);
}, true);

// MARK: 상태

function isDirty(): boolean {
  return !view.state.doc.eq(savedDoc);
}

function isAtEnd(): boolean {
  const scroller = view.scrollDOM;
  return scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 32;
}

function scrollToEnd(): void {
  view.dispatch({ effects: EditorView.scrollIntoView(view.state.doc.length, { y: "end" }) });
  requestAnimationFrame(() => {
    view.scrollDOM.scrollTop = view.scrollDOM.scrollHeight;
    lastAtEnd = true;
    pill.hide();
  });
}

const encodingNames: Record<TextEncodingName, string> = {
  "utf-8": "UTF-8",
  "utf-16le": "UTF-16 LE",
  "utf-16be": "UTF-16 BE",
  "euc-kr": "EUC-KR(저장하면 UTF-8)",
  "windows-1252": "Windows-1252(저장하면 UTF-8)",
};

let lastState = "";
function postState(): void {
  const state = {
    type: "state" as const,
    name: info.name,
    path: info.path,
    kind: info.kind,
    dirty: isDirty(),
    conflict,
    source: mode.source,
    follow: mode.follow,
    outline: outlinePanel.shown,
    // 제목 막대의 작은 표시 — 늘 같은 것(UTF-8)은 적지 않고, 알아야 할 것만.
    notes: [
      mode.follow ? "따라 보기" : "",
      info.stream.encoding === "utf-8" ? "" : encodingNames[info.stream.encoding],
      mode.separator === "\r" ? "CR 줄 끝" : "",
    ].filter(Boolean),
  };
  const json = JSON.stringify(state);
  if (json !== lastState) {
    lastState = json;
    post(state);
  }
}

/** 문서 정보 — 보기 ▸ 문서 정보 · 명령 팔레트. 전에 아래 상태 줄에 늘 있던 것. */
function documentInfo(): string {
  const parts = [
    info.name,
    encodingNames[info.stream.encoding] + (info.stream.bom ? " BOM" : ""),
    lineSeparatorName(mode.separator),
    `${view.state.doc.lines.toLocaleString("ko-KR")}줄`,
    `${view.state.doc.length.toLocaleString("ko-KR")}자`,
    mode.follow ? "따라 보기" : mode.source ? "원본 보기" : "",
  ];
  return parts.filter(Boolean).join(" · ");
}

/** 서식 명령 — 고른 글(없으면 캐럿)에. 고칠 수 없는 보기면 하지 않는다. */
function applyFormat(command: string): void {
  if (view.state.readOnly) return;
  const range = view.state.selection.main;
  // 편집기의 글은 줄 끝이 `\n`(자리를 한 칸으로 센다) — 넣는 글만 문서의 줄 끝으로 바꾼다.
  const edit = formatEdit(command, view.state.doc.toString(), { from: range.from, to: range.to });
  if (!edit) return;
  view.dispatch({
    changes: { from: edit.from, to: edit.to, insert: normalizeLineBreaks(edit.insert, view.state.lineBreak) },
    selection: EditorSelection.range(edit.selection.from, edit.selection.to),
    scrollIntoView: true,
    userEvent: "input.format",
  });
  view.focus();
}

function setMode(change: Partial<Pick<Mode, "source" | "follow">>): void {
  mode = { ...mode, ...change };
  if (mode.follow) cancelAutosave();
  view.dispatch({ effects: reconfigure(mode) });
  // 따라 보기는 켤 때도, 보기를 바꿔 글의 길이가 바뀔 때도 끝에 남는다.
  if (mode.follow) scrollToEnd();
  scheduleOutline(0);
  postState();
}

function setOutline(shown: boolean): void {
  outlinePanel.shown = shown;
  scheduleOutline(0);
  postState();
  requestAnimationFrame(() => view.requestMeasure());
}

let outlineTimer: number | undefined;
function scheduleOutline(delay = 300): void {
  if (!outlinePanel.shown) return;
  window.clearTimeout(outlineTimer);
  outlineTimer = window.setTimeout(() => {
    // 글 파일을 쓴 그대로 볼 때는 목차가 없다 — 로그의 `# ` 줄은 제목이 아니다.
    outlinePanel.render(info.kind !== "markdown" && mode.source ? [] : outline(view.state));
  }, delay);
}

// MARK: 설정 — 모든 창이 함께. 여기서 바꾸면 껍데기가 저장하고 열린 창 모두에(이 창에도) 돌려준다.

function applySettings(next: Settings): void {
  const changed = JSON.stringify(next) !== JSON.stringify(settings);
  settings = next;
  updatePageRule();
  // 내보내는 동안은 흰 종이 그대로 — 끝나면(`exitOutput`) 바뀐 설정으로 돌아간다.
  if (outputting) return;
  const wasDark = dark;
  dark = applyTheme(settings);
  postChrome();
  if (!changed && wasDark === dark) return;
  view.dispatch({ effects: reconfigureEnvironment(environment()) });
  // 글자 크기 · 줄 높이가 바뀌면 줄의 높이를 다시 잰다.
  view.requestMeasure();
  if (mode.follow && lastAtEnd) scrollToEnd();
}

function changeSettings(next: Settings): void {
  applySettings(normalizeSettings(next));
  post({ type: "settings", settings });
  status.say(`설정: ${describeSettings()}`);
}

function describeSettings(): string {
  return `${themeLabels[settings.theme]}${dark ? " 다크" : ""} · ${settings.bodySize}px`;
}

onSystemAppearanceChange(() => applySettings(settings));

// MARK: 내보내기 — PDF(껍데기가 `output` begin → PrintToPdf → end) · 프린트(편집기가 `window.print()`)

/** 용지 · 방향 · 여백 — 프린트 창의 기본값이 된다. PDF는 껍데기가 같은 값을 넘긴다(`PrintLayout`). */
const pageStyle = document.createElement("style");
pageStyle.id = "md-page";
document.head.append(pageStyle);
function updatePageRule(): void {
  pageStyle.textContent = pageRule(settings);
}
updatePageRule();

/**
 * CodeMirror는 보이는 줄만 그린다. 프린트할 때(`beforeprint`) 잠깐(0.5초) 전체를 그리는데, 다이어그램 · 그림은 그 안에 그려지지 않는다.
 * 그래서 내보내는 동안 내내 전체를 그리게 둔다 — CodeMirror의 안쪽 값(`viewState.printing`, 6.43.15에서 확인)이라 판을 올리면
 * 확인 실행의 PDF 쪽 수가 지킨다.
 */
function setPrinting(on: boolean): void {
  const state = (view as unknown as { viewState?: { printing?: boolean } }).viewState;
  if (state && "printing" in state) state.printing = on;
  view.requestMeasure();
}

async function settled(timeout = 20000): Promise<void> {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const pending = view.dom.querySelectorAll('.md-block[data-state="pending"]').length;
    const images = [...view.dom.querySelectorAll("img")].filter((image) => !image.complete).length;
    if (pending === 0 && images === 0) break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  await document.fonts.ready;
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
}

async function enterOutput(): Promise<void> {
  if (outputting) return;
  outputting = true;
  formatBar.hidden = true;
  picker.close();
  // macOS판처럼 고른 테마와 상관없이 흰 종이에 기본 색 — 다이어그램도 라이트로 다시 그린다.
  dark = applyTheme({ ...settings, theme: "standard", appearance: "light" });
  document.documentElement.classList.add("md-output");
  view.dispatch({ effects: reconfigureEnvironment(environment()) });
  setPrinting(true);
  await settled();
  setPrinting(true);
  await settled(2000);
}

function exitOutput(): void {
  if (!outputting) return;
  outputting = false;
  formatBar.hidden = false;
  document.documentElement.classList.remove("md-output");
  dark = applyTheme(settings);
  view.dispatch({ effects: reconfigureEnvironment(environment()) });
  setPrinting(false);
  view.focus();
}

async function printDocument(): Promise<void> {
  await enterOutput();
  // 프린트 창을 닫으면(찍든 취소하든) 돌아온다. `print()`가 창이 닫힐 때까지 기다리지 않는 엔진이면 `afterprint`가 한다.
  window.addEventListener("afterprint", exitOutput, { once: true });
  window.print();
}

/** 껍데기가 시킨 내보내기(PDF) 중인가 — 그때는 껍데기의 `end`를 기다린다. */
let hostOutput = false;
// 프린트 창이 `afterprint` 없이 닫혔을 때 — 사람이 편집기로 돌아오면 끝낸다.
for (const type of ["mousedown", "keydown"] as const) {
  window.addEventListener(type, () => {
    if (outputting && !hostOutput) exitOutput();
  }, true);
}

// MARK: 링크(`madi://`)

function goToLine(line: number): void {
  if (!Number.isInteger(line) || line < 1) return;
  const target = view.state.doc.line(Math.min(line, view.state.doc.lines));
  view.dispatch({
    selection: EditorSelection.cursor(target.from),
    effects: EditorView.scrollIntoView(target.from, { y: "center" }),
  });
  view.focus();
}

function startSearch(text: string): void {
  if (text === "") return;
  openSearchPanel(view);
  view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: text })) });
  findNext(view);
}

/** `madi://new`(경로 없이) — 받은 글로 새 문서. 사람이 쓴 것처럼 들여 고친 상태가 된다(닫을 때 묻는다). 캐럿은 끝. */
function compose(text: string): void {
  const body = normalizeLineBreaks(text, "\n");
  view.dispatch({
    // 넣는 글은 문서의 줄 끝으로(CodeMirror는 정한 줄 끝만 줄로 나눈다), 자리는 줄 끝을 한 칸으로 센다.
    changes: { from: 0, to: view.state.doc.length, insert: normalizeLineBreaks(body, view.state.lineBreak) },
    selection: EditorSelection.cursor(body.length),
    scrollIntoView: true,
    userEvent: "input.link",
  });
  view.focus();
}

function appendText(text: string): void {
  if (text === "" || view.state.readOnly) return;
  // 규칙(`appendPiece`)은 줄 끝이 `\n`인 글로 따진다. 넣을 때는 문서의 줄 끝으로 — CRLF 문서에 `\n`을 그대로 넣으면 CodeMirror가
  // 줄로 나누지 않아 줄 안에 LF가 남는다.
  const piece = appendPiece(normalizeLineBreaks(text, "\n"), view.state.doc.toString());
  const end = view.state.doc.length;
  view.dispatch({
    changes: { from: end, insert: normalizeLineBreaks(piece, view.state.lineBreak) },
    selection: EditorSelection.cursor(end + piece.length),
    scrollIntoView: true,
    userEvent: "input.link",
  });
  view.focus();
}

// MARK: 고르는 칸 — 빠른 열기 · 명령 팔레트 · 글꼴

/** 고르는 칸이 열린 동안은 서식 막대를 띄우지 않는다. */
function openPicker(placeholder: string, items: Parameters<Picker["open"]>[1]): void {
  formatBar.hidden = true;
  picker.open(placeholder, items, () => {
    formatBar.hidden = false;
    view.focus();
  });
}

function quickOpen(): void {
  const items = ask<"files">({ type: "listFiles" })
    .then((reply) => reply.items.map((item): PickItem => ({
      title: item.name,
      detail: item.detail,
      run: () => post({ type: "openPath", path: item.path }),
    })))
    .catch(() => []);
  openPicker("파일 이름으로 열기 — 열린 문서 · 최근 문서 · 이 폴더", items);
}

function commandPalette(): void {
  const entries = catalog({
    settings, source: mode.source, follow: mode.follow, outline: outlinePanel.shown, packaged: window.madiHost?.packaged === true,
  });
  openPicker("명령", entries.map((entry): PickItem => ({
    title: entry.title,
    detail: entry.menu,
    hint: [entry.checked ? "✓" : "", entry.shortcut ?? ""].filter(Boolean).join("  "),
    run: () => commands[entry.id]?.(entry.arg),
  })));
}

function pickFont(which: "body" | "code"): void {
  const current = which === "body" ? settings.bodyFont : settings.codeFont;
  const command = which === "body" ? "setBodyFont" : "setCodeFont";
  const builtIn: PickItem = {
    title: which === "body" ? "Pretendard" : "IBM Plex Mono",
    detail: "앱에 든 글꼴(기본)",
    hint: current === null ? "✓" : "",
    run: () => commands[command]!(undefined),
  };
  const items = ask<"fonts">({ type: "listFonts" })
    .then((reply) => [builtIn, ...reply.families.map((family): PickItem => ({
      title: family,
      hint: current === family ? "✓" : "",
      run: () => commands[command]!(family),
    }))])
    .catch(() => [builtIn]);
  openPicker(which === "body" ? "본문 글꼴" : "코드 글꼴", items);
}

// MARK: 열기

async function open(message: Extract<HostMessage, { type: "open" }>): Promise<void> {
  try {
    const bytes = base64ToBytes(message.bytes);
    const opened = openDocument(bytes);
    const kind = fileKind(message.path ?? message.name);
    info = { path: message.path, name: message.name, kind, stream: opened.stream };
    const reload = message.reason === "reload";
    // 다시 읽을 때(띠의 '다시 읽기')는 고른 보기를 둔다. 처음 열 때만 종류에 맞춘다 — 글 파일은 원본 보기, 로그는 따라 보기.
    mode = reload
      ? { ...mode, kind, separator: opened.lineSeparator }
      : { kind, source: kind !== "markdown", follow: kind === "log", separator: opened.lineSeparator };
    cancelAutosave();
    conflict = false;
    band.shown = false;
    pill.hide();
    if (!reload) forgetImages();
    view.setState(makeState(opened.text));
    savedDoc = view.state.doc;
    if (mode.follow) scrollToEnd();
    else view.focus();
    scheduleOutline(0);
    postState();
    const back = documentBytes(view.state.sliceDoc(), opened.stream);
    const sha = back ? await sha256Hex(back) : null;
    const original = await sha256Hex(bytes);
    post({
      type: "opened",
      path: message.path,
      encoding: opened.stream.encoding,
      bom: opened.stream.bom,
      lineSeparator: lineSeparatorName(opened.lineSeparator),
      lines: view.state.doc.lines,
      chars: view.state.doc.length,
      roundTrip: sha === null ? "converted" : sha === original ? "exact" : "different",
      sha256: sha,
    });
  } catch (error) {
    post({ type: "error", path: message.path, message: error instanceof Error ? error.message : String(error) });
  }
}

// MARK: 바깥 변경 — 호스트가 파일을 지켜보다 보낸다(끝에 붙음 · 다르게 바뀜)

function reportApplied(change: "append" | "replace" | "conflict" | "none"): void {
  // 굴린 자리는 다음 그림에서 정해진다 — 두 번 기다려 잰다.
  requestAnimationFrame(() => requestAnimationFrame(() => post({
    type: "applied", change, lines: view.state.doc.lines, chars: view.state.doc.length, atEnd: isAtEnd(),
  })));
}

function enterConflict(): void {
  if (conflict) return;
  conflict = true;
  cancelAutosave();
  band.shown = true;
  postState();
  status.say("다른 곳에서 바뀌었습니다 — 고를 때까지 자동 저장을 멈춥니다");
}

function applyFromDisk(change: { from: number; to: number; insert: string }, appended: string | null): void {
  const wasAtEnd = isAtEnd();
  view.dispatch({ changes: change, annotations: [fromDisk.of(true), Transaction.addToHistory.of(false)] });
  savedDoc = view.state.doc;
  if (wasAtEnd) scrollToEnd();
  else if (appended !== null) pill.add(countNewLines(appended));
  scheduleOutline();
}

function appended(bytes: Uint8Array): void {
  if (conflict) return reportApplied("conflict");
  if (isDirty()) {
    enterConflict();
    return reportApplied("conflict");
  }
  let text: string;
  try {
    text = info.stream.append(bytes);
  } catch {
    // 이 꼴로 읽을 수 없는 바이트가 붙었다 — 통째로 다시 읽는다(고친 것이 없을 때만 온다).
    post({ type: "reload" });
    return;
  }
  if (text === "") return reportApplied("none");
  const length = view.state.doc.length;
  applyFromDisk(appendSplice(length, view.state.sliceDoc(length - 1, length), text, mode.separator), text);
  reportApplied("append");
}

function replaced(bytes: Uint8Array): void {
  if (conflict) return reportApplied("conflict");
  if (isDirty()) {
    enterConflict();
    return reportApplied("conflict");
  }
  const opened = openDocument(bytes);
  info = { ...info, stream: opened.stream };
  if (opened.lineSeparator !== mode.separator) {
    // 줄 끝이 바뀌었다(LF → CRLF 등) — 편집기의 줄 나눔이 달라 갈아 끼울 수 없다. 보기는 두고 다시 싣는다.
    void open({ type: "open", path: info.path, name: info.name, bytes: bytesToBase64(bytes), reason: "reload" });
    return reportApplied("replace");
  }
  const splice = docSplice(view.state.sliceDoc(), opened.text, mode.separator);
  if (splice) applyFromDisk(splice, null);
  reportApplied(splice ? "replace" : "none");
}

// MARK: 저장

function suggestedName(): string {
  if (info.path !== null) return info.name;
  const first = outline(view.state)[0]?.title ?? "";
  const clean = first.replace(/[\\/:*?"<>|]/g, " ").replace(/\s+/g, " ").trim().slice(0, 60);
  return `${clean || untitled}.md`;
}

function prepareSave(autosave = false) {
  const { bytes, encoding, bom } = bytesForSave(view.state.sliceDoc(), info.stream);
  saving = { doc: view.state.doc, encoding, bom, autosave };
  return bytesToBase64(bytes);
}

/**
 * 지금 자리에 쓴다. 바깥 변경과 부딪쳐 띠가 떠 있으면 자동 저장은 쓰지 않는다(쓰면 바깥 것을 덮는다). 손으로 저장하면(띠의
 * '내 것 지키기', 그때의 Ctrl+S) 여기 것을 쓴다.
 */
function save(autosave = false): void {
  if (info.path === null) {
    if (!autosave) saveAs();
    return;
  }
  if (autosave && (conflict || mode.follow)) return;
  cancelAutosave();
  post({ type: "save", bytes: prepareSave(autosave), autosave });
}

function saveAs(): void {
  cancelAutosave();
  post({ type: "saveAs", bytes: prepareSave(), suggestedName: suggestedName() });
}

function scheduleAutosave(): void {
  cancelAutosave();
  if (info.path === null || conflict || mode.follow) return;
  autosaveTimer = window.setTimeout(() => {
    if (isDirty()) save(true);
  }, autosaveDelay);
}

function cancelAutosave(): void {
  window.clearTimeout(autosaveTimer);
  autosaveTimer = undefined;
}

function saved(path: string, name: string): void {
  const wasAutosave = saving?.autosave === true;
  if (saving) {
    savedDoc = saving.doc;
    if (saving.encoding !== info.stream.encoding || saving.bom !== info.stream.bom) {
      info = { ...info, stream: TextStream.fresh(saving.encoding, saving.bom) };
    }
  }
  saving = null;
  const kind = fileKind(path);
  if (kind !== info.kind) {
    // 다른 이름으로 저장해 종류가 바뀌었다 — 보기는 그대로(저장했을 뿐인데 화면이 바뀌면 안 된다).
    mode = { ...mode, kind };
    view.dispatch({ effects: reconfigure(mode) });
  }
  info = { ...info, path, name, kind };
  if (conflict) {
    conflict = false;
    band.shown = false;
  }
  // 자동 저장은 알리지 않는다 — 쓰다 쉴 때마다 알림이 뜬다(전의 상태 줄은 조용히 바뀌었다). 손으로 저장했을 때만.
  if (!wasAutosave) status.say("저장했습니다");
  postState();
  // 저장하는 동안 더 고쳤으면 다시 잡는다.
  if (isDirty()) scheduleAutosave();
}

// MARK: 호스트

onHostMessage((message) => {
  switch (message.type) {
    case "open":
      void open(message);
      break;
    case "appended":
      appended(base64ToBytes(message.bytes));
      break;
    case "replaced":
      replaced(base64ToBytes(message.bytes));
      break;
    case "saved":
      saved(message.path, message.name);
      break;
    case "saveFailed":
      saving = null;
      status.say(`저장하지 못했습니다: ${message.message}`, true);
      break;
    case "saveCancelled":
      saving = null;
      break;
    case "run":
      picker.close();
      commands[message.command]?.(message.arg);
      if (!picker.isOpen) view.focus();
      break;
    case "settings":
      applySettings(normalizeSettings(message.settings));
      break;
    case "output":
      if (message.action === "begin") {
        hostOutput = true;
        void enterOutput().then(() => post({ type: "outputReady", id: message.id, lines: view.state.doc.lines }));
      } else {
        hostOutput = false;
        exitOutput();
      }
      break;
    case "compose":
      compose(message.text);
      break;
    case "smoke":
      if (smoke) void runSmoke(message);
      break;
  }
});

async function runSmoke(message: Extract<HostMessage, { type: "smoke" }>): Promise<void> {
  switch (message.action) {
    case "type":
      view.dispatch({ changes: { from: message.at, insert: message.text }, userEvent: "input.type" });
      break;
    case "caret":
      view.dispatch({ selection: EditorSelection.cursor(Math.min(message.at, view.state.doc.length)) });
      break;
    case "toggleTask": {
      const box = view.dom.querySelector<HTMLElement>(".cm-md-task");
      box?.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 }));
      break;
    }
    case "pickerType":
      picker.type(message.query);
      break;
    case "pickerClose":
      picker.close();
      break;
    case "select":
      view.dispatch({ selection: EditorSelection.range(message.from, message.to), scrollIntoView: true });
      break;
    case "formatPress": {
      // 사람이 막대의 단추를 누른 것처럼 — 막대가 떠 있어야 누를 수 있다.
      const button = document.querySelector<HTMLElement>(`#formatbar:not([hidden]) [data-command="${message.command}"]`);
      button?.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 }));
      break;
    }
    case "scrollEnd":
      scrollToEnd();
      break;
    case "digest": {
      const back = documentBytes(view.state.sliceDoc(), info.stream);
      const plugin = view.plugin(livePreview);
      post({
        type: "digest",
        sha256: back ? await sha256Hex(back) : null,
        lines: view.state.doc.lines,
        atEnd: isAtEnd(),
        previewDecorations: plugin?.count ?? 0,
        text: view.state.sliceDoc(0, 2000),
        blocks: blockReport(view),
        tasks: view.dom.querySelectorAll(".cm-md-task").length,
        picker: picker.report,
        formatBar: formatBar.report,
        toast: status.report,
        colors: {
          background: getComputedStyle(view.dom).backgroundColor,
          text: getComputedStyle(view.contentDOM).color,
          scheme: document.documentElement.style.colorScheme,
        },
        fontSize: getComputedStyle(view.scrollDOM).fontSize,
        caretLine: view.state.doc.lineAt(view.state.selection.main.head).number,
        output: outputting,
        renderedLines: view.contentDOM.querySelectorAll(".cm-line").length,
        // 코드 블록의 문법 색 — 첫 `let`(확인 문서의 Swift)의 색. 칠하지 않았으면 본문 색이거나 없다.
        codeKeyword: (() => {
          const word = [...view.contentDOM.querySelectorAll(".cm-md-line-code span")].find((span) => span.textContent === "let");
          return word ? getComputedStyle(word).color : null;
        })(),
      });
      break;
    }
  }
}

async function loaded(family: string): Promise<boolean> {
  try {
    return (await document.fonts.load(`15px "${family}"`, "한글 abc")).length > 0;
  } catch {
    return false;
  }
}

postState();
postChrome();
if (hasHost) {
  void (async () => {
    const fonts = { pretendard: await loaded("Pretendard"), plexMono: await loaded("IBM Plex Mono") };
    const style = getComputedStyle(view.contentDOM);
    post({ type: "ready", userAgent: navigator.userAgent, fonts, editorFont: style.fontFamily, editorPaddingLeft: style.paddingLeft });
  })();
}

