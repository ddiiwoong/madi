PROJECT := Md.xcodeproj
SCHEME  := Md
CONFIG  := Debug
BUILD   := .build
DERIVED := $(BUILD)/DerivedData
APP     := $(DERIVED)/Build/Products/$(CONFIG)/Md.app
UNIVERSAL       := $(BUILD)/universal
UNIVERSAL_APP   := $(UNIVERSAL)/Build/Products/Release/Md.app
UNIVERSAL_BIN   := $(UNIVERSAL_APP)/Contents/MacOS/Md

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

clean:
	rm -rf $(BUILD) $(PROJECT)

open-log:
	@tail -40 $(BUILD)/build.log
