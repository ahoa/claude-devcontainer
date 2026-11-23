#!/bin/bash
#
# Tests for template/wl-paste.sh: the clipboard shim for image pastes from aTerm.
# Plain bash, no framework, no Docker. ATERM_PASTE_DIR points the shim at a
# temporary directory instead of /aterm-paste.
#
#   tests/wl-paste.test.sh
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHIM="$REPO_DIR/template/wl-paste.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export ATERM_PASTE_DIR="$WORK/paste"
FAILS=0

fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

# expect <name> <expected exit code> <expected stdout> <shim argument>…
expect() {
  local name="$1" want_rc="$2" want_out="$3" out rc
  shift 3
  out="$(sh "$SHIM" "$@")"
  rc=$?
  if [[ $rc -eq $want_rc && "$out" == "$want_out" ]]; then
    pass "$name"
  else
    fail "$name: exit $rc, output '$out', expected exit $want_rc, output '$want_out'"
  fi
}

expect "a missing directory gives no image" 1 "" --list-types

mkdir -p "$ATERM_PASTE_DIR"
expect "an empty directory gives no image" 1 "" --list-types

echo old > "$ATERM_PASTE_DIR/paste-old.jpg"
touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-2 minutes' +%Y%m%d%H%M.%S)" \
  "$ATERM_PASTE_DIR/paste-old.jpg"
expect "a paste older than one minute is ignored" 1 "" --list-types

echo other > "$ATERM_PASTE_DIR/notes.jpg"
expect "a file without the paste- prefix is ignored" 1 "" --list-types

echo first > "$ATERM_PASTE_DIR/paste-first.jpg"
touch -t "$(date -v-30S +%Y%m%d%H%M.%S 2>/dev/null || date -d '-30 seconds' +%Y%m%d%H%M.%S)" \
  "$ATERM_PASTE_DIR/paste-first.jpg"
echo second > "$ATERM_PASTE_DIR/paste-second.jpg"
expect "a recent paste lists image/jpeg" 0 "image/jpeg" --list-types
expect "--type writes the newest paste" 0 "second" --type image/jpeg
expect "--type writes the paste for any type" 0 "second" --type image/png
expect "a text read exits 1" 1 "" --no-newline
expect "no argument exits 1" 1 ""

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS test(s) failed"
  exit 1
fi
echo "all tests passed"
