#!/usr/bin/env bash
# ติดตั้ง MiniMax H3 ลงบน ComfyUI ที่ยังว่างเปล่า (เครื่องเช่า vast.ai หรือเครื่องตัวเองก็ได้)
#
#   export HF_TOKEN=hf_xxxx
#   bash setup.sh              # ตรวจเครื่องก่อน ถ้าไม่ผ่านจะหยุด
#   bash setup.sh --fix        # ลง torch cu130 + SageAttention 2.2 ให้ก่อน แล้วค่อยติดตั้ง
#
# ตรวจเครื่องก่อนโหลด 38 GB โดยตั้งใจ — การมารู้ตอนโหลดเสร็จว่า CUDA เป็นเวอร์ชันผิด
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
supported = any(a.replace("compute_", "sm_") == mine for a in torch.cuda.get_arch_list())
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

# --- 1. เร่งความเร็วดาวน์โหลด ------------------------------------------------
# Hugging Face ย้ายจาก Git LFS มาเป็น Xet แล้ว โหมดหลายคอนเนกชันปิดไว้เป็นค่าเริ่มต้น
# ซึ่งกับไฟล์รวม 38 GB คือความต่างระหว่าง "ไม่กี่นาที" กับ "เป็นชั่วโมง" ของเวลาที่จ่ายเงินอยู่
$PY -m pip install -q -U "huggingface_hub[hf_xet]"
# ค่าตั้งต้นเปิด Xet ไว้เพราะวัดแล้วเร็วกว่าจริง (605 MB: 59.7 vs 52.8 MB/s ·
# 780 MB: 72.8 vs 30.7 MB/s) แต่ `:-` สำคัญ: บางเครื่องต่อไปยัง CAS backend ของ Xet
# ได้ไม่ดี อาการคือเร็วช่วงแรกแล้วร่วงเหลือหลักร้อย kB/s และแถบ reconstructing
# ค้างนิ่งไม่ขยับ เจอแบบนั้นให้ `export HF_HUB_DISABLE_XET=1` แล้วรันใหม่
# ของเดิมบังคับค่าทับ ผู้ใช้จึงหนีไปทาง CDN ปกติไม่ได้เลยนอกจากแก้ไฟล์นี้
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-0}"
[ -n "${HF_TOKEN:-}" ] && { hf auth login --token "$HF_TOKEN" 2>/dev/null || true; } \
  || echo "!! ไม่ได้ตั้ง HF_TOKEN -- จะโดนจำกัดความเร็ว ดู guides/02-hf-token.md"

dl() { echo ">> $2"; hf download "$1" "$2" --local-dir "$3"; }

# --- 2. โมเดล รวม 38.0 GB ----------------------------------------------------
# fl2va ไม่ใช่ ref2va ชุดเก่าเคยโหลด ref2va มาทั้งที่ workflow ของตัวเองเรียก fl2va
# จึงโหลดไม่ขึ้นตั้งแต่แรก อยู่รีโปเดียวกัน ต่างกันคำเดียว
mkdir -p "$COMFY"/models/{diffusion_models,text_encoders,vae,loras,latent_upscale_models}
dl tsolful/Minimax_H3_INT4MixedConvRot minimax_h3_fl2va_pruned_INT4Q.safetensors "$COMFY/models/diffusion_models"
dl Comfy-Org/MiniMax-H3 text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors "$COMFY/models"
dl Comfy-Org/MiniMax-H3 vae/minimax_h3_video_vae_fp16.safetensors "$COMFY/models"
dl Comfy-Org/MiniMax-H3 vae/minimax_h3_audio_vae_fp32.safetensors "$COMFY/models"
dl larryvrh/MiniMax-H3-Turbo-Lora minimax_h3_turbo_v4_step600_ema.safetensors "$COMFY/models/loras"

