# 릴리스하기

`make release` 한 줄이 검사부터 공증 · 스테이플까지 하고 `.build/release/<판>/`에 내려놓습니다.
**태그를 달거나 올리거나 공개하지는 않습니다.** 결과물을 사람이 확인한 뒤에 손으로 합니다.

| 나오는 것 | |
|---|---|
| `Madi-<판>.dmg` | 받는 사람이 여는 것. 열면 `Madi.app`과 `Applications` 바로 가기가 있고, 끌어 넣으면 설치됩니다 |
| `Madi-<판>.zip` | 같은 앱의 ZIP. 나중에 자동 업데이트(Sparkle 같은 것)를 붙이면 이쪽을 씁니다 |
| `SHA256SUMS` | 위 둘의 SHA-256 |
| `release-notes.md` | `CHANGELOG.md`의 그 판 절 + 판 · 빌드 · 커밋 · 체크섬 |
| `*.log`, `notary-*.plist` | 단계마다의 기록. 실패하면 여기를 봅니다 |

## 한 번만 할 일

### 1. 서명 인증서

키체인에 **Developer ID Application** 인증서가 있어야 합니다.

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

하나도 안 나오면 Apple Developer 계정의 Certificates에서 만들어 키체인에 넣습니다. 스크립트는
인증서를 실행할 때 키체인에서 찾습니다. **이름과 팀 ID를 저장소에 적지 않기 위해서입니다.**
여러 개라면 `SIGN_IDENTITY=<SHA-1>`로 고릅니다.

### 2. 공증 자격 증명

