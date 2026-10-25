# MarkText(Muya) 참조 기록

마디의 블록 편집기를 만들면서 **MarkText**를 읽었다. Mark.app과 달리 오픈소스라
역공학이 아니라 소스를 직접 읽을 수 있고, 같은 문제(마크다운 WYSIWYG 편집)를
먼저 푼 사람들의 결정을 볼 수 있다.

> **읽은 판**: `marktext/marktext` 모노레포, 커밋 `b59942c`(2026-10-25), 버전 0.24.0-dev.
> 패키지는 `desktop`(513 파일) · `muya`(718 파일) · `website`(25 파일).
> 편집 엔진은 `packages/muya`이고, 전에 따로 있던 `marktext/muya` 저장소는
> 2026-05-29에 보관 처리됐다 — 모노레포로 들어왔다.
>
> **라이선스는 MIT다.** 그래서 읽고 배우는 데 제약이 없다. 다만 **코드를 옮겨
> 붙이지 않았다**: Muya는 TypeScript이고 마디는 Swift/AppKit이라 애초에 옮길 수
> 없고, 옮겨 올 가치가 있는 것은 코드가 아니라 **결정과 실패 목록**이다.
> 이 문서에 인용은 없고, 파일 경로와 수치만 적는다.

## 1. 구조 — 블록 트리 vs 블록 배열

Muya의 문서는 **블록 트리**다. `src/block/base/`에 `treeNode` · `parent` · `content` ·
`format` · `list` · `quoteContainer`가 있고, 형제는 배열이 아니라 **연결 리스트**다
(`base/linkedList/`). 블록 종류는 디렉터리로 갈라져 있다:

```
commonMark/  atxHeading setextHeading paragraph blockQuote bulletList orderList
             listItem codeBlock thematicBreak html headingFoldToggle headingCopyLink
gfm/         table taskList taskListItem taskListCheckbox
extra/       diagram footnote frontmatter githubAlert math
content/     paragraphContent atxHeadingContent setextHeadingContent
             codeBlockContent langInputContent tableCell thematicBreakContent
```

마디는 블록을 **배열**로 뒀다(`Core/BlockDocument.swift`). 차이가 생기는 지점은 중첩이다 —
인용 안의 목록, 목록 안의 코드 블록은 트리여야 자연스럽다. 마디의 단계 0은 그런 중첩을
`.quote` · `.list` 블록 하나의 원문 조각으로 삼켜 두었고(설계 §9의 "일부러 남긴 단순화"),
왕복은 성립하지만 중첩된 것을 **따로 편집할 수는 없다.**

**결정: 단계 3까지는 배열을 유지한다.** 표를 격자로 만드는 데 트리는 필요하지 않고
(표는 자기 안에서만 2차원이다), 배열은 가시 범위 레이아웃과 바이트 동일 왕복이
단순해진다. 중첩 편집이 필요해지면 그때 `Block.children`을 더하는 쪽이, 지금 트리로
갈아 두고 쓰지 않는 쪽보다 싸다.

## 2. 왕복 — 여기서는 마디가 더 엄하다

Muya는 상태에서 마크다운을 **다시 생성한다**(`src/state/stateToMarkdown.ts`, 664줄).
원문 조각을 들고 있지 않고, 대신 되살려야 하는 세부를 **구문별로 따로 잡아 둔다**:
`markdownToState.ts`가 setext 제목의 밑줄을 `syntax.underline`에 넣고, 펜스 줄은
`parseFenceLine(raw)`로 뜯어 두고, 참조 정의는 "lossless Markdown round-trips"라는
주석과 함께 **원문 문단 그대로** 남긴다.

즉 그들도 왕복이 중요하다는 것을 알고 있지만, 다시 생성하는 구조를 택한 대가로
**구문마다 보존 코드를 따로 써야 한다.** 새 구문을 더할 때마다 그 일이 또 생긴다.

마디는 반대로 간다 — 모든 블록이 원문 조각을 들고 있고 고치지 않은 블록은 그대로
내보낸다(설계 §6). 그래서 파서가 **모르는** 구문도 공짜로 보존된다(각주·GitHub 알림·
낯선 확장). 대가는 고친 블록에서 칸 맞춤 같은 서식을 잃는 것이고, 그것은 받아들였다.

