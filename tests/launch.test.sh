#!/bin/bash
#
# Tests for template/launch.sh: the arguments, the --dir check and the command
# that starts Claude. Plain bash, no framework. The devcontainer CLI is a stub
# that writes its arguments to a file, so no Docker is needed.
#
#   tests/launch.test.sh
#
# check() evaluates its condition later, so the single quotes and the variables
# that only the condition reads are on purpose.
# The subshells set variables on purpose, so the changes stay local.
# shellcheck disable=SC2016,SC2034,SC2030,SC2031
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
export WORK
trap 'rm -rf "$WORK"' EXIT
FAILS=0

fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# The stub writes each argument on a line of its own, so the last line is the
# shell command that runs in the container.
cat > "$WORK/devcontainer" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$WORK/args"
EOF
chmod +x "$WORK/devcontainer"

# A domain: a directory without .git that holds two projects with a .git
# directory, a plain folder and a submodule-like folder with a .git file.
DOMAIN="$WORK/domain"
mkdir -p "$DOMAIN/beat/.git" "$DOMAIN/hr-borne/.git" "$DOMAIN/notes" "$DOMAIN/sub"
echo "gitdir: ../.git/modules/sub" > "$DOMAIN/sub/.git"

# A single project: a git repository with a subdirectory.
SINGLE="$WORK/single"
mkdir -p "$SINGLE/.git" "$SINGLE/frontend"

# run_check <project dir> <subdir> — check_project_dir in a subshell, because
# it exits on an error. Writes the exit code and stderr to files.
run_check() {
  (
    PROJECT_DIR="$1" PROJECT_SUBDIR="$2"
    # shellcheck source=template/launch.sh
    source "$REPO_DIR/template/launch.sh"
    check_project_dir
  ) 2> "$WORK/err"
  echo $? > "$WORK/rc"
}

# run_parse <windows> <caller> <arg>… — parse_args in a subshell, because it
# exits on an error. Writes the exit code, stderr and the parsed values.
run_parse() {
  local windows="$1"
  shift
  (
    WINDOWS="$windows"
    # shellcheck source=template/launch.sh
    source "$REPO_DIR/template/launch.sh"
    parse_args "$@"
    echo "resume=$RESUME plain=$PLAIN up=$UP_ONLY dir=$PROJECT_SUBDIR wt=$WORKTREE_NAME" > "$WORK/parsed"
  ) 2> "$WORK/err"
  echo $? > "$WORK/rc"
}

# run_launch <plain> <subdir> <worktree> <resume> — launch_claude in a
# subshell, because it ends with exec. The stub records the call.
run_launch() {
  rm -f "$WORK/args"
  (
    DEVCONTAINER_BIN="$WORK/devcontainer" PROJECT_DIR="$DOMAIN" TEMPLATE_DIR="$WORK/t"
    WINDOWS=1 PLAIN="$1" PROJECT_SUBDIR="$2" WORKTREE_NAME="$3" RESUME="$4" CA_FLAG=""
    # shellcheck source=template/launch.sh
    source "$REPO_DIR/template/launch.sh"
    launch_claude "Test" > /dev/null
  )
  LAST="$(tail -n 1 "$WORK/args")"
}

# --- parse_args ---

run_parse 1 start --plain -r --dir beat fix-1 --up-only
check "start reads every option" \
  '[[ "$(cat "$WORK/rc")" == 0 && "$(cat "$WORK/parsed")" == "resume= --continue plain=1 up=1 dir=beat wt=fix-1" ]]'

run_parse 1 attach --up-only
check "attach refuses --up-only" '[[ "$(cat "$WORK/rc")" == 1 ]] && grep -q "option of start.sh" "$WORK/err"'

run_parse 1 attach --dir
check "--dir without a name stops" '[[ "$(cat "$WORK/rc")" == 1 ]] && grep -q "needs a directory name" "$WORK/err"'

