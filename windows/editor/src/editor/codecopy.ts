// 코드 블록의 오른쪽 위에 뜨는 `복사` 단추 — macOS판 `CodeCopyButtonView`와 같은 자리 · 같은 규칙(사용자 — "코드 부분 복사 버튼이
// 없음"). 마우스가 코드 블록(회색 상자) 위에 있을 때만 보인다 — GitHub · Docusaurus와 같다. 누르면 펜스를 뺀 코드를 클립보드에 넣고
// 잠깐 `복사됨`으로 바뀐다. 블록의 위가 굴려져 가려졌으면 보이는 칸의 맨 위에 놓는다 — 긴 블록을 읽다가도 바로 누를 수 있게.
//
// 블록은 그려진 회색 상자(`.cm-md-line-code` 줄)로 찾는다 — 그림이 된 다이어그램 · 수식, 원본 보기에는 상자가 없어 단추도 없다. 누르는
// 순간(mousedown) 베끼고 초점을 가져가지 않는다 — 캐럿이 블록에 들어가면 펜스가 드러나 상자가 움직인다.

import { createElement, Check, Copy } from "lucide";
import type { EditorView } from "@codemirror/view";
import { codeBlockAt, codeText, type CodeBlock } from "../core/codecopy.ts";

export class CodeCopyButton {
  private readonly root = document.getElementById("codecopy") as HTMLButtonElement;
  private readonly copy: (text: string) => Promise<"editor" | "host" | null>;
  private view: EditorView | null = null;
  /** 마지막 마우스 자리(화면 좌표) — 굴리면 그 자리 밑의 블록을 다시 찾는다. 편집기 밖이면 null. */
  private point: { x: number; y: number } | null = null;
  private block: CodeBlock | null = null;
  private suppressed = false;
  private frame = 0;
  private resetTimer: number | undefined;
  /** `복사됨`을 보이는 시간. */
  copiedDuration = 1400;

  /** `copy`는 클립보드에 넣고 어느 길로 넣었는지 답한다 — 못 넣었으면 null(알리는 것도 그쪽이 한다). */
  constructor(copy: (text: string) => Promise<"editor" | "host" | null>) {
    this.copy = copy;
    this.root.tabIndex = -1;
    this.showCopied(false);
    this.root.addEventListener("mousedown", (event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      void this.press();
    });
    this.root.addEventListener("mouseleave", (event) => {
      // 편집기로 돌아가면 그 자리에서 다시 잰다.
      if (this.view?.scrollDOM.contains(event.relatedTarget as Node | null)) return;
      this.point = null;
      this.hide();
    });
  }

  attach(view: EditorView): void {
    this.view = view;
    view.scrollDOM.addEventListener("mousemove", (event) => {
      this.point = { x: event.clientX, y: event.clientY };
      this.schedule();
    });
    view.scrollDOM.addEventListener("mouseleave", (event) => {
      // 단추 위로 옮긴 것 — 단추는 편집기 밖(`#app`)에 있다.
      if (this.root.contains(event.relatedTarget as Node | null)) return;
      this.point = null;
      this.hide();
    });
    view.scrollDOM.addEventListener("scroll", () => this.schedule(), { passive: true });
    window.addEventListener("resize", () => this.schedule());
  }

  /** 내보내는 동안은 띄우지 않는다. */
  set hidden(hidden: boolean) {
    this.suppressed = hidden;
    this.schedule();
  }

  /** 마지막으로 베낀 길 — 편집기(Chromium) · 껍데기(Win32). 확인 실행이 본다. */
  via: "editor" | "host" | null = null;

  /**
   * 확인 실행이 보는 것. `inside`는 단추가 그 블록의 **그려진** 회색 상자(코드 줄들의 DOM) 안 오른쪽 위에 있는가 — 높이 지도가 아니라
   * 화면에서 잰다(블록 위젯의 margin이 높이 지도를 어긋나게 해 단추가 블록 위로 떴다).
   */
  get report(): { shown: boolean; label: string; language: string | null; via: string | null; inside: boolean | null } {
    const shown = !this.root.hidden;
    let inside: boolean | null = null;
    const view = this.view;
    if (shown && view && this.block) {
      const block = this.block;
      const boxes = [...view.contentDOM.querySelectorAll<HTMLElement>(".cm-md-line-code")]
        .filter((line) => {
          const pos = view.posAtDOM(line);
          return pos >= block.from && pos <= block.to;
        })
        .map((line) => line.getBoundingClientRect());
      if (boxes.length > 0) {
        const top = Math.min(...boxes.map((box) => box.top));
        const bottom = Math.max(...boxes.map((box) => box.bottom));
        const right = Math.max(...boxes.map((box) => box.right));
        const button = this.root.getBoundingClientRect();
        inside = button.top >= top - 0.5 && button.bottom <= bottom + 0.5 && button.right <= right + 0.5 && button.right >= right - 16;
      }
    }
    return { shown, label: this.root.querySelector("span")?.textContent ?? "", language: this.block?.language ?? null, via: this.via, inside };
  }

