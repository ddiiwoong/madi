#!/bin/bash
# 릴리스 만들기 — 검사 → 유니버설 Release 빌드 → Developer ID 서명 → DMG · ZIP → 공증 → 스테이플 → 확인.
#
#   make release              project.yml의 MARKETING_VERSION으로 만든다(공증까지)
#   make release NOTARIZE=0   공증 없이(서명까지) — 파이프라인을 시험할 때. 다른 Mac에서는 Gatekeeper가 막는다
#   make release SKIP_CHECKS=1  검사를 건너뛴다 — 방금 돌렸을 때만
#
# 태그를 달거나, 올리거나, 공개하지 않는다. 그것은 사람이 결과를 확인한 뒤에 한다(docs/releasing.md).
#
# 환경 변수:
#   SIGN_IDENTITY   서명할 인증서(이름이나 SHA-1). 없으면 키체인의 "Developer ID Application"을 하나 찾는다.
#                   이름과 팀 ID를 이 저장소에 적지 않으려고 실행할 때 찾는다.
#   NOTARY_PROFILE  공증 자격 증명의 키체인 프로필 이름(기본 madi). 한 번 만들어 둔다:
#                   xcrun notarytool store-credentials madi --apple-id <Apple ID> --team-id <팀 ID>
#                   (앱 암호를 묻는다 — 값은 키체인에만 남고 이 스크립트는 읽지 않는다)
#   NOTARIZE        1(기본) 또는 0.
#   SKIP_CHECKS     1이면 시험 · 점검을 건너뛴다.
#   ALLOW_DIRTY     1이면 고친 파일이 있어도 만든다(시험용 — 나온 것을 배포하지 않는다).
#
# 나오는 곳: .build/release/<판>/ — Madi.app, Madi-<판>.dmg, Madi-<판>.zip, SHA256SUMS, release-notes.md, 로그들.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NOTARIZE="${NOTARIZE:-1}"
SKIP_CHECKS="${SKIP_CHECKS:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-madi}"

step() { printf '\n▶ %s\n' "$*"; }
size() { ls -lh "$1" | awk '{print $5}'; }  # 끝의 목록(ls -lh)과 같은 숫자 — du는 할당 블록을 세어 다르게 나온다
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }
ok() { printf '  ✓ %s\n' "$*"; }

# ─── 1. 판과 전제 ────────────────────────────────────────────────────────────
step "판과 전제"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "project.yml의 MARKETING_VERSION이 x.y.z 꼴이 아닙니다: '$VERSION'"
BUILD_NUMBER="$(git rev-list --count HEAD)"
TAG="v$VERSION"
ok "판 $VERSION (빌드 번호 $BUILD_NUMBER — 커밋 수라 늘 커진다)"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "태그 $TAG가 이미 있습니다 — project.yml의 MARKETING_VERSION을 올리십시오"
fi
if [[ "$ALLOW_DIRTY" != 1 && -n "$(git status --porcelain)" ]]; then
    git status --short | head -10
    fail "커밋하지 않은 변경이 있습니다 — 릴리스는 커밋된 것만 만듭니다(시험이면 ALLOW_DIRTY=1)"
fi
COMMIT="$(git rev-parse --short HEAD)"
[[ "$ALLOW_DIRTY" == 1 && -n "$(git status --porcelain)" ]] && COMMIT="$COMMIT-dirty"
ok "커밋 $COMMIT"

grep -q "^## \[$VERSION\]" CHANGELOG.md || fail "CHANGELOG.md에 '## [$VERSION]' 절이 없습니다 — 이 판의 바뀐 점을 먼저 적으십시오"
ok "CHANGELOG.md에 $VERSION 절이 있다"

for tool in xcodegen xcodebuild codesign hdiutil ditto lipo shasum; do
    command -v "$tool" >/dev/null || fail "$tool이 없습니다"
done

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application:.*$/\1/p' | head -1)"
fi
[[ -n "$SIGN_IDENTITY" ]] || fail "키체인에 'Developer ID Application' 인증서가 없습니다 — docs/releasing.md의 '한 번만 할 일'"
ok "서명 인증서를 찾았다"

