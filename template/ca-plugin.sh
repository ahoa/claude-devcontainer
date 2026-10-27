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
#
# The Dockerfile also copies this script to /usr/local/bin, so the claude()
# function in ca-claude.zsh makes the same test.
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
TOKEN_FILE=/run/secrets/ca_plugin_token
PLUGINS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# Read from the files and not from `claude plugin list`: attach.sh asks on each
# attach, and the files cost no Claude start. Claude loads an entry of the user
# scope, or an entry whose projectPath is this workspace. The claude volume can
# be shared between projects, so an entry for another workspace does not count.
# An entry whose directory is gone does not count, and neither does a plugin
# that settings.json disables.
installed() {
  local workspace dir
  workspace="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  [[ "$(jq -r --arg p "$PLUGIN" 'if .enabledPlugins[$p] == false then "off" else "on" end' \
    "$SETTINGS" 2>/dev/null)" != off ]] || return 1
  while read -r dir; do
    [[ -n "$dir" && -d "$dir" ]] && return 0
  done < <(jq -r --arg p "$PLUGIN" --arg ws "$workspace" \
    '.plugins[$p][]? | select(.scope == "user" or .projectPath == $ws) | .installPath' \
    "$PLUGINS_DIR/installed_plugins.json" 2>/dev/null)
  return 1
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
  # A marketplace from an earlier attempt that stopped before the install.
  if ! marketplace_known; then
    if ! timeout 120 claude plugin marketplace add "$MARKETPLACE_SOURCE"; then
      echo "WARNING: could not add the marketplace $MARKETPLACE_SOURCE. Claude starts with the host plugin." >&2
      echo "         Examine the token: GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/$MARKETPLACE_SOURCE.git" >&2
      return 0
    fi
  fi
  if ! timeout 120 claude plugin install "$PLUGIN"; then
    echo "WARNING: could not install $PLUGIN. Claude starts with the host plugin." >&2
  fi
  return 0
}

case "${1:-}" in
  install)   install ;;
  installed) installed ;;
  *)         echo "Usage: $0 install|installed" >&2; exit 2 ;;
esac
