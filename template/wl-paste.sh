#!/bin/sh
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated.
#
# A clipboard for image pastes from aTerm, installed as /usr/local/bin/wl-paste.
# The container has no clipboard. aTerm uploads the image to ~/.cache/aterm on
# the host and sends Ctrl+V. docker-compose.yml mounts that directory read-only
# at /aterm-paste.
#
# Claude Code on Linux reads an image with `wl-paste --list-types` and
# `wl-paste --type <type>`. It tries xclip first, and the image has no xclip.
# It needs no WAYLAND_DISPLAY: that variable only puts wl-paste before xclip.
#
# Only a paste from the last minute counts, so a later Ctrl+V does not paste an
# old image. Every other call, for example a text read, exits 1.
#
#   wl-paste --list-types     print image/jpeg when a recent paste exists
#   wl-paste --type <type>    write the newest recent paste to stdout

DIR="${ATERM_PASTE_DIR:-/aterm-paste}"

# ls -t sorts by age. find runs it only when a file matches.
newest=$(find "$DIR" -maxdepth 1 -type f -name 'paste-*.jpg' -mmin -1 \
  -exec ls -t {} + 2>/dev/null | head -n 1)
[ -n "$newest" ] || exit 1

case "$1" in
  --list-types) echo image/jpeg ;;
  --type) cat "$newest" ;;
  *) exit 1 ;;
esac
