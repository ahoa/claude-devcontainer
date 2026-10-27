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
works through the pipe. ([Read the script first](install.sh), and the parts in
[installer/](installer/) it sources from the same archive, if you'd rather not
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
| `--docker MODE` | `on` (default) gives the container the host Docker socket through the `docker-outside-of-docker` feature, which also gives the container control of the host. `off` leaves the feature out, and nothing in the container can reach Docker |
| `--force` | Overwrite an existing `.devcontainer/` and reuse conflicting Docker objects |

| Env var | Meaning |
|---------|---------|
| `CLAUDE_DEVCONTAINER_REPO` | Repo to install and update from, e.g. your own fork |
| `CLAUDE_DEVCONTAINER_REF` | Branch, tag or commit to install (default `main`) |

### The ca plugin

Claude in the container runs with the
[claude-agents](https://github.com/codeborne/claude-agents) plugin (`ca`). The
container gets it in one of two ways:

- **Its own install, which updates itself.** The container installs
  `claude-agents@codeborne` from the marketplace and updates it through Claude's
  own mechanism: the update at start, `/plugin` and `claude plugin update`. The
  repo is private, so this needs a read-only GitHub token. Make it as the
  claude-agents README tells in its section Devcontainer only, and keep it in
  1Password. The first `start.sh` asks for its 1Password reference (default
  `op://Employee/claude-agents-github-token/credential`) and reads it with
  `op read` on each start. The 1Password CLI (`op`) must be signed in. The
  container gets the token when it is created, so a new or changed token needs
  a rebuild: remove `.devcontainer/.build-hash` and run `start.sh`.
- **The host's install, read-only.** Without a token, the container uses the
  newest version under `~/.claude/plugins/cache/codeborne/claude-agents/` on the
  host, and only the host can update it. Install it on the host with
  `claude plugin install claude-agents@codeborne`.

## Run

```sh
cd /path/to/your/project
./.devcontainer/start.sh            # builds, starts, attaches Claude
./.devcontainer/attach.sh           # re-attach to the live session, no rebuild
./.devcontainer/start.sh -r         # rebuild + resume the previous Claude session
./.devcontainer/start.sh feature-x  # run Claude on git worktree "feature-x"
./.devcontainer/update-fw.sh        # apply domains.conf + current addresses to the live container
TMUX_WINDOWS=3 ./.devcontainer/start.sh   # override the window count for one run
```

The image has two parts. The base image `claude-devbase:<hash>` holds everything
that is the same in every project: the system packages, Node, Java, Playwright,
osv-scanner, Codex and the common-utils, claude and github-cli features. Its tag
is the hash of its inputs, so the projects on one template version share one copy
on a machine. `start.sh` builds it only when that tag is missing. The project
image adds the timezone, the firewall lists, `tools.sh` and, with `--docker on`,
the docker-outside-of-docker feature. After a template update the base of the
older version stays on disk. `start.sh` lists such images. Remove one with
`docker image rm` when no project uses it.

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
names the directory that holds its session transcripts after the working
directory. One shared path therefore put every project's sessions in one bucket,
and `--resume` in one project listed the sessions of all of them. This separates
what `--resume` offers you, not who can read what. Under the `shared` login every
container still mounts the whole `claude-shared` volume, so one project's
container can read another's transcripts. Answer `project` if that matters.

A project installed before this change keeps its old sessions under
`~/.claude/projects/-workspace` in the volume. On the first install or update
after this change, the installer hardlinks them into the project's new bucket, so
`--resume` finds them again. Both buckets sit in one volume, so the links cost no
disk space, and the old bucket stays where it is. That bucket holds the sessions
of every project that shared `/workspace`, so each project's history shows all of
them once. Sessions written after the update stay separate. The installer copies
auto-memory files instead of linking them, because two projects that share one
file read each other's edits.

The devcontainer's own compose project is `<name>-dc`, not `<name>`. Inside the
container the repo sits at `/workspace/<name>`, and a bare `docker compose` there
takes `<name>` as its project name. Without the suffix that name is the
devcontainer's project, and `docker compose down` in the repo stops the container
that runs the session. The devcontainer therefore answers to
`<name>-dc-devcontainer-1`.

A project installed before the suffix still has its devcontainer under the old
name. `start.sh` removes that container on the next run and builds the new one,
so the live tmux session goes with it once. The old image stays behind. Remove it
with `docker image rm <name>-devcontainer`.

## Loop

The night loop runs on the host, not in this container. `ca-loop`, a script of
the ca plugin, runs one story per tick on the host, in a sandbox of its own and
with a settings file that lists what a tick may run. `ca-loop service install`
puts it on launchd or systemd there. The steps are in the README of
[claude-agents](https://github.com/codeborne/claude-agents), section Loop.

Earlier versions of this template shipped `loop.sh`, which started a loop runner
inside the container. The plugin has no such runner any more, and `install.sh`
removes the file from a project on the next update.

Two rules for a project that is developed in this container:

- Give the loop a clone of its own. `node_modules` of this checkout is
  bind-mounted into the container, and its native binaries are the container's,
  not the host's.
- The test, build and E2E commands of the project must run on the host.
  `ca-loop check` shows the ones that do not. A runner that reaches its test
  stack by container name over the devcontainer's network runs nowhere else.

## Pushing from the container

The container has no SSH key, no forwarded agent, and `gh` is not logged in, so
nothing in there can push until you give it a credential. The firewall is not the
obstacle: GitHub's address ranges go into the allowed set whole, and the rule
that accepts them matches every port, SSH included. There is simply no key.

Give the container a token instead:

1. A fine-grained PAT scoped to this one repository, `contents: write`.
2. `.devcontainer/.gh_token`, mode `600`, holding the token and nothing else,
   listed in the project's `.gitignore`:

   ```sh
   printf '%s\n' github_pat_... > .devcontainer/.gh_token
   chmod 600 .devcontainer/.gh_token
   ```
3. The `secrets:` block in `docker-compose.override.yml` — the recipe is in that
   file's comments. Changing it is a build input, so run `./start.sh` once
   afterwards.

The token reaches the container as a **file** at `/run/secrets/gh_token`, never
as an environment variable. The Notes say why that difference matters.

The firewall setup reads the same file. It gets the GitHub address ranges from
`api.github.com/meta` on each container start, and with the token that call
counts against a limit of 5000 an hour instead of 60.

The recipe's `GIT_CONFIG_*` values are not secret, so they stay in
`environment:`. One points git's credential lookup at a helper that reads the
token file. The other rewrites an `origin` of `git@github.com:…` to HTTPS
**inside the container only**, so your own pushes from the host keep using SSH.
They are environment rather than `git config` because `/home/dev` is not a
volume: a `~/.gitconfig` written in the container dies with the next rebuild.

Both the file and those variables reach `devcontainer exec`, and through it the
tmux session of `start.sh`, which is how a push from the container works. `gh`
stays logged out: a push needs git and the helper, not `gh`.

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
    ├── Dockerfile               the project layer, FROM the shared base
    ├── base/                    the shared base image (Dockerfile, devcontainer.json, lock)
    ├── docker-compose.yml
    ├── init-firewall.sh         (+ domains-base.conf)
    ├── fw-watch.sh
    └── tmux.conf
```

**The four files at the top are yours.** Created once, never overwritten, so a
template update cannot touch them. Everything else says `DO NOT CHANGE THIS FILE`
at the top and is replaced on update. Each of the four is a build input, so
`start.sh` rebuilds when you change one.

| File | What goes in it |
|------|-----------------|
| `tools.sh` | Toolchain beyond the Node, Java, Playwright, osv-scanner and Codex CLI the image already has — Python, database clients, … Plain shell, run as root at build time with unrestricted network. |
| `domains.conf` | Outbound hosts, one per line. Only what your project adds: the baseline (Anthropic, npm, Docker Hub, `fm.codeborne.com`) is in `.template/domains-base.conf`, and GitHub ranges are fetched dynamically. |
| `firewall.sh` | `iptables`/`ipset` rules hostnames cannot express. Sourced at container start while the rules are still being built, before the catch-all reject. |
| `docker-compose.override.yml` | Services, published ports, environment, extra volumes. Merged on top of the template's compose file. |

The firewall resolves each host once, at container start, and the rules match
those addresses only. A CDN host can answer with other addresses later, so a download can fail
hours after the start although its host is in the list. `domains.conf` is baked
into the image too, so an edit to it would normally need a rebuild.

The container therefore keeps both current by itself: `.template/fw-watch.sh`
starts with the container and, every five minutes, copies an edited `domains.conf`
in and re-resolves every host. It only adds addresses and flushes nothing, so a
tick cannot take the network down. It stays quiet unless something changed —
`tail -f /tmp/fw-watch.log` inside the container shows what it did. Set
`FW_WATCH_INTERVAL` (seconds) in `docker-compose.override.yml` to change the pace.

To apply an edit at once instead of waiting for the next tick:

```bash
./.devcontainer/update-fw.sh                       # from the host
.devcontainer/.template/fw-watch.sh --once         # from a shell inside the container
```

A host **removed** from `domains.conf` is the one change this cannot apply: a
refresh never takes an address out of the live set. Removals take effect on the
next `./start.sh`, which rebuilds the image and builds the rules from scratch.
The tick says so in the log when it sees one.

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

To join the network of the project's own dev stack, declare that network as
external. `start.sh` creates each missing external network before `up`, so the
container also starts on a machine where nobody started the dev stack:

```yaml
services:
  devcontainer:
    networks: [default, app]
networks:
  app:
    name: myapp_default   # the dev stack's network: <compose project>_<network key>
    external: true
```

The dev stack later accepts the network only when it carries the compose labels
of its owner. `start.sh` reads them from the name: the text before the last `_`
is the compose project, and the text after it is the network key. When the name
does not follow that pattern, put the two labels on the network in the override.
`start.sh` then uses these labels:

```yaml
    labels:
      com.docker.compose.project: myapp
      com.docker.compose.network: back_end
```

### Knobs that do not survive an update

These work, but they live in template-owned files, so the next update replaces
them. Fine for an experiment; fork the template for anything you want to keep.

| Knob | File | What it does |
|------|------|--------------|
| `NODE_MAJOR` | `.template/base/Dockerfile` | Node LTS line (currently `24`) |
| `openjdk-25-jdk-headless` | `.template/base/Dockerfile` | JDK package; another LTS, or `jre` for a smaller image |
| `PLAYWRIGHT_VERSION` | `.template/base/Dockerfile` | Playwright release whose headless Chromium is baked in (currently `1.62.1`). Drop the whole `RUN` line to save ~680 MB in a project that never runs browser tests |
| `OSV_SCANNER_VERSION` | `.template/base/Dockerfile` | osv-scanner release baked in (currently `2.5.1`). The `/review` dependency audit runs it against `gradle.lockfile` and `pom.xml`; it needs `api.osv.dev`, which `domains-base.conf` allows |
| `CODEX_VERSION` | `.template/base/Dockerfile` | Codex CLI release baked in (currently `0.159.0`). `/xreview` runs `codex exec`. `CODEX_HOME` keeps its login in the Claude config volume, and `domains-base.conf` allows the OpenAI hosts. Log in once with `codex login --device-auth` in the container: the browser flow of `codex login` waits on a port in the container, which the host browser cannot reach |
| `ENV` block | `.template/base/Dockerfile` | `CLAUDE_CONFIG_DIR`, `SHELL`, `LANG`, `COLORTERM`, `DISABLE_AUTOUPDATER` |
| `extra_hosts` | `.template/docker-compose.yml` | Makes `host.docker.internal` exist on Linux Docker Engine |
| `domains-base.conf` | `.template/` | Baseline outbound hosts; template-owned so updates can extend it |
| `tmux.conf` | `.template/` | Prefix, mouse, scrollback, truecolor, clipboard, copy mode |
| Feature list | `.template/base/devcontainer.json` + lock | `common-utils`, Claude, `github-cli`, pinned by digest, in the base image. `docker-outside-of-docker` is in `.template/devcontainer.json` + lock, present when the install answered `--docker on` |
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
| `~/.config/claude-devcontainer/ca-plugin-token-ref` | Next `start.sh` asks for the 1Password reference of the ca plugin token again. On the host, for every project. |

## Updating

`install.sh` records the commit it installed from in
`.devcontainer/.template-version` — commit that file. `start.sh` compares it
against the repo on every run (SHA cached for a day, 10 s timeout, silent offline)
and prints one line when a newer template exists:

```
⚡ devcontainer template update: fe7781b → a3c91f2 — run ./.devcontainer/update.sh
```

```sh
./.devcontainer/update.sh            # update to the latest commit
./.devcontainer/update.sh --check    # just report; exit 1 = update available
./.devcontainer/update.sh --ref v2   # update to a specific branch, tag or commit
```

`update.sh` finds the latest commit with `git ls-remote`, which has no rate
limit. Only a host without git uses the GitHub API. The API allows 60 calls an
hour per IP address without a token, and every device behind the same NAT
shares that limit. With `GITHUB_TOKEN` set or `gh` logged in, `update.sh`
sends the token, and the limit is 5000. When the limit is used up, the error
says so and gives the reset time.

An update is the installer re-run at a newer commit: template-owned files are
rewritten, your four are left alone, and the changed build inputs make the next
`start.sh` rebuild. Nothing to merge. It refuses to run on a dirty
`.devcontainer/`, so `git diff` afterwards shows exactly what changed and
`git checkout` undoes it; `--force` overrides.

**Update every project that mounts `claude-shared` at the same time.** Since
`31bd592` (2026-10-06) the `dev` user is UID 1000. Before that it was UID 1001.
The first start of an updated project gives the volume to UID 1000, because
`postStartCommand` re-owns it when another UID owns it. A project that is not
updated yet still runs as UID 1001, so its Claude cannot save its login or its
sessions. `/login` then reports that the credentials file is not writable, and
the `SessionStart` hook fails with `EACCES` under `session-env/`. `start.sh`
prints a warning before a start that re-owns the volume and names the
containers that mount it. A `<name>_claude` volume has no other project to
break.

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
  (1.8 MB) into `.devcontainer/.template/` on first run. Never into the project's
  own `node_modules` — that made the project's package manager our business, and
  a pnpm workspace, whose `workspace:`/`catalog:` dependencies npm refuses to
  parse, could not be started at all. A project needs no Node of its own. A
  project started before this keeps an unused copy in its own `node_modules`;
  the next `npm ci` or `pnpm install` clears it.
- For the ca plugin, one of the two (see Install, The ca plugin): the 1Password
  CLI `op` and a read-only GitHub token for `codeborne/claude-agents`, or the
  `claude` CLI on the host with the plugin installed. The host install needs git
  access to `codeborne/claude-agents` over SSH. With neither, Claude starts
  without the plugin and `start.sh` says so.

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
  path (rootless Docker) mounts it in `docker-compose.override.yml`. The socket
  also reaches the shared base image `claude-devbase:<hash>`. A container with the
  socket can put another image under that tag, and every project on the machine,
  `--docker off` projects too, builds on it at the next rebuild.
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
- **A push from the container goes over HTTPS with a token.** There is no SSH key
  in there and no forwarded agent, so SSH is not an option — not because the
  firewall blocks it (GitHub's ranges are allowed on every port), but because
  there is no key to offer. See the Loop section for the token and the git config
  that uses it.
- **That token is a file, not an environment variable**, and the difference is
  the point. An env var shows up in `docker inspect` for every member of the
  host's `docker` group. It also lands in the merged compose config that
  `start.sh` prints at `--log-level debug`. And every process Claude starts —
  node, Chromium, MCP servers, Gradle — inherits it, then exposes it again in
  `/proc/<pid>/environ`. A compose secret does none of that. One thing it does
  not change: whoever reaches the Docker socket can `docker exec` and read the
  file anyway, which is the trust boundary the socket already sets. Scope the
  PAT to one repository and give it an expiry.
- **The ca plugin token is a compose secret too**, at
  `/run/secrets/ca_plugin_token`. `start.sh` reads it from 1Password on the host
  and gives it to `devcontainer up` only, so it is never written to a file on the
  host. Compose writes it into the container when it creates the container, and
  `docker commit` or an export of the container carries it. Git in the container
  uses it only for the `codeborne/claude-agents` URL. Use a fine-grained token
  with read access to that one repo: the agent in the container can read the
  file.
- **`start.sh` runs on the host from a directory the container can write.**
  That was true before, but now `start.sh` also reads 1Password through it. An
  agent that rewrites `.devcontainer/` scripts gets the host user's 1Password
  session at the next start. Look at `git status` before you run `start.sh`
  after an unattended session.
  The claude-agents README puts the token in `GH_TOKEN` and runs
  `gh auth setup-git`. This template does not, for the reasons in the bullet
  above, and because that helper gives the token to every GitHub URL.
- **The container's ca plugin is not the host's.** The two can have different
  versions, at different paths. Each Claude session copies the plugin's rules
  into the project's `.claude/rules/` with its own path, so the rules change each
  time you change between host and container. Do not run a host session and a
  container session in one project at the same time.
- **A loop host is worth more than a laptop.** It holds the Claude login, the
  Feature Manager token, a PAT that can write to the repo, and — unless
  installed with `--docker off` — the Docker socket, which is the host itself.
  Close it to the LAN except for SSH, and give each project on it its own login
  volume (`--login project`) so one unattended run cannot read the rest.
