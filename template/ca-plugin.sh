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
#   ca-plugin.sh installed   exit 0 when the plugin is installed, 1 when not
#
# An installed plugin updates through Claude's own mechanism: the update at
# start, /plugin and `claude plugin update`. The read-only host mount cannot do
# that. Claude loads the mount through --plugin-dir and does not know it as an
# installed plugin. The mount stays as the fallback for a container without a
# token.
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

# Read from the file and not from `claude plugin list`: attach.sh asks on each
# attach, and the file costs no Claude start.
installed() {
  grep -q "\"$PLUGIN\"" "$PLUGINS_DIR/installed_plugins.json" 2>/dev/null
}

marketplace_known() {
  grep -q "\"$MARKETPLACE_NAME\"" "$PLUGINS_DIR/known_marketplaces.json" 2>/dev/null
}

install() {
  # No token: start.sh already said so, and the host mount stays in use.
  [[ -s "$TOKEN_FILE" ]] || return 0
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