if [[ "$NOTARIZE" == 1 ]]; then
    xcrun --find notarytool >/dev/null 2>&1 || fail "notarytool이 없습니다(Xcode 13 이상)"
    # 자격 증명이 있는지 미리 본다 — 빌드를 다 하고 나서 막히지 않게. 값은 읽지 않는다.
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        fail "공증 자격 증명이 키체인에 없거나 쓸 수 없습니다(프로필 이름 $NOTARY_PROFILE) — docs/releasing.md의 '한 번만 할 일'
  (공증 없이 시험하려면 NOTARIZE=0)"
    fi
    ok "공증 자격 증명 '$NOTARY_PROFILE'"
fi

OUT=".build/release/$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
APP="$OUT/Madi.app"
DMG="$OUT/Madi-$VERSION.dmg"
ZIP="$OUT/Madi-$VERSION.zip"

# ─── 2. 검사 ────────────────────────────────────────────────────────────────
if [[ "$SKIP_CHECKS" == 1 ]]; then
    step "검사 — 건너뜀(SKIP_CHECKS=1)"
else
    step "검사 — 시험 · 영어 표 · Core · 공개 점검(지금 파일)"
    make test > "$OUT/test.log" 2>&1 || { tail -20 "$OUT/test.log"; fail "시험이 실패했습니다 — $OUT/test.log"; }
    ok "$(grep -E 'Executed [0-9]+ tests' "$OUT/test.log" | tail -1 | sed 's/^[[:space:]]*//')"
    make l10n-check > "$OUT/l10n.log" 2>&1 || { tail -20 "$OUT/l10n.log"; fail "영어 표가 맞지 않습니다"; }
    ok "영어 표"
    make core-only > "$OUT/core.log" 2>&1 || { tail -10 "$OUT/core.log"; fail "Core가 Foundation만으로 서지 않습니다"; }
    ok "Core"
    HISTORY=0 bash scripts/public-check.sh > "$OUT/public.log" 2>&1 || { tail -20 "$OUT/public.log"; fail "공개 점검에 걸렸습니다"; }
    ok "공개 점검(지금 파일)"
fi

# ─── 3. 빌드 ────────────────────────────────────────────────────────────────
step "빌드 — Release, arm64 + x86_64"
xcodegen generate --spec project.yml --quiet
DERIVED=".build/release/DerivedData"
# 서명은 빌드 뒤에 따로 한다 — 빌드 설정의 서명은 팀 · 프로필 설정에 얽혀 실패할 길이 많고, 직접 하면 한 줄이다.
xcodebuild -project Madi.xcodeproj -scheme Madi -configuration Release -derivedDataPath "$DERIVED" \
    ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
    clean build > "$OUT/build.log" 2>&1 || { grep -E "error:" "$OUT/build.log" | sort -u | head -20; fail "빌드 실패 — $OUT/build.log"; }
ditto "$DERIVED/Build/Products/Release/Madi.app" "$APP"

archs="$(lipo -archs "$APP/Contents/MacOS/Madi")"
for want in arm64 x86_64; do
    [[ " $archs " == *" $want "* ]] || fail "$want가 빠졌습니다(들어 있는 것: $archs)"
done
ok "아키텍처: $archs"
plist="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$VERSION" ]] || fail "Info.plist의 판이 $VERSION이 아닙니다"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$BUILD_NUMBER" ]] || fail "Info.plist의 빌드 번호가 $BUILD_NUMBER가 아닙니다"
ok "Info.plist: $VERSION ($BUILD_NUMBER), $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
# 시험 · 미리보기용 조각이 Release에 들어오면 안 된다.
for stray in Madi.debug.dylib __preview.dylib; do
    [[ ! -e "$APP/Contents/MacOS/$stray" ]] || fail "Release에 $stray가 들어 있습니다"
done
if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist" >/dev/null 2>&1 \
   && ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$plist" >/dev/null 2>&1; then
    printf '  ! 앱 아이콘이 없습니다 — Finder와 Dock에 기본 아이콘으로 보입니다\n'
fi

# ─── 4. 서명 ────────────────────────────────────────────────────────────────
step "서명 — Developer ID, 강화된 런타임, 타임스탬프"
# 안쪽부터 — 앱 안의 다른 실행 코드(지금은 없다)를 먼저, 앱을 마지막에.
while IFS= read -r -d '' nested; do
    if file -b "$nested" | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$nested"
        ok "안쪽: ${nested#$APP/}"
    fi
