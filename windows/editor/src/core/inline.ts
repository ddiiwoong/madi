// 짧은 마크다운(표 칸 · 앞머리 값)을 HTML로 — 굵게 · 기울임 · 취소선 · 코드 · 링크만. 글은 모두 이스케이프하고, 문서의 HTML은
// 그대로 내지 않는다(문서는 남이 쓴 것일 수 있다). 링크는 `data-url`에만 두고 누르면 껍데기가 웹 주소만 연다.

export function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!);
}

export function inlineHtml(source: string): string {
  // 코드 조각을 먼저 떼어 두어 그 안의 `*`가 꾸밈으로 읽히지 않게 한다.
  const codes: string[] = [];
  let text = source.replace(/`([^`]+)`/g, (_, code: string) => {
    codes.push(code);
    return `\u0000${codes.length - 1}\u0000`;
  });
  text = escapeHtml(text);
  text = text
    .replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)/g, (_, label: string, url: string) =>
      `<a class="cm-md-link" data-url="${url}">${label}</a>`)
    .replace(/\*\*(.+?)\*\*|__(.+?)__/g, (_, a?: string, b?: string) => `<strong>${a ?? b}</strong>`)
    .replace(/(^|[^*\w])\*(?!\s)(.+?)\*(?!\w)/g, (_, before: string, inner: string) => `${before}<em>${inner}</em>`)
    .replace(/~~(.+?)~~/g, (_, inner: string) => `<del>${inner}</del>`)
    .replace(/\\([\\`*_{}[\]()#+\-.!|~])/g, "$1");
  return text.replace(/\u0000(\d+)\u0000/g, (_, index: string) => `<code>${escapeHtml(codes[Number(index)]!)}</code>`);
}