  /** 글이 바뀌거나 굴리면 — 상자가 옮겨졌을 수 있다. */
  schedule(): void {
    cancelAnimationFrame(this.frame);
    this.frame = requestAnimationFrame(() => this.place());
  }

  /** 누른 것과 같다(확인 실행도 쓴다). 누르는 순간의 글을 베낀다 — 단추가 뜬 뒤에 고쳤을 수 있다. */
  async press(): Promise<void> {
    const view = this.view;
    if (!view || !this.block) return;
    const block = codeBlockAt(view.state, Math.min(this.block.from, view.state.doc.length));
    if (!block) return;
    const via = await this.copy(codeText(view.state.doc, block));
    if (!via) return;
    this.via = via;
    this.showCopied(true);
  }

  private hide(): void {
    this.root.hidden = true;
  }

  private showCopied(copied: boolean): void {
    window.clearTimeout(this.resetTimer);
    this.resetTimer = undefined;
    this.root.classList.toggle("copied", copied);
    this.root.replaceChildren(createElement(copied ? Check : Copy, { width: 12, height: 12, "stroke-width": 2.25 }));
    const label = document.createElement("span");
    label.textContent = copied ? "복사됨" : "복사";
    this.root.append(label);
    this.root.title = copied ? "" : "코드 복사";
    this.root.setAttribute("aria-label", copied ? "코드를 복사했습니다" : "코드 복사");
    if (copied) this.resetTimer = window.setTimeout(() => this.showCopied(false), this.copiedDuration);
    // 오른쪽 끝을 그대로 둔다 — `복사됨`이 더 넓다(macOS판에서 상자 밖으로 나갔다).
    if (!this.root.hidden) this.schedule();
  }

  private place(): void {
    const view = this.view;
    const point = this.point;
    if (!view || !point || this.suppressed) return this.hide();
    const under = document.elementFromPoint(point.x, point.y);
    if (!under) return this.hide();
    if (!this.root.contains(under)) {
      const line = under.closest<HTMLElement>(".cm-md-line-code");
      if (!line || !view.contentDOM.contains(line)) return this.hide();
      const block = codeBlockAt(view.state, view.posAtDOM(line));
      if (!block) return this.hide();
      if (this.block?.from !== block.from && this.root.classList.contains("copied")) this.showCopied(false);
      this.block = block;
    } else if (!this.block) {
      return this.hide();
    }
    const block = this.block;
    if (block.to > view.state.doc.length) return this.hide();
    const scroller = view.scrollDOM.getBoundingClientRect();
    const top = view.documentTop + view.lineBlockAt(block.from).top;
    const bottom = view.documentTop + view.lineBlockAt(block.to).bottom;
    // 상자의 오른쪽 끝 — 줄은 모두 글 폭을 다 쓴다(목록 안의 블록도). 블록의 첫 줄은 굴려 나가 그려지지 않았을 수 있어 아무 줄로 잰다.
    const right = (view.contentDOM.querySelector(".cm-line") ?? view.contentDOM).getBoundingClientRect().right;
    // 블록이 보이는 칸 밖이면(마우스는 그대로인데 굴렸다) 거둔다.
    if (bottom < scroller.top || top > scroller.bottom) return this.hide();
    const app = document.getElementById("app")!.getBoundingClientRect();
    this.root.hidden = false;
    const width = this.root.offsetWidth;
    const height = this.root.offsetHeight;
    const inset = 6;
    let y = Math.max(top + inset, scroller.top + inset);
    y = Math.min(y, bottom - height - inset);
    this.root.style.left = `${Math.round(right - width - inset - app.left)}px`;
    this.root.style.top = `${Math.round(y - app.top)}px`;
  }
}
