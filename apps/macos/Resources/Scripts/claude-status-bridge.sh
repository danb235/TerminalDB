#!/bin/sh

# Claude Code sends documented status-line JSON to this script on stdin.
# Store it privately for TerminalDB's native status bar and intentionally emit
# no output, avoiding a duplicate status line inside Claude Code itself.

set -eu
umask 077

status_file=${TERMINALDB_CLAUDE_STATUS_FILE:-}
window_status_file=${TERMINALDB_CLAUDE_WINDOW_STATUS_FILE:-}
[ -n "$status_file" ] || [ -n "$window_status_file" ] || exit 0

# Claude's status-line payload includes the active model and workspace. Keep a
# per-profile copy for usage aggregation and a per-window copy for tab identity;
# otherwise two Claude sessions using the same account can overwrite one
# another's model and directory.
payload_file="${window_status_file:-$status_file}.payload.$$"
temporary_file=""
trap 'rm -f "$payload_file" "$temporary_file"' EXIT HUP INT TERM
cat > "$payload_file"
chmod 600 "$payload_file"

for destination in "$status_file" "$window_status_file"; do
    [ -n "$destination" ] || continue
    status_dir=${destination%/*}
    mkdir -p "$status_dir"
    temporary_file="${destination}.tmp.$$"
    cp "$payload_file" "$temporary_file"
    chmod 600 "$temporary_file"
    mv -f "$temporary_file" "$destination"
    temporary_file=""
done

trap - EXIT HUP INT TERM
rm -f "$payload_file"
