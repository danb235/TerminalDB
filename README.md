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

When Claude Code is installed, TerminalDB can keep as many as three persistent
Claude account profiles. Every profile has its own Claude configuration
directory and macOS Keychain credential item. A profile is selected per tab
from the native **Claude** application menu, so two TerminalDB tabs or windows
can use different Claude subscriptions at the same time without changing the
Claude account used by Terminal, iTerm, or another application. New TerminalDB
tabs start with the most recently selected profile.

Each tab is also a fully independent terminal session. It has its own login
shell, PTY, working directory, foreground process, scrollback, and selected
Claude profile, so switching accounts in one tab does not alter another tab.

## Natural-language terminal assistant

At a zsh prompt, input whose first word does not resolve to a command, alias,
function, built-in, or shell keyword is treated as a natural-language request.
TerminalDB sends the request and current working directory to the Claude
Messages API, then streams the answer into a terminal-styled response panel.
Ordinary commands continue to run through the shell unchanged.

Claude is prompted to explain its approach and place suggested shell commands
in fenced code blocks. Each shell block gets a **Run command** button. The
button inserts the command into the current prompt using the terminal's normal
paste behavior; it deliberately does not press Return, so the user can review
or edit the command before executing it. Non-shell code samples are never made
runnable. Conversation context is retained independently in each tab.

The response panel is also a conversation. Use the follow-up field to refine a
command, ask Claude to explain a choice, or continue investigating without
losing the earlier turns. Closing the panel or inserting a command preserves
that tab's context, and the next natural-language request reopens the same
transcript. Choose **New conversation** when the task changes; after
confirmation, TerminalDB clears only that tab's AI context. A newly opened
terminal tab always starts with fresh context.

Open **TerminalDB → Claude API Settings…** (Command-,) to add an Anthropic API
key. The key is stored only as a generic password in macOS Keychain. It is not
written to project files, user defaults, logs, or generated shell integration.
The settings field reads the saved value back from Keychain so persistence is
visible and the key can be edited or replaced directly.
After a key is saved, TerminalDB loads the models available to that key from
Anthropic's Models API. The model list refreshes on launch and whenever the
settings window opens, so newly available models appear without an app update.
The selected model is used for new terminal conversations.

The bottom status bar displays the selected account and subscription as static
identity text on the left. The five-hour, seven-day, and separate Fable 5
weekly usage meters are right-aligned against the opposite edge. The 5-hour and
7-day meters include their next reset date and time when Anthropic reports one;
an em dash indicates that no reset is currently scheduled or reported. Usage
refreshes every five minutes from Anthropic's OAuth usage service without
making a model request. The access token is read from the selected profile's
macOS Keychain item into memory and is never written by TerminalDB. Because
Anthropic does not currently document this endpoint as a public API, the
Claude Code status-line feed remains a fallback.

Account actions live in the native **Claude** application menu. It shows the
account selected for the current tab, provides checked account choices, and
separates switching from **Add Claude Account…**, sign-in, and manual usage
refresh actions. Each tab retains its own selection.

To enroll an account, open the **Claude** menu and choose
**Add Claude Account…**,
give the profile a memorable name, and complete Claude's browser sign-in. The
normal `claude` command in that TerminalDB window is then automatically scoped
to the selected profile. TerminalDB also records Claude's per-profile
first-run-complete state after authentication, so an authenticated account does
not re-enter Claude's login wizard. Authenticated profiles do not show another
sign-in action. If a profile becomes logged out, **Sign In to _Profile_…**
appears automatically.

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
shell code blocks, and authenticated-profile onboarding state. It also runs a
background AppKit integration check for native tab grouping, independent shell
sessions, activity state, switching, and closing. The QA app uses accessory
activation and does not bring test windows to the foreground.

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
