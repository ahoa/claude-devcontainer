FROM debian:13.4-slim

# Core tools + the firewall toolchain (iptables/ipset/aggregate/dig/jq are all
# used by init-firewall.sh). jq is required by the GitHub-IP-range parsing.
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
    aggregate \
    dnsutils \
    jq \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# The `dev` user (own home + sudo group membership). remoteUser in
# devcontainer.json points here.
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
COPY --chown=dev:dev tmux.conf /home/dev/.tmux.conf

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

# Firewall script + its two config files (outbound hosts, inbound/forwarded
# ports). Build-time has full network; the firewall only applies at container
# runtime via postStartCommand.
COPY init-firewall.sh /usr/local/bin/
COPY allowed-domains.conf /usr/local/bin/
COPY firewall-ports.conf /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh && \
    echo "dev ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/init-firewall && \
    chmod 0440 /etc/sudoers.d/init-firewall

# Project toolchain (Node, JDK, Python, …). It lives in install-tools.sh rather
# than in RUN lines here, because this Dockerfile belongs to the template and is
# overwritten on update, while install-tools.sh is yours and is not. Kept last so
# editing it invalidates no earlier layer, and dropped afterwards so the image
# does not ship the script itself.
COPY install-tools.sh /tmp/install-tools.sh
RUN chmod +x /tmp/install-tools.sh && /tmp/install-tools.sh && rm -f /tmp/install-tools.sh

WORKDIR /workspace
