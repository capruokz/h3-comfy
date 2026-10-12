# ติดตั้งโมเดล MiniMax H3 ลงบน ComfyUI ที่มีอยู่แล้ว (ฝั่ง Windows)
#
#   $env:HF_TOKEN = "hf_xxxx"
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -Comfy "C:\ComfyUI\ComfyUI_windows_portable\ComfyUI"
#
# ตัวเดียวกับ setup.sh แต่สำหรับ Windows -- setup.sh ใช้บน Windows ไม่ได้เลย เพราะ
# comfy_env.sh อ่านจาก /proc เพื่อหาโปรเซสที่รันอยู่ ซึ่ง Windows ไม่มี
[CmdletBinding()]
param(
    [string]$Comfy,
    [string]$Python,
    [int]$Port = 8188,
    [switch]$Force
)
$ErrorActionPreference = "Stop"

$HERE = $PSScriptRoot
$REPO = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $HERE))
$mj   = Join-Path $REPO "machine.json"

# --- 0. หา ComfyUI กับ python ที่จะใช้ ---------------------------------------
# บน Windows เดาจากดิสก์ได้ตรงกว่าฝั่ง Linux เพราะ portable มีโครงตายตัว
if (-not $Comfy -and (Test-Path $mj)) {
    $d = Get-Content $mj -Raw | ConvertFrom-Json
    $Comfy  = $d.comfy_root
    $Python = $d.python
}
if (-not $Comfy) {
    foreach ($c in @("C:\ComfyUI\ComfyUI_windows_portable\ComfyUI",
                     "C:\ComfyUI_windows_portable\ComfyUI",
                     "D:\ComfyUI_windows_portable\ComfyUI")) {
        if (Test-Path (Join-Path $c "main.py")) { $Comfy = $c; break }
    }
}
if (-not $Comfy -or -not (Test-Path (Join-Path $Comfy "main.py"))) {
    Write-Host "หา ComfyUI ไม่เจอ"
    Write-Host "  รัน install_comfy.ps1 ก่อน หรือระบุเอง:  -Comfy <path ของโฟลเดอร์ ComfyUI>"
    exit 1
}
if (-not $Python -or -not (Test-Path $Python)) {
    $Python = Join-Path (Split-Path -Parent $Comfy) "python_embeded\python.exe"
}
if (-not (Test-Path $Python)) {
    Write-Host "ไม่เจอ python ของ ComfyUI ที่ $Python -- ระบุเองด้วย -Python"
    exit 1
}
Write-Host "ComfyUI: $Comfy"
Write-Host "python : $Python"

# --- 1. ตรวจเครื่อง ก่อนจ่ายค่าโหลด ------------------------------------------
& $Python (Join-Path $HERE "check_stack.py")
if ($LASTEXITCODE -ne 0 -and -not $Force) {
    Write-Host "แก้ข้อที่ขึ้นว่า [ต้องแก้] ก่อน หรือใช้ -Force ถ้ารู้ตัวว่ากำลังทำอะไร"
    exit 1
}

# --- 1.5 ComfyUI ต้องใหม่พอ --------------------------------------------------
# MiniMaxH3AddGuide (ต่อเฟรมแรกจากคลิปก่อน) เข้า core เมื่อ 13 ส.ค. 2569 และ comfy_kitchen
# ที่มี sol_attn มากับ requirements รุ่นเดียวกัน ถ้าไม่มี ย้ายไปคอมมิตที่เจนงานจริงอยู่
$comfyPin = "ee71d5c4993f29086b27fde1629a945ae48425bf"   # 15 ก.ย. 2569
$h3nodes = Join-Path $Comfy "comfy_extras\nodes_minimax_h3.py"
if (-not ((Test-Path $h3nodes) -and (Select-String -Quiet -Path $h3nodes -Pattern "MiniMaxH3AddGuide"))) {
    if (Test-Path (Join-Path $Comfy ".git")) {
        Write-Host ">> ComfyUI เก่าเกินไป (ไม่มี MiniMaxH3AddGuide) ย้ายไป $($comfyPin.Substring(0,10))"
        git -C $Comfy fetch -q origin
        git -C $Comfy checkout -q $comfyPin
        & $Python -m pip install -q -r (Join-Path $Comfy "requirements.txt")
    } else {
        Write-Host "!! $Comfy ไม่ใช่ git repo อัปเดตเองไม่ได้ -- ติดตั้งใหม่ด้วย install_comfy.ps1"
    }
}
if ((Test-Path $h3nodes) -and (Select-String -Quiet -Path $h3nodes -Pattern "MiniMaxH3AddGuide")) {
    Write-Host "ComfyUI มี MiniMaxH3AddGuide แล้ว"
} else { Write-Host "!! ยังไม่มี MiniMaxH3AddGuide -- การต่อเฟรมจะรันไม่ได้" }

