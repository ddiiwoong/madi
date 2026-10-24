PROJECT := Md.xcodeproj
SCHEME  := Md
CONFIG  := Debug
BUILD   := .build
DERIVED := $(BUILD)/DerivedData
APP     := $(DERIVED)/Build/Products/$(CONFIG)/Md.app

.PHONY: all generate build test run clean open-log

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

clean:
	rm -rf $(BUILD) $(PROJECT)

open-log:
	@tail -40 $(BUILD)/build.log
