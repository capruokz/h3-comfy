#!/usr/bin/env bash
# ติดตั้ง MiniMax H3 ลงบน ComfyUI ที่ยังว่างเปล่า (เครื่องเช่า vast.ai หรือเครื่องตัวเองก็ได้)
#
#   export HF_TOKEN=hf_xxxx
#   bash setup.sh              # ตรวจเครื่องก่อน ถ้าไม่ผ่านจะหยุด
#   bash setup.sh --fix        # ลง torch cu130 + SageAttention 2.2 ให้ก่อน แล้วค่อยติดตั้ง
#
# ตรวจเครื่องก่อนโหลด 45 GB โดยตั้งใจ — การมารู้ตอนโหลดเสร็จว่า CUDA เป็นเวอร์ชันผิด
# คือวิธีเรียนรู้ที่แพงที่สุด เพราะจ่ายค่าเช่าไประหว่างรอโหลดแล้ว
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# ถามโปรเซสที่รันอยู่ว่าตัวเองอยู่ไหน แทนที่จะเดาจากสิ่งที่เจอบนดิสก์
# เทมเพลตของ vast มี ComfyUI สองชุด และตัวที่ `[ -d ]` เจอก่อนไม่ใช่ตัวที่รันอยู่
. "$HERE/comfy_env.sh"
[ -n "$COMFY" ] || { echo "หา ComfyUI ไม่เจอ -- ตั้ง COMFY=<path> แล้วรันใหม่"; exit 1; }
PY="${PY:-python3}"
echo "ComfyUI: $COMFY  (พอร์ต ${COMFY_PORT:-?}${COMFY_PID:+, pid $COMFY_PID})"

# --- 0. ตรวจเครื่อง ก่อนจ่ายค่าโหลด ------------------------------------------
if [ "${1:-}" = "--fix" ]; then
  # ชุดนี้รองรับเฉพาะ Blackwell จึงมีเป้าหมายเดียวคือ cu130 (cu128 ช้ากว่า 1.84 เท่า)
  # แต่ถ้าของเดิมถูกอยู่แล้วก็ไม่ต้องโหลดใหม่ให้เสียเวลา (torch ก้อนหนึ่งหลาย GB)
  NEEDS_NEW="$($PY - <<'PYEOF' 2>/dev/null || echo yes
import torch
cap = torch.cuda.get_device_capability(0)
cu = tuple(int(x) for x in (torch.version.cuda or "0.0").split(".")[:2])
mine = f"sm_{cap[0]}{cap[1]}"
# การ์ดรันโค้ดที่ build ให้รุ่นเดียวกันแต่เลขรองต่ำกว่าได้ (sm_86 ใช้กับ 4090 sm_89)
supported = any((lambda m: m and int(m.group(1)) == cap[0] and int(m.group(2)) <= cap[1])(__import__("re").fullmatch(r"(?:sm|compute)_(\d+?)(\d)", a)) for a in torch.cuda.get_arch_list())
print("no" if (supported and cu >= (13, 0)) else "yes")
PYEOF
)"
  if [ "$NEEDS_NEW" = "no" ]; then
    echo ">> torch ที่มีอยู่ถูกต้องแล้ว ข้ามการโหลดใหม่"
  else
    echo ">> ลง torch cu130 (การ์ด Blackwell กับ cu128 ช้ากว่า 1.84 เท่า)"
    $PY -m pip install -q --index-url https://download.pytorch.org/whl/cu130 \
        torch==2.11.0+cu130 torchvision==0.26.0+cu130 torchaudio==2.11.0+cu130
  fi
  $PY -m pip install -q triton setuptools wheel packaging ninja
  # อิมเมจพวกนี้มี nvcc แต่ *เฮดเดอร์* ของ CUDA ไม่ครบ การ build จะตายที่
  # "cusparse.h: No such file or directory" — ล้อ nvidia-* ของ torch มีเฮดเดอร์พวกนั้น
  # อยู่แล้ว ชี้คอมไพเลอร์ไปที่นั่นก่อน จะได้ไม่ต้องโหลดจาก apt อีกหลายร้อย MB
  if ! ls /usr/local/cuda/include/cusparse.h >/dev/null 2>&1; then
    SITE="$($PY -c 'import site;print(site.getsitepackages()[0])' 2>/dev/null)"
    if ls "$SITE"/nvidia/*/include/cusparse.h >/dev/null 2>&1; then
      export CPATH="$(ls -d "$SITE"/nvidia/*/include | tr '\n' ':')${CPATH:-}"
      echo ">> ใช้เฮดเดอร์ CUDA จากล้อ pip"
    else
      echo ">> ลงเฮดเดอร์ CUDA จาก apt"
      apt-get update -qq && apt-get install -y cuda-libraries-dev-13-2 cuda-cccl-13-2
    fi
  fi
  # PyPI มี sageattention ถึงแค่ 1.0.6 เท่านั้น 2.2 ไม่เคยมีล้อขึ้นไปวาง
  # `pip install "sageattention>=2.2"` จึงล้มเสมอด้วย No matching distribution
  # และ 1.0.6 คือตัวที่ไม่มี path ของ Blackwell — ต้องคอมไพล์จากซอร์สเท่านั้น
  #
  # --no-build-isolation ไม่ใช่ของเลือกใส่: setup.py ของ SageAttention import torch
  # ตอนบิลด์ แต่ build env ที่ pip สร้างแยกไม่มี torch อยู่ในนั้น อาการที่ได้คือ
  # ModuleNotFoundError: No module named 'torch' จาก path /tmp/pip-build-env
  # ซึ่งอ่านแล้วเหมือน torch ไม่ได้ลง ทั้งที่ลงอยู่
  # MAX_JOBS กระจาย nvcc ลงหลายคอร์ ไม่ใส่แล้วคอมไพล์คลานมาก
  MAX_JOBS="${MAX_JOBS:-32}" $PY -m pip install -v --no-build-isolation \
      git+https://github.com/thu-ml/SageAttention.git || \
    echo "!! คอมไพล์ sageattention ไม่สำเร็จ -- ดู guides/03-install.md หัวข้อแก้ปัญหา"
