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
# `|| true` ไม่ใช่ของประดับ: ผู้เรียกตั้ง `set -euo pipefail` ไว้ และไฟล์นี้ถูก source
# เข้าไป ถ้ายังไม่มี ComfyUI รันอยู่ pgrep จะคืน 1, pipefail ดันสถานะนั้นออกมาทั้งไปป์,
# แล้ว set -e ก็ฆ่าสคริปต์ของผู้เรียกทิ้งตรงนี้เลย -- ก่อนถึง echo บรรทัดแรกเสียอีก
# อาการที่ได้คือ setup.sh จบเงียบสนิทไม่มีข้อความใดๆ ซึ่งเป็นเรื่องปกติมากตอนติดตั้ง
# ครั้งแรกเพราะยังไม่มีใครเปิด ComfyUI และดูเหมือนสุ่มเอาตอนเครื่องกำลังรีสตาร์ทมันอยู่
# ไม่เจอโปรเซส = ยังไม่ได้เปิด ซึ่งเป็นสถานะที่ถูกต้อง ไม่ใช่ความล้มเหลว
COMFY_PID="$( { pgrep -f 'main\.py' || true; } | while read -r p; do
    tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- '--port' && echo "$p" && break
  done )"

if [ -n "$COMFY_PID" ]; then
  COMFY="$(readlink -f "/proc/$COMFY_PID/cwd")"
  COMFY_PORT="$(tr '\0' '\n' < "/proc/$COMFY_PID/cmdline" | grep -A1 -x -- '--port' | tail -1)"
  COMFY_ARGS="$(tr '\0' ' ' < "/proc/$COMFY_PID/cmdline")"
else
  # Nothing running yet: fall back to whichever install is on disk, preferring
  # the writable workspace copy since that is what the template actually serves.
  # แต่ละบรรทัดปิดท้ายด้วย `|| true` ด้วยเหตุผลเดียวกับ pgrep ข้างบน: ถ้าหาไม่เจอ
  # ทั้งสองที่ บรรทัดสุดท้ายจะคืน 1 แล้ว set -e ของผู้เรียกก็ฆ่าทิ้งตรงนี้ ทำให้
  # ข้อความ "หา ComfyUI ไม่เจอ -- ตั้ง COMFY=<path>" ที่ setup.sh เตรียมไว้ ไม่มีวันได้พิมพ์
  COMFY="${COMFY:-}"
  [ -n "$COMFY" ] || { [ -d /workspace/ComfyUI ] && COMFY=/workspace/ComfyUI; } || true
  [ -n "$COMFY" ] || { [ -d /opt/workspace-internal/ComfyUI ] && COMFY=/opt/workspace-internal/ComfyUI; } || true
  COMFY_PORT="${COMFY_PORT:-18188}"
  COMFY_ARGS=""
fi
export COMFY COMFY_PORT COMFY_PID COMFY_ARGS
