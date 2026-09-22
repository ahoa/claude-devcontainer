#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated.
#
# The hash of the devcontainer's build inputs, and the one place that decides
# what counts as one.
#
#   build-hash.sh           print the hash of the inputs as they are now
#   build-hash.sh --check    exit 0 when .build-hash matches, 1 when it does not
#
# `devcontainer up` REUSES an existing container as-is — it does not notice an
# edited Dockerfile (or any other build input) and will happily re-attach to a
# stale image. So the inputs are hashed here and the last successful build's hash
# is kept in .build-hash beside this directory.
#
# Two callers, two answers to a changed hash. start.sh rebuilds: it is what you
# run, and you are there to watch it. loop.sh refuses (--check) and tells you to
# run start.sh: it runs at night with nobody watching, and a rebuild that fails
# there leaves no container and no session to find out from.
set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)"
# .devcontainer/ — where the user-owned build inputs and .build-hash live.
DEVCONTAINER_DIR="$(cd "$TEMPLATE_DIR/.." && pwd)"

BUILD_INPUTS=(
    "$TEMPLATE_DIR/Dockerfile"
    "$TEMPLATE_DIR/docker-compose.yml"
    "$TEMPLATE_DIR/tmux.conf"
    "$TEMPLATE_DIR/init-firewall.sh"
    "$TEMPLATE_DIR/domains-base.conf"
    "$TEMPLATE_DIR/devcontainer.json"
    "$DEVCONTAINER_DIR/tools.sh"
    "$DEVCONTAINER_DIR/domains.conf"
    "$DEVCONTAINER_DIR/firewall.sh"
    "$DEVCONTAINER_DIR/docker-compose.override.yml"
)
# This script is not in the list. It decides what a build input is; it is not one
# itself, and adding it would force a rebuild on every template update that
# touches it.

# sha256sum is GNU coreutils; macOS only started shipping it recently, and shasum is
# what is always there. Either way the hash only has to be stable, not standard.
if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD=(sha256sum)
else
    SHA_CMD=(shasum -a 256)
fi
BUILD_HASH="$(cat "${BUILD_INPUTS[@]}" 2>/dev/null | "${SHA_CMD[@]}" | cut -d' ' -f1)"

if [[ "${1:-}" == "--check" ]]; then
    HASH_FILE="$DEVCONTAINER_DIR/.build-hash"
    # No .build-hash means no successful build has been recorded here, which for
    # --check is the same answer as a stale one: this is not a container anybody
    # may reuse unseen.
    [[ -f "$HASH_FILE" && "$(cat "$HASH_FILE")" == "$BUILD_HASH" ]] || exit 1
    exit 0
fi

echo "$BUILD_HASH"