# LoRA เนื้อภาพ "Authentic cinematic texture" -- ดันดำที่จมสนิทให้กลับมามีรายละเอียด
# (วัดแล้ว L* p1 จาก 1.5 ขึ้นเป็น 4.1) และลดอิ่มสีจาก 141 เหลือ 98 ซึ่งเป็นสองอย่าง
# ที่สั่งในพรอมป์ตแล้วไม่เป็นผลเลย ใช้ที่ strength 0.7
# CivitAI บังคับโทเคน ถ้าไม่ตั้ง CIVITAI_TOKEN จะข้ามพร้อมบอกวิธี
CINE_DIR="$COMFY/models/loras/minimax-h3"
CINE_LORA="$CINE_DIR/Minimax H3Authentic cinematic texture.safetensors"
if [ -f "$CINE_LORA" ]; then
  echo ">> LoRA เนื้อภาพ: มีแล้ว ข้าม"
elif [ -n "${CIVITAI_TOKEN:-}" ]; then
  mkdir -p "$CINE_DIR"
  echo ">> LoRA เนื้อภาพ (CivitAI 3267949)"
  curl -fL --retry 3 -o "$CINE_LORA"     -H "Authorization: Bearer $CIVITAI_TOKEN"     "https://civitai.com/api/download/models/3267949"     || { rm -f "$CINE_LORA"; echo "!! โหลด LoRA เนื้อภาพไม่สำเร็จ ข้ามไปก่อน"; }
else
  echo "!! ข้าม LoRA เนื้อภาพ: ไม่ได้ตั้ง CIVITAI_TOKEN"
  echo "   เอาโทเคนจาก https://civitai.com/user/account แล้วรันใหม่แบบ"
  echo "   CIVITAI_TOKEN=xxxx bash setup.sh"
fi
# ตัวขยาย latent 3D 691 MB -- ใช้กับสูตรเจนฐานความละเอียดต่ำแล้วขยาย ซึ่งได้ภาพ
# คมกว่าและเร็วกว่าการเจนที่ความละเอียดปลายทางตรง ๆ
dl LBH-123-AI/Minimax_h3_latent_Upscaler minimax_h3_latent_upscaler_3d_bf16.safetensors "$COMFY/models/latent_upscale_models"

# --- 3. custom node ล็อกคอมมิตไว้ --------------------------------------------
# หกชุด ที่เหลือที่กราฟใช้ -- MiniMaxH3ReferenceToVideo, ResolutionSelector,
# ComfyMathExpression, SplitSigmas, SamplerCustomAdvanced, BasicGuider,
# LTXVSeparateAVLatent, LTXVConcatAVLatent -- อยู่ใน comfy_extras ของ ComfyUI เองแล้ว
clone() {  # url, dir, commit
  local d="$COMFY/custom_nodes/$2"
  [ -d "$d" ] || git clone "$1" "$d"
  git -C "$d" fetch --depth 50 origin >/dev/null 2>&1 || true
  git -C "$d" checkout -q "$3" 2>/dev/null || echo "!! $2: ไม่มีคอมมิต $3 ใช้ HEAD แทน"
  [ -f "$d/requirements.txt" ] && $PY -m pip install -q -r "$d/requirements.txt" || true
}
clone https://github.com/Larryvrh/ComfyUI-MiniMax-H3-Turbo ComfyUI-MiniMax-H3-Turbo 55fee86
clone https://github.com/kijai/ComfyUI-KJNodes              comfyui-kjnodes            dcfcb5d
clone https://github.com/kijai/ComfyUI-SolAttn_triton       ComfyUI-SolAttn_triton     1b8dece
# โหนดขยายภาพ -- ต่อท้าย sampler แล้ว re-sample ที่ความละเอียดสูงกว่า
# หมายเหตุ: การหั่นไทล์ (spatial_split_param) ใช้กับ turbo LoRA ไม่ได้ ตกด้วย
# tensor a (N) vs b (N-1) เหมือนบั๊ก ref_audio ข้างล่าง ให้ปล่อยไม่ต่อไว้
clone https://github.com/bbaudio-2025/Comfyui-MMH3-UltimateUpscale Comfyui-MMH3-UltimateUpscale HEAD
# MinimaxH3LatentUpscaler3D -- คนละแพ็กกับ UltimateUpscale ข้างบน ใช้กับเส้นทางแบ่ง
# sigma (เจนฐานเล็กบางสเตป -> ขยาย latent -> เก็บสเตปท้ายที่ขนาดจริง) ซึ่งเสียงถูกแยก
# ออกด้วย LTXVSeparateAVLatent ก่อนขยาย จึงไม่เจอบั๊ก tensor a (3) vs b (4) เลย
clone https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler \
      Comfyui_Minimax_h3_latent_Upscaler 64fc9d4
