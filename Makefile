APP        = SplashMenuBar
BIN        = build/$(APP)
SWIFTC     = swiftc
FLAGS      = -O
SOURCES    = $(wildcard Sources/*.swift)

# Tests link Xcode's XCTest (the Command Line Tools don't ship it), so they
# build against a full Xcode — override with `make test DEV=/path/to/Xcode.app`.
DEV        ?= /Applications/Xcode.app
PLATFORM   = $(DEV)/Contents/Developer/Platforms/MacOSX.platform
XCTEST_FW  = $(PLATFORM)/Developer/Library/Frameworks
XCTEST_LIB = $(PLATFORM)/Developer/usr/lib
TESTSRC    = $(wildcard Tests/*.swift)
TESTBUNDLE = build/$(APP)Tests.xctest
TESTLIB    = build/test/lib$(APP).dylib

all: $(APP).app

$(BIN): $(SOURCES)
	@mkdir -p build
	$(SWIFTC) $(FLAGS) -o $@ $(SOURCES) -framework AppKit -framework SwiftUI -framework IOKit

$(APP).app: $(BIN) Info.plist Resources/AppIcon.icns
	@rm -rf $(APP).app
	@mkdir -p $(APP).app/Contents/MacOS $(APP).app/Contents/Resources
	@cp $(BIN) $(APP).app/Contents/MacOS/$(APP)
	@cp Resources/AppIcon.icns $(APP).app/Contents/Resources/AppIcon.icns
	@cp Info.plist $(APP).app/Contents/Info.plist
	@echo "Built $(APP).app"

run: $(APP).app
	open $(APP).app

test: $(SOURCES) $(TESTSRC)
	@rm -rf build/test $(TESTBUNDLE)
	@mkdir -p build/test $(TESTBUNDLE)/Contents/MacOS
	$(SWIFTC) -module-name $(APP) -enable-testing -emit-library \
	    -emit-module -emit-module-path build/test/$(APP).swiftmodule \
	    -o $(TESTLIB) $(filter-out Sources/main.swift,$(SOURCES)) \
	    -framework AppKit -framework SwiftUI -framework IOKit \
	    -Xlinker -install_name -Xlinker @rpath/lib$(APP).dylib
	$(SWIFTC) -module-name $(APP)Tests -emit-library -o build/test/$(APP)Tests.dylib $(TESTSRC) \
	    -I build/test -L build/test -l$(APP) \
	    -F $(XCTEST_FW) -framework XCTest \
	    -I $(XCTEST_LIB) -L $(XCTEST_LIB) -lXCTestSwiftSupport \
	    -Xlinker -rpath -Xlinker @loader_path \
	    -Xlinker -rpath -Xlinker $(XCTEST_FW) \
	    -Xlinker -rpath -Xlinker $(XCTEST_LIB)
	@cp build/test/$(APP)Tests.dylib $(TESTLIB) $(TESTBUNDLE)/Contents/MacOS/
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>CFBundleExecutable</key><string>$(APP)Tests.dylib</string>\n<key>CFBundleIdentifier</key><string>com.danastott.splashmenubar.tests</string>\n<key>CFBundlePackageType</key><string>BNDL</string>\n</dict></plist>\n' > $(TESTBUNDLE)/Contents/Info.plist
	DEVELOPER_DIR=$(DEV) xcrun xctest $(TESTBUNDLE)

# Set the app version in Info.plist (short version, build = digits only):
#   make version VERSION=1.1.0   ->   1.1.0 (build 110)
version:
	@test -n "$(VERSION)" || { echo "usage: make version VERSION=x.y.z"; exit 1; }
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(shell echo $(VERSION) | tr -d .)" Info.plist
	@echo "Info.plist: $(VERSION) (build $(shell echo $(VERSION) | tr -d .))"

clean:
	rm -rf build $(APP).app

.PHONY: all run clean test version
