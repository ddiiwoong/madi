#!/bin/bash
# Core만으로 서는 시험 파일을 고른다 — Windows에서 Core 시험을 돌릴 때 쓰는 목록(.github/workflows/platforms.yml).
#
# 고르는 법: AppKit · WebKit 같은 Apple 전용 틀을 import하는 파일을 빼고, 남은 것을 Core 소스와 함께 타입 검사한다.
# 오류가 난 파일(Editor · App의 형을 쓰는 것)을 빼고 다시 — 오류가 없어질 때까지. 손으로 적은 목록은 시험이 늘면
# 낡으므로 판마다 다시 고른다.
#
# 사용: bash scripts/core-tests.sh [출력 파일]   (없으면 표준 출력)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
frameworks="$platform/Developer/Library/Frameworks"
libs="$platform/Developer/usr/lib"

candidates=()
for file in Tests/MadiTests/*.swift; do
    if grep -qE '^(@preconcurrency )?import (AppKit|Cocoa|WebKit|SwiftUI|Translation|UniformTypeIdentifiers|CoreText|Security|CryptoKit)' "$file"; then
        continue
    fi
    candidates+=("$file")
done

work="$(mktemp -d "${TMPDIR:-/tmp}/madi-core-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# 몇 파일은 `@testable import Madi`를 쓴다 — 여기서는 Core와 한 모듈로 컴파일하므로 그 줄을 뺀 사본을 검사한다.
mkdir -p "$work/tests"
for file in "${candidates[@]}"; do
    grep -vE '^@testable import Madi$' "$file" > "$work/tests/$(basename "$file")"
done
for _ in $(seq 1 30); do
    [[ ${#candidates[@]} -gt 0 ]] || break
    copies=()
    for file in "${candidates[@]}"; do copies+=("$work/tests/$(basename "$file")"); done
    if xcrun swiftc -typecheck -swift-version 6 -module-name MadiCoreTests -F "$frameworks" -I "$libs" \
        Sources/Madi/Core/*.swift "${copies[@]}" > "$work/log" 2>&1; then
        break
    fi
    failing="$(sed -n 's#^.*/tests/\([^/:]*\.swift\):[0-9]*:[0-9]*: error:.*#\1#p' "$work/log" | sort -u)"
    if [[ -z "$failing" ]]; then
        cat "$work/log" >&2
        echo "core-tests: 시험 파일이 아닌 곳에서 오류가 났습니다" >&2
        exit 1
    fi
    kept=()
    for file in "${candidates[@]}"; do
        if ! grep -qxF "$(basename "$file")" <<< "$failing"; then kept+=("$file"); fi
    done
    candidates=("${kept[@]}")
done

if [[ $# -gt 0 ]]; then
    printf '%s\n' "${candidates[@]}" > "$1"
else
    printf '%s\n' "${candidates[@]}"
fi
echo "core-tests: ${#candidates[@]}개 파일이 Core만으로 섭니다" >&2
