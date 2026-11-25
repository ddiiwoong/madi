// 편집기 둘레의 것 — 바깥 변경 띠, `새 줄 N개 ↓`, 목차 칸, 잠깐 뜨는 알림. index.html에 자리가 있다.

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

/**
 * 잠깐 뜨는 알림 — 저장했다 · 설정이 바뀌었다 · 바깥에서 바뀌었다. 아래 가운데에 떴다가 사라진다(오류는 누를 때까지 남는다). 전의 아래
 * 상태 줄을 대신한다 — 늘 보이던 인코딩 · 줄 끝은 제목 막대(바뀌는 꼴일 때만)와 `문서 정보`로 옮겼다.
 */
export class Toast {
  private readonly root = element<HTMLDivElement>("toast");
  private timer: number | undefined;
  private last = "";

  constructor() {
    this.root.addEventListener("click", () => this.hide());
  }

  say(text: string, isError = false): void {
    this.last = text;
    this.root.textContent = text;
    this.root.classList.toggle("error", isError);
    this.root.hidden = false;
    // 다시 띄우면 처음부터 — 나타나는 움직임을 다시 건다.
    this.root.classList.remove("show");
    void this.root.offsetWidth;
    this.root.classList.add("show");
    window.clearTimeout(this.timer);
    if (!isError) this.timer = window.setTimeout(() => this.hide(), 2600);
  }

  hide(): void {
    this.root.classList.remove("show");
    this.root.hidden = true;
  }

  /** 확인 실행이 본다 — 마지막으로 띄운 글. */
  get message(): string {
    return this.last;
  }
}
