#!/bin/sh

# Claude Code sends documented status-line JSON to this script on stdin.
# Store it privately for TerminalDB's native status bar and intentionally emit
# no output, avoiding a duplicate status line inside Claude Code itself.

set -eu
umask 077

status_file=${TERMINALDB_CLAUDE_STATUS_FILE:-}
[ -n "$status_file" ] || exit 0

status_dir=${status_file%/*}
mkdir -p "$status_dir"
temporary_file="${status_file}.tmp.$$"

trap 'rm -f "$temporary_file"' EXIT HUP INT TERM
cat > "$temporary_file"
chmod 600 "$temporary_file"
mv -f "$temporary_file" "$status_file"
trap - EXIT HUP INT TERM
