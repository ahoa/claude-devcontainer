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
# Claude Code on Linux lists the clipboard types and then reads one type. It
# tries xclip first, and the image has no xclip. It needs no WAYLAND_DISPLAY:
# that variable only puts wl-paste before xclip. Claude Code versions differ in
# the options: one calls `--list-types`, another calls `-l`. Claude Code can
# also ask for image/png when the list says image/jpeg. So the shim accepts
# every form of both options and gives the JPEG file for any type.
#
# Only a paste from the last minute counts, so a later Ctrl+V does not paste an
# old image. Every other call, for example a text read, exits 1.
#
#   wl-paste -l | --list-types                     print image/jpeg
#   wl-paste -t | --type <type>, --type=<type>     write the newest paste

DIR="${ATERM_PASTE_DIR:-/aterm-paste}"

# ls -t sorts by age. find runs it only when a file matches.
newest=$(find "$DIR" -maxdepth 1 -type f -name 'paste-*.jpg' -mmin -1 \
  -exec ls -t {} + 2>/dev/null | head -n 1)
[ -n "$newest" ] || exit 1

case "$1" in
  -l | --list-types) echo image/jpeg ;;
  -t | --type | --type=*) cat "$newest" ;;
  *) exit 1 ;;
esac
