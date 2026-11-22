// 다이어그램(Mermaid) · 수식(KaTeX) 그리기 — macOS판(`Resources/Diagrams/render.js`)과 같은 파일 · 같은 설정이다.
// 두 꾸러미는 크다(Mermaid 5.5MB) — 그런 블록이 처음 보일 때 `diagrams/`에서 싣는다. 같은 원문은 한 번만 그린다.
//
// - Mermaid: `securityLevel: "strict"`(라벨의 HTML · 스크립트 · click 동작을 걷어 낸다), 다크면 `dark` 테마, 간트 폭 800.
// - KaTeX: `trust: false`(`\href` · `\includegraphics`처럼 바깥을 부르는 명령을 받지 않는다), 틀리면 오류를 던진다.
// 두 출력 모두 문서의 글을 걸러 낸 것이고, 이 페이지의 CSP는 인라인 스크립트를 막는다(이중으로).

export type DiagramKind = "mermaid" | "math";
export type DiagramResult = { ok: true; html: string } | { ok: false; message: string };

interface MermaidApi {
  initialize(config: Record<string, unknown>): void;
  render(id: string, source: string): Promise<{ svg: string }>;
}
interface KatexApi {
  renderToString(source: string, options: Record<string, unknown>): string;
}
declare global {
  interface Window {
    mermaid?: MermaidApi;
    katex?: KatexApi;
  }
}

const loading = new Map<string, Promise<void>>();

function loadScript(src: string): Promise<void> {
  let pending = loading.get(src);
  if (!pending) {
    pending = new Promise<void>((resolve, reject) => {
      const script = document.createElement("script");
      script.src = src;
      script.onload = () => resolve();
      script.onerror = () => reject(new Error(`${src}을(를) 싣지 못했습니다`));
      document.head.append(script);
    });
    loading.set(src, pending);
    pending.catch(() => loading.delete(src));
  }
  return pending;
}

function loadStyle(href: string): void {
  if (document.querySelector(`link[href="${href}"]`)) return;
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = href;
  document.head.append(link);
}

const cache = new Map<string, DiagramResult>();
let queue: Promise<unknown> = Promise.resolve();
let counter = 0;

export function cachedDiagram(kind: DiagramKind, source: string, dark: boolean): DiagramResult | undefined {
  return cache.get(key(kind, source, dark));
}

function key(kind: DiagramKind, source: string, dark: boolean): string {
  // 수식은 다크와 상관없다(글자색을 물려받는다).
  return kind === "math" ? `math\u0000${source}` : `mermaid\u0000${dark ? 1 : 0}\u0000${source}`;
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function draw(kind: DiagramKind, source: string, dark: boolean): Promise<DiagramResult> {
  try {
    if (kind === "math") {
      loadStyle("diagrams/katex.min.css");
      await loadScript("diagrams/katex.min.js");
      const html = window.katex!.renderToString(source, { displayMode: true, throwOnError: true, output: "html", trust: false });
      return { ok: true, html };
    }
    await loadScript("diagrams/mermaid.min.js");
    const mermaid = window.mermaid!;
    const fontFamily = getComputedStyle(document.documentElement).getPropertyValue("--md-font-body").trim();
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: dark ? "dark" : "default",
      fontFamily,
      themeVariables: { fontFamily },
      gantt: { useWidth: 800 },
    });
    counter += 1;
    const { svg } = await mermaid.render(`madi-diagram-${counter}`, source);
    return { ok: true, html: svg };
  } catch (error) {
    // Mermaid는 틀린 원문의 오류 그림을 body에 남긴다 — 걷는다.
    document.getElementById(`dmadi-diagram-${counter}`)?.remove();
    return { ok: false, message: message(error) };
  }
}

/** 그린 HTML(또는 오류). Mermaid의 `initialize`는 전역이라 한 번에 하나씩 그린다. */
export function renderDiagram(kind: DiagramKind, source: string, dark: boolean): Promise<DiagramResult> {
  const id = key(kind, source, dark);
  const hit = cache.get(id);
  if (hit) return Promise.resolve(hit);
  const next = queue.then(async () => {
    const again = cache.get(id);
    if (again) return again;
    const result = await draw(kind, source, dark);
    cache.set(id, result);
    // 고칠 때마다 새 원문이 쌓인다 — 오래된 것부터 버린다.
    if (cache.size > 200) cache.delete(cache.keys().next().value!);
    return result;
  });
  queue = next.catch(() => undefined);
  return next;
}
