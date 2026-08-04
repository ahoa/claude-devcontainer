# Claude devcontainer

A project-agnostic [dev container](https://containers.dev/) that runs
[Claude Code](https://docs.claude.com/en/docs/claude-code) inside a network
sandbox and a long-lived `tmux` session. Drop it into any repo with one command.

## What you get

Running `install.sh` writes these into your project's `.devcontainer/`:

| File | Purpose |
|------|---------|
| `Dockerfile` | Minimal Debian base: `git`, `zsh`, `tmux`, firewall tooling, a `dev` user, and Claude's config baked to a persisted path. **No language runtimes** — add your own. |
| `docker-compose.yml` | The devcontainer service + two named volumes (`ssh`, `claude`) so your deploy key and Claude login survive rebuilds. |
| `devcontainer.json` | Wires in the `common-utils`, Claude, and `docker-outside-of-docker` features; runs the firewall on start. |
| `devcontainer-lock.json` | Pins the three features by digest. |
| `init-firewall.sh` + `allowed-domains.conf` | Runtime egress firewall — default-deny outbound, allowing only GitHub, Anthropic, npm, Docker Hub, and hosts you add. |
| `tmux.conf` | `Ctrl-a` prefix, mouse, big scrollback, truecolor. |
| `start.sh` | Builds/starts the container (rebuilding only when build inputs change) and attaches Claude in tmux. |
| `attach.sh` | Fast re-attach to the running session (no rebuild). |

## Install

Straight from GitHub, nothing to check out. Run it in the project you want the
devcontainer in:

```sh
cd /path/to/your/project
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

It asks two things:

1. **Project name** — used for the Docker image, the compose project name, and
   the named volumes. Must be lowercase (`[a-z0-9][a-z0-9_-]*`). The installer
   checks Docker for an existing compose project, volume, image, or container
   with that name and makes you pick another if it collides (override with
   `--force`).
2. **How many tmux windows** — each window runs its own Claude. Default `1`.

Non-interactive — pass the answers as flags, either form:

```sh
curl -fsSL https://github.com/ahoa/claude-devcontainer/raw/main/install.sh \
  | bash -s -- --name myapp --windows 2

./install.sh --name myapp --windows 2 /path/to/your/project
```

| Flag | Meaning |
|------|---------|
| `--name NAME` | Project name (skips the prompt). |
| `--windows N` | Number of tmux windows (default `1`). |
| `--force` | Overwrite an existing `.devcontainer/` and reuse conflicting Docker objects. |

| Env var | Meaning |
|---------|---------|
| `CLAUDE_DEVCONTAINER_REF` | Branch, tag or commit to pull the template from (default `main`). |
| `CLAUDE_DEVCONTAINER_REPO` | Repo to pull it from, e.g. your own fork. |

## After installing

The base image is intentionally empty of language runtimes. Customise:

- **Toolchain** — add `RUN` lines to `.devcontainer/Dockerfile` (Node, JDK,
  Python, …). Build time has full network access; the firewall only applies at
  runtime.
- **Outbound hosts** — add domains to `.devcontainer/allowed-domains.conf`
  (one host per line). GitHub ranges are already fetched dynamically.
- **Dev-server ports** — set `OPEN_PORTS=(3000 5173)` in
  `.devcontainer/init-firewall.sh` to let a host browser reach your dev server.

## Run

```sh
cd /path/to/your/project
./.devcontainer/start.sh          # first run: builds, starts, attaches Claude
./.devcontainer/attach.sh         # later: re-attach to the live session
./.devcontainer/start.sh -r       # rebuild + resume the previous Claude session
./.devcontainer/start.sh feature-x   # run Claude on git worktree "feature-x"
```

`start.sh` hashes the build inputs and only forces a clean rebuild when they
change; otherwise it reuses the existing container. The tmux session (and the
Claude login, via the `claude` volume) persists across disconnects and
rebuilds, so you can detach, reconnect from another machine, and pick up exactly
where you left off. Set `TMUX_WINDOWS=N` in the environment to override the
window count for a single run.

## Requirements

- Docker (with Compose v2)
- `bash`, plus `curl` and `tar` when installing without a checkout
- Node.js / `npm` on the host — `start.sh` installs the `@devcontainers/cli`
  locally into the project on first run.

## Notes

- **The sandbox is not a security boundary against a hostile toolchain.** The
  container runs with `NET_ADMIN`/`NET_RAW` (needed to program iptables) and
  mounts the host Docker socket. The firewall limits accidental/agent egress; it
  does not contain a determined attacker. Remove the `docker.sock` mount from
  `docker-compose.yml` if the container has no need to drive Docker.
- Claude is launched with `--dangerously-skip-permissions`; the firewall is the
  compensating control. Review `allowed-domains.conf` before trusting it.
