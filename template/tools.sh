#!/bin/bash
#
# tools.sh — your project's toolchain. EDIT THIS FILE.
#
# Runs at IMAGE BUILD time, as root, with full network access: the runtime
# firewall is applied later (postStartCommand), so it does not restrict anything
# here. Editing this file changes a build input, so start.sh notices and forces a
# clean rebuild on the next run.
#
# This file is yours. The installer creates it once and never overwrites it, so
# template updates leave your toolchain alone — as they do domains.conf and
# docker-compose.override.yml. Everything else in .devcontainer/ belongs to the
# template and IS overwritten; that is why it says so at the top of each file
# and why the bulk of it is tucked away in .template/.
#
# The base image already has Node and Java, both on their current LTS line, plus
# ca-certificates, curl, git, zsh, tmux, sudo, tzdata and the firewall tooling.
# Anything else — Python, a database client, a linter — goes below. The base image
# build removes /var/lib/apt/lists, so run `apt-get update` before installing.
set -euo pipefail

# Example — Python:
#   apt-get update
#   apt-get install -y --no-install-recommends python3 python3-venv
#
# Example — a different Node line than the image's default:
#   curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
#   apt-get install -y --no-install-recommends nodejs
#
# Finish with a cleanup to keep the image small:
#   apt-get clean && rm -rf /var/lib/apt/lists/*

echo "tools.sh: nothing to install — edit .devcontainer/tools.sh to add your toolchain"
