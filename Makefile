APP := build/TerminalDB.app
BIN := $(APP)/Contents/MacOS/TerminalDB
SOURCES := src/main.m src/ClaudeAPI.m src/ClaudeAssistantView.m \
	src/TerminalInspector.m \
	src/ClaudeProfile.m src/ClaudeStatusBar.m src/TerminalTheme.m \
	src/TerminalLedger.m src/TerminalPermissions.m src/TerminalProduct.m
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

.PHONY: all run test qa-tabs qa-claude-state qa-signature qa-icon qa-secrets clean

all: $(BIN)

$(BIN): $(SOURCES) Info.plist Makefile $(FONT_RESOURCES) $(LICENSE_RESOURCES) $(SCRIPT_RESOURCES) $(ICON_RESOURCE)
	mkdir -p $(APP)/Contents/MacOS
	mkdir -p $(APP)/Contents/Resources/Fonts
	mkdir -p $(APP)/Contents/Resources/Licenses
	mkdir -p $(APP)/Contents/Resources/Scripts
	cp Info.plist $(APP)/Contents/Info.plist
	cp $(FONT_RESOURCES) $(APP)/Contents/Resources/Fonts/
	cp $(LICENSE_RESOURCES) $(APP)/Contents/Resources/Licenses/
	cp $(SCRIPT_RESOURCES) $(APP)/Contents/Resources/Scripts/
	cp $(ICON_RESOURCE) $(APP)/Contents/Resources/
	chmod 755 $(APP)/Contents/Resources/Scripts/claude-status-bridge.sh
	chmod 755 $(APP)/Contents/Resources/Scripts/claude-tab-state.sh
	clang -fobjc-arc -Wall -Wextra -framework AppKit -framework Foundation \
		$(SOURCES) -o $(BIN)
	codesign --force --deep --sign - \
		--identifier com.terminaldb.app \
		--requirements '=designated => identifier "com.terminaldb.app"' \
		$(APP)

run: all
	open $(APP)

test: all
	$(BIN) --self-test
	$(MAKE) qa-signature
	$(MAKE) qa-icon
	$(MAKE) qa-secrets
	$(MAKE) qa-tabs
	$(MAKE) qa-claude-state

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
	@if rg -n --hidden --glob '!.git/**' --glob '!build/**' \
			'sk-ant-api0[0-9]-[A-Za-z0-9_-]{20,}' . >/dev/null; then \
		printf '%s\n' "FAIL: probable Anthropic API key in working tree" >&2; \
		exit 1; \
	fi
	@printf '%s\n' "TerminalDB working-tree secret QA: passed"

qa-tabs: all
	@output="$$($(BIN) --background-tab-qa 2>&1)"; \
		printf '%s\n' "$$output"; \
		case "$$output" in \
			*"grouped=yes selected=yes independent-shells=yes activity=yes titles=yes menu=yes assistant=yes close=yes"*) ;; \
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

clean:
	rm -r build
