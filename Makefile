APP        = SplashMenuBar
BIN        = build/$(APP)
SWIFTC     = swiftc
FLAGS      = -O
SOURCES    = $(wildcard Sources/*.swift)

all: $(APP).app

$(BIN): $(SOURCES)
	@mkdir -p build
	$(SWIFTC) $(FLAGS) -o $@ $(SOURCES) -framework AppKit -framework SwiftUI

$(APP).app: $(BIN) Info.plist Resources/AppIcon.icns
	@rm -rf $(APP).app
	@mkdir -p $(APP).app/Contents/MacOS $(APP).app/Contents/Resources
	@cp $(BIN) $(APP).app/Contents/MacOS/$(APP)
	@cp Resources/AppIcon.icns $(APP).app/Contents/Resources/AppIcon.icns
	@cp Info.plist $(APP).app/Contents/Info.plist
	@echo "Built $(APP).app"

run: $(APP).app
	open $(APP).app

clean:
	rm -rf build $(APP).app

.PHONY: all run clean
