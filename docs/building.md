# 빌드와 기여

## 준비물

| | |
|---|---|
| macOS | 14 이상에서 **돌고**, 빌드는 최신 Xcode가 있는 Mac에서 합니다 |
| Xcode | 26 이상 (Swift 6 언어 모드) |
| xcodegen | `brew install xcodegen` |

`.xcodeproj`는 **생성물이고 저장소에 없습니다.** `project.yml`이 유일한 출처이고 모든
`make` 타깃이 먼저 `xcodegen`을 돌립니다. 프로젝트 설정을 바꿀 때는 Xcode의 빌드 설정 창이
아니라 `project.yml`을 고치십시오 — 전자는 다음 `make`에서 사라집니다.

## 타깃

```sh
make build       # 빌드. 로그는 .build/build.log
make test        # 테스트 598개. 로그는 .build/test.log
make run         # 빌드 후 실행
make core-only   # Core가 Foundation만으로 서는지 (아래 참고)
make universal   # Release, arm64 + x86_64, lipo로 검사까지
make public-check  # 공개 전 점검 — 추적 파일과 모든 커밋 이력 (아래 참고)
make l10n-check    # 영어 표가 소스의 화면 글자와 맞는지 (아래 참고)
make screenshots   # README 그림을 실제 편집기로 다시 그림 (docs/images/)
make clean       # .build와 생성된 .xcodeproj 삭제
make open-log    # 마지막 빌드 로그 꼬리
```

### `make public-check`가 보는 것

공개하면 지금 파일만이 아니라 **모든 커밋 이력**이 나갑니다. 그래서 둘 다 훑어 홈
디렉터리 경로, 토큰·키 모양, 사설 IP, 추적되면 안 되는 산출물을 찾고, 하나라도 있으면
실패합니다. 지금 파일만 보려면 `make public-check HISTORY=0`.

소속·실명·내부 호스트명처럼 **모양이 없는** 것은 직접 적어야 찾습니다. 저장소 맨 위에
`.public-check-words`를 만들어 한 줄에 하나씩 적으십시오. 이 파일은 `.gitignore`에 있습니다 —
저장소에 적으면 그 낱말이 공개되기 때문입니다.

바꾼 뒤 최소한 `make test`와 `make core-only`는 돌려 주십시오. 둘 다 빠릅니다.

### 화면 글자를 더하거나 고칠 때

화면에 보이는 글자는 `String(localized: "한국어 문장")`으로 씁니다. 키가 곧 한국어 글자이고
(한국어가 개발 언어), 영어는 `Sources/Madi/Resources/en.lproj/Localizable.strings`에 같은 키로
적습니다. 보간은 그대로 씁니다 — `String(localized: "그림 \(n)개")`의 키는 `"그림 %lld개"`입니다.

키를 손으로 맞추지 말고 `make l10n-check`를 돌리십시오. 컴파일러가 뽑은 키와 표를 맞춰
**빠진 키**(영어 화면에 한국어가 나온다), **남은 키**(고치기 전 문장의 번역), **형식 지정자가
어긋난 키**를 줄 번호와 함께 알려 줍니다. 같은 한국어 낱말이 영어로 갈리면
`String(localized: "lineSpacing.tight", defaultValue: "좁게")`처럼 키를 따로 둡니다.

영어 화면을 직접 보려면 설정 ▸ 일반 ▸ 화면 언어에서 English를 고르고 다시 여십시오.
한 번만 보려면 `.build/DerivedData/Build/Products/Debug/Madi.app/Contents/MacOS/Madi -AppleLanguages '(en)'`.

### `make core-only`가 하는 일

`Sources/Madi/Core/`의 파일만 따로 타입 체크합니다. 거기에 AppKit 타입이 들어오면 실패합니다.
이유와 이 검사의 맹점은 [구조 안내](architecture.md#불변식-1--core는-foundation만-쓴다)에
적었고, Makefile 주석에도 같은 내용이 있습니다.

### `make universal`이 검사까지 하는 이유

`ONLY_ACTIVE_ARCH=NO`를 빼먹거나 툴체인이 한쪽을 조용히 떨어뜨리면 **빌드는 성공하고
산출물만 단일 아키텍처**가 됩니다. 그걸 배포하면 한쪽 Mac에서 아예 실행되지 않습니다.
그래서 `lipo -archs`로 둘 다 들었는지 확인하고 아니면 실패시킵니다.

참고로 macOS 26이 Intel을 지원하는 마지막 버전이라, 유니버설 빌드의 쓸모에는 만료 시점이
있습니다.

## 서명

기본값은 ad-hoc(`CODE_SIGN_IDENTITY=-`)입니다. 직접 빌드한 Mac에서는 그대로 돌지만 다른
Mac에 건네면 Gatekeeper가 막습니다. 배포하려면 Developer ID 서명과 공증이 따로 필요하고,
아직 그 길을 만들지 않았습니다.

## 빌드가 멈추면

`Resolve Package Graph`에서 영원히 멈추고 열린 소켓이 0개라면 네트워크 문제가 아닙니다.
`git fsmonitor--daemon`이 `xcodebuild`의 출력 파이프를 물고 놓지 않아 EOF가 오지 않는
경우가 있습니다. 매달린 데몬만 종료하면 즉시 풀리고, 재발은 이렇게 막습니다:

```sh
git config --local core.fsmonitor false
```

## 고칠 때 지켜야 하는 것

[구조 안내](architecture.md)에 불변식 두 개가 있습니다. 요약하면:

1. **`Core`는 Foundation만 씁니다.** AppKit에 닿는 코드는 위 층으로.
2. **저장되는 것은 사용자가 쓴 그대로입니다.** 보여 주기를 바꾸되 글자는 건드리지 않습니다.
   원문을 고쳐서 화면을 맞추는 방법이 더 쉬워 보이면, 그게 바로 이 저장소가 거절한
   방법입니다.

그리고 **UI를 바꿨으면 실제로 띄워 눈으로 보십시오.** 테스트가 전부 통과하는 상태에서
화면만 틀렸던 버그가 여럿 있었습니다.

## 테스트를 쓸 때

`Core`에 파일을 더하면 테스트 타깃이 자동으로 집어 갑니다(`Sources/Madi/Core`를 소스로
컴파일합니다). `@testable import`는 쓰지 않습니다 — 이유는 구조 안내에 있습니다.

이 저장소에서 지키는 테스트 습관 둘:

- **고장나는 것을 먼저 확인합니다.** 결함을 다시 넣어 빨개지는지 보지 않은 가드는 아무것도
  보장하지 않습니다. 실제로 `-parse`로 쓴 `core-only`와 ZIP의 CRC 검사가 둘 다 "통과하지만
  아무것도 검사하지 않는" 상태였던 적이 있습니다.
- **픽스처의 전제를 테스트로 적습니다.** 어떤 입력이 몇 조각으로 나뉘는지에 의존하는
  어서션을 쓸 때는 그 개수 자체를 재는 테스트를 함께 둡니다. 없으면 알고리즘이 바뀔 때
  다른 어서션들이 엉뚱한 것을 보면서 통과합니다.

## 커밋

한 커밋에 한 가지. 제목은 무엇을 했는지, 본문은 **왜 그렇게 했는지와 무엇을 재서
알았는지**를 적습니다 — 이 저장소의 기존 커밋이 그 형식입니다. 측정한 숫자가 있으면
넣어 주십시오.
