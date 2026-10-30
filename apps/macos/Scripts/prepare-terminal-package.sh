#!/usr/bin/env bash
# Apply only the reviewed read-only state export to the exact pinned source.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="${1:?Swift package scratch directory required}"
xcrun swift package --package-path TerminalSurface --scratch-path "${scratch}" resolve
python3 - "${scratch}" <<'PY'
import hashlib
from pathlib import Path
import sys
source = Path(sys.argv[1]) / 'checkouts/SwiftTerm/Sources/SwiftTerm/Terminal.swift'
addition = Path('TerminalSurface/Patches/SwiftTermDisplayState.swift').read_text()
marker = '\n// TERMINALDB_DISPLAY_STATE_EXPORT_V1\n'
original = source.read_text().split(marker)[0]
expected = '1b49eefe757cb612801d0b55eb1086d9ce746654d34318b8001cdd33b4d3ccd1'
if hashlib.sha256(original.encode()).hexdigest() != expected:
    raise SystemExit('SwiftTerm source changed; review the state export before building.')
result = original + marker + addition
if source.read_text() != result:
    mode = source.stat().st_mode
    source.chmod(mode | 0o200)
    source.write_text(result)
    source.chmod(mode)
PY

python3 Scripts/patch-terminal-parser.py "${scratch}"
