#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated.
#
# Prints the GitHub token for the private repo of the ca plugin, or nothing.
# It runs on the HOST. start.sh gives the output to compose as a secret, and
# ca-plugin.sh in the container installs the plugin with it.
#
# The token comes from CA_PLUGIN_TOKEN when that is set. If not, it comes from
# 1Password through `op read`. The 1Password reference is asked once and kept in
# REF_FILE, for every project on this host. The file holds the reference, never
# the token. The answer '-' keeps the question away and uses no token. Remove the
# file to get the question again.
#
# Without a token, Claude in the container uses the read-only host plugin, as
# before. Every failure here is a warning: a start without the token still works.
set -uo pipefail

DEFAULT_REF="op://Employee/claude-agents-github-token/credential"
REF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-devcontainer/ca-plugin-token-ref"

if [[ -n "${CA_PLUGIN_TOKEN:-}" ]]; then
  printf '%s' "$CA_PLUGIN_TOKEN"
  exit 0
fi

ref=""
if [[ -f "$REF_FILE" ]]; then
  ref="$(head -1 "$REF_FILE")"
elif [[ -t 0 ]]; then
  {
    echo "The ca plugin can update itself in the container when the container has a"
    echo "read-only GitHub token for codeborne/claude-agents. The claude-agents README,"
    echo "section Devcontainer only, tells how to make the token."
  } >&2
  # End of input (Ctrl-D) saves nothing, so the question comes again next time.
  if ! read -r -p "1Password reference for the token ['-' for no token, Enter for $DEFAULT_REF]: " ref; then
    echo >&2
    exit 0
  fi
  ref="${ref:-$DEFAULT_REF}"
  mkdir -p "$(dirname "$REF_FILE")"
  printf '%s\n' "$ref" > "$REF_FILE"
  echo "Saved in $REF_FILE. Remove that file to get this question again." >&2
fi

[[ -z "$ref" || "$ref" == "-" ]] && exit 0

if [[ ! "$ref" =~ ^op://[^[:space:]]+$ ]]; then
  echo "WARNING: $REF_FILE holds '$ref', which is not an op:// reference. Claude starts with the host plugin." >&2
  exit 0
fi
if ! command -v op >/dev/null 2>&1; then
  echo "WARNING: the 1Password CLI (op) is not installed, so the ca plugin token is not available. Claude starts with the host plugin." >&2
  exit 0
fi
if ! token="$(op read "$ref")" || [[ -z "$token" ]]; then
  echo "WARNING: 'op read $ref' gave no token. Claude starts with the host plugin." >&2
  exit 0
fi
printf '%s' "$token"
