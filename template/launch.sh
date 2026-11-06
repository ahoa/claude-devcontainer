# shellcheck shell=bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated.
#
# launch.sh — sourced by start.sh and attach.sh at their start. parse_args and
# check_project_dir run before the container starts, launch_claude is their
# last step. The functions read DEVCONTAINER_BIN, PROJECT_DIR, TEMPLATE_DIR,
# WINDOWS and CA_FLAG from the caller.

# parse_args <start|attach> <arg>… — read the arguments into RESUME, PLAIN,
# UP_ONLY, PROJECT_SUBDIR and WORKTREE_NAME, and check each value that goes
# into the shell command in the container, WINDOWS too. Without the check,
# `TMUX_WINDOWS='1; curl … | sh'` ran that command, and a worktree name that
# held a quote closed the quoting and did the same. The installer validates
# the number it writes, but not what the environment overrides it with.
#
# Args (any order):
#   -r | --resume   resume the most recent Claude session in this dir
#                   (claude --continue), for example after a rebuild. In tmux
#                   it applies only when no live session exists yet: tmux
#                   ignores the launch command of a session that runs.
#   --plain         run one Claude straight in this terminal, without tmux. For a
#                   host that runs its own tmux: one host window per Claude.
#   --dir <name>    start Claude in this subdirectory of the project. Required
#                   in a domain, see check_project_dir. One directory level of
#                   letters, digits, '_' and '-', so it cannot leave the project
#                   and is safe in the shell command.
#   --up-only       start.sh only: start the container and stop, without Claude.
#                   A host script then opens each Claude with attach.sh.
#   <name>          worktree name, forwarded as `claude --worktree <name>`.
# The values are globals that the caller reads.
# shellcheck disable=SC2034
parse_args() {
  local caller="$1"
  shift
  RESUME="" PLAIN=0 UP_ONLY=0 PROJECT_SUBDIR="" WORKTREE_NAME=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--resume) RESUME=" --continue" ;;
      --plain)     PLAIN=1 ;;
      --up-only)
        if [[ "$caller" != start ]]; then
          echo "ERROR: --up-only is an option of start.sh." >&2
          exit 1
        fi
        UP_ONLY=1 ;;
      --dir)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --dir needs a directory name." >&2
          exit 1
        fi
        PROJECT_SUBDIR="$2"
        shift ;;
      *)           WORKTREE_NAME="$1" ;;
    esac
    shift
  done
  if [[ ! "$WINDOWS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: TMUX_WINDOWS must be a positive integer (got '$WINDOWS')." >&2
    exit 1
  fi
  if [[ -n "$WORKTREE_NAME" && ! "$WORKTREE_NAME" =~ ^[A-Za-z0-9_.][A-Za-z0-9_./-]*$ ]]; then
    echo "ERROR: worktree name may hold letters, digits, '.', '_', '-' and '/' only (got '$WORKTREE_NAME')." >&2
    exit 1
  fi
  if [[ -n "$PROJECT_SUBDIR" && ! "$PROJECT_SUBDIR" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]]; then
    echo "ERROR: --dir takes a directory name of letters, digits, '_' and '-' (got '$PROJECT_SUBDIR')." >&2
    exit 1
  fi
}

# domain_projects — the subdirectories of PROJECT_DIR with a .git directory,
# one name per line. A git submodule has a .git file, not a directory, so it
# does not count.
domain_projects() {
  local d
  for d in "$PROJECT_DIR"/*/; do
    [[ -d "$d.git" ]] && basename "$d"
  done
  return 0
}

# is_domain — 0 when PROJECT_DIR is a domain: a directory that is not a git
# repository itself and holds one or more projects with their own repository.
is_domain() {
  [[ ! -e "$PROJECT_DIR/.git" && -n "$(domain_projects)" ]]
}

# check_project_dir — stop with an error when PROJECT_SUBDIR (--dir), already
# checked by parse_args, does not fit this project. Claude names its session
# folder after its working directory. In a domain, a Claude in the root puts
# the sessions of all projects in one folder. So a domain requires --dir.
check_project_dir() {
  if [[ -z "$PROJECT_SUBDIR" ]]; then
    if is_domain; then
      echo "ERROR: $PROJECT_DIR holds several projects. Name one with --dir <project>." >&2
      echo "       Projects: $(domain_projects | tr '\n' ' ')" >&2
      exit 1
    fi
    return 0
  fi
  if [[ ! -d "$PROJECT_DIR/$PROJECT_SUBDIR" ]]; then
    echo "ERROR: $PROJECT_DIR/$PROJECT_SUBDIR is not a directory." >&2
    exit 1
  fi
}

# Start Claude in the dev container as the remoteUser (`dev`), and do not return.
#
# The default is a tmux session. The first run makes it, and a later run attaches
# to it as it is, so start.sh and attach.sh share one live session, also from
# another machine. A worktree gets a session of its own. A new session gets
# WINDOWS windows, each with its own Claude. `--continue` only makes sense for
# one instance, so windows 2..N start fresh.
#
# With --plain, one Claude runs straight in this terminal, without tmux.
#
# With --dir, Claude starts in that subdirectory of the workspace, and the tmux
# session gets the directory in its name, so each project of a domain has a
# session of its own.
#
# $1 is the start of the status line, which differs between the two callers.
launch_claude() {
  local action="$1" session base_cmd cmd cd_prefix=""
  local exec_cmd=("$DEVCONTAINER_BIN" exec --workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json")
  session="claude${PROJECT_SUBDIR:+-$PROJECT_SUBDIR}${WORKTREE_NAME:+-$WORKTREE_NAME}"
  base_cmd="claude --dangerously-skip-permissions$CA_FLAG${WORKTREE_NAME:+ --worktree $WORKTREE_NAME}"
  cmd="$base_cmd$RESUME"
  [[ -n "$PROJECT_SUBDIR" ]] && cd_prefix="cd $PROJECT_SUBDIR && "

  if [[ $PLAIN -eq 1 ]]; then
    if [[ $WINDOWS -gt 1 ]]; then
      echo "==> --plain starts one Claude. TMUX_WINDOWS=$WINDOWS applies to the tmux session only."
    fi
    echo "==> Starting Claude in this terminal, without tmux..."
    exec "${exec_cmd[@]}" zsh -lc "${cd_prefix}exec $cmd"
  fi

  # The "=" makes tmux match the exact name. Without it, a target matches the
  # start of a name, and `claude-app` found the session `claude-app-wt`.
  echo "==> $action tmux session '$session' ($WINDOWS window(s))..."
  exec "${exec_cmd[@]}" \
    zsh -c "if ! tmux has-session -t '=$session' 2>/dev/null; then tmux new-session -d -s '$session' -n claude1 '$cd_prefix$cmd'; for i in \$(seq 2 $WINDOWS); do tmux new-window -d -t '=$session:' -n claude\$i '$cd_prefix$base_cmd'; done; fi; exec tmux attach -t '=$session'"
}
