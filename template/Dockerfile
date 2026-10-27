# ─────────────────────────────────────────────────────────────────────────────
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated. Your project's settings go in the
# visible files one level up: tools.sh (toolchain), domains.conf (outbound hosts),
# firewall.sh (extra rules), docker-compose.override.yml (compose additions).
# ─────────────────────────────────────────────────────────────────────────────
#
# Build context is .devcontainer/, not .devcontainer/.template/, so this file can
# COPY the user-owned files that sit beside the hidden directory.
#
# Everything that is the same in every project is in the base image, built from
# base/. Its tag holds the hash of its inputs, so all the projects on one template
# version share one copy of it on a machine. start.sh builds the base when the tag
# is missing and gives its name in BASE_IMAGE. This file adds only what differs
# per project: the clock, the firewall lists and tools.sh.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
# The devcontainer features in the base can leave another user active.
USER root

# Container clock, chosen at install time (the installer prompts; default
# Europe/Tallinn). Without this the container runs UTC, so log lines, git commit
# timestamps and Claude's own sense of "now" disagree with the host's wall clock.
# TZ is what glibc reads; /etc/localtime and /etc/timezone cover the programs
# that ignore it.
ENV TZ=__TIMEZONE__
RUN ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone

# Firewall script, its two host lists (the template's baseline and the project's
# own additions) and the project's own extra rules. Build-time has full network; the firewall only applies at
# container runtime via postStartCommand.
COPY .template/init-firewall.sh /usr/local/bin/
COPY .template/domains-base.conf /usr/local/bin/
COPY domains.conf /usr/local/bin/
COPY firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh && \
    echo "dev ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/init-firewall && \
    chmod 0440 /etc/sudoers.d/init-firewall

# The git credential for the private repo of the ca plugin, see ca-plugin.sh.
# It applies to that one repo URL only, so it does not compete with a token that
# the project gives git for its own repo. The token is a compose secret file, not
# an environment variable, and the helper gives nothing when the file is absent.
# --system: /home/dev is not a volume, but the image keeps /etc/gitconfig. Git
# matches the path of a credential URL segment by segment, so the URL with .git
# and the URL without it each need a key.
RUN for url in https://github.com/codeborne/claude-agents.git https://github.com/codeborne/claude-agents; do \
      git config --system "credential.$url.helper" \
        '!f() { test "$1" = get && test -s /run/secrets/ca_plugin_token && echo username=x-access-token && echo "password=$(cat /run/secrets/ca_plugin_token)"; }; f'; \
    done

# Project toolchain — anything beyond Node, Java, Playwright, osv-scanner and Codex. It lives in
# tools.sh rather than in RUN lines here, because this Dockerfile belongs to the
# template and is overwritten on update, while tools.sh is yours and is not.
# Kept last so editing it invalidates no earlier layer, and dropped afterwards so
# the image does not ship the script itself.
COPY tools.sh /tmp/tools.sh
RUN chmod +x /tmp/tools.sh && /tmp/tools.sh && rm -f /tmp/tools.sh

WORKDIR /workspace/__PROJECT_NAME__
