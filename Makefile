# CodeLook — Quick Look previews with syntax highlighting for code & config files.
# Highlighting is Lithe's editor engine (Bridge/, a Go c-archive; the engine's code is in Bridge/internal).
#
#   make            Lithe syntax library + plists + Xcode project, build Release
#   make install    build, copy to $(INSTALL_DIR), register, reset Quick Look
#   make check      which types this Mac gives our files, and how they are covered
#   make render F=path/to/file   timings + /tmp/codelook-preview.png snapshot (no install)
#   make config     create ~/.config/codelook/config.yaml from the example (if there is none)
#   make uninstall
#   make dist       universal release build: build/dist/CodeLook.zip (+ .sha256, install.sh)
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
# Lithe's syntax engine for this Mac's architecture, a Go shared library: the app ships one copy
# in Contents/Frameworks for itself and both extensions. Its header is the Swift bridging header.
SYNTAX_DIR  := $(BUILD)/lithesyntax
SYNTAX_LIB  := $(SYNTAX_DIR)/libLitheSyntax.dylib
SYNTAX_SRC  := $(shell find Bridge -type f ! -name '*_test.go' ! -path '*/testdata/*')
SYNTAX_LD   := -L$(SYNTAX_DIR) -lLitheSyntax -Xlinker -rpath -Xlinker $(CURDIR)/$(SYNTAX_DIR)
# Found through each binary's rpath: Contents/Frameworks in the app.
GO_SHARED   := -trimpath -buildmode=c-shared \
               -ldflags="-s -w -extldflags=-Wl,-install_name,@rpath/libLitheSyntax.dylib"

# Release builds (make dist): a universal app; claims are fitted on the user's Mac by install.sh.
VERSION     ?= $(patsubst v%,%,$(or $(shell git describe --tags --match 'v*' --abbrev=0 2>/dev/null),v0.0.0))
BUILD_NUM   ?= $(or $(shell git rev-list --count HEAD 2>/dev/null),1)
DIST_ARCHS  ?= arm64 x86_64
DIST        := $(BUILD)/dist
DIST_DATA   := $(BUILD)/DistData
DIST_APP    := $(DIST_DATA)/Build/Products/Release/CodeLook.app
UNI_DIR     := $(BUILD)/lithesyntax-universal
goarch       = $(patsubst x86_64,amd64,$(1))

.PHONY: all syntax gen project build install uninstall check render test config clean dist

all: build

$(SYNTAX_LIB): $(SYNTAX_SRC)
	@mkdir -p $(SYNTAX_DIR)
	cd Bridge && CGO_ENABLED=1 CGO_CFLAGS="-O2 -mmacosx-version-min=13.0" \
	  CGO_LDFLAGS="-mmacosx-version-min=13.0" go build $(GO_SHARED) -o ../$(SYNTAX_LIB) .

syntax: $(SYNTAX_LIB)

# One library per architecture (cgo cross-compiles with clang -arch), joined with lipo. The
# headers cgo writes are the same for both 64-bit targets; the first one is the bridging header.
$(BUILD)/lithesyntax-%/libLitheSyntax.dylib: $(SYNTAX_SRC)
	@mkdir -p $(@D)
	cd Bridge && CGO_ENABLED=1 GOOS=darwin GOARCH=$(call goarch,$*) CC="clang -arch $*" \
	  CGO_CFLAGS="-O2 -mmacosx-version-min=13.0" CGO_LDFLAGS="-mmacosx-version-min=13.0" \
	  go build $(GO_SHARED) -o ../$@ .

$(UNI_DIR)/libLitheSyntax.dylib: $(foreach a,$(DIST_ARCHS),$(BUILD)/lithesyntax-$(a)/libLitheSyntax.dylib)
	@mkdir -p $(@D)
	@for h in $(^:.dylib=.h); do cmp -s $$h $(firstword $(^:.dylib=.h)) || { echo "cgo headers differ: $$h"; exit 1; }; done
	lipo -create $^ -output $@
	cp $(firstword $(^:.dylib=.h)) $(UNI_DIR)/libLitheSyntax.h

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

# Xcode registers what it builds; only installed copies should provide the extensions, or the
# build product competes with them for previews.
unregister = $(LSREGISTER) -u "$(1)" >/dev/null 2>&1 || true; \
	for e in CodeLookPreview CodeLookFallback; do pluginkit -r "$(1)/Contents/PlugIns/$$e.appex" >/dev/null 2>&1 || true; done

build: $(SYNTAX_LIB) project
	xcodebuild -project CodeLook.xcodeproj -scheme CodeLook -configuration $(CONFIG) \
	  -derivedDataPath $(DERIVED) -destination 'generic/platform=macOS' -quiet build
	@$(call unregister,$(APP))

install: build
	@mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/CodeLook.app"
	ditto "$(APP)" "$(INSTALL_DIR)/CodeLook.app"
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

# --release: the plists claim neither this Mac's third-party types nor this user's config.yaml.
# They are rewritten for the next `make build` again.
dist: $(UNI_DIR)/libLitheSyntax.dylib $(BUILD)/codelook-gen
	$(BUILD)/codelook-gen --release .
	xcodegen generate --quiet
	rm -rf $(DIST) $(DIST_DATA)
	xcodebuild -project CodeLook.xcodeproj -scheme CodeLook -configuration Release \
	  -derivedDataPath $(DIST_DATA) -destination 'generic/platform=macOS' -quiet \
	  ARCHS="$(DIST_ARCHS)" ONLY_ACTIVE_ARCH=NO LITHESYNTAX_DIR="$(CURDIR)/$(UNI_DIR)" \
	  MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUM) \
	  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build
	@$(call unregister,$(DIST_APP))
	codesign --verify --deep --strict "$(DIST_APP)"
	@for f in MacOS/CodeLook Frameworks/libLitheSyntax.dylib \
	  PlugIns/CodeLookPreview.appex/Contents/MacOS/CodeLookPreview \
	  PlugIns/CodeLookFallback.appex/Contents/MacOS/CodeLookFallback; do \
	  archs=$$(lipo -archs "$(DIST_APP)/Contents/$$f"); echo "  $$f: $$archs"; \
	  for a in $(DIST_ARCHS); do case " $$archs " in *" $$a "*) ;; *) echo "missing $$a"; exit 1;; esac; done; done
	@mkdir -p $(DIST)
	ditto -c -k --keepParent "$(DIST_APP)" $(DIST)/CodeLook.zip
	cd $(DIST) && shasum -a 256 CodeLook.zip > CodeLook.zip.sha256
	cp scripts/install.sh $(DIST)/install.sh
	@echo "CodeLook $(VERSION) ($(BUILD_NUM)): $$(du -h $(DIST)/CodeLook.zip | cut -f1) $(DIST)/CodeLook.zip"

clean:
	rm -rf $(BUILD) CodeLook.xcodeproj
