#!/bin/bash
#
# Tests for the version cache of template/ca-plugin.sh. Plain bash, no
# framework. curl is a stub on PATH, so no network and no token are needed.
#
#   tests/ca-plugin.test.sh
#
# shellcheck disable=SC2016,SC2034
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
export WORK
trap 'rm -rf "$WORK"' EXIT
FAILS=0

fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# The stub prints $CURL_BODY, exits with $CURL_RC and logs its stdin, which
# holds the curl config with the token header.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
cat > "$WORK/curl-stdin"
printf '%s' "$CURL_BODY"
exit "${CURL_RC:-0}"
STUB
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

export HOME="$WORK/home"
mkdir -p "$HOME"
CACHE="$HOME/.cache/claude-agents-remote-version"
export CA_PLUGIN_TOKEN_FILE="$WORK/token"
printf 'ghp_secret\n' > "$CA_PLUGIN_TOKEN_FILE"

run() { bash "$REPO_DIR/template/ca-plugin.sh" "$@"; }

# ── no token ────────────────────────────────────────────────────────────────
rm -f "$CACHE" "$WORK/curl-stdin"
: > "$CA_PLUGIN_TOKEN_FILE"
CURL_BODY='{"version": "1.5.33"}' run version-cache
check "no token: no cache file" '[[ ! -e "$CACHE" ]]'
check "no token: curl not called" '[[ ! -e "$WORK/curl-stdin" ]]'
printf 'ghp_secret\n' > "$CA_PLUGIN_TOKEN_FILE"

# ── a version ───────────────────────────────────────────────────────────────
rm -f "$CACHE"
CURL_BODY='{ "name": "claude-agents", "version": "1.5.33" }' run version-cache
check "version written" '[[ "$(cat "$CACHE")" == "1.5.33" ]]'
check "token goes to curl on stdin, without the newline" \
  'grep -qx "header = \"Authorization: Bearer ghp_secret\"" "$WORK/curl-stdin"'

# ── a fresh cache is kept ───────────────────────────────────────────────────
rm -f "$WORK/curl-stdin"
CURL_BODY='{"version": "9.9.9"}' run version-cache
check "fresh cache: curl not called" '[[ ! -e "$WORK/curl-stdin" ]]'
check "fresh cache: value kept" '[[ "$(cat "$CACHE")" == "1.5.33" ]]'

# ── an old cache is refreshed ───────────────────────────────────────────────
touch -d '2 hours ago' "$CACHE" 2>/dev/null || touch -t "$(date -v-2H +%Y%m%d%H%M)" "$CACHE"
CURL_BODY='{"version": "1.5.34"}' run version-cache
check "old cache: refreshed" '[[ "$(cat "$CACHE")" == "1.5.34" ]]'

# ── an error body never reaches the file ────────────────────────────────────
touch -d '2 hours ago' "$CACHE" 2>/dev/null || touch -t "$(date -v-2H +%Y%m%d%H%M)" "$CACHE"
CURL_BODY='{"message": "Not Found", "version": "x"}' run version-cache
check "error body: value kept" '[[ "$(cat "$CACHE")" == "1.5.34" ]]'
CURL_BODY='' CURL_RC=22 run version-cache
check "curl failure: value kept, exit 0" '[[ $? -eq 0 && "$(cat "$CACHE")" == "1.5.34" ]]'

echo
if [[ "$FAILS" -gt 0 ]]; then echo "$FAILS failure(s)"; exit 1; fi
echo "all ok"
