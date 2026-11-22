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
  /** 메뉴에서 고른 명령(`commands` in main.ts). */
  | { type: "run"; command: string }
  /** 확인 실행만(`?smoke=1`). */
  | { type: "smoke"; action: "type"; at: number; text: string }
  | { type: "smoke"; action: "digest" }
  | { type: "smoke"; action: "caret"; at: number };

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
    }
  /** 지금 자리에 쓴다(호스트가 아는 파일). `autosave`면 실패해도 대화상자를 띄우지 않는다. */
  | { type: "save"; bytes: string; autosave: boolean }
  /** 저장하지 않은 문서 · 다른 이름으로 — 호스트가 저장 창을 띄운다. */
  | { type: "saveAs"; bytes: string; suggestedName: string }
  | { type: "command"; name: "new" | "open" | "close" }
  | { type: "openUrl"; url: string }
  /** 파일을 디스크에서 다시 읽어 `open`으로 보내 달라(띠의 '다시 읽기'). */
  | { type: "reload" }
  /** 바깥 변경을 어떻게 했는지 — 확인 실행이 본다. */
  | { type: "applied"; change: "append" | "replace" | "conflict" | "none"; lines: number; chars: number; atEnd: boolean }
  | { type: "digest"; sha256: string | null; lines: number; atEnd: boolean; previewDecorations: number; text: string }
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

export function onHostMessage(handler: (message: HostMessage) => void): void {
  webview?.addEventListener("message", (event) => handler(event.data as HostMessage));
}
