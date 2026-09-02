# ─────────────────────────────────────────────────────────────────────────────
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated. Your project's settings go in the
# visible files one level up: tools.sh (toolchain), domains.conf (outbound hosts),
# firewall.sh (extra rules), docker-compose.override.yml (compose additions).
# ─────────────────────────────────────────────────────────────────────────────
#
# Build context is .devcontainer/, not .devcontainer/.template/, so this file can
# COPY the user-owned files that sit beside the hidden directory.
FROM debian:13.4-slim

# Core tools + the firewall toolchain (iptables/ipset/aggregate/dig/jq and ip from
# iproute2 are all used by init-firewall.sh). jq is required by the
# GitHub-IP-range parsing. iproute2 supplies the `ip route` call that finds the
# subnets the container is attached to — until now it arrived only as a
# side effect of a devcontainer feature, and without it the firewall setup fails.
# tzdata carries the zoneinfo database the TZ setting below resolves against;
# DEBIAN_FRONTEND keeps its postinst from prompting for a geographic area.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    zsh \
    tmux \
    sudo \
    tzdata \
    iptables \
    ipset \
    iproute2 \
    aggregate \
    dnsutils \
    jq \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# The `dev` user, with its own home. remoteUser in devcontainer.json points here.
#
# No sudo group: the useradd below grants none, and the sudoers entry further down
# covers one command. What does give this user full root in the container is the
# common-utils devcontainer feature — it reads remoteUser and writes
# /etc/sudoers.d/dev with NOPASSWD:ALL. Run `sudo -l` in the container to see it.
# So the runtime firewall is a guardrail against a mistake or a stray command, not
# a boundary that holds against the agent: root in here can flush the rules.
RUN groupadd --gid 1001 dev \
    && useradd --uid 1001 --gid dev --create-home --shell /bin/zsh dev

# Relocate ALL of Claude's state (login token + .claude.json + sessions) into a
# single directory so one named volume persists it across rebuilds. With
# CLAUDE_CONFIG_DIR set, every ~/.claude path lives under that directory instead,
# including the global config that normally sits at ~/.claude.json. Pre-create it
# dev-owned so the named volume (docker-compose.yml) initializes with dev
# ownership rather than root.
ENV CLAUDE_CONFIG_DIR=/home/dev/.claude
RUN mkdir -p /home/dev/.claude && chown dev:dev /home/dev/.claude

# tmux config (Ctrl-a prefix etc.) for the `dev` user.
COPY --chown=dev:dev .template/tmux.conf /home/dev/.tmux.conf

# Default shell zsh instead of sh.
ENV SHELL=/bin/zsh
# Do not auto-update Claude Code (the runtime firewall blocks the update egress).
ENV DISABLE_AUTOUPDATER=1
# Nicer-looking terminal.
ENV COLORTERM=truecolor
# Without a UTF-8 locale the image defaults to POSIX/C, so tmux and Claude render
# box-drawing glyphs and non-ASCII (e.g. õ, ä) as "_". C.UTF-8 ships with Debian
# — no locale-gen needed — and applies to every process, not just interactive
# shells.
ENV LANG=C.UTF-8
# Container clock, chosen at install time (the installer prompts; default
# Europe/Tallinn). Without this the container runs UTC, so log lines, git commit
# timestamps and Claude's own sense of "now" disagree with the host's wall clock.
# TZ is what glibc reads; /etc/localtime and /etc/timezone cover the programs
# that ignore it.
ENV TZ=__TIMEZONE__
RUN ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone

# Workaround for OrbStack/Docker Desktop "fakeowner" bind-mount filesystems:
# git's stat cache misinterprets inode/ctime changes and falsely reports
# unmodified files as dirty during rebase/merge. Disabling ctime trust and using
# a minimal stat comparison avoids "local changes would be overwritten" errors on
# clean trees.
RUN git config --global core.checkStat minimal && \
    git config --global core.trustctime false

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

# ── Default language runtimes ────────────────────────────────────────────────
# Node and Java, both on their current LTS line. They live here rather than in
# tools.sh because every project gets them: a template update can bump the version,
# whereas tools.sh is frozen the moment a project is installed.
#
# Node from NodeSource — Debian's own nodejs package trails the LTS line badly. Its
# setup script runs apt-get update itself.
ENV NODE_MAJOR=24
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Java from Debian, which does carry the current LTS. Headless: no AWT/Swing, which
# saves a lot of image for a container that has no display anyway. JAVA_HOME is
# derived from javac's real path so the architecture is not baked into it.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    openjdk-25-jdk-headless \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -s "$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")" /usr/lib/jvm/current
ENV JAVA_HOME=/usr/lib/jvm/current

# ── Playwright + headless Chromium ───────────────────────────────────────────
ENV PLAYWRIGHT_VERSION=1.62.1
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
# `playwright install` deletes every browser build that its own version does not
# use. A project on an older Playwright than PLAYWRIGHT_VERSION would thus delete
# the build below on its first install, and the replacement then has to come
# through the runtime firewall. This flag keeps every build in place.
ENV PLAYWRIGHT_SKIP_BROWSER_GC=1
RUN npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps --only-shell chromium \
    && chown -R dev:dev /ms-playwright \
    && rm -rf /root/.npm \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Project toolchain — anything beyond Node, Java and Playwright. It lives in
# tools.sh rather than in RUN lines here, because this Dockerfile belongs to the
# template and is overwritten on update, while tools.sh is yours and is not.
# Kept last so editing it invalidates no earlier layer, and dropped afterwards so
# the image does not ship the script itself.
COPY tools.sh /tmp/tools.sh
RUN chmod +x /tmp/tools.sh && /tmp/tools.sh && rm -f /tmp/tools.sh

WORKDIR /workspace
