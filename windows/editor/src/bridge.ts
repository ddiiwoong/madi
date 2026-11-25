// 편집기 ↔ Windows 호스트(WPF, `windows/Madi.Windows`). WebView2의 웹 메시지로 주고받는다 — 호스트 객체는 열지 않는다
// (`AreHostObjectsAllowed = false`). 브라우저에서 띄우면(개발) 호스트가 없고, 받는 것도 보내는 것도 없다.
//
// 파일을 읽고 쓰는 것 · 대화상자 · 창은 호스트가, 글로 읽는 일(인코딩 · 줄 끝) · 편집 · 고친 상태 · 자동 저장은 편집기가 한다.

/** 호스트 → 편집기. 바이트는 base64. */
export type HostMessage =
  | { type: "open"; path: string | null; name: string; bytes: string; reason?: "open" | "reload" }
  /** 지켜보는 파일의 끝에 붙은 바이트(호스트가 앞부분이 그대로인지 끝 4KB로 봤다). */
  | { type: "appended"; bytes: string }
  /** 지켜보는 파일이 다르게 바뀌었다 — 파일 전체. */
  | { type: "replaced"; bytes: string }
  | { type: "saved"; path: string; name: string }
  | { type: "saveFailed"; message: string }
  | { type: "saveCancelled" }
  /** 메뉴에서 고른 명령(`commands` in main.ts) — 설정 명령은 값을 `arg`로(`setTheme` · `github`). */
  | { type: "run"; command: string; arg?: string }
  /** 설정(모든 창이 함께) — 띄울 때, 그리고 어느 창에서든 바뀌면. 껍데기는 내용을 고치지 않고 저장 · 전달만 한다. */
  | { type: "settings"; settings: unknown }
  /** PDF 내보내기 — `begin`이면 흰 종이 · 문서 전체로 그리고 `outputReady`로 답한다. 껍데기가 PDF를 쓴 뒤 `end`. */
  | { type: "output"; action: "begin"; id: number }
  | { type: "output"; action: "end" }
  /** `madi://new`(경로 없이) — 이 글로 새 문서(고친 상태). */
  | { type: "compose"; text: string }
  | Reply
  /** 확인 실행만(`?smoke=1`). */
  | { type: "smoke"; action: "type"; at: number; text: string }
  | { type: "smoke"; action: "digest" }
  | { type: "smoke"; action: "caret"; at: number }
  /** 첫 할 일 상자를 사람이 누른 것처럼(mousedown). */
  | { type: "smoke"; action: "toggleTask" }
  /** 열린 고르는 칸에 친다. */
  | { type: "smoke"; action: "pickerType"; query: string }
  | { type: "smoke"; action: "pickerClose" }
  /** 끝까지 굴린다(화면을 찍으려고 — 캐럿만 옮기면 굴리지 않는다). */
  | { type: "smoke"; action: "scrollEnd" }
  /** 글을 고른다(서식 막대가 뜨게). */
  | { type: "smoke"; action: "select"; from: number; to: number }
  /** 서식 막대의 단추를 사람이 누른 것처럼. */
  | { type: "smoke"; action: "formatPress"; command: string }
  /** 첫(`last`면 마지막) 코드 블록을 보이게 굴리고 그 둘째 줄에 마우스를 올린 것처럼(mousemove). */
  | { type: "smoke"; action: "hoverCode"; last?: boolean }
  /** 코드 복사 단추를 사람이 누른 것처럼(mousedown). `via: "host"`면 껍데기의 길(Win32)로. */
  | { type: "smoke"; action: "codeCopyPress"; via?: "editor" | "host" };

/** 편집기가 물은 것의 답 — `id`로 짝을 짓는다. */
export type Reply =
  | { type: "files"; id: number; items: { path: string; name: string; detail: string }[] }
  | { type: "fonts"; id: number; families: string[] }
  | { type: "image"; id: number; ok: true; dataUrl: string }
  | { type: "image"; id: number; ok: false; message: string }
  | { type: "copied"; id: number; ok: true }
  | { type: "copied"; id: number; ok: false; message: string };

/** 편집기 → 껍데기, 답을 기다리는 것. */
export type Request =
  /** 빠른 열기의 후보 — 열린 창, 최근 파일, 지금 문서의 폴더(macOS판과 같은 상한 · 건너뛰는 폴더). */
  | { type: "listFiles" }
  /** 이 PC의 글꼴 이름(WPF `Fonts.SystemFontFamilies`). */
  | { type: "listFonts" }
  /** 로컬 그림 — 문서 폴더를 기준으로 풀고, 그림 확장자만 읽어 `data:` 주소로. */
  | { type: "loadImage"; path: string }
  /** 클립보드에 글로(코드 복사 단추). 줄 끝은 `\n` — 껍데기가 Windows의 CRLF로 바꾼다. */
  | { type: "copyText"; text: string };