fi

if ! $PY "$HERE/check_stack.py"; then
  [ "${FORCE:-0}" = "1" ] || { echo "รัน: bash setup.sh --fix"; exit 1; }
  echo "!! FORCE=1 -- รันต่อทั้งที่เครื่องไม่ผ่านการตรวจ ตัวเลขที่ได้จะเชื่อไม่ได้"
fi

# --- 0.5 ComfyUI ต้องใหม่พอ ---------------------------------------------------
# MiniMaxH3AddGuide (ต่อเฟรมแรกจากคลิปก่อน) เพิ่งเข้า core เมื่อ 13 ส.ค. 2569 และ
# comfy_kitchen ที่มี sol_attn (โหนด SolAttnMiniMax) มากับ requirements รุ่นเดียวกัน
# เทมเพลต vast มักเก่ากว่านั้น -- ถ้าไม่มีโหนดนี้ ย้ายไปคอมมิตที่เราใช้จริงแล้วลง requirements ใหม่
COMFY_PIN=ee71d5c4993f29086b27fde1629a945ae48425bf   # 15 ก.ย. 2569 ตัวที่เจนงานจริงอยู่
if ! grep -q "MiniMaxH3AddGuide" "$COMFY/comfy_extras/nodes_minimax_h3.py" 2>/dev/null; then
  if [ -d "$COMFY/.git" ]; then
    echo ">> ComfyUI เก่าเกินไป (ไม่มี MiniMaxH3AddGuide) ย้ายไป ${COMFY_PIN:0:10}"
    { git -C "$COMFY" fetch -q origin "$COMFY_PIN" || git -C "$COMFY" fetch -q origin; } && git -C "$COMFY" checkout -q "$COMFY_PIN" \
      && $PY -m pip install -q -r "$COMFY/requirements.txt" \
      || echo "!! อัปเดต ComfyUI ไม่สำเร็จ -- การต่อเฟรม (SING_FIRST) จะรันไม่ได้"
  else
    echo "!! $COMFY ไม่ใช่ git repo อัปเดตเองไม่ได้ -- ติดตั้งใหม่ด้วย install_comfy.sh"
  fi
fi
grep -q "MiniMaxH3AddGuide" "$COMFY/comfy_extras/nodes_minimax_h3.py" 2>/dev/null \
  && echo "ComfyUI มี MiniMaxH3AddGuide แล้ว" || echo "!! ยังไม่มี MiniMaxH3AddGuide"

