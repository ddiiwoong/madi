# Md — 남은 일

상태는 세 가지로만 적는다: **지금 할 것** · **설계가 끝난 것** · **결정이 필요한 것**.
이 파일이 현재 상태를 주장하는 유일한 곳이다. 왜 그렇게 됐는지는
`README.md`와 `docs/block-editor-design.md`가 설명한다.

## 끝난 것

- 라이브 프리뷰 편집(뷰어 상태에서 바로 수정, 마커는 캐럿 줄에서만 보임)
- 문서 내 검색 — 모든 일치 강조, `⌘G`/`⇧⌘G` 이동, 큰 문서 가드
- 목차 · 파일 브라우저 · 최근 문서 사이드바, 도구 막대 **토글**로 상태 표시
- 버거 메뉴 + 메뉴 바(같은 명령 표에서 생성), 단축키를 Mark.app에 맞춤
- front matter 메타데이터 카드(읽기 전용, 원문 블록 바이트 보존 + 왕복 테스트)
- 코드 보기 `⌘E`, PDF 내보내기, 프린트
- 코드 블록 구문 강조 11개 언어 — swift · js/ts · python · shell · json · rust · go · yaml · css · html · sql
- 기록 패널 `⌘⇧L` — 한 일과 실패가 남는다
- 표 열 맞추기(정렬 읽기, 원문 불변) + 표 안 인라인 마크업 렌더
- `NSDocument` 기반 열기/저장/자동 저장/최근 문서
- Apple 번역 `⌘⇧T` — 마크다운 구조 보존(자리표), 긴 문단 800자 청킹,
  진행 시트 + 취소 버튼, 구분자 역할에 따른 공백 보정

## 지금 할 것

### 번역 (Apple Translation) — 동작하지만 다듬을 것이 있다
Sogon의 구조를 가져왔다(`~/sogon/Sogon/Services/Translation/AppleTranslationService.swift`,
`Sogon/Models/TranslationChunker.swift`, `Sogon/Models/TranslationRunner.swift`).
마크다운이라서 Sogon과 **다르게** 한 것이 핵심이다 — 마커마다 쪼개 넘기면 문맥이 사라지고,
통째로 넘기면 마크업이 깨진다. 그래서 **문장은 통째로 넘기고 보호 구간만 자리표로** 바꾼다
(`Sources/Md/Core/MarkdownTranslationPlan.swift`).

측정 기록(ko→en, 이 Mac, 2026-10-25):

```
1차: 마커마다 쪼갠 설계(13조각)
  본문은 **굵게**와 `인라인 코드`, [문서 링크](…)를 포함합니다.
  → The main text is**Boldly**Wow`인라인 코드`,[Document link](…)Includes.   ← 말이 안 된다

2차: 자리표 설계(8조각)
  → The text includes **bold** and `인라인 코드`, [ document links](…).      ← 문장은 되지만 '[ ' 결함

3차: 자리표 + 공백 보정(구분자의 여는/닫는 역할 구분)
  → The text includes **bold** and `인라인 코드`, [document links](…).       ← 현재
```

**공백 보정에서 한 번 더 틀렸고 그것이 설계를 바꿨다.** 처음에는 "원문에 공백이 없던
자리에 생긴 공백을 지운다"로 했는데 `**굵게**와`가 `**bold**and`가 됐다 — 한국어는 조사가
붙어 공백이 없지만 영어는 있어야 한다. 그래서 보호 구간에 **여는/닫는/독립** 역할을 붙여
여는 쪽은 뒤의 공백만, 닫는 쪽은 앞의 공백만 보도록 고쳤다. 인라인 코드처럼 감싸는 것이
아닌 구간은 공백을 아예 건드리지 않는다.

남은 결함 하나(측정됨):

- [ ] **표의 칸은 문맥이 없다.** 칸마다 독립 단위라 `검색`이 `reference`로, `항목`이
      `a head`로 나왔다. 칸을 행 단위로 묶어 넘기면 문맥이 생기지만 칸 경계가 섞일
      위험이 있다. 헤더 행을 함께 넘기는 방법을 시험해 볼 수 있다.

그리고 남은 일:

