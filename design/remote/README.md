# TerminalDB Remote design

`TerminalDBRemote.dc.html` is authored in the existing TerminalDB Claude Design
project. The implementation uses the desktop Graphite Ledger tokens in
`../desktop/TerminalDB.dc.html` and mirrors the remote connection-state matrix
defined in `packages/protocol`.

The exported design includes pairing, the Claude-first session dashboard,
terminal control, account switching, paired devices, connection diagnostics,
and the connectivity laboratory at phone, tablet, and desktop breakpoints.

## Terminal parity contract

The terminal route controls the Mac-authoritative PTY while giving each client
an independent presentation viewport:

- the browser document never scrolls while the terminal is open;
- each Mac tab keeps an independent emulator, selection, scroll position, and
  follow-output state;
- the web renderer holds the Graphite Ledger default at 13.5px and derives its
  visible rows and columns only from the browser's own content box;
- Mac PTY dimensions remain transport metadata and never zoom or resize the
  browser renderer;
- browser resizing changes visible content capacity rather than font size;
- account and explicit diagnostics surfaces overlay the terminal without
  moving it, while routine resync and rotation have no foreground overlay; and
- a previously synchronized terminal remains focused and usable through safe
  background maintenance while real transport or Mac outages disable input.

QA asserts fixed typography under browser resize and simulated Mac resize,
invariant stage geometry, plain-text copy, terminal keyboard bytes, chunked
encrypted snapshot assembly, touch target size, accessibility, and every
connection state at 390×844, 834×1194, and 1440px.