**결정: 바뀌지 않는다.** 오히려 이 비교가 근거를 보강한다. 다만 Muya가 보존에 공을
들인 **목록**(setext 밑줄, 펜스 줄의 원형, 참조 정의)은 마디가 모델링할 때 주의할
지점으로 쓸 수 있다.

## 3. IME — 마디의 결함을 이 쪽에서 찾았다

Muya는 조합 중에 **문서를 고치는 키를 입력기에 넘긴다.** 키마다 테스트가 있다:

```
block/base/__tests__/imeBackspaceComposition.spec.ts   Backspace·Delete를 입력기에
block/base/__tests__/imeTabComposition.spec.ts         Tab을 입력기에 (#1250)
block/base/__tests__/imeSoftLineBreak.spec.ts          조합 확정이 soft break를 지우지 않게
block/content/tableCell/__tests__/composeHandler.spec.ts  빈 칸에서의 조합
```

구현은 `src/editor/index.ts`의 `_isComposing` 하나로, `compositionstart`에 세우고
`compositionend`에 내린다(그 사이의 `input`은 소비하지 않는다).

이것을 읽고 마디를 다시 보니 **블록을 넘는 삭제에 그 검사가 없었다.** 조합 중에
Backspace를 누르면 블록을 허물 수 있는 길이 열려 있었다. 가드를 넣었다.

다만 정직하게 적어 둔다: 변이로 재 보니 **그 가드가 걸리는 경로를 지금은 만들 수 없다** —
조합이 시작되면 선택이 그 블록 안으로 줄어들고, 합치기는 캐럿이 (0,0)일 때만이라
조합 중에는 조건이 거짓이다. 가드는 방어로 남겼고 테스트는 "조합 중에 문서가 바뀌지
않는다"는 **동작**만 지킨다.

같은 읽기에서 **실제로 깨져 있던 것**을 하나 더 찾았다 → 다음 절.

## 4. 블록을 넘는 편집 — 치기도 한 연산이어야 한다

Muya에는 `block/base/__tests__/crossBlockFormat.spec.ts`가 있다. 그걸 보고 마디에서
"블록을 넘는 선택 위에 글자를 치면 어떻게 되는가"를 재 봤더니, **자기 블록의 몫만
대체되고 나머지 블록의 선택된 글이 남았다.** 블록마다 텍스트 뷰가 따로이므로
`insertText`가 자기 저장소만 보기 때문이다.

고쳤다. `BlockEditFactory.deletion`을 `replacement(in:selection:with:)`로 일반화해
치기·붙이기·지우기가 **같은 한 연산**을 지나게 했다(되돌리기도 한 번에 돌아간다).
`BlockContainerTests.testTypingOverACrossBlockSelectionReplacesAllOfIt`가 지킨다 —
라우팅을 없애면 블록이 1개가 아니라 5개로 남아 빨개진다.

## 5. 표 — 단계 3의 점검 목록

`block/gfm/table/index.ts`(305줄)의 표 연산: `insertRow` · `insertColumn` ·
`removeRow` · `removeColumn` · `alignColumn` · `cellAt` · `getSubTableState` ·
`rowCount` · `columnCount`. 마디의 `TableModel`은 이미 거의 같은 것을 들고 있다
(정렬·행·열 고치기). **빠진 것은 `getSubTableState`뿐**이고, 그건 표의 일부를
복사할 때 쓰인다.

값은 `block/content/tableCell/index.ts`(268줄)의 **키 처리**에 있다. 마디가 단계 3에서
그대로 겪을 것들이다:

