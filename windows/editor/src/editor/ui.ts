// 편집기 둘레의 것 — 바깥 변경 띠, `새 줄 N개 ↓`, 목차 칸, 아래 상태 줄. index.html에 자리가 있다.

import type { Heading } from "../core/outline.ts";

function element<T extends HTMLElement>(id: string): T {
  const found = document.getElementById(id);
  if (!found) throw new Error(`#${id}이 index.html에 없다`);
  return found as T;
}

/** 여기서 고친 것을 저장하지 않았는데 파일이 바깥에서 바뀌었다 — 섞지 않고 묻는다(macOS판과 같다). */
export class ConflictBand {
  private readonly root = element<HTMLDivElement>("band");
  constructor(onReload: () => void, onKeepMine: () => void) {
    element<HTMLButtonElement>("band-reload").addEventListener("click", onReload);
    element<HTMLButtonElement>("band-keep").addEventListener("click", onKeepMine);
  }
  set shown(shown: boolean) {
    this.root.hidden = !shown;
  }
  get shown(): boolean {
    return !this.root.hidden;
  }
}

/** 위를 읽는 동안 끝에 붙은 줄 — 누르면 끝으로. */
export class NewLinesPill {
  private readonly button = element<HTMLButtonElement>("newlines");
  private count = 0;
  constructor(onClick: () => void) {
    this.button.addEventListener("click", onClick);
  }
  add(lines: number): void {
    this.count += lines;
    this.button.textContent = `새 줄 ${this.count}개 ↓`;
    this.button.hidden = false;
  }
  hide(): void {
    this.count = 0;
    this.button.hidden = true;
  }
  get unseen(): number {
    return this.count;
  }
}

export class OutlinePanel {
  private readonly root = element<HTMLElement>("outline");
  private readonly list = this.root.querySelector("ol")!;
  private readonly empty = this.root.querySelector<HTMLElement>(".empty")!;
  private readonly onPick: (heading: Heading) => void;
  constructor(onPick: (heading: Heading) => void) {
    this.onPick = onPick;
  }
  set shown(shown: boolean) {
    this.root.hidden = !shown;
  }
  get shown(): boolean {
    return !this.root.hidden;
  }
  render(headings: Heading[]): void {
    this.list.replaceChildren(...headings.map((heading) => {
      const item = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = heading.title || "(빈 제목)";
      button.style.paddingInlineStart = `${8 + (heading.level - 1) * 12}px`;
      button.addEventListener("click", () => this.onPick(heading));
      item.append(button);
      return item;
    }));
    this.empty.hidden = headings.length > 0;
  }
}

export class StatusBar {
  private readonly message = element<HTMLSpanElement>("status-message");
  private readonly info = element<HTMLSpanElement>("status-info");
  private timer: number | undefined;
  say(text: string, isError = false): void {
    this.message.textContent = text;
    this.message.classList.toggle("error", isError);
    window.clearTimeout(this.timer);
    if (!isError) this.timer = window.setTimeout(() => { this.message.textContent = ""; }, 3000);
  }
  describe(parts: string[]): void {
    this.info.textContent = parts.filter(Boolean).join(" · ");
  }
}
