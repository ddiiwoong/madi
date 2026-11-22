# 마디 Windows판

macOS판과 같은 기능을 Windows에서 내는 두 번째 앱입니다(사용자 — "윈도우 버전 만들어줘 기능 동일하고", 고른 구조: C안,
번역은 일단 뺌). **아직 0단계입니다** — 창이 뜨고 편집기가 문서를 바이트 그대로 싣는 데까지입니다.

## 구조 — 왜 이렇게 했나

| 자리 | 하는 일 | 쓰는 것 |
|---|---|---|
| `editor/` | 편집기와 문서 로직(인코딩 · 줄 끝 · 앞으로 라이브 프리뷰 · 찾기 · 목차 …) | TypeScript, [CodeMirror 6](https://codemirror.net/), esbuild |
| `Madi.Windows/` | 창 · 파일 · (다음 단계의) 메뉴 · 대화상자 · 파일 감시 | C# · WPF(.NET 10), [WebView2](https://learn.microsoft.com/microsoft-edge/webview2/) |

- macOS판의 라이브 프리뷰는 `NSLayoutManager`가 마크다운 표식의 글리프를 지우는 데 기대고, Windows에는 그 대응물이 없다.
  CodeMirror 6의 장식(decoration)으로 표식을 숨기는 것은 이미 검증된 길이다(Obsidian의 라이브 프리뷰가 이 방식이다).
- 한글 조합(IME)은 Edge(WebView2)가 맡는다. 다이어그램 · 수식(Mermaid · KaTeX)은 macOS판도 웹 엔진으로 그리므로 같은 화면에서 된다.
- 껍데기는 얇게 둔다 — 로직은 `editor/`에 두어 이 Mac에서도 Node로 시험한다(`npm test`). C#은 Windows에서만 빌드된다.
- 대가: macOS판의 Swift Core를 TypeScript로 한 벌 더 갖는다. 기능을 더하면 두 번 만든다.

### 껍데기 ↔ 편집기

웹 메시지만 주고받는다(호스트 객체를 열지 않는다). 편집기는 exe 옆의 `editor\` 폴더를 `https://app.madi/`로 열고, 그 밖의 주소로는
가지 않는다. 브라우저 단축키(F5 새로 고침 · Ctrl+F · Ctrl+P)는 껐다 — 새로 고침은 고친 글을 버린다.

| 보내는 쪽 | 메시지 | |
|---|---|---|
| 편집기 → 껍데기 | `ready` | 떴다. 앱에 든 글꼴이 실렸는지(`fonts`) |
| 껍데기 → 편집기 | `open` | 파일의 **바이트**(base64). 글로 읽는 일은 편집기가 한다 |
| 편집기 → 껍데기 | `opened` · `error` | 읽은 꼴(인코딩 · BOM · 줄 끝)과, 다시 쓰면 파일과 같은지(SHA-256) |

### 바이트 그대로

- 줄 끝: CodeMirror는 기본으로 CRLF를 LF로 바꿔 잇는다. 파일마다 줄 끝을 골라(`EditorState.lineSeparator`) CRLF 파일이 열기만 해도
  바뀌지 않게 한다. 섞인 파일은 LF로 나눠 `\r`이 글자로 남는다 — 그래도 다시 이으면 같다(`src/core/lines.ts`).
- 인코딩: UTF-8(BOM은 떼어 기억), BOM이 있는 UTF-16, 아니면 **EUC-KR(CP949)**, 아니면 windows-1252. macOS판은 UTF-8 → UTF-16 → Latin-1이다.
  한국어 Windows의 옛 파일은 CP949라 Latin-1로 읽으면 한글이 깨진다 — 일부러 다르게 했다(`src/core/text.ts`).

## 빌드 · 실행(Windows)

```powershell
cd windows\editor
npm ci
npm test
npm run build            # dist\ — 껍데기가 이것을 exe 옆 editor\로 옮긴다
cd ..
dotnet run --project Madi.Windows -- 문서.md
```

필요한 것: Node 24 이상, .NET 10 SDK, WebView2 런타임(Windows 11에는 들어 있다). 편집기만 볼 때는 이 Mac에서도 `npm run build` 뒤
`dist/`를 `python3 -m http.server --bind 127.0.0.1 --directory dist`로 열면 된다(호스트가 없으면 환영 글만 보인다).

## CI — `.github/workflows/windows.yml`

`windows/**` 가지에 올리거나 `windows/`를 고친 PR에서 `windows-latest`가 편집기 시험 · 형 검사 · 묶기, 껍데기 빌드(x64, .NET 포함),
확인 실행(`Madi.exe --smoke <폴더>`)을 돈다. 확인 실행은 시험 문서 다섯(CP949 · UTF-16LE BOM · 섞인 줄 끝 · UTF-8 BOM CRLF · UTF-8 LF)을
열어 견주고 `editor.png` · `screen.png` · `result.json`을 남긴다. 받을 것: `Madi-windows-x64`(풀어서 `Madi.exe`), `smoke`.

서명하지 않은 exe라 처음 열면 SmartScreen이 막는다 — `추가 정보` ▸ `실행`. 받은 zip은 속성에서 `차단 해제`를 먼저 누르면 편하다.

## 단계

| 단계 | 내용 | 상태 |
|---|---|---|
| 0 | 창 · WebView2 · CodeMirror, 파일을 바이트 그대로 싣기, CI에서 띄워 확인 | 이번 |
| 1 | 열기 · 편집 · 저장, 기본 라이브 프리뷰, 찾기, 목차, 바깥 변경 다시 읽기 · 따라 보기, `.txt` · `.log` | |
| 2 | 표, 체크박스, 다이어그램 · 수식, 그림, 메타데이터 카드, 테마 · 글꼴, 빠른 열기 · 명령 팔레트 | |
| 3 | AI 교정, PDF · 프린트, `madi://`, 파일 연결, 자동 업데이트, 설치 파일(MSIX · winget) · 서명 | |
| 뒤 | 번역(Edge의 기기 안 Translator API를 WebView2에서 쓸 수 있는지부터) | |
