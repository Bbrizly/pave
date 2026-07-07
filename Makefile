SWIFT = swift
DIST = dist

# Use the first real codesigning identity so TCC grants survive rebuilds.
# Ad-hoc (-) means macOS re-keys permissions to the binary hash every build,
# which is why Accessibility grants kept dying. Create one identity once:
# Keychain Access > Certificate Assistant > Create a Certificate,
# name "MacroStudio Dev", Self-Signed Root, type Code Signing.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NR==1 {print $$2}')
ifeq ($(SIGN_ID),)
SIGN_ID := -
endif

.PHONY: build test app install clean

build:
	$(SWIFT) build -c release

test:
	$(SWIFT) test

app: build
	rm -rf $(DIST)
	mkdir -p "$(DIST)/Macro Studio.app/Contents/MacOS"
	mkdir -p "$(DIST)/MacroStudioAgent.app/Contents/MacOS"
	cp .build/release/MacroStudio "$(DIST)/Macro Studio.app/Contents/MacOS/MacroStudio"
	cp Support/Editor-Info.plist "$(DIST)/Macro Studio.app/Contents/Info.plist"
	cp .build/release/MacroStudioAgent "$(DIST)/MacroStudioAgent.app/Contents/MacOS/MacroStudioAgent"
	cp Support/Agent-Info.plist "$(DIST)/MacroStudioAgent.app/Contents/Info.plist"
	cp .build/release/macroctl "$(DIST)/macroctl"
	@echo "Signing as: $(SIGN_ID)"
	@if [ "$(SIGN_ID)" = "-" ]; then \
		echo "WARNING: ad-hoc signature. Accessibility grants will NOT survive rebuilds."; \
		echo "Create a 'MacroStudio Dev' code signing cert in Keychain Access (see Makefile header)."; \
	fi
	codesign --force -s "$(SIGN_ID)" "$(DIST)/Macro Studio.app"
	codesign --force -s "$(SIGN_ID)" "$(DIST)/MacroStudioAgent.app"

install: app
	-killall MacroStudioAgent 2>/dev/null || true
	rm -rf "/Applications/Macro Studio.app" "/Applications/MacroStudioAgent.app"
	cp -R "$(DIST)/Macro Studio.app" /Applications/
	cp -R "$(DIST)/MacroStudioAgent.app" /Applications/

clean:
	rm -rf .build $(DIST)
