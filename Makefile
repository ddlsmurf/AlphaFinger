.DEFAULT_GOAL := help

.PHONY: help
help: ## List available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

# Harmless unless you build inside a nix shell, in which case it is essential:
# nix exports a macOS SDK that Apple's swiftc rejects outright, and NIX_* / CPATH
# would leak nix headers into a build that must link CoreBluetooth, SwiftUI and
# AppKit. Stripping them makes swift fall back to Xcode's own SDK.
SWIFT_ENV := env -u SDKROOT -u DEVELOPER_DIR -u CPATH -u LIBRARY_PATH \
  -u LD_LIBRARY_PATH -u NIX_CFLAGS_COMPILE -u NIX_LDFLAGS

.PHONY: build
build: ## Build the app
	cd swift && $(SWIFT_ENV) swift build

.PHONY: test
test: ## Run the test suite (no hardware needed)
	cd swift && $(SWIFT_ENV) swift test

.PHONY: app
app: build ## Assemble build/AlphaFinger.app
	rm -rf build/AlphaFinger.app
	mkdir -p build/AlphaFinger.app/Contents/MacOS build/AlphaFinger.app/Contents/Resources
	cp swift/.build/debug/AlphaFinger build/AlphaFinger.app/Contents/MacOS/
	cp swift/Resources/Info.plist build/AlphaFinger.app/Contents/
	cp swift/Resources/AlphaFinger.icns build/AlphaFinger.app/Contents/Resources/
	@echo "built build/AlphaFinger.app -- open it with: open build/AlphaFinger.app"

.PHONY: clean
clean: ## Remove build output
	rm -rf swift/.build build
