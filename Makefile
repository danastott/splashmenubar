APP        = SplashMenuBar
BIN        = build/$(APP)
SWIFTC     = swiftc
FLAGS      = -O
# The cask's floor, regardless of the build machine's OS: without an
# explicit target, swiftc stamps minos with the build machine's version
# and the app won't launch on older macOS ("can't use this version of the
# application ... with this version of macOS").
TARGET     = $(shell uname -m)-apple-macosx13.0
SOURCES    = $(wildcard Sources/*.swift)
LOCALES    = $(wildcard Resources/*.lproj)

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
	$(SWIFTC) $(FLAGS) -target $(TARGET) -o $@ $(SOURCES) -framework AppKit -framework SwiftUI -framework IOKit

$(APP).app: $(BIN) Info.plist Resources/AppIcon.icns $(LOCALES)
	@rm -rf $(APP).app
	@mkdir -p $(APP).app/Contents/MacOS $(APP).app/Contents/Resources
	@cp $(BIN) $(APP).app/Contents/MacOS/$(APP)
	@cp Resources/AppIcon.icns $(APP).app/Contents/Resources/AppIcon.icns
	@cp Info.plist $(APP).app/Contents/Info.plist
	# Localized .lproj bundles (Localizable.strings / .stringsdict). Keys are
	# the English source text; a missing key falls back to the key itself.
	@for l in $(LOCALES); do cp -R $$l $(APP).app/Contents/Resources/; done
	# Ad-hoc sign the bundle: the linker's ad-hoc signature on the bare
	# binary leaves the bundle unsigned, and macOS calls a quarantined
	# app in that state "damaged" (unbypassable) instead of the usual
	# unsigned-developer prompt (right-click > Open).
	@codesign --force --sign - $(APP).app
	@echo "Built $(APP).app"

run: $(APP).app
	open $(APP).app

test: $(SOURCES) $(TESTSRC)
	@rm -rf build/test $(TESTBUNDLE)
	@mkdir -p build/test $(TESTBUNDLE)/Contents/MacOS
	$(SWIFTC) -target $(TARGET) -module-name $(APP) -enable-testing -emit-library \
	    -emit-module -emit-module-path build/test/$(APP).swiftmodule \
	    -o $(TESTLIB) $(filter-out Sources/App.swift,$(SOURCES)) \
	    -framework AppKit -framework SwiftUI -framework IOKit \
	    -Xlinker -install_name -Xlinker @rpath/lib$(APP).dylib
	$(SWIFTC) -target $(TARGET) -module-name $(APP)Tests -emit-library -o build/test/$(APP)Tests.dylib $(TESTSRC) \
	    -I build/test -L build/test -l$(APP) \
	    -F $(XCTEST_FW) -framework XCTest \
	    -I $(XCTEST_LIB) -L $(XCTEST_LIB) -lXCTestSwiftSupport \
	    -Xlinker -rpath -Xlinker @loader_path \
	    -Xlinker -rpath -Xlinker $(XCTEST_FW) \
	    -Xlinker -rpath -Xlinker $(XCTEST_LIB)
	@cp build/test/$(APP)Tests.dylib $(TESTLIB) $(TESTBUNDLE)/Contents/MacOS/
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>CFBundleExecutable</key><string>$(APP)Tests.dylib</string>\n<key>CFBundleIdentifier</key><string>com.danastott.splashmenubar.tests</string>\n<key>CFBundlePackageType</key><string>BNDL</string>\n</dict></plist>\n' > $(TESTBUNDLE)/Contents/Info.plist
	DEVELOPER_DIR=$(DEV) xcrun xctest $(TESTBUNDLE)

PLISTVER   = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
VERSION    ?= $(PLISTVER)
ZIP        = $(APP)-$(VERSION).zip

# Build, zip the .app as $(APP)-$(VERSION).zip, and print its sha256 (for the
# Homebrew Cask). VERSION defaults to the Info.plist version. Upload with:
#   gh release create v$(VERSION) $(ZIP) --title "Splash Menu Bar $(VERSION)"
release: $(APP).app
	@test "$(VERSION)" = "$(PLISTVER)" || { echo "VERSION=$(VERSION) does not match Info.plist ($(PLISTVER)); run: make version VERSION=$(VERSION)"; exit 1; }
	@rm -f $(ZIP)
	ditto -c -k --sequesterRsrc --keepParent $(APP).app $(ZIP)
	@shasum -a 256 $(ZIP)

# Set the app version in Info.plist (short version, build = digits only):
#   make version VERSION=1.1.0   ->   1.1.0 (build 110)
version:
	@test -n "$(VERSION)" || { echo "usage: make version VERSION=x.y.z"; exit 1; }
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(shell echo $(VERSION) | tr -d .)" Info.plist
	@echo "Info.plist: $(VERSION) (build $(shell echo $(VERSION) | tr -d .))"

# Verify localization files: every <lang>.lproj has the same key set as
# en.lproj, and every simple (un-interpolated) UI literal in Sources/ has a
# key in en.lproj.
check-i18n:
	python3 scripts/check_localizations.py

clean:
	rm -rf build $(APP).app

.PHONY: all run clean test version check-i18n
