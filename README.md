# TerminalDB

TerminalDB is an original native macOS terminal application built with AppKit,
Objective-C, and the system pseudo-terminal APIs.

It intentionally uses only the Apple Command Line Tools: there is no Xcode
project and no dependency manager.

TerminalDB has one built-in visual system based on the Monokai Pro
look: its terminal, ANSI colors, selection, title bar, and status bar are
defined directly by TerminalDB. It does not load or require Monokai Pro, VS
Code, or an installed theme, and it does not include Monokai extension code,
theme files, icons, fonts, or other package assets.

JetBrains Mono is TerminalDB's bundled application font. It is included under
the SIL Open Font License, so users do not need to install any font separately.
The terminal uses 14-point type with 1.2 line spacing.

When Claude Code is installed, TerminalDB can keep multiple persistent Claude
account profiles without an application-imposed account limit. Every profile
has its own Claude configuration directory and macOS Keychain credential item.
A profile is selected per tab from the native **Claude** application menu, so
two TerminalDB tabs or windows can use different Claude subscriptions at the
same time without changing the Claude account used by Terminal, iTerm, or
another application. New TerminalDB tabs start with the most recently selected
profile.

Each tab is also a fully independent terminal session. It has its own login
shell, PTY, working directory, foreground process, scrollback, and selected
Claude profile, so switching accounts in one tab does not alter another tab.
The terminal draws a solid theme-colored block at the PTY cursor position so
the active input location remains visible after the shell prompt. When focus
moves elsewhere in the window, the block becomes an outline, and full-screen
terminal programs can hide or show it with the standard cursor mode.

## AI chat

Select the standard right-sidebar icon in the upper-right corner or choose
**View → Show AI Chat** (Command-Shift-L) to open a collapsible chat pane
beside the active terminal. The icon is built into the window title bar and
toggles the pane in either direction. Terminal input is always sent to the
shell; TerminalDB does not try to classify commands as natural language.

Each message sent from the chat includes a fresh snapshot of that tab's current
working directory, window state, and visible terminal output. Claude can use
this context to explain an error, help investigate the system, write code, or
craft a command without the user copying terminal output manually. Terminal
output is marked as untrusted reference data in the model instructions.

For factual questions such as “count the JPEGs in this directory,” Claude can
run a tightly validated, read-only inspection in a separate sidecar process.
The chat shows the exact command, working directory, combined output, exit
status, duration, and whether output was truncated. Inspections use a strict
command allowlist and a macOS sandbox that denies file writes and network
access. They never type into, press Return in, or otherwise interrupt the
interactive terminal session.

Every inspected command can also be pasted into the terminal. Commands that
change state, need broader access, or fail inspection validation are never run
automatically; Claude instead places them in fenced shell blocks. Each block
gets its own inline **Paste** button immediately beside the command. The button
uses the terminal's normal paste behavior and deliberately does not press
Return, so the user can review or edit the command before executing it.
Non-shell code samples are never made runnable.

Conversation context is retained independently in each tab, including while
the pane is collapsed. Choose **New chat** when the task changes; after
confirmation, TerminalDB clears only that tab's AI context. A newly opened
terminal tab always starts with fresh context.

Open **TerminalDB → Settings…**, choose **Claude → AI Chat Settings…**, select
the gear in the AI-chat header, or press **Command-,** to add an Anthropic API
key. Choose the active model directly from **Claude → AI Chat Model**. That
submenu is populated from Anthropic's Models API and can be refreshed without
opening Settings. The active model remains visible under the AI Chat heading.
The key is stored only in this Mac's TerminalDB preferences. It is not written
to project files, logs, or generated shell integration. This intentionally
favors frictionless local persistence over Keychain protection; anyone with
access to the macOS account can read the preference value.

When no key or model is configured, the chat pane explains the required setup,
provides a direct settings button, and keeps the composer disabled until the
configuration is ready.

The settings field reads the saved value back from TerminalDB preferences but
uses a single-line secure control so the key is masked on screen. The stored
key can still be replaced directly.
Local development builds use a stable ad-hoc designated requirement for the
TerminalDB bundle identifier. Distributed builds should replace the ad-hoc
signature with the project’s normal Apple Developer signature.
After a key is saved, TerminalDB loads the models available to that key from
Anthropic's Models API. The model list refreshes on launch and whenever the
settings window opens, so newly available models appear without an app update.
The selected model is used for new AI chats.

The bottom status bar displays the selected account and subscription as static
identity text on the left. The five-hour, seven-day, and separate Fable 5
weekly usage meters are right-aligned against the opposite edge. The 5-hour and
7-day meters include their next reset date and time when Anthropic reports one;
an em dash indicates that no reset is currently reported. If the most recently
reported reset has already passed, the meter labels it as ended with the
reported date and time instead of presenting it as the next reset. Usage
refreshes every five minutes from Anthropic's OAuth usage service without
making a model request. The access token is read from the selected profile's
macOS Keychain item into memory and is never written by TerminalDB. Because
Anthropic does not currently document this endpoint as a public API, the
Claude Code status-line feed remains a fallback.

