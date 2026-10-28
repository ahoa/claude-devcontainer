# shellcheck shell=bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated.
#
# launch.sh — the last step of start.sh and attach.sh, sourced by both. It reads
# their DEVCONTAINER_BIN, PROJECT_DIR, TEMPLATE_DIR, WINDOWS, PLAIN,
# WORKTREE_NAME, RESUME and CA_FLAG. Both scripts check WINDOWS and
# WORKTREE_NAME first, because the values go into a shell command that runs in
# the container.

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
# $1 is the start of the status line, which differs between the two callers.
launch_claude() {
  local action="$1" session base_cmd cmd
  local exec_cmd=("$DEVCONTAINER_BIN" exec --workspace-folder "$PROJECT_DIR" --config "$TEMPLATE_DIR/devcontainer.json")
  if [[ -n "$WORKTREE_NAME" ]]; then
    session="claude-$WORKTREE_NAME"
    base_cmd="claude --dangerously-skip-permissions$CA_FLAG --worktree $WORKTREE_NAME"
  else
    session="claude"
    base_cmd="claude --dangerously-skip-permissions$CA_FLAG"
  fi
  cmd="$base_cmd$RESUME"

  if [[ $PLAIN -eq 1 ]]; then
    if [[ $WINDOWS -gt 1 ]]; then
      echo "==> --plain starts one Claude. TMUX_WINDOWS=$WINDOWS applies to the tmux session only."
    fi
    echo "==> Starting Claude in this terminal, without tmux..."
    exec "${exec_cmd[@]}" zsh -lc "exec $cmd"
  fi

  echo "==> $action tmux session '$session' ($WINDOWS window(s))..."
  exec "${exec_cmd[@]}" \
    zsh -c "if ! tmux has-session -t '$session' 2>/dev/null; then tmux new-session -d -s '$session' -n claude1 '$cmd'; for i in \$(seq 2 $WINDOWS); do tmux new-window -d -t '$session:' -n claude\$i '$base_cmd'; done; fi; exec tmux attach -t '$session'"
}
