#!/usr/bin/env bash
# Apply reviewed state export and bounded link lookup to the exact pinned source.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="${1:?Swift package scratch directory required}"
xcrun swift package --package-path TerminalSurface --scratch-path "${scratch}" resolve
python3 - "${scratch}" <<'PY'
import hashlib
import re
from pathlib import Path
import sys
source = Path(sys.argv[1]) / 'checkouts/SwiftTerm/Sources/SwiftTerm/Terminal.swift'
addition = Path('TerminalSurface/Patches/SwiftTermDisplayState.swift').read_text()
marker = '\n// TERMINALDB_DISPLAY_STATE_EXPORT_V1\n'
original = source.read_text().split(marker)[0]
original = re.sub(r'^ *// TERMINALDB_LINK_BOUND_BEGIN\n.*?^ *// TERMINALDB_LINK_BOUND_END\n', '', original, flags=re.M | re.S)
original = original.replace('        let matches = terminalDBBoundedLinkMatches(regex, text: lineMap.text, range: searchRange)\n',
                            '        let matches = regex.matches(in: lineMap.text, options: [], range: searchRange)\n')
expected = '1b49eefe757cb612801d0b55eb1086d9ce746654d34318b8001cdd33b4d3ccd1'
if hashlib.sha256(original.encode()).hexdigest() != expected:
    raise SystemExit('SwiftTerm source changed; review the state export before building.')
# Link lookup runs synchronously on the UI thread, including modifier changes.
# Long wrapped output must never feed unbounded text to the upstream regex.
anchors = [
    ('    private func implicitLinkMatch(at position: Position, in buffer: Buffer) -> LinkMatch?\n',
     '''    private func terminalDBBoundedLinkMatches(_ regex: NSRegularExpression, text: String, range: NSRange) -> [NSTextCheckingResult] {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.005
        var result: [NSTextCheckingResult] = []
        var timedOut = false
        regex.enumerateMatches(in: text, options: [.reportProgress], range: range) { match, _, stop in
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                stop.pointee = true
            } else if let match { result.append(match) }
        }
        return timedOut ? [] : result
    }

'''),
    ('        let searchRange = NSRange(lineMap.text.startIndex',
     '        guard lineMap.text.contains("/") || lineMap.text.contains(":") else { return nil }\n'),
    ('        var text = ""\n        var cells: [GhosttyImplicitCellRef] = []',
     '        guard (endRow - startRow + 1) <= 4096 / max(1, cols) else { return nil }\n'),
    ('                text.append(character)\n                cells.append(',
     '                guard text.utf8.count + String(character).utf8.count <= 4096 else { return nil }\n'),
]
for anchor, body in anchors:
    if original.count(anchor) != 1:
        raise SystemExit('SwiftTerm link lookup anchor changed; review the lookup bounds.')
    original = original.replace(anchor, '// TERMINALDB_LINK_BOUND_BEGIN\n' + body + '// TERMINALDB_LINK_BOUND_END\n' + anchor, 1)
original = original.replace('        let matches = regex.matches(in: lineMap.text, options: [], range: searchRange)\n',
                            '        let matches = terminalDBBoundedLinkMatches(regex, text: lineMap.text, range: searchRange)\n')
result = original + marker + addition
if source.read_text() != result:
    mode = source.stat().st_mode
    source.chmod(mode | 0o200)
    source.write_text(result)
    source.chmod(mode)
PY

python3 Scripts/patch-terminal-parser.py "${scratch}"
