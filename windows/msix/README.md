# Microsoft Store판(MSIX)

마디 Windows판을 Microsoft Store에 올리는 꾸러미입니다. Store가 꾸러미를 받은 뒤 **Microsoft의 인증서로 서명**하므로 따로 인증서를 사지
않아도 되고, Store에서 받은 사람에게는 SmartScreen 경고가 뜨지 않습니다(2026-11-23 조사 — [Microsoft: 코드 서명 선택지](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options)).
설치 파일판(`windows/installer`)은 그대로 둡니다 — GitHub에서 받는 사람용.

| 파일 | 무엇 |
|---|---|
| `AppxManifest.xml` | 꾸러미 매니페스트. `{{…}}`는 `build.ps1`이 채운다 |
| `build.ps1` | `dotnet publish` 출력 → `Madi-<판>-windows-x64.msix`(서명 없음). Windows SDK의 makepri · makeappx |
| `Assets/` | 타일 · 작업 표시줄 · Store 로고 25장(배율 · 크기마다). `make-assets.py`가 macOS판 아이콘에서 만든다 |
| `make-assets.py` | 이 Mac에서(iconutil · sips) `Assets/`와 `../Madi.Windows/Madi.ico`를 다시 만든다 |

CI(`.github/workflows/windows.yml`)가 꾸러미를 만들고, **시험 인증서**(그 실행에서 만들고 버린다)로 사본에 서명해 깔아, 확인 실행을 꾸러미
안에서 한 번 더 돌린 뒤 지웁니다. 받을 것: `Madi-windows-x64-msix` — Store에 올리는 것은 그 안의 서명하지 않은 `.msix`입니다.

## Store판이 설치 파일판과 다른 것

| | 설치 파일판 | Store판 |
|---|---|---|
| 업데이트 | 하루 한 번 GitHub에 묻고 받는 페이지를 연다 | Store가 한다 — 마디는 묻지 않는다(도움말 ▸ 업데이트 확인 · 명령 팔레트에서 빠진다) |
| 설정 · 최근 문서 | `%APPDATA%\Madi` | Windows가 꾸러미 안에 따로 둔다 — 설치 파일판과 나누지 않고, 앱을 지우면 함께 지워진다 |
| 연결 프로그램 · `madi://` | 설치 파일이 레지스트리에 적는다 | 매니페스트에 선언 — Windows가 깔고 거둔다 |
| 터미널 | — | `madi 문서.md`(별칭 `madi.exe`) |
| 도구 ▸ 기본 앱 설정 열기 | `registeredAppUser=Madi` | 꾸러미의 앱 ID(`registeredAUMID`) |

## 올리는 순서(사람이 할 일)

