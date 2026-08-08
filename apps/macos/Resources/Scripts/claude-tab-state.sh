#!/bin/sh

# Claude Code invokes this through documented lifecycle hooks. Keep only the
# coarse state needed by TerminalDB's tab label; hook JSON and prompt text are
# intentionally neither read nor persisted.

set -eu
umask 077

state_file=${TERMINALDB_CLAUDE_STATE_FILE:-}
state=${1:-}
[ -n "$state_file" ] || exit 0

# Drain Claude's hook payload without parsing or retaining it.
cat >/dev/null

case "$state" in
  ready|working|attention) ;;
  *) exit 0 ;;
esac

state_dir=${state_file%/*}
mkdir -p "$state_dir"
temporary_file="${state_file}.tmp.$$"

trap 'rm -f "$temporary_file"' EXIT HUP INT TERM
printf '%s\n' "$state" > "$temporary_file"
chmod 600 "$temporary_file"
mv -f "$temporary_file" "$state_file"
trap - EXIT HUP INT TERM
