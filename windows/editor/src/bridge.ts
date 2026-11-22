// 편집기 ↔ Windows 호스트(WPF, `windows/Madi.Windows`). WebView2의 웹 메시지로 주고받는다 — 호스트 객체는 열지 않는다
// (`AreHostObjectsAllowed = false`). 브라우저에서 띄우면(개발) 호스트가 없고, 받는 것도 보내는 것도 없다.

export type HostMessage = {
  type: "open";
  path: string;
  name: string;
  /** 파일의 바이트(base64). 글로 읽는 일 — 인코딩 · BOM · 줄 끝 — 은 편집기가 한다(`core/document.ts`). */
  bytes: string;
};

export type EditorMessage =
  | {
      type: "ready";
      userAgent: string;
      /** 앱에 든 글꼴이 실제로 실렸는가. */
      fonts: { pretendard: boolean; plexMono: boolean };
      /** 편집기 글이 실제로 쓰는 글꼴과 왼쪽 여백(계산된 CSS) — 실렸어도 다른 규칙에 밀리면 쓰이지 않는다. */
      editorFont: string;
      editorPaddingLeft: string;
    }
  | {
      type: "opened";
      path: string;
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
  | { type: "error"; message: string; path?: string };

interface WebViewBridge {
  postMessage(message: unknown): void;
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

export function onHostMessage(handler: (message: HostMessage) => void): void {
  webview?.addEventListener("message", (event) => handler(event.data as HostMessage));
}
