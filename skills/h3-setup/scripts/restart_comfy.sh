#!/usr/bin/env bash
# Replace the template's ComfyUI with one that has our flags, and win the race
# against the thing that keeps restarting it.
#
#   bash restart_comfy.sh
#
# The template launches ComfyUI WITHOUT --use-sage-attention. That single
# omission throws away the entire reason we compiled SageAttention 2.2, and it
# fails silently -- clips render, just slower -- which is exactly the trap that
# cost 5.2x at home. So the process has to be replaced, not just restarted.
#
# It must come back on the SAME port it was on: a proxy in front of it (the one
# holding 8188) is what the tunnel and its auth token talk to, and moving the
# app breaks that whole chain.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/comfy_env.sh"
[ -n "$COMFY" ] || { echo "no ComfyUI found"; exit 1; }
PORT="${COMFY_PORT:-18188}"
echo "install : $COMFY"
echo "port    : $PORT"
[ -n "${COMFY_ARGS:-}" ] && echo "was     : $COMFY_ARGS"

# Ask the supervisor to stop it. pkill alone loses -- the supervisor notices
# within seconds and starts a replacement that grabs the port before we do.
for name in $(supervisorctl status 2>/dev/null | awk '{print $1}'); do
  case "$name" in
    *[Cc]omfy*) echo "stopping supervisor job: $name"; SUPER_JOB="$name"; supervisorctl stop "$name" >/dev/null 2>&1 ;;
  esac
done
pkill -f 'main\.py' 2>/dev/null
# If something respawns it anyway, keep killing for a few seconds; whoever holds
# the port when this loop ends decides whether our flags took effect.
for _ in $(seq 1 8); do
  sleep 1
  pgrep -f 'main\.py' >/dev/null || break
  pkill -f 'main\.py' 2>/dev/null
done
if pgrep -f 'main\.py' >/dev/null; then
  echo "!! something keeps restarting ComfyUI -- stop it on the vast Supervisor page, then re-run"
  exit 1
fi

cd "$COMFY" || exit 1
# แฟล็กที่ต้องมีครบ ไม่ใช่แค่ sage attention:
#   --disable-pinned-memory  โมเดล 17.7 GB ถูก stage ไว้ในแรมระบบเมื่อการ์ดอุ้มไม่หมด
#     ถ้าหน่วยความจำก้อนนั้นถูกล็อกห้ามสลับออก เคอร์เนลจะฆ่าโปรเซสทิ้งกลาง sampling
#     step แรก โดยไม่มี traceback และไม่มี torch.OutOfMemoryError ให้เห็นเลย
#     (เจอจริงบน 5080 15.5 GB / RAM 62 GB ล่มสี่รอบติด 2026-08-23 — เครื่องบ้าน
#      สเปกเดียวกันเป๊ะแต่รันได้ เพราะเปิดแฟล็กนี้อยู่)
#   --fast-disk              ให้ที่พักส่วนที่ล้นลงดิสก์แทนที่จะกองในแรม
#   --fast fp16_accumulation ความเร็ว ไม่กระทบภาพ
ARGS="--port $PORT --disable-auto-launch --enable-cors-header\
  --disable-pinned-memory --fast-disk --fast fp16_accumulation --use-sage-attention"

# ถ้ามี supervisor job ของ comfyui อยู่ ให้แก้ config ของมันแล้วสั่งเปิดผ่าน supervisor
# ดีกว่าถือโปรเซสเอง: หน้า portal จะไม่โกหกว่า STOPPED ทั้งที่รันอยู่ และเมื่อโปรเซส
# ตายกลางดึกจะมีคนปลุกให้ ส่วน nohup ตายแล้วตายเลย (บทเรียน 2026-08-23)
CONF="$(grep -rl "ComfyUI" /etc/supervisor* 2>/dev/null | head -1)"
if [ -n "$CONF" ] && [ -n "${SUPER_JOB:-}" ]; then
  echo "แก้ config supervisor: $CONF"
  python3 - "$CONF" "$COMFY" "$ARGS" <<'PY'
import re, sys
conf, comfy, args = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(conf).read()
cmd = f"command=python {comfy}/main.py " + " ".join(args.split())
s = re.sub(r"^command=.*$", cmd, s, count=1, flags=re.M)
open(conf, "w").write(s)
print("  ->", cmd)
PY
  supervisorctl reread >/dev/null 2>&1; supervisorctl update >/dev/null 2>&1
  supervisorctl start "$SUPER_JOB" >/dev/null 2>&1
  echo "เปิดผ่าน supervisor แล้ว (ปุ่มในหน้า portal ใช้ได้ตามปกติ)"
else
  cd "$COMFY" || exit 1
  # ทางสำรอง: ไม่มี config ให้แก้ ต้องถือโปรเซสเอง
  # **log จะไปอยู่ที่ /workspace/comfy.log ไม่ใช่ $COMFY/comfy.log** — เคยหลงอ่าน
  # ไฟล์ของโปรเซสที่ตายไปแล้วสามรอบจนหาสาเหตุไม่เจอ
  nohup python main.py $ARGS > /workspace/comfy.log 2>&1 &
  echo "started pid $! -- log อยู่ที่ /workspace/comfy.log"
  echo "!! หน้า portal จะขึ้น STOPPED ตลอดเพราะ supervisor ไม่ได้ถือโปรเซสนี้"
fi
echo "started pid $! -- waiting for it to answer"

for i in $(seq 1 60); do
  sleep 3
  if curl -s -m 5 "http://127.0.0.1:$PORT/system_stats" | grep -q comfyui_version; then
    echo "up after $((i*3))s"
    # Registration is the real check. The files can all be in place and still not
    # be visible if this process started before they landed.
    python - "$PORT" <<'PY'
import json, sys, urllib.request
o = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/object_info", timeout=300).read())
need = ["MiniMaxH3ReferenceToVideo", "MiniMaxH3TurboLoRA", "MiniMaxH3TurboSampler",
        "PathchSageAttentionKJ", "MiniMaxH3MemoryEfficientSageAttentionPatch",
        "SolAttnPatch", "ResolutionSelector", "ComfyMathExpression"]
miss = [n for n in need if n not in o]
unet = o.get("UNETLoader", {}).get("input", {}).get("required", {}).get("unet_name", [[]])[0]
print("nodes :", "all present" if not miss else "MISSING " + ", ".join(miss))
print("unets :", unet or "NONE -- models are not where this install reads them")
sys.exit(1 if miss or not unet else 0)
PY
    exit $?
  fi
done
echo "!! did not come up -- tail /workspace/comfy.log"
tail -20 /workspace/comfy.log
exit 1
