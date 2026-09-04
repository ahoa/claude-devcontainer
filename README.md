# Claude devcontainer

A project-agnostic [dev container](https://containers.dev/) that runs
[Claude Code](https://docs.claude.com/en/docs/claude-code) inside a network
sandbox and a long-lived `tmux` session. Drop it into any repo with one command.

The application under development is meant to run on your **host**, not in here —
the container is where Claude reads, edits and builds the code.

## Install

Run this in the project you want the devcontainer in:

```sh
curl -fsSL https://github.com/ahoa/claude-devcontainer/raw/main/install.sh | bash
```

It asks five things: a project name (used for the Docker image, compose project
and volumes), how many tmux windows to open, the container's timezone, whether
Claude's login is shared with your other projects or belongs to this one, and
whether the container gets the host Docker socket. In a project that already has a
`.devcontainer/`, every question defaults to what that install answered, so
pressing Enter five times keeps it.

Prompts are read from your terminal rather than stdin, so the interactive flow
works through the pipe. ([Read the script first](install.sh) if you'd rather not
pipe an unread one into your shell.) To answer up front, or to install somewhere
other than the current directory:

```sh
./install.sh --name myapp --windows 2 --timezone UTC /path/to/your/project
```

| Flag | Meaning |
|------|---------|
| `--name NAME` | Project name, lowercase `[a-z0-9][a-z0-9_-]*` |
| `--windows N` | tmux windows, each running its own Claude (default `1`) |
| `--timezone ZONE` | IANA timezone for the container clock (default `Europe/Tallinn`) |
| `--login MODE` | `shared` (default) — one Claude login for every project from this template — or `project`, a login of this project's own |
| `--docker MODE` | `on` (default) mounts the host Docker socket, which also gives the container control of the host. `off` leaves the socket out and drops the `docker-outside-of-docker` feature with it |
| `--force` | Overwrite an existing `.devcontainer/` and reuse conflicting Docker objects |

| Env var | Meaning |
|---------|---------|
| `CLAUDE_DEVCONTAINER_REPO` | Repo to install and update from, e.g. your own fork |
| `CLAUDE_DEVCONTAINER_REF` | Branch, tag or commit to install (default `main`) |

## Run

```sh
cd /path/to/your/project
./.devcontainer/start.sh            # builds, starts, attaches Claude
./.devcontainer/attach.sh           # re-attach to the live session, no rebuild
./.devcontainer/start.sh -r         # rebuild + resume the previous Claude session
./.devcontainer/start.sh feature-x  # run Claude on git worktree "feature-x"
./.devcontainer/update-fw.sh        # re-resolve the allowed hosts in the live container
TMUX_WINDOWS=3 ./.devcontainer/start.sh   # override the window count for one run
```

`start.sh` hashes the build inputs and rebuilds only when they change. The tmux
session and the Claude login persist across disconnects and rebuilds, so you can
detach, reconnect from another machine, and pick up where you left off.

Where that login lives is the fourth install question. `shared` puts it in one
`claude-shared` Docker volume that **every** project from this template mounts, so
a single `/login` authenticates them all — which also means any one project's
container can read the token all the others use. `project` gives this project a
`<name>_claude` volume of its own: one more `/login` to do, and a repo you do not
trust cannot reach the other projects' credentials. `start.sh` creates whichever
volume the install chose. If you bring the container up some other way, run
`docker volume create <that name>` once.

Your project is mounted at `/workspace/<name>`, not at a bare `/workspace`. Claude
keys its sessions, todos and shell snapshots by the working directory, so one
shared path put every project's sessions in one bucket — `--resume` in one project
then listed the sessions of all of them. A project installed before this change
keeps its old sessions under `~/.claude/projects/-workspace` in the volume, where
nothing lists them any more. This separates what `--resume` offers you, not who
can read what: under the `shared` login every container still mounts the whole
`claude-shared` volume, so one project's container can read another's transcripts.
Answer `project` if that matters.

## Configuration

```
.devcontainer/
├── tools.sh                     ← yours: project toolchain
├── domains.conf                 ← yours: extra outbound hosts
├── firewall.sh                  ← yours: extra firewall rules
├── docker-compose.override.yml  ← yours: compose additions
│
├── start.sh                     the commands you run
├── attach.sh
├── update.sh
├── update-fw.sh
│
└── .template/                   machinery — hidden, never edit
    ├── devcontainer.json        (+ devcontainer-lock.json)
    ├── Dockerfile
    ├── docker-compose.yml
    ├── init-firewall.sh         (+ domains-base.conf)
    └── tmux.conf
```

**The four files at the top are yours.** Created once, never overwritten, so a
template update cannot touch them. Everything else says `DO NOT CHANGE THIS FILE`
at the top and is replaced on update. Each of the four is a build input, so
`start.sh` rebuilds when you change one.

| File | What goes in it |
|------|-----------------|
| `tools.sh` | Toolchain beyond the Node, Java, Playwright and osv-scanner the image already has — Python, database clients, … Plain shell, run as root at build time with unrestricted network. |
| `domains.conf` | Outbound hosts, one per line. Only what your project adds: the baseline (Anthropic, npm, Docker Hub, `fm.codeborne.com`) is in `.template/domains-base.conf`, and GitHub ranges are fetched dynamically. |
| `firewall.sh` | `iptables`/`ipset` rules hostnames cannot express. Sourced at container start while the rules are still being built, before the catch-all reject. |
| `docker-compose.override.yml` | Services, published ports, environment, extra volumes. Merged on top of the template's compose file. |

The firewall resolves each host once, at container start, and the rules match
those addresses only. A CDN host can answer with other addresses later, so a download can fail
hours after the start although its host is in the list. Then refresh the set. It
adds the new addresses and flushes nothing:

```bash
./.devcontainer/update-fw.sh                      # from the host
sudo /usr/local/bin/init-firewall.sh --refresh    # from a shell inside the container
```

Nothing needs configuring to reach the host — it is at `host.docker.internal:PORT`,
which the firewall allows — or to reach a sibling compose service, which resolves
by its service name. Two recipes for the override file:

```yaml
services:
  # Expose a container port to a browser on your machine. Bind to localhost: the
  # short "5173:5173" form binds every interface, LAN included.
  devcontainer:
    ports:
      - "127.0.0.1:5173:5173"

  # Only for config that cannot be moved off localhost — gives the service the
  # devcontainer's network namespace, so it answers on localhost:5432.
  db:
    image: postgres:17
    network_mode: "service:devcontainer"
```

Relative paths in the override resolve against `.template/`, since that is where
the base compose file lives: `../data` is `.devcontainer/data`.

### Knobs that do not survive an update

These work, but they live in template-owned files, so the next update replaces
them. Fine for an experiment; fork the template for anything you want to keep.

| Knob | File | What it does |
|------|------|--------------|
| `NODE_MAJOR` | `.template/Dockerfile` | Node LTS line (currently `24`) |
| `openjdk-25-jdk-headless` | `.template/Dockerfile` | JDK package; another LTS, or `jre` for a smaller image |
| `PLAYWRIGHT_VERSION` | `.template/Dockerfile` | Playwright release whose headless Chromium is baked in (currently `1.62.1`). Drop the whole `RUN` line to save ~680 MB in a project that never runs browser tests |
| `OSV_SCANNER_VERSION` | `.template/Dockerfile` | osv-scanner release baked in (currently `2.5.1`). The `/review` dependency audit runs it against `gradle.lockfile` and `pom.xml`; it needs `api.osv.dev`, which `domains-base.conf` allows |
| `ENV` block | `.template/Dockerfile` | `CLAUDE_CONFIG_DIR`, `SHELL`, `LANG`, `COLORTERM`, `DISABLE_AUTOUPDATER` |
| `extra_hosts` | `.template/docker-compose.yml` | Makes `host.docker.internal` exist on Linux Docker Engine |
| `domains-base.conf` | `.template/` | Baseline outbound hosts; template-owned so updates can extend it |
| `tmux.conf` | `.template/` | Prefix, mouse, scrollback, truecolor, clipboard, copy mode |
| Feature list | `.template/devcontainer.json` + lock | `common-utils`, Claude, `github-cli`, pinned by digest. `docker-outside-of-docker` joins them when the install answered `--docker on` |
| `--dangerously-skip-permissions` | `start.sh`, `attach.sh` | How Claude is launched |

To make such a change permanent, fork this repo and install from the fork — it is
recorded in `.template-version`, so updates come from it too:

```sh
CLAUDE_DEVCONTAINER_REPO=https://github.com/you/your-fork ./install.sh --name myapp .
```

### State files

| File | Effect of deleting it |
|------|-----------------------|
| `.devcontainer/.build-hash` | Next `start.sh` does a clean rebuild. Gitignored. |
| `.devcontainer/.update-check` | Next update check fetches the remote SHA instead of the day-old cache. Gitignored. |
| The login volume (`claude-shared`, or `<name>_claude`) | Discards the Claude login it holds. |

## Updating

`install.sh` records the commit it installed from in
`.devcontainer/.template-version` — commit that file. `start.sh` compares it
against the repo on every run (SHA cached for a day, 5 s timeout, silent offline)
and prints one line when a newer template exists:

```
⚡ devcontainer template update: fe7781b → a3c91f2 — run ./.devcontainer/update.sh
```

```sh
./.devcontainer/update.sh            # update to the latest commit
./.devcontainer/update.sh --check    # just report; exit 1 = update available
./.devcontainer/update.sh --ref v2   # update to a specific branch, tag or commit
```

An update is the installer re-run at a newer commit: template-owned files are
rewritten, your four are left alone, and the changed build inputs make the next
`start.sh` rebuild. Nothing to merge. It refuses to run on a dirty
`.devcontainer/`, so `git diff` afterwards shows exactly what changed and
`git checkout` undoes it; `--force` overrides.

### Projects installed before `update.sh` existed

Bootstrap them with the installer, run in the project directory — no arguments, it
reads the existing answers back out of the install:

```sh
curl -fsSL https://github.com/ahoa/claude-devcontainer/raw/main/install.sh | bash
```

Such a project owns its `Dockerfile`, `docker-compose.yml` and
`init-firewall.sh`, and those are template-owned now, so the installer replaces
them — keeping a verbatim `<file>.from-old` copy of each first, and printing a
warning. Nothing is lost, but moving the content across is manual: the old
template had no marker saying which lines were the project's.

| Was in the old file | Goes to |
|---------------------|---------|
| Toolchain (`apt`/`curl` installs) | `tools.sh` |
| `iptables` / `ipset` rules | `firewall.sh` |
| Extra compose services | `docker-compose.override.yml` |
| Outbound hosts | `domains.conf` |
| `ENV`, `COPY`, other image-level lines | Nowhere — fork the template |

Handled for you: `allowed-domains.conf` is renamed to `domains.conf` with entries
intact, and the old `OPEN_PORTS`/`PORT_FORWARDS` arrays are reported rather than
carried over — neither is needed any more. A per-project `<project>_claude` volume
from the pre-shared-login era is copied into `claude-shared` when you choose the
shared login, and can be removed with `docker volume rm <project>_claude` once the
new setup works. Answer `project` instead and that same volume stays in use, with
nothing to copy and nothing to remove. Delete the
`.from-old` files when you are done.

## Requirements

- Docker with Compose v2 — Docker Desktop, OrbStack or Docker Engine
- `bash`, `curl`, and `tar` when installing without a checkout
- Node.js / `npm` on the host: `start.sh` installs the `@devcontainers/cli`
  locally into the project on first run

The same install works from macOS and Linux, on x86-64 and arm64. Where the two
would differ the template handles it: `extra_hosts` gives Linux a
`host.docker.internal`, the devcontainer CLI remaps the container user's UID to
yours on Linux bind mounts, `JAVA_HOME` is derived rather than hardcoded per
architecture, and the host scripts stick to what both BSD and GNU userlands have.
Rootless Docker is the exception — its socket is not at `/var/run/docker.sock`.
Install with `--docker off` and mount the real path in
`docker-compose.override.yml`, which updates never touch.

## Notes

- **The sandbox is not a security boundary against a hostile toolchain.** The
  container has `NET_ADMIN`/`NET_RAW`, and the `common-utils` feature gives `dev`
  passwordless root in it, so code running in there can flush the firewall. Read
  the firewall as a guardrail against a mistake, a stray command or an injected
  instruction, not as a wall that holds against a determined attacker.
- **The host Docker socket is the loosest part of it, and it is optional.** A
  container that reaches that socket can start a privileged one, so mounting it
  hands over the host. `--docker on` is the default because tests that start their
  own containers need it. Answer `off` for a project that does not, and nothing in
  the container can reach Docker. A project that needs the socket at a different
  path (rootless Docker) mounts it in `docker-compose.override.yml`.
- **The host is reachable on every port.** The firewall allows whatever
  `host.docker.internal` resolves to, because your application runs there — which
  also puts other projects' databases, your IDE's built-in server and SSH within
  reach of code in the container. Bind local dev services to `127.0.0.1` if you
  would rather they were not visible.
- **What the firewall allows**, beyond the hosts in `domains.conf` and
  `.template/domains-base.conf`: the GitHub ranges, the container's
  directly-connected subnets, the host, and DNS to the container's own resolvers.
  There is no blanket rule for SSH, IPv6 egress is closed as a whole, and a
  failure during setup closes the network instead of leaving it open.
- **One login volume covers every project, unless you asked for `project`.** A
  container that mounts `claude-shared` reads the token your other projects use.
- Claude is launched with `--dangerously-skip-permissions`. The firewall is the
  compensating control, so review `domains.conf` before you trust it.