- [ ] 언어 팩이 없을 때의 받기 흐름. Sogon은 SwiftUI `.translationTask`가 붙은 화면으로
      받는다(`TranslationLanguagePackPreparation`). Md에는 그 화면이 없어 지금은 시스템
      설정으로 안내만 한다. 받기 화면을 넣을지 결정이 필요하다.
- [ ] ko↔en 외 언어. 방향 판정이 한글 비율 기반 2개 언어 전용이다.

### LLM 교정 — 아직 손대지 않음
Sogon에 있는 교정을 Md에도 넣는다. Sogon 쪽 구성은 이렇다:

```
Sogon/Services/LLM/LLMProvider.swift          프로토콜
Sogon/Services/LLM/{Bedrock,Claude,Gemini,Groq,OpenAI,LocalText}Provider.swift
Sogon/Services/LLM/CorrectionPrompts.swift    프롬프트
Sogon/Services/LLM/LLMOutputSanitizer.swift   응답 정리
Sogon/Services/LLM/LLMStopReason.swift        출력이 상한에서 잘렸는가
Sogon/Services/Recording/LLMChunkPlanner.swift
Sogon/Models/{CorrectionMode,PromptTemplate,TextCorrectionInput}.swift
Constants.Limits.maxCorrectionCharacters = 1500   (이보다 길면 Sogon은 교정을 건너뛴다)
```

**번역에서 이미 푼 문제를 다시 쓸 수 있다.** 마크업을 LLM에 넘기면 깨지는 것은 번역과
같은 문제이고, `MarkdownTranslationPlan`의 자리표 방식이 그대로 통한다. 다만 이름이
번역 전용이므로 교정과 함께 쓰려면 `MarkdownTextPlan` 같은 이름으로 일반화해야 한다
(`Sources/Md/Core/MarkdownTranslationPlan.swift`).

번역과 **다른** 점이 교정의 진짜 위험이다:

- [ ] **LLM은 마크다운을 "고치려" 든다.** 번역기는 주어진 글만 옮기지만 LLM은 `- 항목`을
      `1. 항목`으로 바꾸거나 제목 수준을 올리거나 표를 다시 그린다. 프롬프트로 금지하고,
      **구조가 바뀌었는지 코드로 검사**해야 한다 — 교정 전후의 `MarkdownSyntax.scanLines`
      결과(블록 종류 배열)가 같은지 비교하면 잡힌다. 다르면 그 조각의 교정을 버린다.
- [ ] **출력이 상한에서 잘린다.** 번역기는 상한이 없지만 LLM은 있다(Bedrock·Groq 2048,
      Claude·Gemini 4096 토큰). Sogon은 `LLMStopReason`으로 잘림을 읽고
      `TranslationRunner`가 구간을 반으로 쪼개 다시 한다. 그 안전망을 같이 가져와야 한다 —
      **잘린 글을 교정 결과로 내보내면 문서가 날아간다.**