done < <(find "$APP/Contents" -type f -perm -u+x ! -path "*/MacOS/Madi" -print0)
# 빌드가 단 ad-hoc 서명을 갈아 끼운다("replacing existing signature"는 그 알림이라 로그로 보낸다).
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP" 2> "$OUT/codesign.log" \
    || { cat "$OUT/codesign.log"; fail "서명 실패"; }
codesign --verify --deep --strict --verbose=2 "$APP" > "$OUT/codesign-verify.log" 2>&1 \
    || { cat "$OUT/codesign-verify.log"; fail "서명 확인 실패"; }
details="$(codesign -dvv "$APP" 2>&1)"
[[ "$details" == *"flags=0x10000(runtime)"* ]] || fail "강화된 런타임이 켜지지 않았습니다"
[[ "$details" == *"Timestamp="* ]] || fail "타임스탬프가 없습니다(공증이 거절한다)"
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
    fail "get-task-allow 권한이 들어 있습니다(공증이 거절한다)"
fi
ok "서명 확인: 강화된 런타임 · 타임스탬프 · 디버그 권한 없음"

# ─── 5. 묶기 ────────────────────────────────────────────────────────────────
make_dmg() {
    local stage="$OUT/dmg-stage"
    rm -rf "$stage" && mkdir -p "$stage"
    ditto "$APP" "$stage/Madi.app"
    ln -s /Applications "$stage/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname "Madi $VERSION" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"
    rm -rf "$stage"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
}
make_zip() {
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
}

step "묶기 — DMG(끌어서 Applications로) · ZIP"
make_dmg
ok "$(basename "$DMG") ($(size "$DMG"))"

# ─── 6. 공증 ────────────────────────────────────────────────────────────────
if [[ "$NOTARIZE" == 1 ]]; then
    step "공증 — Apple에 올리고 기다린다(보통 몇 분)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist \
        > "$OUT/notary-submit.plist" 2> "$OUT/notary-submit.err" || true
    status="$(plutil -extract status raw "$OUT/notary-submit.plist" 2>/dev/null || echo "알 수 없음")"
    id="$(plutil -extract id raw "$OUT/notary-submit.plist" 2>/dev/null || echo "")"
    if [[ -n "$id" ]]; then
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" "$OUT/notary-log.json" >/dev/null 2>&1 || true
    fi
    [[ "$status" == "Accepted" ]] || { cat "$OUT/notary-submit.err" 2>/dev/null; fail "공증이 '$status'입니다 — $OUT/notary-log.json"; }
    ok "공증 통과(제출 $id)"

    step "스테이플 — 공증 표를 앱과 DMG에 붙인다(인터넷 없이도 Gatekeeper가 통과시키게)"
    xcrun stapler staple -q "$APP" || fail "앱에 스테이플 실패"
    # DMG는 스테이플한 앱으로 다시 만들고 다시 공증한다 — 그래야 DMG 안의 앱에도 표가 붙어 있다.
    make_dmg
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist \
        > "$OUT/notary-submit-dmg.plist" 2>/dev/null || true
    [[ "$(plutil -extract status raw "$OUT/notary-submit-dmg.plist" 2>/dev/null)" == "Accepted" ]] \
        || fail "다시 만든 DMG의 공증이 통과하지 못했습니다"
    xcrun stapler staple -q "$DMG" || fail "DMG에 스테이플 실패"
    xcrun stapler validate -q "$APP" && xcrun stapler validate -q "$DMG" || fail "스테이플 확인 실패"
    ok "앱 · DMG에 표가 붙었다"
else
    step "공증 — 건너뜀(NOTARIZE=0). 이 결과물은 다른 Mac에서 Gatekeeper가 막는다 — 배포하지 마십시오"
fi
make_zip
ok "$(basename "$ZIP") ($(size "$ZIP"))"

# 묶은 것 안의 앱이 그대로인지 — 압축 · 디스크 이미지가 확장 속성이나 링크를 떨어뜨리면 서명이 깨진다.
step "묶은 것 안의 앱"
check="$(mktemp -d "${TMPDIR:-/tmp}/madi-release.XXXXXX")"
ditto -x -k "$ZIP" "$check/zip"
codesign --verify --deep --strict "$check/zip/Madi.app" 2> "$OUT/verify-zip.log" \
    || { cat "$OUT/verify-zip.log"; fail "ZIP 안의 앱 서명이 깨졌습니다"; }
