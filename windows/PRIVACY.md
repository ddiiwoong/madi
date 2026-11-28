# 마디 Windows판 개인정보 처리방침

마지막으로 고친 날: 2026-11-28

마디 Windows판(Microsoft Store판과 설치 파일판)은 **개인정보를 모으지 않고, 사용 기록을 보내지 않습니다.** 광고 · 분석 · 오류 보고 도구가
들어 있지 않습니다. 마디가 바깥과 주고받는 것은 아래가 전부이고, 모두 사용자가 고른 곳으로만 갑니다.

## 바깥으로 나가는 것

| 언제 | 어디로 | 무엇을 | 끄는 법 |
|---|---|---|---|
| 새 판 확인 — 설치 파일판만, 켤 때와 켜 둔 동안 하루 한 번 | GitHub(`api.github.com`) | 마지막 판을 묻는 요청 하나(마디의 판 번호가 든 User-Agent). 문서는 보내지 않습니다 | 도움말 ▸ 하루 한 번 새 판 확인. Store판은 하지 않습니다(Store가 업데이트합니다) |
| LLM 키 확인 — **0.1.4-windows.3까지의 판만**, 도구 ▸ LLM 키에서 `확인`을 누를 때만. 그 뒤의 판에는 이 메뉴가 없습니다 | 사용자가 고른 서비스(Anthropic · OpenAI · Google · Groq · Amazon) | 그 키와 모델 목록을 묻는 요청. 문서는 보내지 않습니다 | 누르지 않으면 보내지 않습니다 |
| 원격 그림 — 보기 ▸ 원격 그림 받기를 켰을 때만(기본 꺼짐) | 문서에 적힌 그림의 주소(https만) | 그 그림을 받는 요청 | 그 설정을 끕니다 |
| 링크 열기 — 링크를 Ctrl+클릭할 때만 | 기본 브라우저 | 그 주소 | — |

다이어그램(Mermaid) · 수식(KaTeX) · 글꼴은 앱에 들어 있습니다 — 그리느라 바깥에 묻지 않습니다.

## 이 PC에 두는 것

- 설정 · 최근 문서 목록: `%APPDATA%\Madi`(Store판은 Windows가 앱 꾸러미 안에 둡니다 — 앱을 지우면 함께 지워집니다)
- LLM 키(0.1.4-windows.3까지의 판에서 넣었다면): Windows 자격 증명 관리자(`Madi/llm/…`). 이 PC의 이 사용자만 읽고, 설정 파일에는 적지
  않습니다. 그 뒤의 판은 이 키를 읽지도 쓰지도 않습니다 — 지우려면 제어판 ▸ 자격 증명 관리자 ▸ Windows 자격 증명 ▸ 일반 자격 증명에서 `Madi/llm/…`을 지웁니다.
- 편집기 화면의 자료(WebView2): `%LOCALAPPDATA%\Madi\WebView2`
- 문서는 사용자가 연 자리에만 씁니다.

## 다른 회사의 구성 요소

마디의 화면은 Microsoft Edge WebView2 런타임이 그립니다. WebView2는 Windows에 든 Microsoft의 구성 요소이고, 그 진단 자료는 Windows의
설정과 [Microsoft 개인정보처리방침](https://privacy.microsoft.com/privacystatement)을 따릅니다. Microsoft Store에서 받았다면 Store도
Microsoft의 방침을 따릅니다. 0.1.4-windows.3까지의 판에서 LLM 서비스에 키를 확인했다면 그 서비스의 방침이 적용됩니다.

## 문의

[github.com/ddiiwoong/madi/issues](https://github.com/ddiiwoong/madi/issues)

---

# Madi for Windows — Privacy Policy

Last updated: 2026-11-23

Madi for Windows (the Microsoft Store and installer editions) **does not collect personal information and sends no usage data.** It contains no
advertising, analytics or crash-reporting code. It connects to the network only in these cases, and only to destinations the user chooses:

- **Update check** (installer edition only; at launch and once a day; can be turned off in Help): one request to `api.github.com` asking for the
  latest release. The Store edition does not check — the Store updates it.
- **LLM key check** (only when the user presses Check in Tools ▸ LLM keys): the key and a model-list request go to the provider the user selected.
  No document content is sent.
- **Remote images** (off by default; View ▸ Load remote images): image requests to the https addresses written in the document.
- **Links** open in the default browser only when the user Ctrl+clicks them.

Settings and the recent-documents list are stored in `%APPDATA%\Madi` (inside the app package for the Store edition, removed with the app). LLM keys
are stored in Windows Credential Manager for the current user only. The editor view is rendered by the Microsoft Edge WebView2 runtime, which
follows Windows' diagnostic settings and the [Microsoft Privacy Statement](https://privacy.microsoft.com/privacystatement).

Contact: [github.com/ddiiwoong/madi/issues](https://github.com/ddiiwoong/madi/issues)