- [ ] **응답을 감싼 코드 펜스.** 모델이 답 전체를 ```` ``` ````로 감싸는 실수가 흔해
      `LLMOutputSanitizer`가 그것을 벗긴다. 그런데 교정하는 조각이 **정말 코드 블록
      하나**일 때 정당한 펜스까지 벗겨진다. Sogon이 이미 걸렸고
      `TranslationChunker.restoringWrappingFence`로 되돌린다. 같은 보호가 필요하다.
- [ ] **되돌릴 수 있어야 한다.** 번역은 결과가 눈에 띄게 다르지만 교정은 원문과 비슷해서
      무엇이 바뀌었는지 모른 채 저장하게 된다. **적용 전 diff를 보여 주는 화면이 사실상
      필수**다(번역에는 없어도 됐다). 조각별로 받거나 버릴 수 있으면 더 낫다.
- [ ] **API 키 보관.** Apple 번역은 키가 없지만 LLM은 있다. 키체인에 넣을지, 어느
      프로바이더를 지원할지 결정이 필요하다. 로컬(MLX)만 지원하면 키가 아예 필요 없다.
- [ ] **무엇을 교정 대상으로 볼지.** front matter는 제외(값이 망가진다). 코드 블록·인라인
      코드·URL도 제외. 결국 번역과 같은 보호 집합이다.
- [ ] 길이 게이트. Sogon은 1500자가 넘으면 건너뛴다. 문서 편집기는 긴 글이 기본이므로
      조각 단위로 교정하고 진행을 보이는 쪽이 맞다.

규모가 번역보다 크다 — 프로바이더 하나만 붙여도 키 보관·프롬프트·잘림 복구·diff 화면이
함께 와야 한다. **로컬 모델 하나로 시작해 diff 화면까지 만든 다음 프로바이더를 늘리는**
순서를 권한다. 키가 필요 없어 첫 단계에서 결정할 것이 줄어든다.

### 작은 것들
- [ ] 한글 기울임 대안. 시스템 한글 글꼴에 italic 꼴이 없어 `*기울임*`이 시각적으로 구분되지
      않는다. 색이나 자간 같은 다른 표현을 고르거나, 기울임을 포기하고 그 사실을 적는다.
- [x] 표 정렬 보기 — `| --- |`의 `:---`/`:--:`/`---:`를 읽어 열을 맞춘다. **문서를 한
      바이트도 고치지 않는다**: 칸에 공백을 끼워 넣는 흔한 방법은 저장할 때 원문을
      바꾸므로 쓸 수 없어, 글자 간격(`.kern`)으로 나아감만 늘렸다. 표 안의 인라인
      마크업도 이제 그려진다(전에는 표 행만 건너뛰어 `**굵게**`가 날 글자로 보였다).
      한계: 캐럿이 있는 줄은 마커가 보여 그 줄의 칸이 열 너비보다 넓어질 수 있고,
      그때는 늘리지 않고 그 줄만 밀린 채 둔다.
- [x] 기록 `⌘⇧L` — 떠 있는 패널에 앱이 한 일과 실패가 남는다. 수준 걸러 보기, 모두 복사,
      지우기. **여기 적혀 있던 서술이 틀렸다** — 사라지는 토스트가 아니라 모달 경고창이었고,
      그래서 성공 문구가 작업을 가로막고 실패는 닫는 순간 사라졌다. 이제 성공은 가로막지
      않고 떠서 사라지며 기록에 남고, 실패는 경고창으로 알리면서 기록에도 남는다.

설정 화면은 아래 'Mark.app에 있고 Md에 없는 것'에 함께 적었다.

## Mark.app에 있고 Md에 없는 것

실제 앱을 띄워 접근성 트리로 읽고(도구 막대·버거 메뉴·편집기 구조), 번들에서 꺼낸 애셋과
crate 목록으로 확인한 목록이다. 메뉴 13개 중 9개는 넣었고 **4개가 빠졌으며**, 메뉴에
없는 렌더링 기능 쪽 격차가 더 크다.

### 렌더링 — 격차가 가장 큰 쪽

- [ ] **Mermaid 다이어그램.** Mark은 22종을 렌더한다 — 번들에 `mermaid.core`(600KB),
      `cytoscape.esm`(442KB), 그리고 flow · sequence · gantt · ER · C4 · class · state ·
      journey · mindmap · timeline · sankey · kanban · gitGraph · quadrant · xychart ·
      requirement · architecture · block · venn · wardley · info · pie 모듈이 각각 들어 있다.
      **앱 전체에서 가장 큰 기능군이고 Md에는 없다.**
      네이티브로 가는 길은 둘이다. (ㄱ) 종류별 렌더러를 직접 짠다 — 22종이면 현실적이지 않고,
      많이 쓰는 flow·sequence 둘만 해도 레이아웃 알고리즘(cytoscape가 하는 일)이 필요하다.
      (ㄴ) **다이어그램 블록만 화면 밖 WKWebView로 그려 이미지로 심는다** — 앱 전체는
      네이티브로 남고 다이어그램만 웹에 맡긴다. 번들에 mermaid를 넣어야 하니 앱이 수 MB
      커지고, 그려진 결과는 편집이 아니라 미리보기다. 설계가 필요하다.
- [ ] **KaTeX 수식.** Mark은 `katex`(259KB)와 **KaTeX 글꼴 59개**를 번들에 품는다.
      네이티브 대안이 다이어그램보다는 있다 — 수식을 MathML로 바꿔 `NSAttributedString`에
      얹는 경로가 있고, 그래도 TeX 파싱은 직접 해야 한다. 다이어그램과 같은 숨은 웹뷰
      방식으로 묶어 처리할 수도 있다.
- [x] **코드 블록 구문 강조** — `CodeHighlighter`(Core, 손으로 쓴 스캐너). swift ·
      js/ts · python · shell · json 다섯 언어. 모르는 언어는 칠하지 않는다(규칙을 모르는
      언어에 C 비슷한 규칙을 대면 틀린 강조가 나온다 — `#`은 셸에서 주석이지만 C에서는
      전처리기다). Mark은 `syntect`로 Sublime 문법 정의를 쓰므로 언어 수가 훨씬 많다.
      남은 것:
