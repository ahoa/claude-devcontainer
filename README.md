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
├── ports.conf                   ← yours: inbound and forwarded ports
├── docker-compose.override.yml  ← yours: extra services
│
├── start.sh                     the commands you run
├── attach.sh
├── update.sh
├── devcontainer.json            must sit here for VS Code to find it
├── devcontainer-lock.json
│
└── .template/                   machinery — hidden, never edit
    ├── Dockerfile
    ├── docker-compose.yml
    ├── init-firewall.sh
    └── tmux.conf
```

**The four files at the top are yours.** They are created once and never
overwritten, so a template update cannot touch them. Everything else belongs to
the template, says `DO NOT CHANGE THIS FILE` at the top, and is replaced on
update — which is why the bulk of it is tucked out of sight in `.template/`.

Yours:

| File | Purpose |
|------|---------|
| `tools.sh` | Your project's toolchain (Node, JDK, Python, …). Plain shell, run as root at image build time with full network. |
| `domains.conf` | Extra outbound hosts, one per line. |
| `ports.conf` | `OPEN_PORTS` (inbound dev-server ports) and `PORT_FORWARDS` (localhost:PORT → compose service). |
| `docker-compose.override.yml` | Extra services, ports, env and volumes, merged on top of the template's compose file. |

The template's:

| File | Purpose |
|------|---------|
| `.template/Dockerfile` | Minimal Debian base: `git`, `zsh`, `tmux`, firewall tooling, a `dev` user, the timezone you picked, and Claude's config baked to a persisted path. **No language runtimes** — those go in `tools.sh`. |
| `.template/docker-compose.yml` | The devcontainer service, plus the `claude-shared` volume (Claude login/config, one volume shared by **all** projects — log in once, every devcontainer is authenticated). |
| `.template/init-firewall.sh` | Runtime egress firewall — default-deny outbound, allowing only GitHub, Anthropic, npm, Docker Hub, and what you add. |
| `.template/tmux.conf` | `Ctrl-a` prefix, mouse, big scrollback, truecolor, OSC 52 clipboard, vi copy mode. |
| `devcontainer.json` | Wires in the `common-utils`, Claude, and `docker-outside-of-docker` features; merges `docker-compose.override.yml`; runs the firewall on start. |
| `devcontainer-lock.json` | Pins the three features by digest. Has to sit beside `devcontainer.json`. |
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

The base image is intentionally empty of language runtimes. Customise — all four
files survive template updates:

- **Toolchain** — write plain shell into `.devcontainer/tools.sh` (Node, JDK,
  Python, …). It runs as root at build time, where the network is unrestricted;
  the firewall only applies at runtime.
- **Outbound hosts** — add domains to `.devcontainer/domains.conf` (one host per
  line). GitHub ranges are already fetched dynamically.
- **Dev-server ports** — set `OPEN_PORTS=(3000 5173)` in
  `.devcontainer/ports.conf` to let a host browser reach your dev server;
  `PORT_FORWARDS=("5432 db 5432")` maps `localhost:5432` inside the container to
  a compose service.
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
pick up exactly where you left off. Set `TMUX_WINDOWS=N` in the environment to override the
window count for a single run.

The `claude-shared` volume is global — every project installed from this
template mounts the same one, so a single `/login` in any devcontainer
authenticates them all. `start.sh` creates the volume on first run; if you
bypass `start.sh` (e.g. VS Code's "Reopen in Container"), create it once with
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

- `OPEN_PORTS` and `PORT_FORWARDS` are lifted out of `init-firewall.sh` into a new
  `ports.conf`, multi-line arrays included. Nothing to do.
- `allowed-domains.conf` is renamed to `domains.conf`, entries untouched. Nothing
  to do.
- Toolchain lines found in the `Dockerfile` are saved verbatim to
  `tools.from-dockerfile`. **Manual**: they are Dockerfile syntax, not shell, so
  move them into `tools.sh` yourself (drop the leading `RUN `) and delete the
  `.from-dockerfile` file. Until you do, the image builds without your toolchain.
- If the old `docker-compose.yml` defined services beyond `devcontainer`, it is
  copied to `docker-compose.from-old.yml`. **Manual**: move those services into
  `docker-compose.override.yml`. Do this *before* starting — if `ports.conf` forwards a port
  to a service that no longer exists, the firewall aborts and the container will
  not start at all.

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
  container runs with `NET_ADMIN`/`NET_RAW` (needed to program iptables) and
  mounts the host Docker socket. The firewall limits accidental/agent egress; it
  does not contain a determined attacker. The `docker.sock` mount is in
  `.template/docker-compose.yml`; drop it there if the container has no need to
  drive Docker, keeping in mind an update restores it.
- Claude is launched with `--dangerously-skip-permissions`; the firewall is the
  compensating control. Review `domains.conf` before trusting it.