# VHS_LoadVideoPath -- แปลงคลิปเป็นเฟรม IMAGE ให้ ref_videos ของ MiniMaxH3ReferenceToVideo
# ช่องนั้นรับ IMAGE ไม่ใช่ VIDEO โหนด Load Video ของคอร์จึงต่อตรงเข้าไปไม่ได้
clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite \
      comfyui-videohelpersuite 1.7.9
# ComfyUI-Darkroom -- โหนดเกรดสีและฟิล์มสต็อก workflow ละครของเราต่อ
# DarkroomFilmStockColor ไว้ท้าย VAEDecode ถ้าไม่มีแพ็กนี้ workflow จะตกทันทีที่คิว
clone https://github.com/jeremieLouvaert/ComfyUI-Darkroom ComfyUI-Darkroom de6d4a8

# --- 4. แพตช์โหนด turbo ------------------------------------------------------
# โหนดต้นฉบับจะตายทันทีที่ต่อ <Audio N> เดี่ยวๆ เข้าไป เพราะ _unique_t ของมันสร้าง
# แถว timestep น้อยกว่าของ core อยู่หนึ่งแถว จน LoRA บวกเข้า projection ไม่ได้
# (tensor a (3) vs b (2)) คลิปที่มีบทพูดทุกคลิปต้องต่อ ref เสียง จึงรันไม่ได้เลยถ้าไม่แพตช์
#
# หมายเหตุสำหรับคนที่เอาไปใช้ต่อ: นี่คือการเขียนทับไฟล์ของโปรเจกต์คนอื่น มันผูกกับ
# คอมมิต 55fee86 ข้างบน ถ้าคุณเปลี่ยนไปใช้เวอร์ชันใหม่กว่า ให้ลองถอดแพตช์ก่อน
# (คืนค่าจาก __init__.py.stock) แล้วดูว่าต้นทางแก้ให้แล้วหรือยัง
NODE="$COMFY/custom_nodes/ComfyUI-MiniMax-H3-Turbo"
cp -n "$NODE/__init__.py" "$NODE/__init__.py.stock" 2>/dev/null || true
cp "$HERE/h3turbo_patched__init__.py" "$NODE/__init__.py"
echo "แพตช์ ref_audio แล้ว (ของเดิมเก็บไว้ที่ __init__.py.stock)"

# --- 5. เอาแฟล็กของเราใส่โปรเซสที่รันอยู่ ------------------------------------
# เทมเพลตเปิด ComfyUI มาโดยไม่มี --use-sage-attention และโปรเซสที่เปิดมาก่อนขั้นที่ 2
# ก็มองไม่เห็นโมเดลอยู่ดี เพราะ ComfyUI อ่านรายชื่อไฟล์ครั้งเดียวตอนบูต
bash "$HERE/restart_comfy.sh" || { echo "!! ComfyUI ไม่กลับมา -- แก้ตรงนี้ก่อนไปต่อ"; exit 1; }

# --- 6. จดว่า ComfyUI อยู่ไหน ------------------------------------------------
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