ok "ZIP: 서명 그대로"
mnt="$check/dmg"
mkdir -p "$mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$DMG"
dmg_ok=1
codesign --verify --deep --strict "$mnt/Madi.app" 2> "$OUT/verify-dmg.log" || dmg_ok=0
[[ -L "$mnt/Applications" ]] || dmg_ok=0
hdiutil detach -quiet "$mnt" || hdiutil detach -quiet -force "$mnt"
[[ "$dmg_ok" == 1 ]] || { cat "$OUT/verify-dmg.log"; fail "DMG 안의 앱 서명이 깨졌거나 Applications 바로 가기가 없습니다"; }
ok "DMG: 서명 그대로, Applications 바로 가기"
rm -rf "$check"

# ─── 7. Gatekeeper 확인 ─────────────────────────────────────────────────────
step "Gatekeeper가 보는 것"
spctl --assess --type execute -vv "$APP" > "$OUT/spctl-app.log" 2>&1 || true
spctl --assess --type open --context context:primary-signature -vv "$DMG" > "$OUT/spctl-dmg.log" 2>&1 || true
app_source="$(sed -n 's/^source=//p' "$OUT/spctl-app.log")"
dmg_source="$(sed -n 's/^source=//p' "$OUT/spctl-dmg.log")"
ok "앱: ${app_source:-?} · DMG: ${dmg_source:-?}"
if [[ "$NOTARIZE" == 1 ]]; then
    [[ "$app_source" == "Notarized Developer ID" && "$dmg_source" == "Notarized Developer ID" ]] \
        || fail "공증한 결과물을 Gatekeeper가 받지 않습니다 — $OUT/spctl-*.log"
fi

# ─── 8. 체크섬 · 릴리스 노트 ───────────────────────────────────────────────
step "체크섬 · 릴리스 노트"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS)
ok "SHA256SUMS"
awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" { on = 1; next }
    on && /^## \[/ { exit }
    on { print }
' CHANGELOG.md | sed -e '/./,$!d' > "$OUT/release-notes.md"
{
    printf '\n---\n\n'
    # 형식이 '-'로 시작하면 printf가 옵션으로 읽는다 — '--'로 끊는다.
    printf -- '- 판 %s (빌드 %s, 커밋 %s)\n' "$VERSION" "$BUILD_NUMBER" "$COMMIT"
    printf -- '- macOS %s 이상, Apple 실리콘 · Intel\n' "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"
    printf -- '- SHA-256\n\n```\n%s\n```\n' "$(cat "$OUT/SHA256SUMS")"
    # 앱에 든 남의 것. elkjs(Mermaid 번들 안)는 EPL-2.0이라 목적 코드를 나눠 줄 때 원본을 얻는 길을
    # 알려야 한다(3.2절) — 릴리스 노트가 받는 사람이 반드시 보는 곳이다. 목록은 태그 시점의 README로 잇는다.
    repo="$(git remote get-url origin 2>/dev/null | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')"
    repo="${repo:-https://github.com/ddiiwoong/madi}"
    printf '\n### 포함된 오픈 소스\n\n'
    printf -- '- 글꼴: Pretendard · IBM Plex Mono — SIL OFL 1.1 ([목록과 라이선스](%s/blob/%s/Sources/Madi/Resources/Fonts/README.md))\n' "$repo" "$TAG"
    printf -- '- 다이어그램 · 수식: Mermaid · KaTeX — MIT ([목록과 라이선스](%s/blob/%s/Sources/Madi/Resources/Diagrams/README.md))\n' "$repo" "$TAG"
    printf -- '- Mermaid 번들에 든 elkjs는 [Eclipse Public License 2.0](https://www.eclipse.org/legal/epl-2.0/)을 따르며, 원본 코드는 그 라이선스로 [kieler/elkjs](https://github.com/kieler/elkjs)에서 받을 수 있습니다.\n'
} >> "$OUT/release-notes.md"
ok "release-notes.md (CHANGELOG.md의 $VERSION 절)"

step "끝 — $OUT"
ls -lh "$OUT" | sed -n '2,$p' | awk '{printf "  %s  %s\n", $5, $9}'
if [[ "$NOTARIZE" == 1 ]]; then
    printf '\n다음: 다른 Mac(또는 새 사용자 계정)에서 DMG를 열어 보고, 괜찮으면 태그를 달고 올립니다 — docs/releasing.md\n'
fi
