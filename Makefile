APP := build/TerminalDB.app
BIN := $(APP)/Contents/MacOS/TerminalDB
SOURCES := src/main.m src/ClaudeAPI.m src/ClaudeAssistantView.m \
	src/TerminalInspector.m \
	src/ClaudeProfile.m src/ClaudeStatusBar.m src/TerminalTheme.m
FONT_RESOURCES := \
	Resources/Fonts/JetBrainsMono-Regular.ttf \
	Resources/Fonts/JetBrainsMono-Bold.ttf \
	Resources/Fonts/JetBrainsMono-Italic.ttf \
	Resources/Fonts/JetBrainsMono-BoldItalic.ttf
LICENSE_RESOURCES := Resources/Licenses/JetBrainsMono-OFL.txt
SCRIPT_RESOURCES := \
	Resources/Scripts/claude-status-bridge.sh \
	Resources/Scripts/claude-tab-state.sh

.PHONY: all run test qa-tabs qa-claude-state clean

all: $(BIN)

$(BIN): $(SOURCES) Info.plist $(FONT_RESOURCES) $(LICENSE_RESOURCES) $(SCRIPT_RESOURCES)
	mkdir -p $(APP)/Contents/MacOS
	mkdir -p $(APP)/Contents/Resources/Fonts
	mkdir -p $(APP)/Contents/Resources/Licenses
	mkdir -p $(APP)/Contents/Resources/Scripts
	cp Info.plist $(APP)/Contents/Info.plist
	cp $(FONT_RESOURCES) $(APP)/Contents/Resources/Fonts/
	cp $(LICENSE_RESOURCES) $(APP)/Contents/Resources/Licenses/
	cp $(SCRIPT_RESOURCES) $(APP)/Contents/Resources/Scripts/
	chmod 755 $(APP)/Contents/Resources/Scripts/claude-status-bridge.sh
	chmod 755 $(APP)/Contents/Resources/Scripts/claude-tab-state.sh
	clang -fobjc-arc -Wall -Wextra -framework AppKit -framework Foundation \
		-framework Security \
		$(SOURCES) -o $(BIN)

run: all
	open $(APP)

test: all
	$(BIN) --self-test
	$(MAKE) qa-tabs
	$(MAKE) qa-claude-state

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