- [x] 언어를 더 넣기 — rust · go · yaml · css · html · sql을 더해 **11개**가 됐다.
      스캐너는 건드리지 않고 규칙 표만 늘렸다. 언어마다 함정이 달라 각각 테스트로
      못박았다: Rust의 `'`는 수명이라 문자열로 보면 안 되고, CSS에는 줄 주석이 없어
      `//`를 주석으로 보면 URL이 사라지고, SQL은 키워드가 대소문자를 가리지 않는다.
- [ ] 코드 블록 배경이 글자 범위에만 깔려 오른쪽이 들쭉날쭉하다. 블록 전체 너비로
      칠하려면 문단 배경을 직접 그려야 한다(`NSTextBlock` 또는 커스텀 드로잉).
- [ ] **이미지 인라인 표시.** `NSTextAttachment`로 넣을 수 있다. 블록 편집기 설계의 단계 4와
      같은 항목이다.

### 빠진 메뉴 항목 4개

- [ ] **문서 변환해서 가져오기.** crate로 무엇을 받는지 드러난다 — `cfb`(OLE 복합 문서 =
      구형 .doc/.xls), `quick-xml`(docx/xlsx), `tiff` · `fax` · `png` · `image` · `infer`.
      워드 문서와 이미지를 마크다운으로 변환해 가져온다. macOS에는 docx 파서가 없으므로
      직접 짜거나(ZIP + OOXML) 외부 도구(pandoc)에 의존해야 한다 — **의존성 0개 원칙과
      충돌하므로 결정이 필요하다.**
- [ ] **이미지 포함 내보내기.** `base64`로 이미지를 문서에 묻어 단일 `.md`를 만든다.
      네 개 중 가장 쉽다 — 상대 경로 이미지를 읽어 data URL로 바꿔 쓰면 된다.
- [ ] **설정 화면** (`⌘,`). 아래 '작은 것들'에도 적혀 있다. 지금은 메뉴 항목만 있고 비활성.
- [ ] **새 창.** Mark의 `⌘N`은 새 창이고 Md의 `⌘N`은 새 문서다. 이건 **의도된 차이**이지만
      (NSDocument 앱의 macOS 관례), 같은 문서를 두 창으로 보는 기능은 별개로 없다.

### 그 밖에

- [ ] **자동 업데이트.** Mark은 `tauri-plugin-updater`로 `download.loomm.ai`에서 받는다.
      Md는 배포 자체를 하지 않으므로(ad-hoc 서명) 배포를 결정한 뒤에 할 일이다.
- [ ] **표 격자 편집.** 아래 '설계가 끝난 것'에 있다.

### 접근 방식이 다른 것 — 구현할 일이 아니다

- Mark은 마커가 **아예 없는** 문서 모델 WYSIWYG(ProseMirror)이고, 그래서 원문을 보려면
  `코드 보기`가 따로 필요하다. Md는 라이브 프리뷰라 캐럿이 있는 줄에만 마커가 보인다.
  둘 중 어느 쪽이 맞다고 할 수 없는 설계 선택이다.

### Md에만 있는 것

- **Apple 번역**(마크다운 구조 보존). Mark에는 없다.
- 검색의 **일치 개수 표시와 `⌘G` 이동**. Mark의 검색에는 네비게이션이 없다
  (`matchIndex`·`nextMatch`·`matchCount`를 번들에서 grep하면 0건).

## 새 기능 — EPUB 리더

EPUB 책을 Md에서 읽는 기능. **아직 아무것도 구현하지 않았다.** 아래는 하기 전에 재 본
타당성 조사다(2026-10-25, 이 Mac).

의외의 결론부터: **의존성 0개를 지키면서 할 수 있다.** 세 조각이 전부 시스템에 있다.

### 측정한 것