# --- 1. เร่งความเร็วดาวน์โหลด ------------------------------------------------
# Hugging Face ย้ายจาก Git LFS มาเป็น Xet แล้ว โหมดหลายคอนเนกชันปิดไว้เป็นค่าเริ่มต้น
# ซึ่งกับไฟล์รวม 45 GB คือความต่างระหว่าง "ไม่กี่นาที" กับ "เป็นชั่วโมง" ของเวลาที่จ่ายเงินอยู่
# อัปเกรด huggingface_hub แต่ไม่เกินช่วงที่ transformers ในเครื่องยอมรับ
# (เคยดึง 2.x มาแล้ว transformers ล้มด้วย "huggingface-hub>=1.5.0,<2.0 is required" ComfyUI ไม่ขึ้น
# ต้องสั่งลดเวอร์ชันเองทุกครั้ง) -- อ่านเงื่อนไขจาก metadata ของ transformers ตัวที่ติดตั้งอยู่
HUB_PIN=$($PY -c "
import importlib.metadata as m, re
try:
    r = [x.split(';')[0] for x in (m.requires('transformers') or []) if re.match(r'huggingface[-_]hub', x, re.I) and 'extra' not in x]
    print(re.sub(r'^huggingface[-_]hub\s*', '', r[0], flags=re.I).strip() if r else '')
except m.PackageNotFoundError:
    print('')
" 2>/dev/null)
$PY -m pip install -q -U "huggingface_hub[hf_xet]${HUB_PIN}"
# ค่าตั้งต้นเปิด Xet ไว้เพราะวัดแล้วเร็วกว่าจริง (605 MB: 59.7 vs 52.8 MB/s ·
# 780 MB: 72.8 vs 30.7 MB/s) แต่ `:-` สำคัญ: บางเครื่องต่อไปยัง CAS backend ของ Xet
# ได้ไม่ดี อาการคือเร็วช่วงแรกแล้วร่วงเหลือหลักร้อย kB/s และแถบ reconstructing
# ค้างนิ่งไม่ขยับ เจอแบบนั้นให้ `export HF_HUB_DISABLE_XET=1` แล้วรันใหม่
# ของเดิมบังคับค่าทับ ผู้ใช้จึงหนีไปทาง CDN ปกติไม่ได้เลยนอกจากแก้ไฟล์นี้
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-0}"
[ -n "${HF_TOKEN:-}" ] && { hf auth login --token "$HF_TOKEN" 2>/dev/null || true; } \
  || echo "!! ไม่ได้ตั้ง HF_TOKEN -- จะโดนจำกัดความเร็ว ดู guides/02-hf-token.md"

dl() { echo ">> $2"; hf download "$1" "$2" --local-dir "$3" ${4:+--revision "$4"}; }  # arg 4 = revision (ไม่ใส่ = main)

# --- 2. โมเดล รวม 45 GB --------------------------------------------------------
# ชุดเดียวกับที่เจนงานจริงบนเครื่องเช่า (workflow/h3_singularity_rent*_api.json):
# Singularity ref2va int8 + ref2v_turbo_4step LoRA, เจนฐาน 0.4 MP 8 step -> ขยาย latent
# เป็น 1.0 MP -> อีก 2 step · 5090 เช่าคลิป 9 วิ ราว 94 วิ
mkdir -p "$COMFY"/models/{diffusion_models,text_encoders,vae,loras,latent_upscale_models}
dl WarmBloodAban/Minimax-h3_Singularity Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors "$COMFY/models/diffusion_models"
dl Comfy-Org/MiniMax-H3 text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors "$COMFY/models"
dl Comfy-Org/MiniMax-H3 vae/minimax_h3_video_vae_fp16.safetensors "$COMFY/models"
dl Comfy-Org/MiniMax-H3 vae/minimax_h3_audio_vae_fp32.safetensors "$COMFY/models"
dl Comfy-Org/MiniMax-H3 loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors "$COMFY/models"
dl LBH-123-AI/Minimax_h3_latent_Upscaler minimax_h3_latent_upscaler_3d_bf16.safetensors "$COMFY/models/latent_upscale_models" 13ccf95d85d120bdbc92c05b1247a6e147bf54bf

# --- 3. custom node ล็อกคอมมิตไว้ --------------------------------------------
# สี่ชุด ที่เหลือที่กราฟใช้ -- MiniMaxH3ReferenceToVideo, MiniMaxH3AddGuide, ResolutionSelector,
# ComfyMathExpression, SplitSigmas, SamplerCustomAdvanced, BasicGuider, LoraLoader,
# ModelAttentionBackend, LTXVSeparateAVLatent, LTXVConcatAVLatent -- อยู่ใน ComfyUI เองแล้ว
clone() {  # url, dir, commit
  local d="$COMFY/custom_nodes/$2"
  [ -d "$d" ] || git clone "$1" "$d"
  git -C "$d" fetch --depth 50 origin >/dev/null 2>&1 || true
  git -C "$d" checkout -q "$3" 2>/dev/null || echo "!! $2: ไม่มีคอมมิต $3 ใช้ HEAD แทน"
  [ -f "$d/requirements.txt" ] && $PY -m pip install -q -r "$d/requirements.txt" || true
}
# MiniMaxH3MemoryEfficientSageAttentionPatch (โหนด 213)
clone https://github.com/kijai/ComfyUI-KJNodes              comfyui-kjnodes            dcfcb5d
# MinimaxH3LatentUpscaler3D (โหนด 503) -- ขยาย latent ภาพระหว่างสองรอบ เสียงแยกออกด้วย
# LTXVSeparateAVLatent ก่อนขยาย · รุ่น 64fc9d4 บังคับ keep_proportion ซึ่งกราฟส่งไปแล้ว
clone https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler \
      Comfyui_Minimax_h3_latent_Upscaler 64fc9d4