# --- 2. เร่งความเร็วดาวน์โหลด ------------------------------------------------
# HF ย้ายมาใช้ Xet แล้ว โหมดหลายคอนเนกชันปิดไว้เป็นค่าเริ่มต้น ซึ่งกับ 45 GB
# คือความต่างระหว่างไม่กี่นาทีกับเป็นชั่วโมง
# อัปเกรด huggingface_hub แต่ไม่เกินช่วงที่ transformers ในเครื่องยอมรับ
# (เคยดึง 2.x มาแล้ว transformers ล้มด้วย "huggingface-hub>=1.5.0,<2.0 is required" ComfyUI ไม่ขึ้น
# ต้องสั่งลดเวอร์ชันเองทุกครั้ง) -- อ่านเงื่อนไขจาก metadata ของ transformers ตัวที่ติดตั้งอยู่
$hubPinPy = @'
import importlib.metadata as m, re
try:
    r = [x.split(';')[0] for x in (m.requires('transformers') or []) if re.match(r'huggingface[-_]hub', x, re.I) and 'extra' not in x]
    print(re.sub(r'^huggingface[-_]hub\s*', '', r[0], flags=re.I).strip() if r else '')
except m.PackageNotFoundError:
    print('')
'@
$hubPin = (& $Python -c $hubPinPy 2>$null | Out-String).Trim()
& $Python -m pip install -q -U "huggingface_hub[hf_xet]$hubPin"
# ค่าตั้งต้นเปิด Xet ไว้เพราะวัดแล้วเร็วกว่าจริง แต่ถ้าเครื่องไหนต่อไปยัง CAS backend
# ของ Xet ได้ไม่ดี (เร็วช่วงแรกแล้วร่วงเหลือหลักร้อย kB/s แถบ reconstructing ค้างนิ่ง)
# ให้ตั้ง $env:HF_HUB_DISABLE_XET = "1" ก่อนเรียกสคริปต์นี้ แล้วมันจะไม่ถูกทับ
if (-not $env:HF_XET_HIGH_PERFORMANCE) { $env:HF_XET_HIGH_PERFORMANCE = "1" }
if (-not $env:HF_HUB_DISABLE_XET)      { $env:HF_HUB_DISABLE_XET = "0" }
if (-not $env:HF_TOKEN) {
    Write-Host "!! ไม่ได้ตั้ง HF_TOKEN -- จะโดนจำกัดความเร็ว ดู guides/02-hf-token.md"
}
# ไม่เรียก hf auth login -- huggingface_hub อ่าน $env:HF_TOKEN เองอยู่แล้ว
# และการไม่เขียน token ลงดิสก์ก็ปลอดภัยกว่า

# ใช้ Python API ไม่ใช่คำสั่ง hf -- ตัว CLI ใช้ไม่ได้บน python ของ ComfyUI portable
# เพราะ embedded python ไม่มีโมดูล venv แต่ huggingface_hub.cli import มันตอนโหลด
# แล้วตายด้วย ModuleNotFoundError: No module named 'venv' ตั้งแต่ยังไม่ทันทำอะไร
$dlPy = Join-Path $env:TEMP "h3_dl.py"
@'
import sys
from huggingface_hub import hf_hub_download
repo, filename, target = sys.argv[1], sys.argv[2], sys.argv[3]
revision = sys.argv[4] if len(sys.argv) > 4 else None
p = hf_hub_download(repo, filename, local_dir=target, revision=revision)
print(p)
'@ | Set-Content -Path $dlPy -Encoding UTF8

function Get-Model($repo, $file, $dir, $rev = $null) {
    Write-Host ">> $file"
    if ($rev) { & $Python $dlPy $repo $file $dir $rev } else { & $Python $dlPy $repo $file $dir }
    if ($LASTEXITCODE -ne 0) { Write-Host "โหลด $file ไม่สำเร็จ"; exit 1 }
}

# --- 3. โมเดล รวม 45 GB --------------------------------------------------------
# ชุดเดียวกับที่เจนงานจริง (workflow\h3_singularity_rent*_api.json):
# Singularity ref2va int8 + ref2v_turbo_4step LoRA, 0.4 MP 8 step -> ขยาย latent เป็น 1.0 MP -> อีก 2 step
foreach ($sub in @("diffusion_models", "text_encoders", "vae", "loras",
                   "latent_upscale_models")) {
    New-Item -ItemType Directory -Force (Join-Path $Comfy "models\$sub") | Out-Null
}
Get-Model "WarmBloodAban/Minimax-h3_Singularity" "Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors" (Join-Path $Comfy "models\diffusion_models")
Get-Model "Comfy-Org/MiniMax-H3" "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" (Join-Path $Comfy "models")
Get-Model "Comfy-Org/MiniMax-H3" "vae/minimax_h3_video_vae_fp16.safetensors" (Join-Path $Comfy "models")
Get-Model "Comfy-Org/MiniMax-H3" "vae/minimax_h3_audio_vae_fp32.safetensors" (Join-Path $Comfy "models")
Get-Model "Comfy-Org/MiniMax-H3" "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" (Join-Path $Comfy "models")
# ล็อก revision ไว้: 17 ก.ย. 2569 เจ้าของรีโปย้ายไฟล์ไปโฟลเดอร์ใหม่และเปลี่ยนชื่อ ชื่อเดิมบน main หายไป
Get-Model "LBH-123-AI/Minimax_h3_latent_Upscaler" "minimax_h3_latent_upscaler_3d_bf16.safetensors" (Join-Path $Comfy "models\latent_upscale_models") "13ccf95d85d120bdbc92c05b1247a6e147bf54bf"

