// 글을 고르면 그 위에 뜨는 서식 막대 — macOS판 `FormatBarView`와 같은 자리 · 같은 규칙(사용자 — "글을 고르면 위에 뜨는 서식 막대").
// 제목 ▾ · 굵게 · 기울임 · 취소선 · 인라인 코드 · 링크, 그리고 목록 셋 · 인용 · 코드 블록 · 표 · 구분선.
//
// 단추는 누르는 순간(mousedown) 명령을 보내고 초점을 가져가지 않는다 — 캐럿과 선택이 편집기에 남아 굵게를 누른 뒤 바로 기울임을 누를 수
// 있다. 마우스로 고르는 동안(누른 채)에는 숨는다 — 다 고른 뒤에 뜬다. 한글을 조합하는 동안 · 고칠 수 없는 보기 · 내보내는 동안도 숨는다.

import {
  createElement, Bold, Code, Heading, Italic, Link, List, ListChecks, ListOrdered, SeparatorHorizontal, SquareCode,
  Strikethrough, Table, TextQuote, type IconNode,
} from "lucide";
import type { EditorView } from "@codemirror/view";

interface Button {
  command: string;
  icon: IconNode;
  title: string;
  shortcut: string;
}

/** 단추 — `command`는 편집기의 서식 명령(`core/formatting.ts`의 이름). `null`은 칸막이. */
const buttons: (Button | null)[] = [
  { command: "heading", icon: Heading, title: "제목", shortcut: "Ctrl+1~6 · 본문 Ctrl+Alt+0" },
  null,
  { command: "bold", icon: Bold, title: "굵게", shortcut: "Ctrl+B" },
  { command: "italic", icon: Italic, title: "기울임", shortcut: "Ctrl+I" },
  { command: "strikethrough", icon: Strikethrough, title: "취소선", shortcut: "Ctrl+Shift+X" },
  { command: "code", icon: Code, title: "인라인 코드", shortcut: "Ctrl+Shift+C" },
  { command: "link", icon: Link, title: "링크", shortcut: "Ctrl+K" },
  null,
  { command: "bullet", icon: List, title: "글머리 목록", shortcut: "Ctrl+Shift+8" },
  { command: "numbered", icon: ListOrdered, title: "번호 목록", shortcut: "Ctrl+Shift+7" },
  { command: "task", icon: ListChecks, title: "할 일 목록", shortcut: "Ctrl+Shift+9" },
  { command: "quote", icon: TextQuote, title: "인용", shortcut: "Ctrl+Alt+Q" },
  null,
  { command: "codeBlock", icon: SquareCode, title: "코드 블록", shortcut: "Ctrl+Alt+C" },
  { command: "table", icon: Table, title: "표", shortcut: "" },
  { command: "rule", icon: SeparatorHorizontal, title: "구분선", shortcut: "" },
];

const headingChoices = [["heading0", "본문"], ...[1, 2, 3, 4, 5, 6].map((level) => [`heading${level}`, `제목 ${level}`])] as const;

export class FormatBar {
  private readonly root = document.getElementById("formatbar")!;
  private readonly menu = document.getElementById("formatbar-headings")!;
  private readonly run: (command: string) => void;
  private pointerDown = false;
  private suppressed = false;
  private view: EditorView | null = null;
  private frame = 0;

  constructor(run: (command: string) => void) {
    this.run = run;
    for (const button of buttons) {
      if (!button) {
        const gap = document.createElement("span");
        gap.className = "gap";
        this.root.append(gap);
        continue;
      }
      const element = document.createElement("button");
      element.type = "button";
      element.dataset.command = button.command;
      element.title = button.shortcut ? `${button.title} (${button.shortcut})` : button.title;
      element.setAttribute("aria-label", button.title);
      element.append(createElement(button.icon, { width: 16, height: 16, "stroke-width": 2 }));
      element.addEventListener("mousedown", (event) => {
        if (event.button !== 0) return;
        // 초점을 편집기에 둔다 — 선택이 남는다.
        event.preventDefault();
        if (button.command === "heading") this.toggleHeadings(element);
        else this.press(button.command);
      });
      this.root.append(element);
    }
    for (const [command, title] of headingChoices) {
      const item = document.createElement("button");
      item.type = "button";
      item.dataset.command = command;
      item.textContent = title;
      item.className = `level-${command.slice(-1)}`;
      item.addEventListener("mousedown", (event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        this.menu.hidden = true;
        this.press(command);
      });
      this.menu.append(item);
    }
  }

