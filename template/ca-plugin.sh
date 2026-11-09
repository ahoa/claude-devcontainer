#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated.
#
# ca-plugin.sh — the ca plugin as an installed plugin of the container's own.
# It runs in the CONTAINER. start.sh and attach.sh call it through
# `devcontainer exec`.
#
#   ca-plugin.sh install     install claude-agents@codeborne when the token exists
#   ca-plugin.sh installed   exit 0 when Claude loads the installed plugin here
#   ca-plugin.sh loop-start  start the tmux session of the night loop again
#   ca-plugin.sh version-cache  write the released plugin version to the cache once
#   ca-plugin.sh version-watch  write it now and then once an hour, in the background
#
# The Dockerfile also copies this script to /usr/local/bin, so the claude()
# function in ca-claude.zsh makes the same test. postStartCommand in
# devcontainer.json runs loop-start on each container start.
#
# An installed plugin updates through Claude's own mechanism: the update at
# start, /plugin and `claude plugin update`. The read-only host mount cannot do
# that. Claude loads the mount through --plugin-dir and does not know it as an
# installed plugin. The mount stays as the fallback for a container without a
# token. An install that exists stays in use without a token. The claude volume
# can be shared, and another project with a token updates it. Uninstalling it
# here would take it from that project too.
#
# The marketplace repo is private. The token for it is the compose secret
# ca_plugin_token. The git credential helper in the Dockerfile gives it to git
# for that one repo URL, and for no other URL.
set -uo pipefail

PLUGIN="claude-agents@codeborne"
MARKETPLACE_NAME="codeborne"
MARKETPLACE_SOURCE="codeborne/claude-agents"
TOKEN_FILE="${CA_PLUGIN_TOKEN_FILE:-/run/secrets/ca_plugin_token}"
PLUGINS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# The directory of the container's own install, when Claude loads it in this
# workspace. Read from the files and not from `claude plugin list`: attach.sh
# asks on each attach, and the files cost no Claude start. Claude loads an
# entry of the user scope, or an entry whose projectPath is this workspace. The
# claude volume can be shared between projects, so an entry for another
# workspace does not count. An entry whose directory is gone does not count,
# and neither does a plugin that settings.json disables.
install_dir() {
  local workspace dir
  workspace="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  [[ "$(jq -r --arg p "$PLUGIN" 'if .enabledPlugins[$p] == false then "off" else "on" end' \
    "$SETTINGS" 2>/dev/null)" != off ]] || return 1
  while read -r dir; do
    [[ -n "$dir" && -d "$dir" ]] && { echo "$dir"; return 0; }
  done < <(jq -r --arg p "$PLUGIN" --arg ws "$workspace" \
    '.plugins[$p][]? | select(.scope == "user" or .projectPath == $ws) | .installPath' \
    "$PLUGINS_DIR/installed_plugins.json" 2>/dev/null)
  return 1
}

installed() { install_dir >/dev/null; }

# The ca-loop to run: the launcher that `ca-loop setup` wrote, when it exists.
# It finds the newest plugin itself, and ca-loop warns at each run from a
# versioned path without it. /home/dev is not a volume, so a rebuild removes
# the launcher. Then the ca-loop of the plugin that Claude loads here: the
# container's own install, else the newest version of the host mount, which
# CA_PLUGIN_CACHE names (docker-compose.yml). Nothing when none has the script.
ca_loop() {
  local dir launcher="$HOME/.local/bin/ca-loop"
  [[ -x "$launcher" ]] && { echo "$launcher"; return 0; }
  if ! dir="$(install_dir)"; then
    [[ -n "${CA_PLUGIN_CACHE:-}" ]] || return 1
    dir="$(ls -d "$CA_PLUGIN_CACHE"/*/ 2>/dev/null | sort -V | tail -1)"
    dir="${dir%/}"
  fi
  [[ -n "$dir" && -x "$dir/scripts/ca-loop" ]] || return 1
  echo "$dir/scripts/ca-loop"
}

# The night loop in a container runs in the tmux session ca-loop, which
# `ca-loop service install` starts: a container has no launchd and no systemd.
# A restart or a rebuild of the container ends that session. `ca-loop service
# start` starts it again. It reads the projects of the service from
# ~/.claude/loop/service.projects on the claude volume and serves the listed
# ones that exist in this container. It exits 0 when the session runs, when no
# listed project is here, and when no project ran service install. So
# postStartCommand runs this on every start, with no opt-in check of its own.
# It runs after the firewall, because a tick needs the allowed hosts. A failure
# here must not fail the container start. A plugin before 1.5.31 has no
# service start.
loop_start() {
  local ca_loop
  ca_loop="$(ca_loop)" || return 0
  "$ca_loop" service start \
    || echo "NOTE: '$ca_loop service start' failed, so the night loop does not run in this container. A plugin before 1.5.31 has no service start." >&2
  return 0
}

