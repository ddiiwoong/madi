# 앱에 들어 있는 글꼴

마디의 기본 본문 글꼴과 코드 글꼴이다. 어느 Mac에서도 같은 모양이 나오게 앱에 넣는다.
시작할 때 이 앱에만 등록하고(`BundledFonts.register`), 시스템에는 설치하지 않는다.

| 파일 | 글꼴 | 판 | 라이선스 |
|---|---|---|---|
| `Pretendard-Regular.otf`, `Pretendard-Bold.otf` | Pretendard | 1.3.9 | [SIL OFL 1.1](OFL-Pretendard.txt) — © 2021 Kil Hyung-jin, Reserved Font Name "Pretendard" |
| `IBMPlexMono-Regular.otf`, `-Bold`, `-Italic`, `-BoldItalic` | IBM Plex Mono | 2.5.0 | [SIL OFL 1.1](OFL-IBMPlexMono.txt) — © 2017 IBM Corp., Reserved Font Name "Plex" |

어디서 받았는가(2026-10-31):

- Pretendard: [orioncactus/pretendard v1.3.9](https://github.com/orioncactus/pretendard/releases/tag/v1.3.9)
  `Pretendard-1.3.9.zip`(sha256 `04be351a74d6bf7d60c480a3087e51d185485d35a52023142af1df19eb8c428a`)의
  `public/static/`
- IBM Plex Mono: [IBM/plex @ibm/plex-mono@2.5.0](https://github.com/IBM/plex/releases/tag/%40ibm%2Fplex-mono%402.5.0)
  `ibm-plex-mono.zip`(sha256 `6d23f01257663d8cc49a0d64c22ced630b79e0e2a0ac08a0da86e9a38bbc481c`)의
  `fonts/complete/otf/`

**고치지 않았다.** OFL은 고친 판에 예약 글꼴 이름(Pretendard, Plex)을 쓰지 못하게 한다 — 글꼴
파일을 다듬거나 잘라 내면(서브셋) 이름을 바꿔야 하므로, 원본 그대로 둔다. 라이선스 전문 두 파일은
OFL 2조가 요구하는 것이라 앱과 함께 나가야 한다(지우면 안 된다).

Pretendard는 SemiBold 등 다른 굵기도 있지만 쓰는 것만 넣었다(한 굵기에 1.5MB). Pretendard에는
기울임꼴이 없어 기울임은 강제 기울임(`obliqueness`)으로 그린다.
