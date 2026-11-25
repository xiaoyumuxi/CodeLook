# CodeLook — Quick Look previews with syntax highlighting for code & config files.
# Highlighting is Lithe's editor engine (Bridge/, a Go c-archive; the engine's code is in Bridge/internal).
#
#   make            Lithe syntax library + plists + Xcode project, build Release
#   make install    build, copy to $(INSTALL_DIR), register, reset Quick Look
#   make check      which types this Mac gives our files, and how they are covered
#   make render F=path/to/file   timings + /tmp/codelook-preview.png snapshot (no install)
#   make config     create ~/.config/codelook/config.yaml from the example (if there is none)
#   make uninstall
#
# All settings are in ~/.config/codelook/config.yaml (Examples/config.example.yaml). Edits apply
# to the next preview; only new file extensions need `make install` (they go into the plists).

INSTALL_DIR ?= $(HOME)/Applications
CONFIG      ?= Release
BUILD       := build
DERIVED     := $(BUILD)/DerivedData
APP         := $(DERIVED)/Build/Products/$(CONFIG)/CodeLook.app
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SHARED      := $(wildcard Shared/*.swift)
CONFIG_FILE ?= $(HOME)/.config/codelook/config.yaml
EXT_IDS     := dev.openres.CodeLook.Preview dev.openres.CodeLook.Fallback
# Lithe's syntax engine for this Mac's architecture; the header doubles as the Swift bridging header.
SYNTAX_DIR  := $(BUILD)/lithesyntax
SYNTAX_LIB  := $(SYNTAX_DIR)/libLitheSyntax.a
SYNTAX_SRC  := $(shell find Bridge -type f ! -name '*_test.go' ! -path '*/testdata/*')
SYNTAX_LD   := -L$(SYNTAX_DIR) -lLitheSyntax -framework CoreFoundation -framework Security -lresolv

.PHONY: all syntax gen project build install uninstall check render test config clean

all: build

$(SYNTAX_LIB): $(SYNTAX_SRC)
	@mkdir -p $(SYNTAX_DIR)
	cd Bridge && CGO_ENABLED=1 CGO_CFLAGS="-O2 -mmacosx-version-min=13.0" \
	  go build -trimpath -ldflags="-s -w" -buildmode=c-archive -o ../$(SYNTAX_LIB) .

syntax: $(SYNTAX_LIB)

# The generator reads config.yaml too (extensions it maps), so it links the engine.
$(BUILD)/codelook-gen: $(SHARED) Tools/gen/main.swift $(SYNTAX_LIB)
	swiftc -O -swift-version 5 -import-objc-header $(SYNTAX_DIR)/libLitheSyntax.h \
	  $(SHARED) Tools/gen/main.swift $(SYNTAX_LD) -o $@

$(BUILD)/codelook-render: $(SHARED) Tools/render/main.swift $(SYNTAX_LIB)
	swiftc -O -swift-version 5 -import-objc-header $(SYNTAX_DIR)/libLitheSyntax.h \
	  $(SHARED) Tools/render/main.swift $(SYNTAX_LD) -o $@

# --local: also claim the types other apps on this Mac declared for our extensions.
gen: $(BUILD)/codelook-gen
	$(BUILD)/codelook-gen --local .

project: gen
	xcodegen generate --quiet

build: $(SYNTAX_LIB) project
	xcodebuild -project CodeLook.xcodeproj -scheme CodeLook -configuration $(CONFIG) \
	  -derivedDataPath $(DERIVED) -destination 'generic/platform=macOS' -quiet build

install: build
	@mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/CodeLook.app"
	ditto "$(APP)" "$(INSTALL_DIR)/CodeLook.app"
	@# Only the installed copy should be registered; the build product would compete with it.
	-$(LSREGISTER) -u "$(APP)" 2>/dev/null
	-pluginkit -r "$(APP)/Contents/PlugIns/CodeLookPreview.appex" 2>/dev/null
	-pluginkit -r "$(APP)/Contents/PlugIns/CodeLookFallback.appex" 2>/dev/null
	$(LSREGISTER) -f -R -trusted "$(INSTALL_DIR)/CodeLook.app"
	pluginkit -a "$(INSTALL_DIR)/CodeLook.app/Contents/PlugIns/CodeLookPreview.appex"
	pluginkit -a "$(INSTALL_DIR)/CodeLook.app/Contents/PlugIns/CodeLookFallback.appex"
	for id in $(EXT_IDS); do pluginkit -e use -i $$id; done
	qlmanage -r >/dev/null
	qlmanage -r cache >/dev/null
	@for id in $(EXT_IDS); do pluginkit -m -A -D -v -i $$id; done
	@echo "Installed $(INSTALL_DIR)/CodeLook.app"

uninstall:
	-for id in $(EXT_IDS); do pluginkit -e ignore -i $$id; done
	-$(LSREGISTER) -u "$(INSTALL_DIR)/CodeLook.app"
	rm -rf "$(INSTALL_DIR)/CodeLook.app"
	qlmanage -r >/dev/null; qlmanage -r cache >/dev/null

check: $(BUILD)/codelook-gen
	$(BUILD)/codelook-gen --check .

render: $(BUILD)/codelook-render
	$(BUILD)/codelook-render "$(F)" --png /tmp/codelook-preview.png $(ARGS)

test: $(BUILD)/codelook-render
	cd Bridge && go test ./...
	$(BUILD)/codelook-render --batch Samples/*

config:
	@if [ -e "$(CONFIG_FILE)" ]; then echo "$(CONFIG_FILE) exists"; else \
	  mkdir -p "$(dir $(CONFIG_FILE))" && cp Examples/config.example.yaml "$(CONFIG_FILE)" && echo "Created $(CONFIG_FILE)"; fi

clean:
	rm -rf $(BUILD) CodeLook.xcodeproj
