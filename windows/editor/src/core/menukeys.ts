// 메뉴 막대의 키 — 껍데기의 메뉴 막대(`MenuBar.cs`)는 WPF라 편집기(WebView2)에 초점이 있으면 Alt를 받지 못한다. 편집기가 받아 껍데기에
// 알린다(`command: menu`). Windows의 약속: 왼쪽 Alt를 혼자 눌렀다 떼면 메뉴 막대(첫 메뉴), Alt+글자는 그 메뉴. 메뉴 막대가 켜져 있을 때만.
//
// 오른쪽 Alt는 보지 않는다 — 한국어 자판에서는 한/영 키가 오른쪽 Alt로 오는 일이 있어, 받으면 한/영을 바꿀 때마다 메뉴가 열린다.
// 글자는 `code`(자판의 자리)로 본다 — 한글 입력기가 켜져 있으면 `key`가 'ㄹ' 같은 자모로 온다.

/** Alt+글자 → 메뉴 이름(껍데기 `MainWindow.MenuNames`). 밑줄 글자는 … 메뉴의 것과 같다(파일(F) · 편집(E) · 서식(O) · 보기(V) · 도구(T) · 도움말(H)). */
const altKeys: Record<string, string> = { KeyF: "file", KeyE: "edit", KeyO: "format", KeyV: "view", KeyT: "tools", KeyH: "help" };

interface KeyLike {
  key: string;
  code: string;
  altKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  shiftKey: boolean;
  isComposing?: boolean;
}

/** Alt+글자가 메뉴를 여는가 — 열면 그 메뉴 이름. Ctrl · Shift가 함께면 아니다(AltGr는 Ctrl+Alt로 온다). */
export function menuForAltKey(event: KeyLike): string | null {
  if (!event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || event.isComposing) return null;
  return altKeys[event.code] ?? null;
}

/** 왼쪽 Alt를 혼자 눌렀다 뗐는가 — 사이에 다른 키나 마우스가 끼면 아니다(Alt+Tab · Alt+화살표 · Alt+끌기). */
export class AltTap {
  private pending = false;

  down(event: KeyLike): void {
    this.pending = event.code === "AltLeft" && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.isComposing;
  }

  /** 다른 것이 끼었다 — 마우스를 누름, 창이 초점을 잃음. */
  cancel(): void {
    this.pending = false;
  }

  /** 뗄 때 — 혼자 눌렀다 뗀 왼쪽 Alt면 true. */
  up(event: KeyLike): boolean {
    const tapped = this.pending && event.code === "AltLeft";
    this.pending = false;
    return tapped;
  }
}