1. **개발자 계정** — [storedeveloper.microsoft.com](https://storedeveloper.microsoft.com)에서 개인 계정(무료)을 만들고 신분 확인을 마친다.
2. **이름 예약** — Partner Center ▸ 앱 및 게임 ▸ 새 제품 ▸ MSIX 또는 PWA 앱. 이름은 `마디`를 먼저 해 보고, 이미 있으면 다른 이름
   (예: `마디 - 마크다운 편집기`). Store의 앱 이름은 하나뿐이어야 한다.
3. **제품 ID 값** — 그 앱의 제품 관리 ▸ 제품 ID(Product identity)에서 셋을 옮긴다. GitHub 저장소 ▸ Settings ▸ Secrets and variables ▸
   Actions ▸ **Variables**(비밀이 아니다):

   | 변수 | Partner Center의 값 |
   |---|---|
   | `MSIX_IDENTITY_NAME` | Package/Identity/Name |
   | `MSIX_PUBLISHER` | Package/Identity/Publisher(`CN=…`) |
   | `MSIX_PUBLISHER_DISPLAY_NAME` | Package/Properties/PublisherDisplayName |
   | `MSIX_DISPLAY_NAME` | 2에서 예약한 이름(`마디`면 두지 않아도 된다) |

4. **꾸러미** — 판 번호(`windows/Madi.Windows/Madi.Windows.csproj`의 `Version`, 지금 0.0.1)를 정하고 Actions ▸ windows ▸ Run workflow.
   `Madi-windows-x64-msix`를 받아 `.msix`를 꺼낸다. 판은 올릴 때마다 높아야 한다(네 번째 마디는 늘 0 — `build.ps1`이 붙인다).
5. **제출**(Partner Center ▸ 그 앱 ▸ 제출 시작):
   - 가격 및 사용 가능 여부: 무료, 시장
   - 속성: 범주 — 생산성(또는 개발자 도구). 개인정보처리방침 URL — `windows/PRIVACY.md`의 주소(master에 머지된 뒤
     [github.com/ddiiwoong/madi/blob/master/windows/PRIVACY.md](https://github.com/ddiiwoong/madi/blob/master/windows/PRIVACY.md)).
     **데스크톱 앱은 개인정보를 모으지 않아도 이 URL이 있어야 한다.**
   - 연령 등급: 설문(사용자끼리 주고받는 것 없음, 사는 것 없음)
   - 꾸러미: 4의 `.msix`
   - Store 목록(한국어): 아래 초안, **스크린샷 1장 이상 — PNG, 1366×768 이상**(CI가 찍는 화면은 그보다 작다 — 이 PC에서 찍는다)
   - 제출 옵션 ▸ 제한된 기능: `runFullTrust`의 까닭(아래)
6. 인증이 끝나면 Store에 뜬다. 떨어지면 [제출 · 인증 실패 고치기](https://learn.microsoft.com/en-us/windows/apps/publish/fix-submission-failures).

### `runFullTrust`의 까닭(제출 옵션에 붙여 넣는다)

> Madi is a desktop (WPF/.NET) Markdown editor packaged with the Desktop Bridge. It needs runFullTrust to run as a regular desktop app: it reads
> and writes the documents the user opens anywhere on disk, watches those files for external changes, and hosts its editor in WebView2.
> It does not install services, drivers or browser extensions.

### Store 목록 초안

- **설명**: 마디는 쓰는 그대로 보이는 마크다운 편집기입니다. 캐럿이 있는 줄만 원문으로 보이고 나머지는 꾸며진 모습으로 보여, 미리 보기
  창 없이 한 화면에서 쓰고 읽습니다. macOS판과 같은 규칙으로 만들었습니다.
- **기능**:
  - 라이브 프리뷰 — 제목 · 굵게 · 목록 · 인용 · 링크 · 할 일 상자 · 알림 상자
  - 표 · Mermaid 다이어그램 · KaTeX 수식 · 그림 · 문서 메타데이터 카드
  - 코드 블록 문법 색(Swift · JavaScript · TypeScript · Python · 셸 · JSON · Rust · Go · YAML · CSS · HTML · SQL)
  - 테마 여덟 · 다크 모드 · 글꼴 · 글자 크기 · 줄 사이 · 글 폭
  - 빠른 열기 · 명령 팔레트 · 목차 · 찾기와 바꾸기
  - 다른 프로그램이 바꾼 파일을 바로 다시 읽기, 로그를 따라 보기(.txt · .log)
  - PDF 내보내기 · 프린트, madi:// 링크
  - 파일을 바이트 그대로 지킨다 — UTF-8 · BOM · UTF-16 · CRLF, 옛 EUC-KR 파일도 읽는다
- **검색어**: 마크다운, markdown, 메모, 편집기, mermaid

## 아직 하지 않은 것

- **Windows App Certification Kit**(Store가 권하는 사전 검사) — CI에 붙이는 중
- **ARM64 꾸러미** — 지금은 x64만(ARM PC에서는 에뮬레이션으로 돈다)
- **영어 목록** — 화면이 한국어뿐이라 매니페스트의 언어를 `ko-KR` 하나로 두었다