Account actions live under **Claude → Claude Code Account for This Tab**. The
submenu shows compact checked account choices and separates switching from
adding, signing in, and removing a local account. Each tab retains its own
selection. Usage refresh remains a separate top-level Claude action.

To enroll an account, open **Claude → Claude Code Account for This Tab** and
choose **Add Claude Code Account…**,
give the profile a memorable name, and complete Claude's browser sign-in. The
normal `claude` command in that TerminalDB window is then automatically scoped
to the selected profile. TerminalDB also records Claude's per-profile
first-run-complete state after authentication, so an authenticated account does
not re-enter Claude's login wizard. Authenticated profiles do not show another
sign-in action. If a profile becomes logged out, **Sign In to _Profile_…**
appears automatically.

To remove a profile, select it for the current tab and choose **Remove
“_Profile_” from TerminalDB…** in the same submenu. After confirmation,
TerminalDB permanently deletes that local profile's configuration and
TerminalDB-specific Claude Code credential, then moves affected tabs to the
remaining default profile. This removes the account only from TerminalDB; it
does not cancel or change the Claude subscription or its billing.

## Requirements

- macOS 13 or newer
- Apple Command Line Tools

## Build and run

```sh
make
make test
make run
```

The self-test suite exercises terminal cursor positioning and redraws, Claude's
interactive picker layout, split UTF-8 input, Space, Return, Control-C, arrow
keys, output-follow scrolling across successive commands, safe extraction of
shell code blocks, AI transcript rendering, terminal-context attachment,
read-only command validation and sandbox execution, inspection-result
rendering, command pasting without execution, and authenticated-profile
onboarding and removal state.
It also runs a background AppKit integration check for native tab grouping,
independent shell sessions, activity state, AI-pane expansion and collapse,
menu organization, account/model selection actions, switching, and closing.
QA app processes use accessory activation and keep their windows behind the
active application.

## Tabs

TerminalDB uses the native macOS tab bar for a browser-style experience:

- **Command-T** or the tab-bar **+** button opens a new tab and login shell
- **Command-W** or the tab close button closes only the selected tab
- **Command-Shift-[** and **Command-Shift-]** select the previous or next tab
- tabs can be reordered, detached into windows, and merged using normal macOS
  window behavior
- each tab can select a different persisted Claude account from its status bar

An animated activity mark appears only while work is actively progressing.
For Claude Code, its documented lifecycle state is authoritative: the spinner
runs during `Working` and is hidden for `Ready` and `Needs input`. For ordinary
commands, recent PTY output drives the animation. Quiet foreground programs do
not show a stopped loading glyph; their workload remains visible in the tab
title.

Tab names are concise, event-driven descriptions of the current workload.
TerminalDB's per-tab zsh integration reports the current directory at each
prompt and the executable name before each command, producing titles such as
`TerminalDB`, `npm · TerminalDB`, or `ssh · TerminalDB`. Applications may
override this through the standard OSC 0/2 title sequences.

Claude Code receives an additional, TerminalDB-owned settings file with
documented lifecycle hooks. Those hooks update only a private per-tab state
file, allowing titles such as `Claude · TerminalDB · Working`, `Ready`, or
`Needs input`. TerminalDB never stores or displays the prompt, command
arguments, hook JSON, or arbitrary screen output in a title. Control
characters are removed, whitespace is collapsed, and long application-supplied
titles are truncated before display.

## Terminal compatibility

TerminalDB reports `TERM=xterm-256color` and implements the everyday
iTerm-style baseline used by shells and command-line tools:

- UTF-8 input and output, ANSI colors, 256 colors, and truecolor
- cursor movement, screen and line erasing, and in-place TUI redraws
- primary/alternate-screen switching and restoration for tools such as
  `less` and `vim`
- normal and application cursor keys, xterm function/navigation keys, and
  Control-key input
- normal and bracketed paste, selection and macOS clipboard copy/paste
- automatic output following, with preserved scrollback when the user scrolls
  up and a return to the live prompt when the user types
- PTY resize updates with `SIGWINCH`, device/cursor reports, bells, and
  OSC 0/1/2 application and window titles

This is a practical compatibility target rather than full iTerm2 parity.
Mouse-reporting protocols, complete DEC scrolling-region semantics, Unicode
cell-width tables for every emoji/CJK edge case, hyperlinks and inline images,
search, splits, and iTerm2 shell-integration features remain future work.

The current baseline launches the user's login shell in a PTY, accepts keyboard
input, displays styled ANSI output, resizes the PTY with the window, and
supports independent native tabs.