/** 편집기 → 호스트. */
export type EditorMessage =
  | {
      type: "ready";
      userAgent: string;
      fonts: { pretendard: boolean; plexMono: boolean };
      /** 편집기 글이 실제로 쓰는 글꼴과 왼쪽 여백(계산된 CSS) — 실렸어도 다른 규칙에 밀리면 쓰이지 않는다. */
      editorFont: string;
      editorPaddingLeft: string;
    }
  | {
      type: "opened";
      path: string | null;
      encoding: string;
      bom: boolean;
      lineSeparator: "LF" | "CRLF" | "CR";
      lines: number;
      chars: number;
      /** 편집기의 글을 연 꼴로 다시 쓰면 파일과 같은가. 그 꼴로 쓸 수 없으면(EUC-KR) `converted`. */
      roundTrip: "exact" | "different" | "converted";
      /** 다시 쓴 바이트의 SHA-256 — 호스트가 파일의 것과 따로 견준다. */
      sha256: string | null;
    }
  | {
      type: "state";
      name: string;
      path: string | null;
      kind: string;
      dirty: boolean;
      conflict: boolean;
      source: boolean;
      follow: boolean;
      outline: boolean;
      /** 제목 막대에 작게 — 따라 보기, UTF-8이 아닌 인코딩, CR 줄 끝. */
      notes: string[];
    }
  /** 지금 자리에 쓴다(호스트가 아는 파일). `autosave`면 실패해도 대화상자를 띄우지 않는다. */
  | { type: "save"; bytes: string; autosave: boolean }
  /** 저장하지 않은 문서 · 다른 이름으로 — 호스트가 저장 창을 띄운다. */
  | { type: "saveAs"; bytes: string; suggestedName: string }
  | { type: "command"; name: "new" | "open" | "close" | "exportPdf" | "llmKeys" | "checkForUpdates" | "menu" }
  /** 제목 막대(껍데기)의 색 — 편집기와 한 판이게. 모두 `#RRGGBB`. */
  | { type: "chrome"; dark: boolean; background: string; text: string; dim: string; rule: string; accent: string }
  | { type: "outputReady"; id: number; lines: number }
  | { type: "openUrl"; url: string }
  /** 파일을 디스크에서 다시 읽어 `open`으로 보내 달라(띠의 '다시 읽기'). */
  | { type: "reload" }
  /** 바깥 변경을 어떻게 했는지 — 확인 실행이 본다. */
  | { type: "applied"; change: "append" | "replace" | "conflict" | "none"; lines: number; chars: number; atEnd: boolean }
  | {
      type: "digest";
      sha256: string | null;
      lines: number;
      atEnd: boolean;
      previewDecorations: number;
      text: string;
      blocks: { kinds: Record<string, number>; states: Record<string, number>; errors: string[] };
      tasks: number;
      picker: { open: boolean; placeholder: string; query: string; items: number; shown: string[] };
      /** 편집기 바탕 · 글자의 계산된 색 — 테마가 실제로 쓰였는가. */
      colors: { background: string; text: string; scheme: string };
      fontSize: string;
      caretLine: number;
      output: boolean;
      /** 지금 DOM에 그려진 줄 — 내보내는 동안은 문서 전체여야 한다. */
      renderedLines: number;
      codeKeyword: string | null;
      formatBar: { shown: boolean; buttons: string[] };
      codeCopy: { shown: boolean; label: string; language: string | null; via: string | null; inside: boolean | null };
      toast: { text: string; shown: boolean };
    }
  | { type: "settings"; settings: unknown }
  | { type: "openPath"; path: string }
  | (Request & { id: number })
  | { type: "error"; message: string; path?: string | null };

interface WebViewBridge {
  postMessage(message: unknown): void;
  postMessageWithAdditionalObjects?(message: unknown, additionalObjects: ArrayLike<unknown>): void;
  addEventListener(type: "message", listener: (event: MessageEvent) => void): void;
}

declare global {
  interface Window {
    chrome?: { webview?: WebViewBridge };
  }
}

const webview = window.chrome?.webview ?? null;

export const hasHost = webview !== null;

export function post(message: EditorMessage): void {
  webview?.postMessage(message);
}

/** 끌어다 놓은 파일 — 호스트가 그 경로를 받는다(`CoreWebView2File.Path`). 웹 쪽에서는 경로를 알 수 없다. */
export function postDroppedFiles(files: FileList): void {
  webview?.postMessageWithAdditionalObjects?.({ type: "drop" }, files);
}

let nextId = 1;
const waiting = new Map<number, (reply: Reply) => void>();

/** 묻고 답을 기다린다. 껍데기가 없으면(브라우저로 띄운 개발 화면) 실패. */
export function ask<T extends Reply["type"]>(request: Request): Promise<Extract<Reply, { type: T }>> {
  if (!webview) return Promise.reject(new Error("껍데기가 없습니다"));
  const id = nextId++;
  return new Promise((resolve) => {
    waiting.set(id, resolve as (reply: Reply) => void);
    post({ ...request, id });
  });
}

const replyTypes = new Set<string>(["files", "fonts", "image", "copied"]);

export function onHostMessage(handler: (message: HostMessage) => void): void {
  webview?.addEventListener("message", (event) => {
    const message = event.data as HostMessage;
    if (replyTypes.has(message.type)) {
      const reply = message as Reply;
      const resolve = waiting.get(reply.id);
      waiting.delete(reply.id);
      resolve?.(reply);
      return;
    }
    handler(message);
  });
}