| 필요한 것 | 어떻게 | 측정 결과 |
|---|---|---|
| ZIP 해제 | `Compression` 프레임워크, `COMPRESSION_ZLIB` | raw DEFLATE 왕복 OK (5,800바이트 → 71 → 5,800) |
| OPF·NCX 파싱 | `XMLDocument` + XPath | OK. `local-name()`으로 네임스페이스를 피하면 `<dc:title>`·manifest·spine을 바로 읽는다 |
| XHTML → 서식 있는 글 | `NSAttributedString(data:options:)` | 38KB를 **61ms**(629KB/초). 백그라운드 스레드에서도 된다 |

**한글이 깨지는 함정을 찾았다.** 인코딩을 아무도 말해 주지 않으면 AppKit이 잘못 추측한다:

```
meta charset 있음 + 옵션 없음 → 한국어 본문      ✓
meta charset 없음 + 옵션 없음 → �쒓뎅�� 蹂몃Ц   ✗  (UTF-8을 EUC-KR로 읽음)
meta charset 없음 + 옵션 있음 → 한국어 본문      ✓
```

그러니 **`.characterEncoding`을 늘 명시**한다. EPUB의 XHTML은 보통 인코딩을 선언하지만
선언에 기대면 안 된다 — 선언이 없는 파일 하나가 그 책 전체를 모지바케로 만든다.

### 할 일

- [ ] **ZIP 컨테이너 읽기.** `Compression`이 주는 것은 DEFLATE뿐이고 ZIP **구조**는 직접
      걸어가야 한다 — 끝의 중앙 디렉터리(EOCD) 찾기, 중앙 디렉터리 항목 훑기, 로컬 헤더
      읽기, 항목별 inflate. 200~300줄로 본다. EPUB은 `mimetype` 항목이 맨 처음에
      **무압축으로** 있어야 한다고 규정하므로 그것으로 EPUB인지 빠르게 가린다.
- [ ] **OPF 읽기.** `META-INF/container.xml` → OPF 경로 → manifest(id→href→media-type) ·
      spine(읽는 순서) · metadata(제목·저자·언어). XPath로 되는 것은 확인했다.
- [ ] **목차.** EPUB 3은 `epub:type="toc"`가 붙은 XHTML nav, EPUB 2는 NCX다. **둘 다**
      필요하다(현실의 책은 섞여 있다). 이미 있는 목차 사이드바에 꽂으면 된다.
- [ ] **챕터 렌더링.** spine 순서대로 XHTML을 `NSAttributedString`으로 바꿔 보인다.
      이미지는 `NSTextAttachment`, 컨테이너 안의 상대 경로를 풀어 줘야 한다.
- [ ] **DRM 걸린 책을 정직하게 거절하기.** `META-INF/encryption.xml`이 있으면 Adobe ADEPT나
      Apple FairPlay로 암호화된 책이다. 열 수 없다. **깨진 글자를 보여 주지 말고** 왜
      못 읽는지 말해야 한다.
- [ ] 읽던 위치 기억. `NSDocument`의 복원 경로에 얹는다.
- [ ] 쪽 넘김을 할지, 그냥 길게 스크롤할지 결정.

### 재지 못한 것

- 실제 EPUB 파일로 해 보지 않았다. 위 측정은 **직접 만든 XHTML**이다. 현실의 책은
  CSS·글꼴·SVG 표지가 들어 있고 깨진 마크업도 흔하다.
- `NSAttributedString`의 HTML 가져오기가 EPUB의 CSS를 얼마나 따르는지 모른다. 629KB/초는
  본문에서 나온 수치이고, CSS가 복잡한 책에서 어떨지는 별개다.
- 책 한 권(수백 KB~수 MB)을 한꺼번에 들고 있을지 챕터별로 들고 있을지.


### Intel Mac (x86_64) — 거의 다 돼 있다

측정했다(2026-10-25). `ARCHS`는 이미 `arm64 x86_64`이고, **유니버설 빌드가 지금 그대로
성공한다**:

```
xcodebuild -configuration Release ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" … build
→ BUILD SUCCEEDED
lipo -archs …/Md.app/Contents/MacOS/Md → x86_64 arm64
```

`make build`가 arm64만 내는 것은 Debug 구성이 `ONLY_ACTIVE_ARCH=YES`라서다 — 설정 문제가
아니라 Debug의 정상 동작이다.

