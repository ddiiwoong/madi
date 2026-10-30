PROJECT := Madi.xcodeproj
SCHEME  := Madi
CONFIG  := Debug
BUILD   := .build
DERIVED := $(BUILD)/DerivedData
APP     := $(DERIVED)/Build/Products/$(CONFIG)/Madi.app
UNIVERSAL       := $(BUILD)/universal
UNIVERSAL_APP   := $(UNIVERSAL)/Build/Products/Release/Madi.app
UNIVERSAL_BIN   := $(UNIVERSAL_APP)/Contents/MacOS/Madi

.PHONY: all generate build test run clean open-log universal

all: build

# project.yml is the source of truth; the .xcodeproj is generated and gitignored.
generate:
	@command -v xcodegen >/dev/null || { echo "xcodegen가 없습니다: brew install xcodegen"; exit 1; }
	xcodegen generate --spec project.yml

build: generate
	@mkdir -p $(BUILD)
	@xcodebuild \
		-project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
		build > $(BUILD)/build.log 2>&1; \
	status=$$?; \
	grep -E "error:" $(BUILD)/build.log | sort -u | head -30 || true; \
	grep -cE "warning:" $(BUILD)/build.log | sed 's/^/warnings: /'; \
	if ! grep -q "\*\* BUILD SUCCEEDED \*\*" $(BUILD)/build.log; then \
		echo "BUILD FAILED (exit $$status) — $(BUILD)/build.log"; exit 1; \
	fi
	@echo "built: $(APP)"

test: generate
	@mkdir -p $(BUILD)
	@xcodebuild \
		-project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) \
		-destination 'platform=macOS' \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
		test > $(BUILD)/test.log 2>&1; \
	grep -E "error:" $(BUILD)/test.log | sort -u | head -20 || true; \
	grep -E "^Test Case .* failed|Executed .* test" $(BUILD)/test.log | tail -5 || true; \
	if ! grep -q "\*\* TEST SUCCEEDED \*\*" $(BUILD)/test.log; then \
		echo "TEST FAILED — $(BUILD)/test.log"; exit 1; \
	fi

run: build
	open "$(APP)"

# Intel + Apple Silicon 한 묶음. Release로 만든다 — 유니버설은 배포용이고
# Debug 유니버설은 쓸 데가 없다.
#
# `lipo -archs` 검사가 이 타깃의 요점이다. `ONLY_ACTIVE_ARCH=NO`를 빼먹거나
# 툴체인이 한쪽을 조용히 떨어뜨리면 **빌드는 성공하고 산출물만 단일 아키텍처**가 된다.
# 그걸 배포하면 한쪽 Mac에서 아예 실행되지 않는다. 그래서 둘 다 들었는지 확인하고
# 아니면 실패시킨다.
universal: generate
	@mkdir -p $(BUILD)
	@xcodebuild \
		-project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(UNIVERSAL) \
		ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
		build > $(BUILD)/universal.log 2>&1; \
	status=$$?; \
	grep -E "error:" $(BUILD)/universal.log | sort -u | head -30 || true; \
	if ! grep -q "\*\* BUILD SUCCEEDED \*\*" $(BUILD)/universal.log; then \
		echo "UNIVERSAL BUILD FAILED (exit $$status) — $(BUILD)/universal.log"; exit 1; \
	fi
	@test -f "$(UNIVERSAL_BIN)" || { echo "실행 파일이 없습니다: $(UNIVERSAL_BIN)"; exit 1; }
	@archs="$$(lipo -archs "$(UNIVERSAL_BIN)")"; \
	echo "아키텍처: $$archs"; \
	for want in arm64 x86_64; do \
		case " $$archs " in *" $$want "*) ;; \
			*) echo "$$want가 빠졌습니다 — 유니버설이 아닙니다"; exit 1 ;; \
		esac; \
	done; \
	echo "universal: $(UNIVERSAL_APP)"

