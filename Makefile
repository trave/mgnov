# mgnov build. `make` → build/Mgnov.app (+ build/mgnov CLI symlink)
APP      := build/Mgnov.app
BIN      := $(APP)/Contents/MacOS/mgnov
SRCS     := $(wildcard Sources/*.swift)
SWIFTC   ?= swiftc
# Sign with a stable identity when one exists so TCC grants survive rebuilds (see `make cert`).
SIGN_ID  ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"mgnov-dev"' | head -1 | tr -d '"')
ifeq ($(SIGN_ID),)
SIGN_ID  := -
endif

.PHONY: all build sign run stop install uninstall cert clean

all: build
build: $(BIN)

$(BIN): $(SRCS) Resources/Info.plist Makefile
	@mkdir -p $(APP)/Contents/MacOS
	$(SWIFTC) -O -swift-version 5 -framework Cocoa -framework Carbon -o $(BIN) $(SRCS)
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@codesign --force --sign "$(SIGN_ID)" --identifier dev.trave.mgnov $(APP)
	@ln -sf Mgnov.app/Contents/MacOS/mgnov build/mgnov
	@if [ "$(SIGN_ID)" = "-" ]; then echo "note: ad-hoc signed. macOS forgets the Accessibility grant on every rebuild; run 'make cert' once to fix that."; fi
	@echo "built $(APP)"

# Re-sign with the current identity (cheap; the build rule does not notice a new certificate)
sign: build
	@codesign --force --sign "$(SIGN_ID)" --identifier dev.trave.mgnov $(APP)
	@codesign -dv $(APP) 2>&1 | grep -E '^(Signature|Authority)=' | head -2

# Development run: launches the app through LaunchServices so TCC attributes permissions to Mgnov.app
run: sign stop
	open -n $(APP)
	@sleep 1; build/mgnov status || true

stop:
	-@pkill -x mgnov 2>/dev/null; sleep 0.3

install: build
	scripts/install.sh

uninstall:
	scripts/uninstall.sh

cert:
	scripts/make-signing-cert.sh

clean:
	rm -rf build
