# Claude devcontainer

A project-agnostic [dev container](https://containers.dev/) that runs
[Claude Code](https://docs.claude.com/en/docs/claude-code) inside a network
sandbox and a long-lived `tmux` session. Drop it into any repo with one command.

## What you get

Running `install.sh` writes this into your project:

```
.devcontainer/
├── tools.sh                     ← yours: project toolchain
├── domains.conf                 ← yours: extra outbound hosts
├── docker-compose.override.yml  ← yours: compose additions
│
├── start.sh                     the commands you run
├── attach.sh
├── update.sh
│
└── .template/                   machinery — hidden, never edit
    ├── devcontainer.json
    ├── devcontainer-lock.json
    ├── Dockerfile
    ├── docker-compose.yml
    ├── init-firewall.sh
    └── tmux.conf
```

**The three files at the top are yours.** They are created once and never
overwritten, so a template update cannot touch them. Below them sit the three
commands you run. Everything else is machinery: it says `DO NOT CHANGE THIS FILE`
at the top, is replaced on update, and lives out of sight in `.template/`.

`start.sh` and `attach.sh` point the devcontainer CLI at the hidden config with
`--config`, so `devcontainer.json` does not have to sit where the CLI would look
for it on its own. Driving the container by hand needs that flag too:
`devcontainer up --workspace-folder . --config .devcontainer/.template/devcontainer.json`.

Yours:

| File | Purpose |
|------|---------|
| `tools.sh` | Your project's toolchain (Node, JDK, Python, …). Plain shell, run as root at image build time with full network. |
| `domains.conf` | Extra outbound hosts, one per line. |
| `docker-compose.override.yml` | Extra services, ports, env and volumes, merged on top of the template's compose file. |

The application under development is meant to run on the **host**, not in the
container: the container is where Claude edits and builds the code. Nothing needs
configuring for that — reach the host at `host.docker.internal` (the firewall
resolves and allows whatever the runtime publishes that name as), and a sibling
compose service by its service name.

The template's:

| File | Purpose |
|------|---------|
| `.template/Dockerfile` | Debian base: `git`, `zsh`, `tmux`, firewall tooling, a `dev` user, the timezone you picked, Claude's config baked to a persisted path, and **Node and Java on their current LTS lines**. Anything else goes in `tools.sh`. |
| `.template/docker-compose.yml` | The devcontainer service, plus the `claude-shared` volume (Claude login/config, one volume shared by **all** projects — log in once, every devcontainer is authenticated). |
| `.template/init-firewall.sh` | Runtime egress firewall — default-deny outbound, allowing only what the two host lists resolve to, plus the dynamically fetched GitHub ranges. |
| `.template/domains-base.conf` | The baseline hosts every devcontainer needs (Anthropic, npm, Docker Hub, `fm.codeborne.com`). Template-owned so updates can extend it. |
| `.template/tmux.conf` | `Ctrl-a` prefix, mouse, big scrollback, truecolor, OSC 52 clipboard, vi copy mode. |
| `.template/devcontainer.json` | Wires in the `common-utils`, Claude, and `docker-outside-of-docker` features; merges `docker-compose.override.yml`; runs the firewall on start. |
| `.template/devcontainer-lock.json` | Pins the three features by digest. Has to sit beside `devcontainer.json`. |
| `start.sh` | Builds/starts the container (rebuilding only when build inputs change) and attaches Claude in tmux. |
| `attach.sh` | Fast re-attach to the running session (no rebuild). |
| `update.sh` | Pulls a newer template into the project; `--check` reports whether one exists. |

## Install

Straight from GitHub, nothing to check out. Run it in the project you want the
devcontainer in:

```sh
curl -fsSL https://github.com/ahoa/claude-devcontainer/raw/main/install.sh | bash
```

Give it a target directory to install somewhere other than the current one:

```sh
curl -fsSL https://github.com/ahoa/claude-devcontainer/raw/main/install.sh \
  | bash -s -- /path/to/your/project
```

When `install.sh` finds no `template/` next to itself it downloads one into a
temp dir and removes it afterwards. Prompts are read from your terminal rather
than stdin, so the interactive flow works through the pipe. ([Read the script
first](install.sh) if you'd rather not pipe an unread one into your shell.)

Or from a clone you already have — here the target directory is worth naming,
since the current one is the clone itself:

```sh
./install.sh /path/to/your/project
```

It asks three things:

1. **Project name** — used for the Docker image, the compose project name, and
   the named volumes. Must be lowercase (`[a-z0-9][a-z0-9_-]*`). The installer
   checks Docker for an existing compose project, volume, image, or container
   with that name and makes you pick another if it collides (override with
   `--force`).
2. **How many tmux windows** — each window runs its own Claude. Default `1`.
3. **Timezone** — the container's clock, as an IANA zone name. Default
   `Europe/Tallinn`; press Enter to accept it. Checked against the host's
   zoneinfo database, so typos are caught before the build. Without this the
   container would run UTC and its timestamps would disagree with your wall
   clock.

Non-interactive — pass the answers as flags, either form:

```sh
curl -fsSL https://github.com/ahoa/claude-devcontainer/raw/main/install.sh \
  | bash -s -- --name myapp --windows 2

./install.sh --name myapp --windows 2 --timezone UTC /path/to/your/project
```

| Flag | Meaning |
|------|---------|
| `--name NAME` | Project name (skips the prompt). |
| `--windows N` | Number of tmux windows (default `1`). |
| `--timezone ZONE` | IANA timezone for the container clock (default `Europe/Tallinn`). |
| `--force` | Overwrite an existing `.devcontainer/` and reuse conflicting Docker objects. |

| Env var | Meaning |
|---------|---------|
| `CLAUDE_DEVCONTAINER_REF` | Branch, tag or commit to pull the template from (default `main`). |
| `CLAUDE_DEVCONTAINER_REPO` | Repo to pull it from, e.g. your own fork. |

## After installing

The base image ships Node and Java (current LTS lines); everything else is yours to
add. Customise — all three files survive template updates:

- **Toolchain** — write plain shell into `.devcontainer/tools.sh` for anything
  beyond Node and Java (Python, database clients, …). It runs as root at build
  time, where the network is unrestricted; the firewall only applies at runtime.
- **Outbound hosts** — add domains to `.devcontainer/domains.conf` (one host per
  line). Only what your project adds: the baseline (Anthropic, npm, Docker Hub,
  `fm.codeborne.com`) lives in `.template/domains-base.conf`, and GitHub ranges are
  fetched dynamically. The baseline sits on the template's side of the split on
  purpose — a host added to it reaches existing projects on their next update,
  whereas `domains.conf` is frozen the moment a project is installed.
- **Ports** — nothing to configure. The app runs on the host and the container
  reaches it at `host.docker.internal:PORT`. If you do want to expose something
  *from* the container, publish it in the override — bound to localhost, since the
  short `"5173:5173"` form binds every interface on your machine, LAN included:

  ```yaml
  services:
    devcontainer:
      ports:
        - "127.0.0.1:5173:5173"
  ```
- **Extra services** — add them to `.devcontainer/docker-compose.override.yml`,
  which is merged on top of the template's compose file. Mind that relative paths
  there resolve against `.template/`, since that is where the base compose file
  lives — `../data` is `.devcontainer/data`.

Each of these is a build input, so `start.sh` rebuilds when you change one.

## Run

```sh
cd /path/to/your/project
./.devcontainer/start.sh          # first run: builds, starts, attaches Claude
./.devcontainer/attach.sh         # later: re-attach to the live session
./.devcontainer/start.sh -r       # rebuild + resume the previous Claude session
./.devcontainer/start.sh feature-x   # run Claude on git worktree "feature-x"
```

`start.sh` hashes the build inputs and only forces a clean rebuild when they
change; otherwise it reuses the existing container. It also prints a one-line
notice when a newer template exists (see [Updating](#updating)). The tmux session
(and the Claude login, via the `claude-shared` volume) persists across
disconnects and rebuilds, so you can detach, reconnect from another machine, and
pick up exactly where you left off. Set `TMUX_WINDOWS=N` in the environment to
override the window count for a single run.

The `claude-shared` volume is global — every project installed from this
template mounts the same one, so a single `/login` in any devcontainer
authenticates them all. `start.sh` creates the volume on first run; if you bring
the container up some other way, create it once with
`docker volume create claude-shared`.

## Updating

`install.sh` records the template commit it installed from in
`.devcontainer/.template-version` (commit that file). `start.sh` compares it
against the repo on every run — the remote SHA is cached for a day, times out
after 5 s, and stays quiet when offline — and prints one line when a newer
template exists:

```
⚡ devcontainer template update: fe7781b → a3c91f2 — run ./.devcontainer/update.sh
```

```sh
./.devcontainer/update.sh            # update to the latest commit
./.devcontainer/update.sh --check    # just report; exit 1 = update available
./.devcontainer/update.sh --ref v2   # update to a specific branch, tag or commit
```

An update is simply the installer re-run at a newer commit: template-owned files
are rewritten, your four config files are left alone, and the new build inputs
make the next `start.sh` do a clean rebuild. There is nothing to merge.

It refuses to run on a dirty `.devcontainer/`, so `git diff` afterwards shows
exactly what the update changed and `git checkout` undoes it. Pass `--force` to
override that.

### Projects installed before any of this existed

They have no `update.sh` and no `.template-version`, so bootstrap them by running
the installer once — the same command as a fresh install, with the **same project
name** and `--force`:

```sh
cd /path/to/your/project
curl -fsSL https://github.com/ahoa/claude-devcontainer/raw/main/install.sh \
  | bash -s -- --name <project> --force
```

Seeing no stamp, the installer recognises the old layout, moves the machinery into
`.template/`, and rescues what used to live in template-owned files before
replacing them:

- `PORT_FORWARDS` and `OPEN_PORTS` are gone; the installer reports what yours held
  and what replaces it. Reach sibling services by name (`db:5432`), and publish a
  port in the override if you need it exposed.
- `allowed-domains.conf` is renamed to `domains.conf`, entries untouched. Nothing
  to do — though it will still hold the baseline hosts that now also live in
  `.template/domains-base.conf`. The duplicates are harmless; trim them if you
  like.
- Toolchain lines found in the `Dockerfile` are saved verbatim to
  `tools.from-dockerfile`. **Manual**: they are Dockerfile syntax, not shell, so
  move them into `tools.sh` yourself (drop the leading `RUN `) and delete the
  `.from-dockerfile` file. Until you do, the image builds without your toolchain.
- If the old `docker-compose.yml` defined services beyond `devcontainer`, it is
  copied to `docker-compose.from-old.yml`. **Manual**: move those services into
  `docker-compose.override.yml`. Anything referring to those services by name will
  not resolve until you do.

The installer prints a warning for each manual step. Afterwards the project has
`update.sh` and a stamp, and every later update is a single
`./.devcontainer/update.sh`.

From that point on, `update.sh` also copes with a missing stamp on its own: it
reads the project name, window count and timezone back out of the installed files
rather than asking again.

## Migrating an older install

Installs made before the shared-login change gave every project its own
`<project>_claude` volume — and therefore its own `/login`. To move an existing
project over, re-run the installer on it with the **same project name** plus
`--force` (required, since the compose project/image/volumes already exist):

```sh
cd /path/to/your/project
curl -fsSL https://github.com/ahoa/claude-devcontainer/raw/main/install.sh \
  | bash -s -- --name <project> --force
```

This does three things:

1. **Overwrites the template-owned files**, keeping the four user-owned ones.
   Customizations that predate the split are rescued rather than lost — see
   [Projects installed before any of this existed](#projects-installed-before-any-of-this-existed)
   for what lands where and which part you still have to move by hand. The project
   is in git either way, so `git diff` shows exactly what changed.
2. **Migrates the login**: if the old `<project>_claude` volume exists and
   `claude-shared` does not yet hold a login, its contents (credentials, config,
   session transcripts) are copied into `claude-shared`. If `claude-shared` is
   already logged in — e.g. another project migrated first — nothing is copied;
   that login already covers every project.
3. **Leaves the old volume in place.** Once the new setup works, reclaim the
   space with `docker volume rm <project>_claude`.

Then run `./.devcontainer/start.sh` — it notices the changed build inputs, does
a clean rebuild, and the new container mounts `claude-shared`.

To migrate by hand instead: make the same edits the template got (volume
`name: claude-shared` + `external: true` in `.template/docker-compose.yml`, the
`docker volume create claude-shared` line in `start.sh`) and seed the volume
yourself:

```sh
docker volume create claude-shared
docker run --rm -v <project>_claude:/from -v claude-shared:/to alpine cp -a /from/. /to
```

## Requirements

- Docker (with Compose v2)
- `bash` and `curl` — `curl` also does the update check and the update itself;
  plus `tar` when installing without a checkout
- Node.js / `npm` on the host — `start.sh` installs the `@devcontainers/cli`
  locally into the project on first run.

## Notes

- **The sandbox is not a security boundary against a hostile toolchain.** The
  container runs with `NET_ADMIN`/`NET_RAW` (needed to program iptables) and mounts
  the host Docker socket — which is kept deliberately, since integration tests
  start containers of their own, and which by itself amounts to control of the
  host. The firewall limits accidental and agent egress; it does not contain a
  determined attacker.
- **The host is reachable, on every port.** The firewall allows whatever
  `host.docker.internal` resolves to, because the application under development
  runs there. That also puts anything else listening on your machine — other
  projects' databases, your IDE's built-in server, SSH — within reach of code
  running in the container. Bind local dev services to `127.0.0.1` if you would
  rather they were not visible.
- Claude is launched with `--dangerously-skip-permissions`; the firewall is the
  compensating control. Review `domains.conf` before trusting it.
