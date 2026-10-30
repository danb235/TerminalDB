APP := build/TerminalDB.app
BIN := $(APP)/Contents/MacOS/TerminalDB
INSTALL_APP ?= /Applications/TerminalDB.app
SOURCES := src/main.m src/ClaudeAPI.m src/ClaudeAssistantView.m \
	src/TerminalInspector.m \
	src/ClaudeProfile.m src/ClaudeStatusBar.m src/TerminalTheme.m \
	src/TerminalLedger.m src/TerminalPermissions.m src/TerminalProduct.m \
	src/TerminalUpdater.m src/TerminalPeerIntegration.m src/TerminalPeerStores.m src/TerminalPreferences.m
HEADERS := $(wildcard src/*.h)
HELPER_RESOURCES := $(wildcard Resources/LaunchAgents/*.plist)
ICON_RESOURCE := Resources/AppIcon.icns
FONT_RESOURCES := \
	Resources/Fonts/JetBrainsMono-Regular.ttf \
	Resources/Fonts/JetBrainsMono-Bold.ttf \
	Resources/Fonts/JetBrainsMono-Italic.ttf \
	Resources/Fonts/JetBrainsMono-BoldItalic.ttf
LICENSE_RESOURCES := Resources/Licenses/JetBrainsMono-OFL.txt
SCRIPT_RESOURCES := \
	Resources/Scripts/claude-status-bridge.sh \
	Resources/Scripts/claude-tab-state.sh

.PHONY: all release run install test test-ci test-surface qa-tabs qa-claude-state qa-claude-status qa-peers qa-peer-network qa-signature qa-icon qa-secrets clean

all: $(BIN)

SURFACE_SOURCES := $(wildcard TerminalSurface/Sources/TerminalDBTerminal/*.swift)
SURFACE_BUILD := Scripts/patch-terminal-parser.py Scripts/prepare-terminal-package.sh $(wildcard TerminalSurface/Patches/*.swift) Scripts/build-terminal-surface.sh TerminalSurface/Package.swift TerminalSurface/Package.resolved

$(BIN): $(SOURCES) $(HEADERS) $(HELPER_RESOURCES) Info.plist Makefile $(FONT_RESOURCES) $(LICENSE_RESOURCES) $(SCRIPT_RESOURCES) $(ICON_RESOURCE) $(SURFACE_SOURCES) $(SURFACE_BUILD) Scripts/build-app.sh
	TERMINALDB_NATIVE_ONLY=1 ./Scripts/build-app.sh debug

test-surface:
	./Scripts/prepare-terminal-package.sh TerminalSurface/.build
	xcrun swift run --package-path TerminalSurface -c release TerminalSurfaceTests

run: all
	open $(APP)

release:
	./Scripts/build-app.sh release

install: release
	@set -eu; \
		target="$(INSTALL_APP)"; \
		if ps -axo command= | grep -F "$$target/Contents/MacOS/TerminalDB" | grep -v grep >/dev/null; then \
			printf '%s\n' "Quit the installed TerminalDB before replacing $$target" >&2; \
			exit 1; \
		fi; \
		staging="$${target}.installing"; \
		/bin/rm -rf "$$staging"; \
		/usr/bin/ditto "$(APP)" "$$staging"; \
		/usr/bin/codesign --verify --deep --strict "$$staging"; \
		if test -e "$$target"; then /bin/rm -rf "$$target"; fi; \
		/bin/mv "$$staging" "$$target"; \
		printf '%s\n' "Installed $$target"

test: all
	$(MAKE) test-surface
	$(BIN) --self-test
	$(MAKE) qa-signature
	$(MAKE) qa-icon
	$(MAKE) qa-secrets
	$(MAKE) qa-peers
	$(MAKE) qa-tabs
	$(MAKE) qa-claude-state
	$(MAKE) qa-claude-status

test-ci: all
	$(MAKE) test-surface
	$(BIN) --self-test
	$(MAKE) qa-signature
	$(MAKE) qa-icon
	$(MAKE) qa-secrets
	$(MAKE) qa-peers
	$(MAKE) qa-claude-state
	$(MAKE) qa-claude-status

qa-signature: all
	@codesign --verify --deep --strict $(APP)
	@requirement="$$(codesign -dr - $(APP) 2>&1)"; \
		printf '%s\n' "$$requirement"; \
		case "$$requirement" in \
			*'designated => identifier "com.terminaldb.app"'*) ;; \
			*) exit 1 ;; \
		esac

qa-icon: all
	@icon_dir="$$(mktemp -d)/AppIcon.iconset"; \
		trap 'rm -r "$${icon_dir%/AppIcon.iconset}"' EXIT HUP INT TERM; \
		iconutil --convert iconset --output "$$icon_dir" \
			$(APP)/Contents/Resources/AppIcon.icns; \
		for icon in icon_16x16.png icon_16x16@2x.png \
			icon_32x32.png icon_32x32@2x.png \
			icon_128x128.png icon_128x128@2x.png \
			icon_256x256.png icon_256x256@2x.png \
			icon_512x512.png icon_512x512@2x.png; do \
			test -s "$$icon_dir/$$icon" || exit 1; \
		done; \
		test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
			$(APP)/Contents/Info.plist)" = "AppIcon"; \
		printf '%s\n' "TerminalDB icon QA: 10 sizes and bundle metadata passed"

qa-secrets:
	@if command -v rg >/dev/null 2>&1; then \
		rg -n --hidden --glob '!.git/**' --glob '!build/**' --glob '!TerminalSurface/.build/**' \
			'sk-ant-api0[0-9]-[A-Za-z0-9_-]{20,}' . >/dev/null; \
		found="$$?"; \
	else \
		grep -Ern --exclude-dir=.git --exclude-dir=build --exclude-dir=.build \
			'sk-ant-api0[0-9]-[A-Za-z0-9_-]\{20,\}' . >/dev/null; \
		found="$$?"; \
	fi; \
	if [ "$$found" -gt 1 ]; then \
		printf '%s\n' "FAIL: secret scanner could not complete" >&2; \
		exit 1; \
	elif [ "$$found" -eq 0 ]; then \
		printf '%s\n' "FAIL: probable Anthropic API key in working tree" >&2; \
		exit 1; \
	fi
	@printf '%s\n' "TerminalDB working-tree secret QA: passed"

qa-tabs: all
	@output="$$($(BIN) --background-tab-qa 2>&1)"; \
		printf '%s\n' "$$output"; \
		case "$$output" in \
			*"grouped=yes selected=yes independent-shells=yes activity=yes titles=workload:yes/state:yes menu=yes assistant=yes close=yes"*) ;; \
			*) exit 1 ;; \
		esac

qa-claude-state: all
	@state_dir="$$(mktemp -d)"; \
		trap 'rm -r "$$state_dir"' EXIT HUP INT TERM; \
		TERMINALDB_CLAUDE_STATE_FILE="$$state_dir/state" \
			$(APP)/Contents/Resources/Scripts/claude-tab-state.sh working \
			< /dev/null; \
		test "$$(cat "$$state_dir/state")" = "working"; \
		printf '%s\n' "TerminalDB Claude tab-state hook QA: passed"

qa-claude-status: all
	@status_dir="$$(mktemp -d)"; \
		trap 'rm -r "$$status_dir"' EXIT HUP INT TERM; \
		printf '%s\n' '{"model":{"display_name":"Opus QA"},"workspace":{"current_dir":"/tmp/project"}}' | \
			TERMINALDB_CLAUDE_STATUS_FILE="$$status_dir/profile.json" \
			TERMINALDB_CLAUDE_WINDOW_STATUS_FILE="$$status_dir/window.json" \
			$(APP)/Contents/Resources/Scripts/claude-status-bridge.sh; \
		cmp -s "$$status_dir/profile.json" "$$status_dir/window.json"; \
		test "$$(jq -r '.model.display_name' "$$status_dir/window.json")" = "Opus QA"; \
		test "$$(stat -f '%Lp' "$$status_dir/profile.json")" = "600"; \
		test "$$(stat -f '%Lp' "$$status_dir/window.json")" = "600"; \
		printf '%s\n' "TerminalDB per-window Claude model hook QA: passed"

qa-peers: all
	$(BIN) --peer-self-test
	python3 Tests/peer-session-qa.py $(BIN)

clean:
	rm -r build

# Requires an interactive Mac with Local Network permission; separate from CI.
qa-peer-network: all
	python3 Tests/peer-network-qa.py $(BIN)