# Core가 **Foundation만으로 서는지** 확인한다.
#
# 이 불변식은 조용히 깨진다. `ImageReference`에 `CGSize`를 쓴 적이 있는데, 앱 빌드에서는
# 같은 모듈의 AppKit이 CoreGraphics를 끌어와 아무 오류도 나지 않았다. Core만 따로
# 컴파일했을 때 비로소 드러났다. 다른 플랫폼으로 옮길 수 있다는 TODO의 전제가
# 이 한 줄로 깨지므로 타깃으로 지킨다.
#
# `-parse`가 아니라 `-typecheck`를 쓴다. 처음에 `-parse`로 썼더니 Core에 AppKit
# 타입을 일부러 넣어도 **통과했다** — 구문만 보고 타입 이름을 풀지 않기 때문이다.
# 실패하지 못하는 검사는 없는 것보다 나쁘므로 양쪽을 다 시험해 골랐다.
#
# 무엇을 잡는지 실측했다(2026-10-25):
#   NSColor      → 잡음
#   NSView       → 잡음
#   CGSize.zero  → 잡음   (실제로 깨졌던 바로 그 경우)
#   CGFloat      → 못 잡음 (macOS의 Foundation이 이미 노출한다)
# 맨 `CGFloat`은 Double의 다른 이름이라 이식에 걸림돌이 아니고, 걸림돌이 되는
# AppKit 타입과 CoreGraphics API는 잡힌다.
#
# **맹점**: 이 검사는 "macOS에서 AppKit 없이 서는지"를 보는 것이고 "다른 플랫폼으로
# 옮길 수 있는지"를 보는 것이 아니다. `import Compression`을 Core에 넣어도 통과한다 —
# macOS SDK에 있기 때문이다. 그러나 Windows에는 없다. 그래서 압축 해제는 검사에
# 기대지 않고 **설계로** Core 밖에 뒀다(`Services/Inflate.swift`, 주입해서 쓴다).
.PHONY: core-only
core-only:
	@rm -rf $(BUILD)/core-only && mkdir -p $(BUILD)/core-only
	@cp Sources/Madi/Core/*.swift $(BUILD)/core-only/
	@cd $(BUILD)/core-only && swiftc -swift-version 6 -typecheck *.swift > parse.log 2>&1; \
	status=$$?; \
	if [ $$status -ne 0 ]; then \
		echo "Core가 Foundation만으로 서지 않습니다:"; \
		grep "error:" parse.log | head -10; \
		echo "Core가 AppKit 없이 서지 못합니다. AppKit 타입(NSColor·NSView…)이나"; \
		echo "CoreGraphics API(CGSize.zero…)가 들어왔는지 보세요. 평범한 컴파일 오류일 수도 있습니다."; \
		exit 1; \
	fi
	@echo "core-only: Core $$(ls Sources/Madi/Core/*.swift | wc -l | tr -d ' ')개 파일이 Foundation만으로 섭니다"

# 공개 전 점검 — 공개하면 나가는 것(추적 파일 + **모든 커밋 이력**)에 홈 경로·토큰·사설 IP·
# 금지 낱말·산출물이 있는지 본다. 금지 낱말(소속·실명 등)은 추적하지 않는 `.public-check-words`에
# 적는다 — 이 저장소에 적으면 그 낱말이 공개된다. 지금 파일만 보려면 `HISTORY=0`.
# 문제를 하나씩 넣어 잡히는지 확인했다(토큰·키·개인 키·사설 IP·홈 경로·.DS_Store·금지 낱말
# 파일/환경 변수/커밋 메시지·지운 뒤 이력에만 남은 토큰, 그리고 아무것도 없는 기준선).
HISTORY ?= 1
.PHONY: public-check
public-check:
	@HISTORY=$(HISTORY) bash scripts/public-check.sh

# README·기능 안내의 그림을 실제 편집기로 다시 그린다(docs/images/*.png). 공개용 샘플 문서
# `docs/images/sample.md`만 그린다 — 앱 창을 찍으면 최근 문서·파일 목록이 함께 찍힌다.
# 화면을 바꾸는 변경 뒤에 돌려 그림이 거짓이 되지 않게 한다.
.PHONY: screenshots
screenshots:
	@mkdir -p $(BUILD)/screenshots
	@swiftc -O -swift-version 6 -module-name Madi -o $(BUILD)/screenshots/render \
		Sources/Madi/Core/*.swift Sources/Madi/Editor/*.swift \
		Sources/Madi/App/AppLog.swift Sources/Madi/App/AppEnvironment.swift \
		scripts/screenshots/main.swift
	@$(BUILD)/screenshots/render docs/images/sample.md docs/images

clean:
	rm -rf $(BUILD) $(PROJECT)

open-log:
	@tail -40 $(BUILD)/build.log