# H3ReferenceAudio (โหนด 215 216) ตัด ref เสียงให้เหลือ 0.6 วิ -- ยาวกว่านั้น H3 พูดคำในไฟล์ออกมา
clone https://github.com/jlucasmcrell/ComfyUI-H3-Multishot ComfyUI-H3-Multishot d7d1977
# SolAttnMiniMax (โหนด 217) -- โหนดไฟล์เดียวที่ผู้ทำ Singularity ใช้ มาจากแพ็กใหญ่ของ T8mars
# แต่เราเอาแค่ไฟล์นี้ ล็อกคอมมิตไว้ ต้องมี comfy_kitchen ที่มี sol_attn (มากับขั้น 0.5)
SOL_DIR="$COMFY/custom_nodes/ComfyUI-SolAttnMiniMax"
if [ ! -f "$SOL_DIR/__init__.py" ]; then
  mkdir -p "$SOL_DIR"
  curl -fsSL -o "$SOL_DIR/__init__.py"     https://raw.githubusercontent.com/T8mars/comfyui-minimax-h3-audio-T8/8b379b42bde00a315aee146c8d4285e8caa80a5b/sol_attn_minimax_v2.py     || { rm -rf "$SOL_DIR"; echo "!! โหลด SolAttnMiniMax ไม่สำเร็จ -- workflow จะรันไม่ได้"; }
fi
$PY -c "import comfy_kitchen as c; assert c.sol_attn_is_available()" 2>/dev/null   || echo "!! comfy_kitchen ไม่มี sol_attn -- อัปเดต ComfyUI (pip install -U -r requirements.txt) ก่อนเจน"

# --- 4. เอาแฟล็กของเราใส่โปรเซสที่รันอยู่ ------------------------------------
# เทมเพลตเปิด ComfyUI มาโดยไม่มี --use-sage-attention และโปรเซสที่เปิดมาก่อนขั้นที่ 2
# ก็มองไม่เห็นโมเดลอยู่ดี เพราะ ComfyUI อ่านรายชื่อไฟล์ครั้งเดียวตอนบูต
bash "$HERE/restart_comfy.sh" || { echo "!! ComfyUI ไม่กลับมา -- แก้ตรงนี้ก่อนไปต่อ"; exit 1; }

# --- 5. จดว่า ComfyUI อยู่ไหน ------------------------------------------------
# ตรงนี้เรารู้คำตอบแล้วจาก comfy_env.sh ซึ่งอ่านจากโปรเซสที่รันอยู่จริง
# สคริปต์ตัวอื่นจะได้ไม่ต้องเดาเอง -- และเดาไม่ได้ด้วย เพราะ /system_stats ของ ComfyUI
# ไม่ได้บอก path ของตัวเอง
REPO="$(cd "$HERE/../../.." && pwd)"
$PY - "$REPO/machine.json" "$COMFY" "${COMFY_PORT:-8188}" <<'PYEOF'
import json, sys, pathlib
p, comfy, port = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
d = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
d["comfy_root"] = comfy
d["comfy_api"] = f"http://127.0.0.1:{port}"
p.write_text(json.dumps(d, ensure_ascii=False, indent=1), encoding="utf-8")
print(f"จด comfy_root ลง {p}")
PYEOF

cat <<'EOF'

ready

เจนคลิปได้เลย ครั้งแรกแนะนำความยาว 8 หรือ 10 วินาที

ถ้าคลิปยาวขึ้นนิดเดียวแต่เวลาที่ใช้พุ่งขึ้นเท่าตัว แปลว่าเลยเพดานของการ์ดแล้ว
ให้ถอยกลับมาความยาวก่อนหน้า -- ไม่มี error ใดๆ บอก มันแค่ช้าลงเฉยๆ

อยากรู้เพดานแบบเป๊ะๆ มี find_ceiling.py ให้ (ไม่จำเป็น ใช้เวลา 10-20 นาที)
EOF
