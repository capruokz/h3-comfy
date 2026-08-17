#!/usr/bin/env bash
# Find the ComfyUI that is ACTUALLY RUNNING, not the one that merely exists.
#
# The vast comfy template cost an hour of confusion by having every one of these
# assumptions be wrong at once:
#
#   * two installs on disk -- /opt/workspace-internal/ComfyUI and
#     /workspace/ComfyUI -- and the one that exists first is not the live one,
#     so picking by [ -d ] installs 38 GB into a directory nothing reads;
#   * the app listens on 18188, while 8188 is an auth proxy in front of it, so
#     launching "on 8188" dies instantly with a port clash and exit 1;
#   * a supervisor respawns it within seconds of any pkill, so a manual restart
#     silently loses the race and you end up talking to the old process.
#
# Everything here is derived from the live process instead: its cwd is the real
# install, its --port is the real port. Source this, don't run it.
COMFY_PID="$(pgrep -f 'main\.py' | while read -r p; do
    tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- '--port' && echo "$p" && break
  done)"

if [ -n "$COMFY_PID" ]; then
  COMFY="$(readlink -f "/proc/$COMFY_PID/cwd")"
  COMFY_PORT="$(tr '\0' '\n' < "/proc/$COMFY_PID/cmdline" | grep -A1 -x -- '--port' | tail -1)"
  COMFY_ARGS="$(tr '\0' ' ' < "/proc/$COMFY_PID/cmdline")"
else
  # Nothing running yet: fall back to whichever install is on disk, preferring
  # the writable workspace copy since that is what the template actually serves.
  COMFY="${COMFY:-}"
  [ -n "$COMFY" ] || { [ -d /workspace/ComfyUI ] && COMFY=/workspace/ComfyUI; }
  [ -n "$COMFY" ] || { [ -d /opt/workspace-internal/ComfyUI ] && COMFY=/opt/workspace-internal/ComfyUI; }
  COMFY_PORT="${COMFY_PORT:-18188}"
  COMFY_ARGS=""
fi
export COMFY COMFY_PORT COMFY_PID COMFY_ARGS
