.PHONY: generate build test run clean

DERIVED = build
SCHEME = Fenestra

generate:
	xcodegen generate

build: generate
	xcodebuild -project Fenestra.xcodeproj -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) build | xcbeautify 2>/dev/null || \
	xcodebuild -project Fenestra.xcodeproj -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) build

test:
	xcodebuild test -project Fenestra.xcodeproj -scheme $(SCHEME) \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) \
		-skipPackagePluginValidation 2>&1 | tail -40
	@for p in Packages/*/; do echo "== $$p"; swift test --package-path "$$p" || exit 1; done

test-packages:
	@for p in Packages/*/; do echo "== $$p"; swift test --package-path "$$p" || exit 1; done

run: build
	open $(DERIVED)/Build/Products/Debug/Fenestra.app

clean:
	rm -rf $(DERIVED) Fenestra.xcodeproj
