.PHONY: generate build test run clean

DERIVED = build
SCHEME = Dora
APP = "Dora the Explorer.app"

generate:
	xcodegen generate

build: generate
	xcodebuild -project Dora.xcodeproj -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) build | xcbeautify 2>/dev/null || \
	xcodebuild -project Dora.xcodeproj -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) build

test:
	set -o pipefail; xcodebuild test -project Dora.xcodeproj -scheme $(SCHEME) \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) \
		-skipPackagePluginValidation 2>&1 | tail -40
	@for p in Packages/*/; do echo "== $$p"; swift test --package-path "$$p" || exit 1; done

test-packages:
	@for p in Packages/*/; do echo "== $$p"; swift test --package-path "$$p" || exit 1; done

run: build
	open $(DERIVED)/Build/Products/Debug/$(APP)

clean:
	rm -rf $(DERIVED) Dora.xcodeproj
