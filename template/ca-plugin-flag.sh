#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated.
#
# Prints ` --plugin-dir <path>` for the ca plugin, or nothing when the host has
# no plugin installed. It runs on the HOST. docker-compose.yml mounts the plugin
# cache at the same absolute path inside the container, so a path that is valid
# here is valid there.
#
# start.sh and attach.sh both need it. tmux starts Claude through a
# NON-interactive zsh, which does not read ~/.zshrc, so the claude() function
# there never reaches the session those two scripts open.
set -uo pipefail

CACHE="$HOME/.claude/plugins/cache/codeborne/claude-agents"
DIR="$(ls -d "$CACHE"/*/ 2>/dev/null | sort -V | tail -1)"

if [[ -z "$DIR" ]]; then
    # An empty mount must be loud. A session that "works" without the rules is
    # the worst outcome, so say it and let Claude start without the pipeline.
    echo "WARNING: the ca plugin is not installed on the host, so Claude starts without it." >&2
    echo "         Install it on the host: claude plugin install claude-agents@codeborne" >&2
    exit 0
fi

printf ' --plugin-dir %s' "${DIR%/}"
