#!/bin/bash
#
# Tests for template/node-modules.sh. Plain bash, no framework. docker,
# mountpoint, npm and corepack are stubs on PATH, so no Docker is needed.
#
#   tests/node-modules.test.sh
#
# check() evaluates its condition later, so the single quotes and the variables
# that only the condition reads are on purpose.
# shellcheck disable=SC2016,SC2034
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
export WORK
trap 'rm -rf "$WORK"' EXIT
FAILS=0

fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# A project with the template installed under .devcontainer/.template, with the
# placeholders substituted as the installer does it.
new_project() {
  local p="$WORK/$1"
  mkdir -p "$p/.devcontainer/.template"
  sed -e 's|__PROJECT_NAME__|proj|g' -e 's|__COMPOSE_PROJECT__|proj-dc|g' \
    "$REPO_DIR/template/node-modules.sh" > "$p/.devcontainer/.template/node-modules.sh"
  chmod +x "$p/.devcontainer/.template/node-modules.sh"
  echo "$p"
}

add_package() {
  mkdir -p "$1/$2"
  echo '{}' > "$1/$2/package.json"
}

# Stubs log each call to $WORK/calls. DOCKER_RUN_RC sets the exit code of
# `docker run`, MOUNTED lists the mountpoints, INSTALL_RC the exit code of npm
# and corepack.
make_stubs() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$WORK/calls"
[[ "$1 $2" == "volume inspect" ]] && exit 1
[[ "$1" == "run" ]] && exit "${DOCKER_RUN_RC:-0}"
exit 0
EOF
  cat > "$WORK/bin/mountpoint" <<'EOF'
#!/bin/bash
[[ " $MOUNTED " == *" $2 "* ]]
EOF
  for tool in npm corepack; do
    cat > "$WORK/bin/$tool" <<EOF
#!/bin/bash
echo "$tool \$* in \$PWD" >> "\$WORK/calls"
exit "\${INSTALL_RC:-0}"
EOF
  done
  chmod +x "$WORK/bin/"*
}

run() {
  local p="$1"; shift
  PATH="$WORK/bin:$PATH" "$p/.devcontainer/.template/node-modules.sh" "$@"
}

test_prepare() {
  local p yml first rc
  p="$(new_project prepare)"
  for d in . UI packages/lib .claude/worktrees/a UI/node_modules/x target/p build/p dist/p out/p "my app"; do
    add_package "$p" "$d"
  done
  : > "$WORK/calls"
  run "$p" prepare img 1000 1000 2> "$WORK/stderr"; rc=$?
  yml="$(cat "$p/.devcontainer/.node-modules.yml")"
  check "prepare exits 0" '[[ $rc -eq 0 ]]'
  check "root gets a volume without ./" 'grep -q ":/workspace/proj/node_modules$" <<<"$yml"'
  check "UI gets a volume" 'grep -q ":/workspace/proj/UI/node_modules$" <<<"$yml"'
  check "workspace member gets a volume" 'grep -q ":/workspace/proj/packages/lib/node_modules$" <<<"$yml"'
  check "three mounts, nothing else" '[[ $(grep -c "^      - nm_" <<<"$yml") -eq 3 ]]'
  check "hidden, node_modules and build output skipped" '! grep -qE "worktrees|/x/|target|build|dist|out/" <<<"$yml"'
  check "volumes are external with the project prefix" '[[ $(grep -c "name: proj-dc_nm_" <<<"$yml") -eq 3 && $(grep -c "external: true" <<<"$yml") -eq 3 ]]'
  check "a path with a space warns and gets no mount" 'grep -q "my app" "$WORK/stderr" && ! grep -q "my app" <<<"$yml"'
  check "host mountpoints exist" '[[ -d "$p/node_modules" && -d "$p/packages/lib/node_modules" ]]'
  check "volumes are created with the label" '[[ $(grep -c "volume create --label claude-devcontainer.node-modules=proj-dc proj-dc_nm_" "$WORK/calls") -eq 3 ]]'
  check "one chown for all volumes" 'grep -q "run --rm --user 0 --entrypoint chown .* img 1000:1000 /v/0 /v/1 /v/2$" "$WORK/calls"'
  first="$yml"
  run "$p" prepare img 1000 1000 2>/dev/null
  check "a second run gives the same file" '[[ "$(cat "$p/.devcontainer/.node-modules.yml")" == "$first" ]]'
}

