#!/usr/bin/env bash
# ติดตั้ง ComfyUI ลงเครื่อง Linux ที่ยังไม่มี แล้วเปิดให้พร้อมใช้
#
#   bash install_comfy.sh                  # ลงที่ /workspace/ComfyUI (หรือ ~/ComfyUI ถ้าไม่มี /workspace)
#   bash install_comfy.sh /path/to/where   # ระบุที่เอง
#
# รัน precheck.py ก่อนเสมอ ตัวนี้ไม่ตรวจสเปคซ้ำ มันเชื่อว่าคุณผ่านด่านนั้นมาแล้ว
#
# ทำเฉพาะ Linux -- บน Windows ให้โหลด ComfyUI portable จากหน้า release ของเขาแทน
# เป็นไฟล์บีบอัดที่แตกแล้วใช้ได้เลย คนละเส้นทางกันคนละเรื่อง
set -euo pipefail

DEST="${1:-}"
if [ -z "$DEST" ]; then
  [ -d /workspace ] && DEST=/workspace/ComfyUI || DEST="$HOME/ComfyUI"
fi
PY="${PY:-python3}"
PORT="${COMFY_PORT:-8188}"

[ "$(uname -s)" = "Linux" ] || {
  echo "สคริปต์นี้ทำเฉพาะ Linux"
  echo "บน Windows ให้โหลด ComfyUI portable จาก https://github.com/comfyanonymous/ComfyUI/releases"
  echo "แตกไฟล์แล้วรัน run_nvidia_gpu.bat หนึ่งครั้ง จากนั้นค่อยกลับมาทำ setup.sh"
  exit 1
}

if [ -f "$DEST/main.py" ]; then
  echo "มี ComfyUI อยู่แล้วที่ $DEST -- ข้ามการติดตั้ง"
else
  echo ">> ดึง ComfyUI ลง $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI "$DEST"
fi

# --- torch ก่อน requirements -------------------------------------------------
# requirements.txt ของ ComfyUI มี torch อยู่ด้วย ถ้าปล่อยให้ pip เลือกเอง มันจะหยิบ
# ล้อ default ซึ่งไม่ใช่ cu130 แล้วการ์ด Blackwell จะช้ากว่าที่ควร 1.84 เท่า
# ลงตัวที่ถูกไปก่อน pip จะได้เห็นว่ามีแล้วและไม่ไปหยิบตัวอื่นมาทับ
NEEDS="$($PY - <<'PYEOF' 2>/dev/null || echo yes
import torch
cap = torch.cuda.get_device_capability(0)
cu = tuple(int(x) for x in (torch.version.cuda or "0.0").split(".")[:2])
mine = f"sm_{cap[0]}{cap[1]}"
ok = any(a.replace("compute_", "sm_") == mine for a in torch.cuda.get_arch_list())
print("no" if (ok and cu >= (13, 0)) else "yes")
PYEOF
)"
if [ "$NEEDS" = "no" ]; then
  echo ">> torch ที่มีอยู่ใช้ได้กับการ์ดใบนี้แล้ว ข้าม"
else
  echo ">> ลง torch cu130 (ใช้เวลาสักพัก ไฟล์ใหญ่)"
  $PY -m pip install -q --index-url https://download.pytorch.org/whl/cu130 \
      torch==2.11.0+cu130 torchvision==0.26.0+cu130 torchaudio==2.11.0+cu130
fi

echo ">> ลงของที่ ComfyUI ต้องใช้"
$PY -m pip install -q -r "$DEST/requirements.txt"

# --- เปิดแล้วรอจนตอบ ---------------------------------------------------------
if curl -sf -m 3 "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
  echo ">> มี ComfyUI ตอบอยู่ที่พอร์ต $PORT แล้ว"
else
  echo ">> เปิด ComfyUI ที่พอร์ต $PORT"
  cd "$DEST"
  nohup $PY main.py --listen 127.0.0.1 --port "$PORT" --use-sage-attention \
      > "$DEST/comfy.log" 2>&1 &
  echo "   log อยู่ที่ $DEST/comfy.log"
  for i in $(seq 1 60); do
    curl -sf -m 3 "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1 && break
    sleep 3
  done
  curl -sf -m 3 "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1 || {
    echo "!! ComfyUI ไม่ตอบภายใน 3 นาที -- ดูสาเหตุที่ $DEST/comfy.log"
    tail -20 "$DEST/comfy.log" || true
    exit 1
  }
fi

# --- จดไว้ให้สคริปต์ตัวอื่นใช้ -----------------------------------------------
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
$PY - "$REPO/machine.json" "$DEST" "$PORT" <<'PYEOF'
import json, sys, pathlib
p, comfy, port = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
d = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
d["comfy_root"] = comfy
d["comfy_api"] = f"http://127.0.0.1:{port}"
p.write_text(json.dumps(d, ensure_ascii=False, indent=1), encoding="utf-8")
print(f"จด comfy_root ลง {p}")
PYEOF

cat <<EOF

ComfyUI พร้อมแล้วที่ $DEST  (พอร์ต $PORT)

ขั้นต่อไป -- ลงตัวโมเดล H3:
  export HF_TOKEN=hf_xxxx
  bash setup.sh
EOF