- [x] `make universal` 타깃 추가. Release + `ONLY_ACTIVE_ARCH=NO`로 빌드하고 `lipo -archs`로
      두 아키텍처가 다 들어갔는지 **검사까지** 한다(빌드만 하고 믿지 않는다).
- [ ] **Intel에서 Apple 번역이 되는지 확인.** 이것이 유일한 실질 위험이다. 온디바이스 번역이
      Apple Silicon을 요구할 가능성이 있다 — 그러면 Intel에서 `LanguageAvailability`가
      `.unsupported`를 돌려준다. 코드는 그 경로를 이미 처리하므로(안내 문구를 던진다)
      **깨지지는 않고 기능만 없다.** 실기에서 재야 알 수 있다.
- [ ] macOS 26을 Intel Mac이 쓸 수 있는지 Apple 문서로 확인. 배포 타깃은 14.0이라 Intel에서
      앱 자체는 돌지만, 번역은 26 이상이 필요하다. **기억으로 단정하지 말고 문서를 볼 것.**
- [ ] Intel 실기에서 실행 확인. 이 Mac은 Apple Silicon이라 로제타로도 검증이 되지 않는다
      (유니버설 바이너리의 x86_64 조각은 로제타가 아니라 Intel 하드웨어에서 돌 코드다).

### Windows — 빌드 설정이 아니라 **두 번째 앱**이다

솔직하게 적는다. 이것은 플래그를 더하는 일이 아니다. 측정한 수치:

```
Core (Foundation만, AppKit 0):           854줄  → 이식 가능
Editor + Panels + App (AppKit):        2,297줄  → 다시 써야 한다
전체                                    3,151줄
이식 가능 비율                              27%
AppKit을 import하는 파일                     11개
```

Core를 따로 둔 것이 여기서 값을 한다 — `MarkdownSyntax` · `DocumentSearch` · `Outline` ·
`FrontMatter` · `MarkdownTranslationPlan` · `TranslationDirection`은 AppKit을 쓰지 않아
Swift on Windows에서 그대로 컴파일될 것으로 **예상**된다(확인 안 함).

다시 써야 하는 것과 그 난이도:

- [ ] **라이브 프리뷰 편집기.** 가장 큰 벽이다. 마커를 폭 0으로 만드는 방식이
      `NSLayoutManagerDelegate`의 글리프 제어에 기대고 있고, Windows에는 대응물이 없다.
      RichEdit·Direct2D·DirectWrite 중 무엇으로 갈지, 아니면 텍스트 레이아웃을 직접 짤지
      결정해야 한다. **이 기능이 이 앱의 정체성이므로 대체 방법 없이는 포팅 자체가 무의미하다.**
- [ ] **문서 수명주기.** 열기·저장·자동 저장·최근 문서·저장 안 한 변경 경고를 `NSDocument`에서
      공짜로 받고 있다. Windows에서는 전부 직접 만든다.
- [ ] **UI 프레임워크 선택.** `swift-win32`(Win32 얇은 바인딩, 성숙도 낮음) · WinUI 3 +
      C# 상호운용 · UI만 다른 언어로 쓰고 Core는 Swift 라이브러리로 노출. 세 길의 비용이
      크게 다르므로 먼저 결정해야 한다.
- [ ] **번역 엔진.** Apple 번역은 Windows에 없다. 다른 엔진(로컬 모델·클라우드 API)이
      필요하고, 그러면 `MarkdownTranslationPlan`은 그대로 쓰되 엔진만 갈아 끼우는 구조가
      된다 — 번역 로직을 엔진과 분리해 둔 설계가 여기서 값을 한다.
- [ ] **PDF 내보내기·프린트.** `NSPrintOperation` 대신 Windows 인쇄 API.
- [ ] CI. 지금은 로컬 `make`뿐이다. 두 플랫폼을 만들 거라면 Core 테스트만이라도 두 OS에서
      돌리는 것이 먼저다 — Core가 Windows에서 **컴파일되는지조차** 아직 모른다.

권하는 순서: **Core만 Windows에서 컴파일·테스트해 보는 것**이 1단계다. 하루짜리 실험이고,
여기서 막히면(Foundation 차이·정규식 동작 차이) 그 위의 모든 계획이 바뀐다. UI는 그 뒤에
결정한다.