# The released plugin version, in the cache file that the plugin's statusline
# and its update check read: ~/.cache/claude-agents-remote-version. Both
# refresh that file with gh, and gh in the container has no login. The host
# writes a mirror into <project>/.claude/latest-version, but only when Claude
# runs in that project on the host. A project that runs in the container only
# gets no mirror, and one day after the last one the statusline shows
# "agents 1.5.33 ?". The token of the compose secret reads plugin.json of the
# marketplace repo, so the container keeps its own cache fresh. curl reads the
# token from a config on stdin, so the token is not in the process list.
VERSION_CACHE="$HOME/.cache/claude-agents-remote-version"
VERSION_TTL=3600
VERSION_PIDFILE=/tmp/ca-version-watch.pid
VERSION_URL="https://api.github.com/repos/$MARKETPLACE_SOURCE/contents/.claude-plugin/plugin.json"

version_cache() {
  local mtime v
  [[ -s "$TOKEN_FILE" ]] || return 0
  if [[ -f "$VERSION_CACHE" ]]; then
    mtime="$(stat -c %Y "$VERSION_CACHE" 2>/dev/null || stat -f %m "$VERSION_CACHE" 2>/dev/null || echo 0)"
    (( $(date +%s) - mtime < VERSION_TTL )) && return 0
  fi
  v="$(curl -fsS --max-time 5 -K - -H 'Accept: application/vnd.github.raw' "$VERSION_URL" \
        <<<"header = \"Authorization: Bearer $(tr -d '[:space:]' < "$TOKEN_FILE")\"" 2>/dev/null \
      | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  # Only a version reaches the file. The statusline shows what it reads, and
  # an error body would stay in the status bar for an hour.
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 0
  mkdir -p "$(dirname "$VERSION_CACHE")" 2>/dev/null || return 0
  # In place, as the statusline writes it, so a reader keeps the same inode.
  printf '%s\n' "$v" > "$VERSION_CACHE"
}

# Is that pid a version loop of this script? The pid alone is not enough: the
# file outlives the process, and the container reuses pids.
is_version_loop() {
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q 'ca-plugin.sh version-loop'
}

# The loop runs in the background and outlives the shell that started it:
# postStartCommand returns at once. A loop from an earlier start goes first,
# because `devcontainer up` on a running container runs postStartCommand again.
# The loop has no trap, so TERM ends it at once, and its sleep exits alone.
version_watch() {
  local old launch
  [[ -s "$TOKEN_FILE" ]] || return 0
  old="$(cat "$VERSION_PIDFILE" 2>/dev/null || true)"
  if [[ "$old" =~ ^[0-9]+$ ]] && is_version_loop "$old"; then
    kill "$old" 2>/dev/null || true
  fi
  launch=(nohup)
  command -v setsid >/dev/null 2>&1 && launch=(setsid nohup)
  "${launch[@]}" "$0" version-loop >/dev/null 2>&1 </dev/null &
  return 0
}

version_loop() {
  echo $$ > "$VERSION_PIDFILE"
  while :; do
    version_cache
    sleep "$VERSION_TTL"
  done
}

marketplace_known() {
  grep -q "\"$MARKETPLACE_NAME\"" "$PLUGINS_DIR/known_marketplaces.json" 2>/dev/null
}

install() {
  # No token: start.sh already said so. The host mount is in use, unless an
  # install exists.
  if [[ ! -s "$TOKEN_FILE" ]]; then
    if installed; then
      echo "NOTE: Claude uses the container's own ca plugin. Without a token it does not update." >&2
      echo "      To use the host plugin again: claude plugin uninstall $PLUGIN" >&2
      echo "      The claude volume can be shared. The uninstall then applies to each project on it." >&2
    fi
    return 0
  fi
  installed && return 0

  echo "==> Installing the ca plugin in the container ($PLUGIN)"
  # The container has no SSH key, so the clone must use HTTPS.
  export CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1
  # --foreground keeps claude in the process group that owns the terminal.
  # Without it, timeout puts claude in a group of its own. start.sh runs this
  # script with a TTY, and the kernel stops claude with SIGTTOU when claude
  # changes the terminal mode from that background group. The stopped claude
  # does no work, and the timeout did not end it: one install hung for 50
  # minutes under 'timeout 120'. With --foreground, a timeout ends
  # claude only and not its git children.
  # A marketplace from an earlier attempt that stopped before the install.
  if ! marketplace_known; then
    if ! timeout --foreground 120 claude plugin marketplace add "$MARKETPLACE_SOURCE"; then
      echo "WARNING: could not add the marketplace $MARKETPLACE_SOURCE. Claude starts with the host plugin." >&2
      echo "         Examine the token: GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/$MARKETPLACE_SOURCE.git" >&2
      return 0
    fi
  fi
  if ! timeout --foreground 120 claude plugin install "$PLUGIN"; then
    echo "WARNING: could not install $PLUGIN. Claude starts with the host plugin." >&2
  fi
  return 0
}

case "${1:-}" in
  install)    install ;;
  installed)  installed ;;
  loop-start) loop_start ;;
  version-cache) version_cache ;;
  version-watch) version_watch ;;
  version-loop)  version_loop ;;
  *)          echo "Usage: $0 install|installed|loop-start|version-cache|version-watch" >&2; exit 2 ;;
esac