| 키 | Muya의 동작 | 마디에 주는 함의 |
|---|---|---|
| ↑ / ↓ | 같은 **열 번호**의 위/아래 행으로. 행이 없으면 표 바깥의 앞/뒤 블록으로 | 열을 보존해야 한다 — 칸 번호만 세면 들쭉날쭉 움직인다 |
| ↓ (마지막 행, 다음 블록 없음) | **새 문단을 만들어** 그리로 간다 | 문서 끝의 표에 갇히지 않게 하는 탈출구. 없으면 표가 마지막일 때 아래로 나갈 수 없다 |
| Tab / Shift+Tab | 다음/앞 칸. 첫 머리글 칸에서 Shift+Tab은 제자리 | 마디는 Tab을 아직 안 쓴다 |
| Backspace (칸 처음) | **칸을 합치지 않는다.** 표가 비어 있으면 표를 문단으로 바꾸고, 아니면 앞 칸 끝으로 캐럿만 옮긴다 | 마디의 "앞 블록과 합치기"를 표 안에서는 **금지**해야 한다 |
| 조합 시작(빈 칸) | 폭 0 공백을 임시로 넣는다(Safari IME가 빈 칸을 깨뜨려서) | WebKit 전용 우회라 마디에는 안 옮긴다. 다만 **빈 칸에서의 조합**이 알려진 함정이라는 신호 |
| Enter | Shift / ⌘ / 보통을 갈라 처리 | 표 안의 Enter 의미를 정해야 한다(줄바꿈 vs 행 추가 vs 표 탈출) |

표 자체 테스트도 그대로 쓸 만한 목록이다: `alignColumn` · `insertRowColumn` ·
`removeRowColumn` · `subTableState`, 그리고 칸 쪽 `arrowHandler` ·
`backspaceSafety` · `deleteHandler` · `enterHandler` · `tabHandler` · `composeHandler`.

## 6. 되돌리기

`src/history/index.ts`(345줄)는 **선택까지 함께** 쌓는다. 되돌릴 때 블록을 복원하는
것으로 끝내지 않고 앵커/포커스의 **경로와 오프셋**을 되살린다(`_toSerializableSelection`).
블록이 사라졌다 다시 생기면 같은 객체가 아니므로 경로로 다시 찾는 것이다.

마디는 지금 되돌린 뒤 캐럿을 편집 구간의 처음에 놓는다(`perform(_:caretOffsetWithinNew:)`에
0을 넘긴다). 긴 문단 가운데를 고치고 ⌘Z를 누르면 캐럿이 문단 처음으로 튄다.

**결정: 단계 2 전에 고칠 일로 TODO에 올린다.** `BlockEdit`에 "되돌린 뒤의 캐럿"을
같이 싣는 것이 맞고, `BlockEdit.position(forOffset:within:firstBlockIndex:)`가 이미
있으니 쓰는 쪽만 고치면 된다.

## 7. 마디에 없는 구문

Muya가 다루고 마디가 못 다루는 것(`src/block/` 디렉터리와 `inlineRenderer/lexer.ts`의
토큰 목록에서):

- **블록**: setext 제목(`===` 밑줄), 각주, GitHub 알림(`> [!NOTE]`), 수식 블록,
  다이어그램, HTML 블록(마디는 문단으로 보존만 한다), 제목 접기
- **인라인**: 참조 링크·참조 이미지, 각주 표식, 자동 링크(`www.`·이메일), 이모지(`:smile:`),
  수식(`$...$`), 아래/위 첨자, `mark` · `ins` · `del`, hard/soft line break 구분

front matter는 마디도 이미 한다. 수식·다이어그램은 TODO의 "결정이 필요한 것"에 이미
올라가 있다(웹뷰를 쓸지). **setext 제목과 참조 링크는 결정이 필요 없는 순수 파싱 작업**이고,
설계 §9가 이미 단계 2 전에 고칠 단순화로 적어 두었다.

## 8. 이 읽기에서 실제로 바뀐 것

| | |
|---|---|
| 고친 결함 | 블록을 넘는 선택 위에 치기·붙이기가 자기 블록만 대체하던 것 |
| 더한 가드 | 조합 중의 Backspace·Delete·⌘A (방어 — 걸리는 경로는 지금 없다) |
| 일반화 | `deletion` → `replacement(in:selection:with:)`, 치기·붙이기·지우기가 한 연산 |
| TODO로 올린 것 | 되돌린 뒤 캐럿 자리, 표 키 처리 점검 목록, setext·참조 링크 |
| 바꾸지 않기로 한 것 | 블록 배열(트리로 가지 않음), 바이트 동일 왕복(다시 생성하지 않음) |
