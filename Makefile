SWIFT = swift
DIST = dist

# Use the first real codesigning identity so TCC grants survive rebuilds.
# Ad-hoc (-) means macOS re-keys permissions to the binary hash every build,
# which is why Accessibility grants kept dying. Create one identity once:
# Keychain Access > Certificate Assistant > Create a Certificate,
# name "Pave Dev", Self-Signed Root, type Code Signing.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NR==1 {print $$2}')
ifeq ($(SIGN_ID),)
SIGN_ID := -
endif

EDITOR_ID = com.bbrizly.pave
AGENT_ID  = com.bbrizly.pave.agent
LOGO_PNG = Docs/logo.png
RENDERED_LOGO = $(DIST)/logo.rendered.png

.PHONY: build test app install run reset-perms clean

build:
	$(SWIFT) build -c release

test:
	$(SWIFT) test

app: build
	rm -rf $(DIST)
	mkdir -p "$(DIST)/Pave.app/Contents/MacOS"
	mkdir -p "$(DIST)/Pave.app/Contents/Resources"
	mkdir -p "$(DIST)/PaveAgent.app/Contents/MacOS"
	mkdir -p "$(DIST)/PaveAgent.app/Contents/Resources"
	cp .build/release/Pave "$(DIST)/Pave.app/Contents/MacOS/Pave"
	cp Support/Editor-Info.plist "$(DIST)/Pave.app/Contents/Info.plist"
	cp .build/release/PaveAgent "$(DIST)/PaveAgent.app/Contents/MacOS/PaveAgent"
	cp Support/Agent-Info.plist "$(DIST)/PaveAgent.app/Contents/Info.plist"
	cp .build/release/pavectl "$(DIST)/pavectl"
	@test -f "$(LOGO_PNG)" || (echo "Missing $(LOGO_PNG)"; exit 1)
	swift -e 'import AppKit; import Foundation; let input = URL(fileURLWithPath: "$(LOGO_PNG)"); let output = URL(fileURLWithPath: "$(RENDERED_LOGO)"); guard let src = NSImage(contentsOf: input) else { fputs("Failed to load logo\n", stderr); exit(1) }; let canvas = NSSize(width: 1024, height: 1024); let out = NSImage(size: canvas); out.lockFocus(); NSColor.white.setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill(); let rect = NSRect(origin: .zero, size: canvas); src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0); out.unlockFocus(); guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { fputs("Failed to rasterize logo\n", stderr); exit(1) }; let w = rep.pixelsWide; let h = rep.pixelsHigh; for y in 0..<h { for x in 0..<w { guard let c = rep.colorAt(x: x, y: y) else { continue }; rep.setColor(NSColor(calibratedRed: 1 - c.redComponent, green: 1 - c.greenComponent, blue: 1 - c.blueComponent, alpha: c.alphaComponent), atX: x, y: y) } }; guard let png = rep.representation(using: .png, properties: [:]) else { fputs("Failed to encode logo\n", stderr); exit(1) }; try png.write(to: output)'
	rm -rf "$(DIST)/AppIcon.iconset"
	mkdir -p "$(DIST)/AppIcon.iconset"
	sips -z 16 16 "$(RENDERED_LOGO)" --out "$(DIST)/AppIcon.iconset/icon_16x16.png" >/dev/null
	sips -z 32 32 "$(RENDERED_LOGO)" --out "$(DIST)/AppIcon.iconset/icon_16x16@2x.png" >/dev/null
	sips -z 32 32 "$(RENDERED_LOGO)" --out "$(DIST)/AppIcon.iconset/icon_32x32.png" >/dev/null
	sips -z 64 64 "$(RENDERED_LOGO)" --out "$(DIST)/AppIcon.iconset/icon_32x32@2x.png" >/dev/null
	sips -z 128 128 "$(RENDERED_LOGO)" --out "$(DIST)/AppIcon.iconset/icon_128x128.png" >/dev/null
	sips -z 256 256 "$(RENDERED_LOGO)" --out "$(DIST)/AppIcon.iconset/icon_128x128@2x.png" >/dev/null
	sips -z 256 256 "$(RENDERED_LOGO)" --out "$(DIST)/AppIcon.iconset/icon_256x256.png" >/dev/null
	sips -z 512 512 "$(RENDERED_LOGO)" --out "$(DIST)/AppIcon.iconset/icon_256x256@2x.png" >/dev/null
	sips -z 512 512 "$(RENDERED_LOGO)" --out "$(DIST)/AppIcon.iconset/icon_512x512.png" >/dev/null
	sips -z 1024 1024 "$(RENDERED_LOGO)" --out "$(DIST)/AppIcon.iconset/icon_512x512@2x.png" >/dev/null
	iconutil -c icns "$(DIST)/AppIcon.iconset" -o "$(DIST)/AppIcon.icns"
	cp "$(DIST)/AppIcon.icns" "$(DIST)/Pave.app/Contents/Resources/AppIcon.icns"
	cp "$(DIST)/AppIcon.icns" "$(DIST)/PaveAgent.app/Contents/Resources/AppIcon.icns"
	cp "$(RENDERED_LOGO)" "$(DIST)/Pave.app/Contents/Resources/logo.png"
	cp "$(RENDERED_LOGO)" "$(DIST)/PaveAgent.app/Contents/Resources/logo.png"
	@echo "Signing as: $(SIGN_ID)"
	@if [ "$(SIGN_ID)" = "-" ]; then \
		echo "WARNING: ad-hoc signature. Accessibility grants will NOT survive rebuilds."; \
		echo "Create a 'Pave Dev' code signing cert in Keychain Access (see Makefile header)."; \
	fi
	codesign --force -s "$(SIGN_ID)" "$(DIST)/Pave.app"
	codesign --force -s "$(SIGN_ID)" "$(DIST)/PaveAgent.app"

install: app
	-killall PaveAgent 2>/dev/null || true
	rm -rf "/Applications/Pave.app" "/Applications/PaveAgent.app"
	cp -R "$(DIST)/Pave.app" /Applications/
	cp -R "$(DIST)/PaveAgent.app" /Applications/

# Wipe stale TCC grants so macOS re-prompts cleanly. Kills mismatches left over
# from ad-hoc builds or an old copy. Accessibility = the tap; ListenEvent =
# Input Monitoring. Errors ignored when no prior grant exists.
reset-perms:
	-killall PaveAgent 2>/dev/null || true
	-killall "Pave" 2>/dev/null || true
	@echo "Resetting Accessibility + Input Monitoring for both bundles..."
	-tccutil reset Accessibility $(AGENT_ID) 2>/dev/null || true
	-tccutil reset Accessibility $(EDITOR_ID) 2>/dev/null || true
	-tccutil reset ListenEvent $(AGENT_ID) 2>/dev/null || true
	-tccutil reset ListenEvent $(EDITOR_ID) 2>/dev/null || true
	@echo "Done. Grant access again when the agent prompts."

# Clean-slate launch: build, install, wipe old grants, relaunch both apps.
run: install reset-perms
	open "/Applications/PaveAgent.app"
	open "/Applications/Pave.app"

clean:
	rm -rf .build $(DIST)