# --- 4. custom node ล็อกคอมมิตไว้ --------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "!! ไม่พบ git -- ลงจาก https://git-scm.com/download/win แล้วรันใหม่"
    exit 1
}
function Get-Node($url, $name, $commit) {
    $d = Join-Path $Comfy "custom_nodes\$name"
    if (-not (Test-Path $d)) { & git clone $url $d }
    & git -C $d fetch --depth 50 origin 2>$null | Out-Null
    & git -C $d checkout -q $commit 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "!! $name : ไม่มีคอมมิต $commit ใช้ HEAD แทน" }
    $req = Join-Path $d "requirements.txt"
    if (Test-Path $req) { & $Python -m pip install -q -r $req }
}
# MiniMaxH3MemoryEfficientSageAttentionPatch (โหนด 213)
Get-Node "https://github.com/kijai/ComfyUI-KJNodes"             "comfyui-kjnodes"          "dcfcb5d"
# MinimaxH3LatentUpscaler3D (โหนด 503) ขยาย latent ภาพระหว่างสองรอบ
Get-Node "https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler" "Comfyui_Minimax_h3_latent_Upscaler" "64fc9d4"
# H3ReferenceAudio (โหนด 215 216) ตัด ref เสียงให้เหลือ 0.6 วิ
Get-Node "https://github.com/jlucasmcrell/ComfyUI-H3-Multishot" "ComfyUI-H3-Multishot" "d7d1977"
# SolAttnMiniMax (โหนด 217) -- โหนดไฟล์เดียวของ Singularity ล็อกคอมมิตไว้ (ต้องมี comfy_kitchen ที่มี sol_attn)
$solDir = Join-Path $Comfy "custom_nodes\ComfyUI-SolAttnMiniMax"
if (-not (Test-Path (Join-Path $solDir "__init__.py"))) {
    New-Item -ItemType Directory -Force $solDir | Out-Null
    try {
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/T8mars/comfyui-minimax-h3-audio-T8/8b379b42bde00a315aee146c8d4285e8caa80a5b/sol_attn_minimax_v2.py" `
            -OutFile (Join-Path $solDir "__init__.py") -ErrorAction Stop
    } catch {
        Remove-Item $solDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "!! โหลด SolAttnMiniMax ไม่สำเร็จ -- workflow จะรันไม่ได้"
    }
}
& $Python -c "import comfy_kitchen as c; assert c.sol_attn_is_available()" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "!! comfy_kitchen ไม่มี sol_attn -- อัปเดต ComfyUI ก่อนเจน" }

# --- 5. เปิดใหม่ -------------------------------------------------------------
# ComfyUI อ่านรายชื่อโมเดลครั้งเดียวตอนบูต โปรเซสที่เปิดค้างอยู่ก่อนขั้นที่ 3
# จะมองไม่เห็นโมเดลที่เพิ่งโหลดมา
Write-Host ">> เปิด ComfyUI ใหม่"
Get-Process python -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path -eq $Python } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
$root = Split-Path -Parent $Comfy
$log  = Join-Path $root "comfy.log"
Start-Process -FilePath $Python `
    -ArgumentList "-s", (Join-Path $Comfy "main.py"), "--windows-standalone-build",
                  "--listen", "127.0.0.1", "--port", "$Port" `
    -WorkingDirectory $root -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
    -WindowStyle Hidden
$ok = $false
foreach ($i in 1..40) {
    Start-Sleep -Seconds 3
    try { Invoke-RestMethod "http://127.0.0.1:$Port/system_stats" -TimeoutSec 3 | Out-Null; $ok = $true; break } catch {}
}
if (-not $ok) {
    Write-Host "!! ComfyUI ไม่กลับมาภายใน 2 นาที -- ดูสาเหตุที่ $log"
    exit 1
}

# --- 6. จดไว้ ----------------------------------------------------------------
$d = if (Test-Path $mj) { Get-Content $mj -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$d | Add-Member -NotePropertyName comfy_root -NotePropertyValue $Comfy -Force
$d | Add-Member -NotePropertyName comfy_api  -NotePropertyValue "http://127.0.0.1:$Port" -Force
$d | Add-Member -NotePropertyName python     -NotePropertyValue $Python -Force
$d | ConvertTo-Json -Depth 10 | Set-Content $mj

@"

ready

เจนคลิปได้เลย ครั้งแรกแนะนำความยาว 8 หรือ 10 วินาที
เปิดหน้าเว็บได้ที่ http://127.0.0.1:$Port

ถ้าคลิปยาวขึ้นนิดเดียวแต่เวลาที่ใช้พุ่งขึ้นเท่าตัว แปลว่าเลยเพดานของการ์ดแล้ว
ให้ถอยกลับมาความยาวก่อนหน้า -- ไม่มี error ใดๆ บอก มันแค่ช้าลงเฉยๆ
"@
