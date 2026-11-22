# 마디 Windows판

macOS판과 같은 기능을 Windows에서 내는 두 번째 앱입니다(사용자 — "윈도우 버전 만들어줘 기능 동일하고", 고른 구조: C안,
번역은 일단 뺌). **지금 1단계까지입니다** — 열고 고치고 저장하고, 라이브 프리뷰 · 찾기 · 목차, 바깥에서 바뀐 파일 다시 읽기 ·
따라 보기, `.txt` · `.log`.

## 구조 — 왜 이렇게 했나

| 자리 | 하는 일 | 쓰는 것 |
|---|---|---|
| `editor/` | 편집기와 문서 로직 — 인코딩 · 줄 끝, 라이브 프리뷰, 찾기, 목차, 고친 상태 · 자동 저장, 바깥 변경 들이기 | TypeScript, [CodeMirror 6](https://codemirror.net/), esbuild |
| `Madi.Windows/` | 창 · 메뉴 · 열기 · 저장 창, 파일 읽고 쓰기, 파일 지켜보기, 닫을 때 묻기 | C# · WPF(.NET 10), [WebView2](https://learn.microsoft.com/microsoft-edge/webview2/) |
| `Madi.Windows.Tests/` | 껍데기의 파일 로직 시험(xunit v3, Windows에서만) | |

- macOS판의 라이브 프리뷰는 `NSLayoutManager`가 마크다운 표식의 글리프를 지우는 데 기대고, Windows에는 그 대응물이 없다.
  CodeMirror 6의 장식(decoration)으로 표식을 숨기는 것은 이미 검증된 길이다(Obsidian의 라이브 프리뷰가 이 방식이다).
- 한글 조합(IME)은 Edge(WebView2)가 맡는다. 다이어그램 · 수식(Mermaid · KaTeX)은 macOS판도 웹 엔진으로 그리므로 같은 화면에서 된다.
- 껍데기는 얇게 둔다 — 로직은 `editor/src/core/`에 두어 이 Mac에서도 Node로 시험한다(`npm test`). C#은 Windows에서만 빌드된다.
- 대가: macOS판의 Swift Core를 TypeScript로 한 벌 더 갖는다. 기능을 더하면 두 번 만든다.

### 껍데기 ↔ 편집기

웹 메시지만 주고받는다(호스트 객체를 열지 않는다). 편집기는 exe 옆의 `editor\` 폴더를 `https://app.madi/`로 열고, 그 밖의 주소로는
가지 않는다. 브라우저 단축키(F5 새로 고침 · Ctrl+P …)는 껐다 — 새로 고침은 고친 글을 버린다. 바이트는 base64로 오간다.

| 보내는 쪽 | 메시지 | |
|---|---|---|
| 껍데기 → 편집기 | `open` | 파일의 **바이트**. 글로 읽는 일(인코딩 · BOM · 줄 끝)은 편집기가 한다 |
| 껍데기 → 편집기 | `appended` · `replaced` | 지켜보는 파일의 끝에 붙은 바이트 · 다르게 바뀐 파일 전체 |
| 껍데기 → 편집기 | `saved` · `saveFailed` · `saveCancelled` · `run` | 저장의 결과, 메뉴에서 고른 명령 |
| 편집기 → 껍데기 | `ready` · `opened` · `state` | 떴다 · 읽은 꼴 · 문서 상태(이름 · 고침 · 부딪침 · 보기) — 제목 줄과 메뉴 체크가 따른다 |
| 편집기 → 껍데기 | `save` · `saveAs` · `reload` · `command` · `openUrl` · `drop` | 쓸 바이트, 다시 읽기, 새 창 · 열기 · 닫기, 링크, 끌어다 놓은 파일 |

## 쓰는 법

| 단축키 | 하는 일 |
|---|---|
| `Ctrl+N` · `Ctrl+O` | 새로 만들기(새 창) · 열기(여러 개 고를 수 있다) |
| `Ctrl+S` · `Ctrl+Shift+S` | 저장 · 다른 이름으로 저장 |
| `Ctrl+W` | 닫기 |
| `Ctrl+F` · `F3` · `Shift+F3` | 찾기 · 다음 · 이전(찾기 칸에서 `Enter` · `Shift+Enter`) |
| `Ctrl+E` | 원본 보기 |
| `Ctrl+Alt+L` | 따라 보기 |
| `Ctrl+Shift+O` | 목차 |
| `Ctrl+클릭` | 링크를 기본 브라우저로(`http` · `https` · `mailto`만) |

- **열기**: 파일을 창에 끌어다 놓거나 exe 아이콘에 놓아도 연다. 이미 연 파일이면 그 창이 앞으로 온다. 빈 창(저장한 적 없고 고친 것도
  없음)에는 그 자리에, 아니면 새 창에.
- **저장**: 이름 있는 문서는 고친 뒤 1.5초 쉬면 저장하고, 닫을 때도 묻지 않고 저장한다 — macOS판의 자동 저장과 같다. 저장한 적 없는
  문서는 닫을 때 묻는다. 같은 폴더의 임시 파일에 다 쓴 뒤 바꿔 넣는다(쓰다 멈춰도 반쯤 쓴 파일이 남지 않는다). 연 꼴을 지킨다 —
  UTF-8 · BOM · UTF-16 · CRLF 그대로. EUC-KR · windows-1252는 UTF-8로 쓴다(macOS판과 같다). 새 문서는 UTF-8 · LF.
- **라이브 프리뷰**: 캐럿이 없는 줄은 표식(`#` · `**` · `*` · `~~` · `` ` `` · `[…](주소)` · `> `)을 숨기고 꾸민다. 글머리 `-`는
  ● ○ ■(깊이마다), `---`는 선. 캐럿이 있는 줄은 원문 그대로 — macOS판과 같은 약속이다. 제목 크기는 macOS판의 배율.
- **원본 보기**: 쓴 그대로, 고정폭(IBM Plex Mono). `.txt` · `.log`는 이것으로 연다 — 창 폭을 다 쓰고, 마크다운 문법을 칠하지 않고, 목차가
  없다. 끄면 마크다운으로 그린다.
- **따라 보기**: 고칠 수 없게 하고 끝을 따라간다. `.log`는 이것으로 연다. 위를 읽는 동안 줄이 붙으면 그 자리에 두고 `새 줄 N개 ↓`.
  창 크기가 바뀌어도 끝에 남는다.
- **바깥에서 바뀐 파일**: 고친 것이 없으면 묻지 않고 들인다 — 끝에 붙은 것은 붙은 바이트만(덜 쓴 한 글자는 다음 조각과 합쳐),
  다르게 바뀌면 다른 가운데만 갈아 끼운다(캐럿 · 읽던 자리가 남는다). 고친 것이 있으면 섞지 않고 위에 띠를 띄운다 —
  `다시 읽기`(여기 것을 버림) · `내 것 지키기`(여기 것을 씀). 고를 때까지 자동 저장을 멈춘다. 그때 닫으면 묻는다.
- **상태 줄**(아래): 저장 결과, 보기 · 인코딩 · 줄 끝. 제목 줄의 `*`는 저장하지 않은 고침이다.

### macOS판과 다른 것

| | macOS판 | Windows판 | 까닭 |
|---|---|---|---|
| UTF-8이 아닌 파일 | UTF-16 → Latin-1 | BOM 있는 UTF-16 → EUC-KR → windows-1252 | 한국어 Windows의 옛 파일은 CP949 |
| UTF-16 파일 저장 | UTF-8로 | UTF-16 그대로 | Windows의 메모장 · 프로그램이 UTF-16을 쓴다 — 바이트를 지킨다 |
| 찾기 | 도구 막대의 칸, 대소문자 · 분음부호 무시 | CodeMirror의 찾기 칸 — 대소문자 · 정규식 · 낱말 단위를 고르고, 바꾸기도 된다 | 분음부호 무시는 없다(다음 단계 후보) |
| 창 부제 | `원본 보기` · `따라 보기` | 아래 상태 줄 | Windows의 창에는 부제가 없다 |

## 빌드 · 실행(Windows)

```powershell
cd windows\editor
npm ci
npm test
npm run build            # dist\ — 껍데기가 이것을 exe 옆 editor\로 옮긴다
cd ..
dotnet run --project Madi.Windows.Tests -c Release    # 껍데기 시험
dotnet run --project Madi.Windows -- 문서.md
```

필요한 것: Node 24 이상, .NET 10 SDK, WebView2 런타임(Windows 11에는 들어 있다). 편집기만 볼 때는 이 Mac에서도 `npm run build` 뒤
`dist/`를 `python3 -m http.server --bind 127.0.0.1 --directory dist`로 열면 된다(호스트가 없으면 빈 문서).

## CI — `.github/workflows/windows.yml`

`windows/**` 가지에 올리거나 `windows/`를 고친 PR에서 `windows-latest`가 편집기 시험 · 형 검사 · 묶기, 껍데기 시험 · 빌드(x64, .NET 포함),
확인 실행(`Madi.exe --smoke <폴더>`)을 돈다. 확인 실행은 창 하나로 실제 길(파일 읽기 · 지켜보기 · 저장)을 지나며 본다:

1. 시험 문서 다섯(CP949 · UTF-16LE BOM · 섞인 줄 끝 · UTF-8 BOM CRLF · UTF-8 LF)을 열어 편집기를 지나도 바이트가 그대로인지(SHA-256)
2. 고쳐서 저장하면 BOM · CRLF가 남는지, 내가 쓴 것을 바깥 변경으로 읽지 않는지
3. 로그가 따라 보기로 열리고 붙는 줄을 따라가는지, 한 글자를 둘로 나눠 써도 한 번만 들어오는지
4. 고친 것이 있는데 바깥에서 바뀌면 띠로 묻고 자동 저장을 멈추는지, `내 것 지키기`가 여기 것을 쓰는지
5. 라이브 프리뷰 · 목차를 켠 화면(`editor.png`), 앱에 든 글꼴이 편집기 글에 **실제로 쓰이는지**(계산된 CSS — 0단계의 처음 빌드는
   `style.css`의 규칙이 CodeMirror 기본 테마에 밀려 쓰이지 않았다. 그래서 편집기의 글꼴 · 꾸밈은 `src/editor/setup.ts`의 테마에 둔다)

`editor.png` · `screen.png` · `result.json`을 남긴다. 받을 것: `Madi-windows-x64`(풀어서 `Madi.exe`), `smoke`.

서명하지 않은 exe라 처음 열면 SmartScreen이 막는다 — `추가 정보` ▸ `실행`. 받은 zip은 속성에서 `차단 해제`를 먼저 누르면 편하다.

## 단계

| 단계 | 내용 | 상태 |
|---|---|---|
| 0 | 창 · WebView2 · CodeMirror, 파일을 바이트 그대로 싣기, CI에서 띄워 확인 | 끝 |
| 1 | 열기 · 편집 · 저장, 기본 라이브 프리뷰, 찾기, 목차, 바깥 변경 다시 읽기 · 따라 보기, `.txt` · `.log` | 끝 |
| 2 | 표, 체크박스, 다이어그램 · 수식, 그림, 메타데이터 카드, 테마(어두운 테마) · 글꼴 · 글자 크기, 빠른 열기 · 명령 팔레트 | |
| 3 | AI 교정, PDF · 프린트, `madi://`, 파일 연결 · 한 번만 켜기, 자동 업데이트, 설치 파일(MSIX · winget) · 서명 | |
| 뒤 | 번역(Edge의 기기 안 Translator API를 WebView2에서 쓸 수 있는지부터) | |
