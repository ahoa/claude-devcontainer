# Appended to ~/.zshrc by devcontainer.json's postCreateCommand, after the
# claude feature's own claude() line. The feature runs later than the image
# build, so the Dockerfile cannot own this.
#
# CA_PLUGIN_CACHE comes from docker-compose.yml and holds one directory per
# installed plugin version. The host owns the versions.
claude() {
  local ca="$(ls -d "$CA_PLUGIN_CACHE"/*/ 2>/dev/null | sort -V | tail -1)"
  if [ -z "$ca" ]; then
    echo "ca plugin: the mount is empty. Install it on the host (claude plugin install claude-agents@codeborne). Running without the pipeline." >&2
    command claude --dangerously-skip-permissions "$@"
    return
  fi
  command claude --dangerously-skip-permissions --plugin-dir "${ca%/}" "$@"
}
