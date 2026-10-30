#!/usr/bin/env python3
"""Keep the exact unfinished control prefix for read-only snapshot replay.

The existing parser still interprets all bytes. These bounded annotations only
record the last incomplete prefix, and fail on any unexpected upstream edit.
"""
import hashlib
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]) / 'checkouts/SwiftTerm/Sources/SwiftTerm/EscapeSequenceParser.swift'
current = source.read_text()
base = re.sub(r'^ *// TERMINALDB_PENDING_BEGIN\n.*?^ *// TERMINALDB_PENDING_END\n', '', current, flags=re.M | re.S)
if hashlib.sha256(base.encode()).hexdigest() != 'b8bed0484a777146542cfa040db27223d93c7621edfefd3dde34aa61b4ff3b60':
    raise SystemExit('SwiftTerm parser source changed; review pending-state export before building.')

def before(anchor, body):
    global base
    if base.count(anchor) != 1:
        raise SystemExit('SwiftTerm pending-state anchor changed.')
    base = base.replace(anchor, '// TERMINALDB_PENDING_BEGIN\n' + body + '// TERMINALDB_PENDING_END\n' + anchor, 1)

before('    var currentState: ParserState = .ground\n', '''    var terminalDBPendingBytes: [UInt8] = []
    var terminalDBPendingOverflow = false
''')
before('        var currentState = self.currentState\n', '''        var terminalDBStart: Int? = self.currentState == .ground ? nil : data.startIndex
        var terminalDBContinues = self.currentState != .ground
''')
before('            currentState = ParserState (rawValue: transition & 15)!\n', '''            let terminalDBNext = ParserState(rawValue: transition & 15)!
            if terminalDBNext == .ground {
                terminalDBStart = nil; terminalDBContinues = false
            } else if currentState == .ground || code == 0x1b {
                terminalDBStart = i; terminalDBContinues = false
            }
''')
before('        // push leftover pushable buffers to terminal\n', '''        if currentState == .ground {
            terminalDBPendingBytes.removeAll(keepingCapacity: false); terminalDBPendingOverflow = false
        } else if let start = terminalDBStart {
            if !terminalDBContinues { terminalDBPendingBytes.removeAll(keepingCapacity: false); terminalDBPendingOverflow = false }
            let part = data[start..<end]
            if !terminalDBPendingOverflow && terminalDBPendingBytes.count + part.count <= 65536 {
                terminalDBPendingBytes.append(contentsOf: part)
            } else { terminalDBPendingBytes.removeAll(keepingCapacity: false); terminalDBPendingOverflow = true }
        }
''')
if current != base:
    mode = source.stat().st_mode
    source.chmod(mode | 0o200)
    source.write_text(base)
    source.chmod(mode)
