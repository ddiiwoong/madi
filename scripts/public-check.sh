#!/bin/bash
# 공개 전 점검 — 저장소를 공개하기 전에, 공개되면 안 되는 것이 들어 있는지 본다.
#
#   make public-check            지금 추적되는 파일 + 모든 커밋 이력
#   make public-check HISTORY=0  지금 추적되는 파일만
#
# 공개하면 **이력까지** 나간다. 지금 파일에서 지운 것도 옛 커밋에 남아 있으면 누구나
# 꺼내 볼 수 있으므로 기본으로 이력을 함께 훑는다.
#
# 보는 것:
#   1. 홈 디렉터리 경로(/Users/<이름>, /home/<이름>) — 계정 이름이 박힌다
#   2. 토큰·키 모양(GitHub·AWS·Slack·OpenAI·Google, 개인 키 머리글)
#   3. 사설 IP 주소(10/8, 172.16/12, 192.168/16의 네 마디 꼴)
#   4. 사용자가 정한 금지 낱말 — 소속·실명·내부 호스트명 등. **이 파일에 적지 않는다**
#      (적으면 그 낱말이 공개된다). 추적하지 않는 `.public-check-words`(한 줄에 하나)나
#      환경 변수 MADI_PUBLIC_CHECK_WORDS(쉼표로 가름)에서 읽는다. 커밋 메시지도 본다.
#   5. 추적되면 안 되는 산출물(.build, DerivedData, xcuserdata, 생성된 .xcodeproj, .DS_Store, .env)
#
# 못 보는 것: 남의 코드를 옮겨 온 것처럼 **모양이 없는** 문제. 그런 것은 사람이 읽어야 한다.
#
# 찾은 것이 하나라도 있으면 1로 끝난다.

set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

HISTORY="${HISTORY:-1}"
SELF="scripts/public-check.sh"
found=0

# 시험 코드의 자리 표시 경로처럼 일부러 둔 것. 이름을 붙여 허용한다.
ALLOWED_HOME='/(Users|home)/(someone|Shared)(/|$|[^A-Za-z0-9._-])'

report() {  # report <분류> <grep 출력>
    local kind="$1" lines="$2"
    [ -z "$lines" ] && return
    found=1
    echo "✗ $kind"
    echo "$lines" | head -20 | sed 's/^/    /'
    local count; count=$(echo "$lines" | wc -l | tr -d ' ')
    [ "$count" -gt 20 ] && echo "    … 그리고 $((count - 20))곳 더"
}

# scan <분류> <git grep 인자…> — 지금 파일과(원하면) 이력에서 찾는다.
# 이력의 같은 줄은 커밋마다 나오므로 경로와 내용으로 한 번만 보인다.
# EXCLUDE(확장 정규식)가 있으면 그것에 맞는 줄은 뺀다.
EXCLUDE=""
scan() {
    local kind="$1"; shift
    local now history=""
    local drop="${EXCLUDE:-^\$^}"
    now=$(git grep -I -n "$@" -- . ":!$SELF" 2>/dev/null | grep -vE "$drop")
    if [ "$HISTORY" = "1" ]; then
        history=$(git rev-list --all | while read -r rev; do
            git grep -I -n "$@" "$rev" -- . ":!$SELF" 2>/dev/null
        done | grep -vE "$drop" \
             | awk -F: '{ key = $2 ":" substr($0, index($0, $4)); if (!(key in seen)) { seen[key] = 1; print } }')
    fi
    report "$kind (지금 파일)" "$now"
    # 이력에서만 나오는 것 — 지금 파일에서는 지웠지만 옛 커밋에 남은 것.
    if [ -n "$history" ]; then
        local only
        only=$(echo "$history" | while IFS= read -r line; do
            path=$(echo "$line" | cut -d: -f2)
            text=$(echo "$line" | cut -d: -f4-)
            printf '%s\n' "$now" | grep -qF -- "$path:" && printf '%s\n' "$now" | grep -qF -- "$text" && continue
            echo "$line"
        done)
        report "$kind (이력에만 — 지금 파일에서는 지웠지만 옛 커밋에 남아 있다)" "$only"
    fi
}

echo "공개 전 점검: $(git rev-parse --short HEAD), 추적 파일 $(git ls-files | wc -l | tr -d ' ')개, 커밋 $(git rev-list --all | wc -l | tr -d ' ')개$([ "$HISTORY" = "1" ] || echo ' (이력 건너뜀)')"

# 1. 홈 디렉터리 경로 — 허용한 자리 표시 경로만 있는 줄은 뺀다.
EXCLUDE="$ALLOWED_HOME"
scan "홈 디렉터리 경로" -E -e '/(Users|home)/[A-Za-z0-9._-]+'
EXCLUDE=""

# 2. 토큰·키
scan "토큰·키 모양" -E \
    -e 'ghp_[A-Za-z0-9]{36}' -e 'github_pat_[A-Za-z0-9_]{20,}' \
    -e '(AKIA|ASIA)[0-9A-Z]{16}' -e 'xox[abprs]-[A-Za-z0-9-]{10,}' \
    -e 'sk-[A-Za-z0-9_-]{20,}' -e 'AIza[0-9A-Za-z_-]{35}' \
    -e '-----BEGIN [A-Z ]*PRIVATE KEY-----'

# 3. 사설 IP
scan "사설 IP 주소" -E \
    -e '(^|[^0-9.])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9.]|$)' \
    -e '(^|[^0-9.])192\.168\.[0-9]{1,3}\.[0-9]{1,3}([^0-9.]|$)' \
    -e '(^|[^0-9.])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9.]|$)'

# 4. 금지 낱말
words=()
if [ -f .public-check-words ]; then
    if git ls-files --error-unmatch .public-check-words >/dev/null 2>&1; then
        report "금지 낱말 목록이 추적되고 있다 — 그 낱말들이 공개된다" ".public-check-words"
    fi
    while IFS= read -r word; do
        word="${word%%#*}"; word="$(echo "$word" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$word" ] && words+=("$word")
    done < .public-check-words
fi
if [ -n "${MADI_PUBLIC_CHECK_WORDS:-}" ]; then
    IFS=',' read -ra extra <<< "$MADI_PUBLIC_CHECK_WORDS"
    for word in "${extra[@]}"; do
        word="$(echo "$word" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$word" ] && words+=("$word")
    done
fi
if [ ${#words[@]} -eq 0 ]; then
    echo "· 금지 낱말 없음 — 소속·실명·내부 호스트명을 보려면 .public-check-words에 한 줄에 하나씩 적는다"
else
    args=()
    for word in "${words[@]}"; do args+=(-e "$word"); done
    scan "금지 낱말 (${#words[@]}개)" -i -F "${args[@]}"
    messages=$(git log --all --format='%h %s%n%b' | grep -i -F "${args[@]}")
    report "금지 낱말 (커밋 메시지)" "$messages"
fi

# 5. 추적되면 안 되는 산출물
artifacts=$(git ls-files | grep -E '(^|/)(\.build|DerivedData|xcuserdata)/|\.xcodeproj/|(^|/)\.DS_Store$|(^|/)\.env$')
report "추적되면 안 되는 산출물" "$artifacts"

# 알림 — 실패는 아니지만 공개하면 함께 나가는 것.
echo "· 커밋 작성자(공개하면 함께 나간다):"
git log --all --format='  %an <%ae>' | sort | uniq -c | sed 's/^/   /'

if [ "$found" = "0" ]; then
    echo "✓ 찾은 것 없음"
fi
exit "$found"