1. [appleid.apple.com](https://appleid.apple.com) ▸ 로그인 및 보안 ▸ 앱 암호에서 앱 암호를 하나 만듭니다.
2. 키체인에 넣습니다. 앱 암호는 명령이 물을 때 붙여 넣습니다. 그러면 셸 기록에 남지 않습니다.

   ```sh
   xcrun notarytool store-credentials madi-notary --apple-id <Apple ID> --team-id <팀 ID>
   ```

3. 확인합니다. 오류 없이 지난 제출 목록(처음이면 빈 목록)이 나오면 됩니다.

   ```sh
   xcrun notarytool history --keychain-profile madi-notary
   ```

값은 키체인에만 있고 스크립트는 프로필 이름만 압니다. 이름을 바꿨다면 `NOTARY_PROFILE=<이름>`을 씁니다.

## 판 하나를 내는 순서

1. `project.yml`의 `MARKETING_VERSION`을 올립니다([유의적 버전](https://semver.org/lang/ko/)).
   빌드 번호(`CFBundleVersion`)는 손대지 않습니다. 스크립트가 커밋 수로 넣습니다.
2. `CHANGELOG.md`에 `## [x.y.z] - YYYY-MM-DD` 절을 씁니다. 그 절이 그대로 릴리스 노트가 됩니다.
3. 커밋합니다. 커밋하지 않은 변경이 있으면 스크립트가 멈춥니다.
4. `make release`를 돌립니다. 공증 전까지 1분 반쯤(시험 40초 포함, 2026-11-09)이고, 공증은 두 번
   기다리며 보통 한 번에 몇 분씩입니다.
5. **다른 Mac이나 새로 만든 사용자 계정에서** DMG를 브라우저로 받아(그래야 격리 표시가 붙습니다)
   열고, 앱을 끌어 넣고, 띄워 봅니다. "확인되지 않은 개발자" 창 없이 바로 열려야 합니다.
   문서 하나를 열어 다이어그램 · 수식 · 그림이 보이는지도 봅니다(`docs/samples/madi-sample.md`).
6. 태그를 달고 올립니다.

   ```sh
   git tag -a vX.Y.Z -m "마디 X.Y.Z"
   git push origin vX.Y.Z
   gh release create vX.Y.Z \
     .build/release/X.Y.Z/Madi-X.Y.Z.dmg \
     .build/release/X.Y.Z/Madi-X.Y.Z.zip \
     .build/release/X.Y.Z/SHA256SUMS \
     --title "마디 X.Y.Z" --notes-file .build/release/X.Y.Z/release-notes.md
   ```

태그가 이미 있는 판은 스크립트가 만들지 않습니다. 같은 판 번호로 다른 바이너리가 두 번 나가는
일을 막기 위해서입니다.

## `make release`가 하는 일

| 단계 | 하는 일 | 멈추는 경우 |
|---|---|---|
| 전제 | 판 번호, 태그, 커밋 안 된 변경, `CHANGELOG.md`의 절, 인증서, 공증 자격 증명 | 하나라도 없으면 빌드 전에 멈춥니다 |
| 검사 | `make test` · `make l10n-check` · `make core-only` · 공개 점검(지금 파일) | 하나라도 실패 |
| 빌드 | Release, arm64 + x86_64. 판과 빌드 번호를 넣고 `lipo`로 두 아키텍처를 확인합니다 | 한쪽이 빠졌거나, Info.plist의 판이 다르거나, 디버그용 `Madi.debug.dylib`가 들어 있음 |
| 서명 | Developer ID, 강화된 런타임, 타임스탬프 | 강화된 런타임 · 타임스탬프가 없거나 `get-task-allow`(디버그 권한)가 있음 — 셋 다 공증이 거절합니다 |
| 묶기 | DMG(`hdiutil`, 서명), ZIP(`ditto`) | |
| 공증 | DMG를 올리고 기다린 뒤, 앱에 표를 붙이고(staple), 그 앱으로 DMG를 다시 만들어 다시 공증하고 DMG에도 붙입니다 | `Accepted`가 아님. 이유는 `notary-log.json` |
| 확인 | ZIP을 풀고 DMG를 붙여 그 안의 앱 서명을 다시 확인, `spctl`이 둘 다 `Notarized Developer ID`로 보는지 | 다르면 멈춤 |
| 노트 | `SHA256SUMS`, `release-notes.md` | |

공증을 두 번 하는 이유: DMG 안의 앱에도 표가 붙어 있어야, 받은 사람이 앱을 꺼내 오프라인에서 처음
열어도 Gatekeeper가 통과시킵니다. 처음 DMG의 앱은 표를 붙이기 전의 앱입니다.

### 권한(entitlements) 파일이 없는 이유

샌드박스를 쓰지 않고(`ENABLE_APP_SANDBOX: NO`), 앱 안에 남이 서명한 라이브러리가 없고,
다이어그램을 그리는 웹뷰의 자바스크립트 JIT는 WebKit의 별도 프로세스에서 돕니다. 그래서 강화된
런타임에 예외를 둘 것이 없습니다. 2026-11-09에 Release 빌드를 강화된 런타임으로 서명해 띄워
Mermaid · KaTeX · 앱에 든 글꼴 · 문서 옆 그림 · `madi://` 열기가 모두 되는 것을 봤습니다.
기능을 더하다 막히면(예: 다른 앱을 조종하는 Apple Events) 그때 필요한 권한 하나만 더합니다.

## 시험 삼아 돌리기

```sh
make release NOTARIZE=0                             # 공증만 빼고 끝까지 — 자격 증명 없이
ALLOW_DIRTY=1 SKIP_CHECKS=1 NOTARIZE=0 bash scripts/release.sh   # 고치는 중에 빌드 · 서명 · 묶기만
```

`NOTARIZE=0`으로 만든 것은 이 Mac에서는 열리지만 다른 Mac에서는 Gatekeeper가 막습니다.
`ALLOW_DIRTY=1`로 만든 것은 커밋에 `-dirty`가 붙습니다. 둘 다 배포하지 않습니다.

| 환경 변수 | 기본 | |
|---|---|---|
| `NOTARIZE` | `1` | `0`이면 공증 · 스테이플을 건너뜁니다 |
| `NOTARY_PROFILE` | `madi-notary` | 공증 자격 증명의 키체인 프로필 이름 |
| `SIGN_IDENTITY` | 키체인의 첫 Developer ID Application | 인증서 이름이나 SHA-1 |
| `SKIP_CHECKS` | `0` | `1`이면 시험 · 점검을 건너뜁니다 |
| `ALLOW_DIRTY` | `0` | `1`이면 커밋 안 된 변경이 있어도 만듭니다 |

## 처음 공개하기 전에

판을 처음 낼 때 한 번 볼 것들입니다. 스크립트는 이것을 검사하지 않습니다.

- **커밋 이력.** 정리했습니다(2026-11-09). 소스는 공개 저장소 `ddiiwoong/madi`에 두고 Releases도 거기에
  올립니다. 공개 뒤에도 `make public-check`(이력 포함)가 통과해야 합니다. 걸리면 그 커밋을 올리기 전에 고칩니다.
  한 번 올린 이력은 되돌릴 수 없습니다.
- **앱 아이콘.** 아직 없어서 Finder와 Dock에 기본 아이콘이 나옵니다. 스크립트가 경고만 합니다.
- **라이선스.** Mermaid 번들에 elkjs(EPL-2.0)가 들어 있습니다. EPL-2.0은 받는 사람에게 원본을 얻는 길을
  알리라고 해서, 스크립트가 릴리스 노트 끝에 '포함된 오픈 소스' 절을 붙입니다(글꼴 · 다이어그램 라이선스
  목록과 elkjs 원본 저장소로 가는 링크). 자세한 것은 `Sources/Madi/Resources/Diagrams/README.md`.
- **AI 교정 키.** 개발 빌드(ad-hoc 서명)에서 키체인에 넣은 키는 서명이 다른 Release 앱이 처음
  꺼낼 때 "키체인의 정보를 쓰려고 합니다" 창이 한 번 뜹니다. 받은 사람에게는 해당이 없습니다.
- **자동 업데이트**가 없습니다. 새 판은 받은 사람이 직접 받아 바꿔 넣습니다.
