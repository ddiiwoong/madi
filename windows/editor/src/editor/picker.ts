// 고르는 칸 — 빠른 열기(Ctrl+P), 명령 팔레트(Ctrl+Shift+P), 글꼴 고르기가 함께 쓴다. 쓰는 대로 거른다(`core/fuzzy.ts`,
// macOS판 `FuzzyMatch`와 같은 점수). ↑↓로 옮기고 Enter로 고르고 Esc로 닫는다.

import { fuzzyRank } from "../core/fuzzy.ts";

export interface PickItem {
  title: string;
  /** 흐린 둘째 글 — 파일의 폴더, 명령의 메뉴 자리. 이름에 맞는 것이 먼저고 여기에만 맞는 것은 뒤다. */
  detail?: string;
  /** 오른쪽 끝 — 단축키, 지금 고른 것(✓). */
  hint?: string;
  run: () => void;
}

/** 한 번에 그리는 줄 — 2000개를 다 그리면 칠 때마다 느리다. */
const shownLimit = 200;

export class Picker {
  private readonly root: HTMLElement;
  private readonly input: HTMLInputElement;
  private readonly list: HTMLOListElement;
  private readonly empty: HTMLElement;
  private items: PickItem[] = [];
  private shown: PickItem[] = [];
  private selected = 0;
  private onClose: () => void = () => {};
  private generation = 0;

  constructor() {
    this.root = document.getElementById("picker")!;
    this.input = this.root.querySelector("input")!;
    this.list = this.root.querySelector("ol")!;
    this.empty = this.root.querySelector(".empty")!;
    this.input.addEventListener("input", () => this.filter());
    this.input.addEventListener("keydown", (event) => this.key(event));
    this.input.addEventListener("blur", () => {
      // 목록을 누르는 중이면 그 클릭이 먼저 — 바깥을 눌렀을 때만 닫는다.
      requestAnimationFrame(() => {
        if (this.isOpen && !this.root.contains(document.activeElement)) this.close();
      });
    });
  }

  get isOpen(): boolean {
    return !this.root.hidden;
  }

  /** 확인 실행이 본다. */
  get report(): { open: boolean; placeholder: string; query: string; items: number; shown: string[] } {
    return {
      open: this.isOpen,
      placeholder: this.input.placeholder,
      query: this.input.value,
      items: this.items.length,
      shown: this.shown.slice(0, 10).map((item) => item.title),
    };
  }

  open(placeholder: string, items: PickItem[] | Promise<PickItem[]>, onClose: () => void): void {
    const generation = ++this.generation;
    this.onClose = onClose;
    this.input.placeholder = placeholder;
    this.input.value = "";
    this.root.hidden = false;
    this.input.focus();
    if (Array.isArray(items)) this.setItems(items);
    else {
      this.setItems([]);
      this.empty.textContent = "불러오는 중…";
      void items.then((loaded) => {
        if (generation === this.generation && this.isOpen) this.setItems(loaded);
      });
    }
  }

  /** 확인 실행 — 사람이 친 것처럼. */
  type(query: string): void {
    this.input.value = query;
    this.filter();
  }

  close(): void {
    if (!this.isOpen) return;
    this.root.hidden = true;
    this.generation++;
    this.items = [];
    this.shown = [];
    this.list.replaceChildren();
    this.onClose();
  }

  private setItems(items: PickItem[]): void {
    this.items = items;
    this.empty.textContent = "맞는 것이 없습니다";
    this.filter();
  }

  private filter(): void {
    this.shown = fuzzyRank(this.items, this.input.value, (item) => item).slice(0, shownLimit);
    this.selected = 0;
    this.render();
  }

  private render(): void {
    this.list.replaceChildren(...this.shown.map((item, index) => {
      const row = document.createElement("li");
      row.className = index === this.selected ? "selected" : "";
      row.setAttribute("role", "option");
      row.setAttribute("aria-selected", String(index === this.selected));
      const title = document.createElement("span");
      title.className = "title";
      title.textContent = item.title;
      row.append(title);
      if (item.detail) {
        const detail = document.createElement("span");
        detail.className = "detail";
        detail.textContent = item.detail;
        row.append(detail);
      }
      if (item.hint) {
        const hint = document.createElement("span");
        hint.className = "hint";
        hint.textContent = item.hint;
        row.append(hint);
      }
      row.addEventListener("mousedown", (event) => event.preventDefault());
      row.addEventListener("click", () => this.choose(index));
      return row;
    }));
    this.empty.hidden = this.shown.length > 0;
    this.list.children[this.selected]?.scrollIntoView({ block: "nearest" });
  }

  private choose(index: number): void {
    const item = this.shown[index];
    this.close();
    item?.run();
  }

  private key(event: KeyboardEvent): void {
    const move = (by: number) => {
      if (this.shown.length === 0) return;
      const last = this.shown.length - 1;
      // 한 칸씩은 끝에서 처음으로 돈다. 쪽 단위는 끝에서 멈춘다.
      this.selected = Math.abs(by) === 1
        ? (this.selected + by + this.shown.length) % this.shown.length
        : Math.min(last, Math.max(0, this.selected + by));
      this.render();
    };
    switch (event.key) {
      case "ArrowDown":
        move(1);
        break;
      case "ArrowUp":
        move(-1);
        break;
      case "PageDown":
        move(10);
        break;
      case "PageUp":
        move(-10);
        break;
      case "Enter":
        this.choose(this.selected);
        break;
      case "Escape":
        this.close();
        break;
      default:
        return;
    }
    event.preventDefault();
    event.stopPropagation();
  }
}
