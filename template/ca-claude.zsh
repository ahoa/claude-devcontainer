# Appended to ~/.zshrc by devcontainer.json's postCreateCommand, after the
# claude feature's own claude() line. The feature runs later than the image
# build, so the Dockerfile cannot own this.
#
# With the container's own install of the ca plugin (ca-plugin.sh), Claude loads
# it by itself. Without it, CA_PLUGIN_CACHE from docker-compose.yml holds one
# directory per version of the read-only host plugin, and --plugin-dir loads the
# newest one. Never both: the plugin then loads twice.
claude() {
  # The same test as `ca-plugin.sh installed`.
  if grep -q '"claude-agents@codeborne"' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" 2>/dev/null; then
    command claude --dangerously-skip-permissions "$@"
    return
  fi
  local ca="$(ls -d "$CA_PLUGIN_CACHE"/*/ 2>/dev/null | sort -V | tail -1)"
  if [ -z "$ca" ]; then
    echo "ca plugin: the mount is empty. Install it on the host (claude plugin install claude-agents@codeborne). Running without the pipeline." >&2
    command claude --dangerously-skip-permissions "$@"
    return
  fi
  command claude --dangerously-skip-permissions --plugin-dir "${ca%/}" "$@"
}