for bad in "../single" "beat/x" ".hidden" "a b" "a;b" "-x" "a'b"; do
  run_parse 1 attach --dir "$bad"
  check "--dir '$bad' stops" '[[ "$(cat "$WORK/rc")" == 1 ]] && grep -q "takes a directory name" "$WORK/err"'
done

run_parse "1; id" attach
check "a TMUX_WINDOWS that is not a number stops" '[[ "$(cat "$WORK/rc")" == 1 ]] && grep -q "positive integer" "$WORK/err"'

run_parse 1 attach "x'y"
check "a worktree name with a quote stops" '[[ "$(cat "$WORK/rc")" == 1 ]] && grep -q "worktree name" "$WORK/err"'

# --- check_project_dir ---

run_check "$DOMAIN" ""
check "domain without --dir stops" '[[ "$(cat "$WORK/rc")" == 1 ]]'
check "the error names the projects with a .git directory" \
  'grep -q "beat hr-borne" "$WORK/err" && ! grep -q "notes\|sub" "$WORK/err"'

run_check "$DOMAIN" "beat"
check "domain with --dir of a project passes" '[[ "$(cat "$WORK/rc")" == 0 ]]'

run_check "$DOMAIN" "notes"
check "--dir of a folder without .git passes" '[[ "$(cat "$WORK/rc")" == 0 ]]'

run_check "$DOMAIN" "missing"
check "--dir of a missing directory stops" '[[ "$(cat "$WORK/rc")" == 1 ]] && grep -q "not a directory" "$WORK/err"'

run_check "$SINGLE" ""
check "a git repository without --dir passes" '[[ "$(cat "$WORK/rc")" == 0 ]]'

run_check "$SINGLE" "frontend"
check "a git repository with --dir passes" '[[ "$(cat "$WORK/rc")" == 0 ]]'

EMPTY="$WORK/empty"
mkdir -p "$EMPTY/folder"
run_check "$EMPTY" ""
check "a directory with no repository at all is no domain" '[[ "$(cat "$WORK/rc")" == 0 ]]'

# --- launch_claude ---

run_launch 1 "" "" ""
check "plain without --dir starts claude in the workspace" \
  '[[ "$LAST" == "exec claude --dangerously-skip-permissions" ]]'

run_launch 1 "beat" "" ""
check "plain with --dir changes to the project first" \
  '[[ "$LAST" == "cd beat && exec claude --dangerously-skip-permissions" ]]'

run_launch 1 "beat" "" " --continue"
check "plain with --dir and -r resumes in the project" \
  '[[ "$LAST" == "cd beat && exec claude --dangerously-skip-permissions --continue" ]]'

run_launch 1 "beat" "fix-1" ""
check "plain with --dir and a worktree" \
  '[[ "$LAST" == "cd beat && exec claude --dangerously-skip-permissions --worktree fix-1" ]]'

run_launch 0 "" "" ""
check "tmux without --dir keeps the session name claude" \
  '[[ "$LAST" == *"new-session -d -s '"'claude'"' -n claude1 '"'claude --dangerously-skip-permissions'"'"* ]]'

run_launch 0 "" "fix-1" ""
check "tmux with a worktree keeps the session name claude-<worktree>" \
  '[[ "$LAST" == *"-s '"'claude-fix-1'"'"* ]]'

run_launch 0 "beat" "" ""
check "tmux with --dir gets a session per project" \
  '[[ "$LAST" == *"-s '"'claude-beat'"' -n claude1 '"'cd beat && claude --dangerously-skip-permissions'"'"* ]]'
check "tmux matches the exact session name" \
  '[[ "$LAST" == *"has-session -t '"'=claude-beat'"'"* && "$LAST" == *"attach -t '"'=claude-beat'"'" ]]'

run_launch 0 "beat" "fix-1" ""
check "tmux with --dir and a worktree" '[[ "$LAST" == *"-s '"'claude-beat-fix-1'"'"* ]]'

echo
if [[ $FAILS -eq 0 ]]; then
  echo "All tests passed."
else
  echo "$FAILS test(s) failed."
  exit 1
fi
