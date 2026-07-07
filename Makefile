SWIFT = swift
DIST = dist

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
	codesign --force -s - "$(DIST)/Macro Studio.app"
	codesign --force -s - "$(DIST)/MacroStudioAgent.app"

install: app
	rm -rf "/Applications/Macro Studio.app" "/Applications/MacroStudioAgent.app"
	cp -R "$(DIST)/Macro Studio.app" /Applications/
	cp -R "$(DIST)/MacroStudioAgent.app" /Applications/

clean:
	rm -rf .build $(DIST)
