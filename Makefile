APP := build/Vid2GIF.app
BIN := .build/release/Vid2GIF

.PHONY: app run cli clean

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/Vid2GIF
	cp -R .build/release/Vid2GIF_Vid2GIF.bundle $(APP)/Contents/Resources/
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP)/Contents/Resources/; fi
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

cli:
	swift build -c release
	@echo "CLI ready: $(BIN) convert <input> <output.gif> [options]"

clean:
	rm -rf .build build