## 설계가 끝난 것 — 구현 대기

### 표 격자 편집 → 블록 편집기
`docs/block-editor-design.md`에 전체 설계가 있다. 요지:

- `NSTextTable`로는 안 된다(셀이 전역 오프셋을 공유 → 마크다운 왕복 불가)
- 문서를 블록 배열로 두고 블록마다 뷰를 준다
- 진짜 작업은 표를 그리는 것이 아니라 **블록을 넘는 선택 · 문서 레벨 되돌리기 ·
  캐럿 경계 이동 · 한글 조합 보호** 네 가지다
- 단계 0(파서/직렬화 + 왕복 테스트) → 1(문단 블록) → 2(읽기 전용 격자) → 3(셀 편집) → 4(이미지)
- **단계 1에서 한글 입력이나 되돌리기가 무너지면 멈추고 현재 구조로 돌아간다**

주 단위 작업이므로 다른 항목과 섞어 하지 않는다.

## 결정이 필요한 것

- **Mermaid·KaTeX를 숨은 WKWebView로 그릴지.** 그러면 "웹뷰 없는 네이티브"라는 전제가
  다이어그램·수식에 한해 깨지고 번들이 수 MB 커진다. 대신 Mark과 같은 결과가 나오고,
  직접 짜는 길은 현실적으로 막혀 있다. **이 앱을 네이티브로 만든 이유를 어디까지
  지킬지의 문제**이므로 코드로 결정할 수 없다.
- **Windows를 정말 할지.** 공유되는 코드가 27%(854줄)이고 나머지는 다시 쓴다. 편집기의
  핵심인 마커 숨김에 Windows 대응물이 없어 **대체 설계 없이는 포팅이 의미가 없다.**
  하기로 하면 Core만 Windows에서 컴파일해 보는 1단계부터 — 거기서 막히면 계획이 바뀐다.
- **문서 변환해서 가져오기를 어떻게 할지.** docx 파서를 직접 짜거나 pandoc에 의존해야
  한다. 후자는 의존성 0개 원칙과 충돌한다.

- **언어 팩 받기 화면을 Md에 넣을지.** 넣으면 SwiftUI 뷰 하나가 AppKit 앱에 들어온다.
  안 넣으면 사용자가 시스템 설정에서 직접 받아야 한다.
- **배포할지.** 지금은 ad-hoc 서명(`CODE_SIGN_IDENTITY=-`)이라 이 Mac에서만 돈다.
  배포하려면 Developer ID 서명 + 공증이 필요하다.
- **표 격자 편집을 실제로 할지.** 설계는 끝났지만 비용이 크다. 하지 않기로 하면
  "표는 텍스트로 남는다"를 제품의 결정으로 적고 설계 문서를 보관 상태로 표시한다.
- **EPUB 리더가 이 앱에 들어갈 일인지.** 타당성은 통과했다(의존성 0개로 가능, 위 절 참조).
  막는 것은 기술이 아니라 **제품 성격**이다. Md의 전제는 "뷰어 상태에서 바로 편집"인데
  EPUB은 읽기 전용이다(EPUB을 편집하는 것은 완전히 다른 일이다). 그래서 한 앱 안에
  **성격이 다른 두 번째 화면**이 생긴다 — 쪽 넘김, 챕터 이동, 편집 불가. 마크다운 편집기가
  EPUB도 읽는 것이 자연스러운지, 아니면 별도 앱이 맞는지 결정해야 한다. 같은 Core(ZIP·XML
  읽기)를 쓰는 두 번째 앱으로 두는 선택지도 있다.

## 검증하지 못한 것

정직하게 남긴다 — 다음에 만지는 사람이 다시 확인해야 한다.

- **창 상태가 완전히 비어 있는 첫 실행.** `~/Library/Saved Application State`를 지워야
  볼 수 있고 에이전트 세션에서 그 삭제가 막힌다. 현재 상태에서 860x700으로 뜨는 것까지만
  확인했다.
- **번역 실제 동작.** 한국어·영어 언어 팩이 이 Mac에 설치돼 있어야 하고, 없으면 코드가
  안내 문구를 던지는 경로만 확인된다.
- **큰 문서 성능.** 줄 스캔이 매번 문서 전체를 훑는다. 수천 줄 문서로 측정한 적이 없다.