test_prepare_edges() {
  local p rc
  p="$(new_project edges)"
  add_package "$p" UI
  : > "$WORK/calls"
  DOCKER_RUN_RC=1 run "$p" prepare img 1000 1000 2> "$WORK/stderr"; rc=$?
  check "a failed chown warns and exits 0" '[[ $rc -eq 0 ]] && grep -q "could not give" "$WORK/stderr"'
  : > "$WORK/calls"
  run "$p" prepare img "" "" 2>/dev/null; rc=$?
  check "no uid: no chown, exit 0" '[[ $rc -eq 0 ]] && ! grep -q "docker run" "$WORK/calls"'
  p="$(new_project empty)"
  run "$p" prepare img 1000 1000; rc=$?
  check "no package.json: an empty compose file" '[[ $rc -eq 0 ]] && grep -q "devcontainer: {}" "$p/.devcontainer/.node-modules.yml"'
}

test_stub() {
  local p
  p="$(new_project stub)"
  run "$p" stub
  check "stub writes an empty compose file" 'grep -q "devcontainer: {}" "$p/.devcontainer/.node-modules.yml"'
  echo "# kept" > "$p/.devcontainer/.node-modules.yml"
  run "$p" stub
  check "stub keeps an existing file" '[[ "$(cat "$p/.devcontainer/.node-modules.yml")" == "# kept" ]]'
}

test_install() {
  local p rc
  p="$(new_project install)"
  for d in npm pnpm berry classic nolock filled notmounted failing; do add_package "$p" "$d"; mkdir -p "$p/$d/node_modules"; done
  touch "$p/npm/package-lock.json" "$p/pnpm/pnpm-lock.yaml" "$p/berry/yarn.lock" "$p/berry/.yarnrc.yml" \
    "$p/classic/yarn.lock" "$p/filled/package-lock.json" "$p/notmounted/package-lock.json" "$p/failing/package-lock.json"
  touch "$p/filled/node_modules/.package-lock.json"
  local mounted=""
  for d in npm pnpm berry classic nolock filled failing; do mounted+=" $p/$d/node_modules"; done
  : > "$WORK/calls"
  # failing is the only directory where the install fails.
  cat > "$WORK/bin/npm" <<'EOF'
#!/bin/bash
echo "npm $* in $PWD" >> "$WORK/calls"
[[ "$PWD" == */failing ]] && exit 1
exit 0
EOF
  MOUNTED="$mounted" run "$p" install > "$WORK/stdout" 2> "$WORK/stderr"; rc=$?
  check "install exits 0 when one install fails" '[[ $rc -eq 0 ]]'
  check "package-lock.json: npm ci" 'grep -q "^npm ci in $p/npm$" "$WORK/calls"'
  check "pnpm-lock.yaml: pnpm frozen" 'grep -q "^corepack pnpm install --frozen-lockfile in $p/pnpm$" "$WORK/calls"'
  check "yarn.lock + .yarnrc.yml: yarn immutable" 'grep -q "^corepack yarn install --immutable in $p/berry$" "$WORK/calls"'
  check "yarn.lock alone: yarn frozen" 'grep -q "^corepack yarn install --frozen-lockfile in $p/classic$" "$WORK/calls"'
  check "no lockfile: no install" '! grep -q "/nolock$" "$WORK/calls"'
  check "a filled volume: no install" '! grep -q "/filled$" "$WORK/calls"'
  check "not a mountpoint: no install" '! grep -q "/notmounted$" "$WORK/calls"'
  check "a failed install warns" 'grep -q "failed in .failing." "$WORK/stderr"'
}

make_stubs
test_prepare
test_prepare_edges
test_stub
test_install

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS test(s) failed"
  exit 1
fi
echo "all tests passed"
