# Diagrams — Mermaid·KaTeX를 그리는 숨은 페이지

`DiagramRenderer.swift`가 이 폴더를 숨은 웹뷰에 싣고 블록 하나씩 그림으로 받는다. 화면에는
보이지 않는다. 폴더째 앱의 `Contents/Resources/Diagrams`로 들어간다(`project.yml`의 폴더 참조 —
KaTeX의 CSS가 `fonts/` 아래를 상대 경로로 부르므로 납작하게 펴면 안 된다).

| 파일 | 무엇 |
|---|---|
| `render.html` · `render.js` | 마디가 쓴 페이지. CSP로 이 폴더 밖과 네트워크를 막는다 |
| `mermaid.min.js` | Mermaid 12.2.0 (MIT) — npm `mermaid-12.2.0.tgz`의 `dist/mermaid.min.js` |
| `katex.min.js` · `katex.min.css` · `fonts/*.woff2` | KaTeX 0.19.1 (MIT) — npm `katex-0.19.1.tgz`의 `dist/` |
| `LICENSE-mermaid.txt` · `LICENSE-katex.txt` | 두 라이선스 전문 |

받은 곳과 확인(2026-10-31): npm 레지스트리의 tarball을 받아 레지스트리가 주는 `integrity`(sha512)와
맞춰 보았다. 파일은 고치지 않았다.

```
a8a6a6f805b074a8261a2825c86f99c8054acb3b35f50bb7e24a4f9f2c3c3b9f  mermaid.min.js
fa140498b8cfc8302cbe5e7cb1bdbc1f952bc38b3fa258ede09e73edbf9a74bc  katex.min.js
00e0b094171b07f58422075f469b4feac2b2f7bce1aeec943c08da4d697f4dcf  katex.min.css
```

KaTeX의 CSS는 글꼴마다 `woff2`·`woff`·`ttf`를 차례로 적는다. 앞의 것을 읽으면 뒤는 부르지
않으므로 `woff2`만 넣었다(20개, 296KB).

## `mermaid.min.js` 안에 든 것

한 파일로 묶인 번들이라 Mermaid가 쓰는 꾸러미가 함께 들어 있다. 직접 의존하는 꾸러미와 그
라이선스(npm 레지스트리, 2026-10-31 조회 — 판 번호는 그날의 최신이고 번들에 든 판과 다를 수 있다):

| 꾸러미 | 라이선스 |
|---|---|
| d3 | ISC |
| d3-sankey | BSD-3-Clause |
| dompurify | MPL-2.0 또는 Apache-2.0 |
| chevrotain | Apache-2.0 |
| **elkjs** | **EPL-2.0 또는 GPL-3.0-or-later** |
| khroma | npm 메타데이터에 적혀 있지 않다 — 확인이 필요하다 |
| @braintree/sanitize-url · @iconify/utils · @upsetjs/venn.js · cytoscape · cytoscape-cose-bilkent · cytoscape-fcose · dagre-d3-es · dayjs · es-toolkit · katex · marked · roughjs · stylis · ts-dedent · uuid · @mermaid-js/parser | MIT |

**elkjs의 고지**: elkjs는 EPL-2.0이다(번들 안에 `org.eclipse.elk`가 342번 나온다 — 2026-11-09에 셈).
EPL-2.0은 목적 코드로 나눠 줄 때 받는 사람에게 **원본을 얻는 길을 알리라**고 한다(3.2절). 릴리스 노트에
적는다 — `scripts/release.sh`가 '포함된 오픈 소스' 절을 붙이고, 그 절이 이 파일과 elkjs 원본 저장소로
잇는다(0.1.0부터). 남은 것: 직접 의존 꾸러미가 끌어온 꾸러미(d3의 하위 모듈 등)는 이 표에 없고, khroma의
라이선스는 아직 확인하지 못했다 — 번들을 도구로 훑어 목록을 다시 만드는 편이 정확하다.
