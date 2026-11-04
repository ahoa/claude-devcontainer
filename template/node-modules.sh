#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated.
#
# The container's own node_modules. The project is bind-mounted from the host,
# and a node_modules holds native binaries for one platform only: lightningcss,
# esbuild, rollup and swc each install one binary for the OS and the CPU of the
# install. One shared node_modules thus works on the host or in the container,
# never on both. So each directory with a package.json gets a named volume over
# its node_modules in the container. The host keeps its own node_modules, and the
# container fills its volume.
#
#   node-modules.sh prepare <image> <uid> <gid>   on the host, from start.sh
#   node-modules.sh stub                          on the host, from attach.sh
#   node-modules.sh install                       in the container, at each start
#
# prepare writes ../.node-modules.yml, which devcontainer.json merges into the
# compose project, creates the volumes and gives them to dev. stub writes an
# empty ../.node-modules.yml when there is none, because the devcontainer CLI
# reads every compose file it is given. install fills each empty volume from the
# lockfile beside it. A failed install prints a warning and the start goes on.
set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVCONTAINER_DIR="$(cd "$TEMPLATE_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$DEVCONTAINER_DIR/.." && pwd)"
COMPOSE_FILE="$DEVCONTAINER_DIR/.node-modules.yml"
COMPOSE_PROJECT="__COMPOSE_PROJECT__"
WORKSPACE="/workspace/__PROJECT_NAME__"
LABEL="claude-devcontainer.node-modules=$COMPOSE_PROJECT"

# The directories with a package.json, relative to the project, "." for the
# root. Hidden directories are skipped: .git, .devcontainer, and the git
# worktrees under .claude. So are node_modules and the usual build output, which
# can hold a copied package.json.
package_dirs() {
  (cd "$PROJECT_DIR" && find . \
    \( -name node_modules -o -name '.?*' -o -name target -o -name build -o -name dist -o -name out \) -prune \
    -o -name package.json -type f -print) \
    | sed -e 's|/package\.json$||' -e 's|^\./||' | LC_ALL=C sort
}

# A compose short-syntax mount splits on ":", and the YAML below is not quoted.
# A path with another character keeps the shared node_modules.
safe_dir() {
  [[ "$1" =~ ^[A-Za-z0-9._@+/-]+$ ]]
}

# The directories that get a volume, as "<volume key> <dir>" lines.
volume_dirs() {
  local dir
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    if safe_dir "$dir"; then
      echo "$(volume_key "$dir") $dir"
    else
      echo "WARNING: '$dir' has a character a compose mount cannot hold. Its node_modules stays shared with the host." >&2
    fi
  done < <(package_dirs)
}

# The node_modules of a directory, below the given root. No "./" for the root
# directory itself.
node_modules_of() {
  if [[ "$2" == "." ]]; then echo "$1/node_modules"; else echo "$1/$2/node_modules"; fi
}

# The Docker volume of a key. The compose file names it, and prepare creates
# it, so both must agree.
volume_name() {
  echo "${COMPOSE_PROJECT}_$1"
}

# What a compose file holds when no directory gets a volume.
write_empty_compose() {
  printf 'services:\n  devcontainer: {}\n'
}

# Stable per directory, so a restart finds the same volume.
volume_key() {
  local sum
  if command -v sha256sum >/dev/null 2>&1; then
    sum="$(printf %s "$1" | sha256sum)"
  else
    sum="$(printf %s "$1" | shasum -a 256)"
  fi
  echo "nm_${sum:0:12}"
}

write_compose() {
  local key dir mounts="" volumes=""
  while read -r key dir; do
    mounts+="      - $key:$(node_modules_of "$WORKSPACE" "$dir")"$'\n'
    volumes+="  $key:"$'\n'"    name: $(volume_name "$key")"$'\n'"    external: true"$'\n'
  done < <(volume_dirs)
  {
    echo "# Written by .template/node-modules.sh on each start. Do not edit."
    if [[ -z "$mounts" ]]; then
      write_empty_compose
    else
      printf 'services:\n  devcontainer:\n    volumes:\n%svolumes:\n%s' "$mounts" "$volumes"
    fi
  } > "$COMPOSE_FILE.new"
  mv -f "$COMPOSE_FILE.new" "$COMPOSE_FILE"
}

# Docker creates a missing mountpoint in the bind mount, and on a Linux host it
# then belongs to root, so the next npm install on the host fails. The host user
# creates it first. A new volume belongs to root as well. One container gives
# all of them to dev, the top directory only: dev writes everything below it.
prepare_volumes() {
  local image="$1" uid="$2" gid="$3" key dir name args=() targets=() i=0
  while read -r key dir; do
    name="$(volume_name "$key")"
    mkdir -p "$(node_modules_of "$PROJECT_DIR" "$dir")"
    docker volume inspect "$name" >/dev/null 2>&1 \
      || docker volume create --label "$LABEL" "$name" >/dev/null
    args+=(-v "$name:/v/$i")
    targets+=("/v/$i")
    i=$((i + 1))
  done < <(volume_dirs 2>/dev/null)
  [[ $i -eq 0 || -z "$uid" || -z "$gid" ]] && return 0
  docker run --rm --user 0 --entrypoint chown "${args[@]}" "$image" "$uid:$gid" "${targets[@]}" \
    || echo "WARNING: could not give the node_modules volumes to UID $uid. An install in the container fails." >&2
}

# The install command for the lockfile in a directory. A directory without a
# lockfile is a workspace member, which the install at its root fills, or a
# project without a lock, which nobody should install blind.
install_command() {
  if [[ -f "$1/pnpm-lock.yaml" ]]; then
    echo "corepack pnpm install --frozen-lockfile"
  elif [[ -f "$1/yarn.lock" && -f "$1/.yarnrc.yml" ]]; then
    echo "corepack yarn install --immutable"
  elif [[ -f "$1/yarn.lock" ]]; then
    echo "corepack yarn install --frozen-lockfile"
  elif [[ -f "$1/package-lock.json" || -f "$1/npm-shrinkwrap.json" ]]; then
    echo "npm ci"
  fi
}

# Only a volume that is still empty: a filled one belongs to whoever filled it.
install_all() {
  local key dir modules cmd
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  while read -r key dir; do
    modules="$(node_modules_of "$PROJECT_DIR" "$dir")"
    mountpoint -q "$modules" 2>/dev/null || continue
    [[ -z "$(ls -A "$modules")" ]] || continue
    cmd="$(install_command "$PROJECT_DIR/$dir")"
    [[ -z "$cmd" ]] && continue
    echo "==> node_modules of '$dir' is empty in the container — running: $cmd"
    # shellcheck disable=SC2086 # cmd is one of the fixed commands above
    (cd "$PROJECT_DIR/$dir" && $cmd) \
      || echo "WARNING: '$cmd' failed in '$dir'. Run it again in the container." >&2
  done < <(volume_dirs 2>/dev/null)
}

case "${1:-}" in
  prepare)
    write_compose
    prepare_volumes "${2:?image}" "${3:-}" "${4:-}"
    ;;
  stub)
    [[ -f "$COMPOSE_FILE" ]] || write_empty_compose > "$COMPOSE_FILE"
    ;;
  install)
    install_all || true
    ;;
  *)
    echo "usage: $0 prepare <image> <uid> <gid> | stub | install" >&2
    exit 2
    ;;
esac
