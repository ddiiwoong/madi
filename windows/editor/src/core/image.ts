// 그림 경로 — macOS판 `ImageReference`와 같은 규칙. 편집기는 경로를 고르기만 하고, 파일을 읽는 일은 껍데기가 한다
// (문서 폴더를 기준으로 풀고, 그림 확장자만, 크기 한도 안에서).
//
// 원격 주소는 **https만**, 그것도 설정(`loadsRemoteImages`)을 켰을 때만 받는다. 문서를 연 것만으로 바깥에 요청이 나가면 안 된다 —
// 문서에 적힌 주소가 추적용일 수 있다. `http:`는 켜도 받지 않는다(중간의 누구나 어떤 문서를 열었는지 본다).

export type ImageSource =
  | { kind: "remote"; url: string }
  /** 껍데기가 풀 경로 — 상대(문서 폴더 기준) · 절대(`C:\…`, `\\서버\…`) · `file:` 주소. 퍼센트 인코딩은 풀었다. */
  | { kind: "local"; path: string };

const remoteSchemes = ["http:", "https:", "ftp:", "data:", "about:", "javascript:", "blob:"];

function unwrap(raw: string): string {
  const path = raw.trim();
  return path.startsWith("<") && path.endsWith(">") && path.length > 2 ? path.slice(1, -1) : path;
}

export function isRemote(raw: string): boolean {
  const value = raw.trim().toLowerCase();
  return value.startsWith("//") || remoteSchemes.some((scheme) => value.startsWith(scheme));
}

export function imageSource(raw: string): ImageSource | null {
  let path = unwrap(raw);
  if (path === "") return null;
  if (path.toLowerCase().startsWith("https://")) {
    try {
      const url = new URL(path);
      return url.hostname ? { kind: "remote", url: url.href } : null;
    } catch {
      return null;
    }
  }
  if (isRemote(path)) return null;
  if (path.toLowerCase().startsWith("file:")) return { kind: "local", path };
  // 조각(`#`) · 질의(`?`)는 파일 경로에 뜻이 없다.
  path = path.replace(/[#?].*$/, "");
  if (path === "") return null;
  let decoded = path;
  try {
    decoded = decodeURIComponent(path) || path;
  } catch {
    // `%`가 홀로 있다 — 적힌 그대로.
  }
  return { kind: "local", path: decoded };
}
