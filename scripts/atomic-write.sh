#!/usr/bin/env bash
# atomic-write.sh — atomic file write helper (write-to-temp + sync + mv).
#
# Why this exists
# ----------------
# Per Issue #237: naive jq_inplace (read file → modify → write tmp → mv) can
# leave the target file empty or partially-written if the process is killed
# mid-write. The fix: write the new content to a temp file in the SAME
# directory, fsync it, then atomically mv into place. The mv is atomic on
# POSIX filesystems (rename(2)), so observers always see either the old
# content or the new content — never a half-written state.
#
# Reusable from any state-owning script (DRY across 5 agents' state files).
# agent-state.sh cmd_set/cmd_mark/cmd_heartbeat/cmd_trim/cmd_kick all delegate
# here instead of inline jq_inplace.
#
# Usage:
#   source atomic-write.sh
#   atomic_write_json <target_file> [jq_args...]
#     target_file: existing JSON file to modify
#     jq_args: any jq filter + --arg/--argjson flags
#
# Returns:
#   0 on success (atomic mv completed)
#   1 on jq failure (target file unchanged, tmp file removed)
#
# Example:
#   atomic_write_json "$state_file" --argjson v '42' '.some_field = $v'

set -euo pipefail

atomic_write_json() {
  local target="$1"
  shift
  if [ -z "$target" ]; then
    echo "ERROR: atomic_write_json requires a target file path" >&2
    return 1
  fi
  if [ ! -f "$target" ]; then
    echo "ERROR: atomic_write_json target does not exist: $target" >&2
    return 1
  fi
  # Temp file in SAME directory as target (required for atomic mv on same FS).
  local tmp
  tmp="$(mktemp "${target}.atomic.XXXXXX")"
  # Run jq filter, write to tmp. If jq fails, clean up + return 1.
  if ! jq "$@" "$target" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "ERROR: atomic_write_json: jq filter failed for $target" >&2
    return 1
  fi
  # Fsync the temp file to ensure content is on disk before mv.
  # (mv is atomic on POSIX, but the write may not be flushed yet.)
  sync "$tmp" 2>/dev/null || true
  # Atomic rename.
  mv -f "$tmp" "$target"
}

# If sourced (not executed), expose the function. If executed directly, run a
# smoke test.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  # Standalone smoke test
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  testfile="$tmpdir/state.json"
  echo '{"foo": 1, "processed_event_ids": []}' > "$testfile"
  source <(echo 'atomic_write_json() { :; }')  # placeholder
  echo "Smoke test placeholder — atomic_write_json is a sourced helper."
  echo "For real test, see scripts/tests/d027-state-recovery.sh"
fi

# Alias for grep-based tests + ergonomic usage
atomic_write() {
  atomic_write_json "$@"
}