  /** 편집기에 붙인다 — 고르는 동안 숨기기, 굴리면 따라가기. */
  attach(view: EditorView): void {
    this.view = view;
    // 누름은 포인터 이벤트로 — 놓는 것(pointerup)이 창 밖에서 일어나도, 창이 초점을 잃어도 풀린다. 마우스 이벤트로 셌더니 누름만 있고
    // 뗌이 없는 경우(만든 mousedown — 할 일 상자를 누른 확인 실행)에 막대가 다시는 뜨지 않았다.
    view.contentDOM.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      this.pointerDown = true;
      this.hide();
    });
    const release = () => {
      if (!this.pointerDown) return;
      this.pointerDown = false;
      this.schedule();
    };
    window.addEventListener("pointerup", release);
    window.addEventListener("pointercancel", release);
    window.addEventListener("blur", release);
    view.scrollDOM.addEventListener("scroll", () => this.schedule(), { passive: true });
    window.addEventListener("resize", () => this.schedule());
  }

  /** 내보내는 동안 · 고르는 칸이 열린 동안은 띄우지 않는다. */
  set hidden(hidden: boolean) {
    this.suppressed = hidden;
    this.schedule();
  }

  get report(): { shown: boolean; buttons: string[] } {
    return { shown: !this.root.hidden, buttons: [...this.root.querySelectorAll<HTMLElement>("button")].map((button) => button.dataset.command!) };
  }

  /** 확인 실행 — 사람이 누른 것처럼. */
  press(command: string): void {
    this.run(command);
    this.schedule();
  }

  schedule(): void {
    cancelAnimationFrame(this.frame);
    this.frame = requestAnimationFrame(() => this.place());
  }

  private hide(): void {
    this.root.hidden = true;
    this.menu.hidden = true;
  }

  private toggleHeadings(anchor: HTMLElement): void {
    if (!this.menu.hidden) {
      this.menu.hidden = true;
      return;
    }
    const app = document.getElementById("app")!.getBoundingClientRect();
    const box = anchor.getBoundingClientRect();
    this.menu.style.left = `${box.left - app.left}px`;
    this.menu.style.top = `${box.bottom - app.top + 4}px`;
    this.menu.hidden = false;
  }

  private place(): void {
    const view = this.view;
    if (!view) return;
    const range = view.state.selection.main;
    if (range.empty || this.pointerDown || this.suppressed || view.composing || view.state.readOnly) return this.hide();
    const start = view.coordsAtPos(range.from, 1);
    const end = view.coordsAtPos(range.to, -1);
    const scroller = view.scrollDOM.getBoundingClientRect();
    if (!start || !end || end.bottom < scroller.top || start.top > scroller.bottom) return this.hide();
    const app = document.getElementById("app")!.getBoundingClientRect();
    this.root.hidden = false;
    const width = this.root.offsetWidth;
    const height = this.root.offsetHeight;
    const gap = 8;
    // 고른 글의 첫 줄 위에. 위에 자리가 없으면 끝 줄 아래에(macOS판과 같다).
    let top = start.top - height - gap;
    if (top < scroller.top + 4) top = end.bottom + gap;
    const sameLine = Math.abs(start.top - end.top) < 2;
    const middle = sameLine ? (start.left + end.right) / 2 : start.left + width / 2;
    const left = Math.min(Math.max(middle - width / 2, scroller.left + 8), scroller.right - width - 16);
    this.root.style.left = `${Math.round(left - app.left)}px`;
    this.root.style.top = `${Math.round(top - app.top)}px`;
    if (!this.menu.hidden) {
      const anchor = this.root.querySelector<HTMLElement>('[data-command="heading"]')!.getBoundingClientRect();
      this.menu.style.left = `${anchor.left - app.left}px`;
      this.menu.style.top = `${anchor.bottom - app.top + 4}px`;
    }
  }
}
