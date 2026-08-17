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

# --- 2. เร่งความเร็วดาวน์โหลด ------------------------------------------------
# HF ย้ายมาใช้ Xet แล้ว โหมดหลายคอนเนกชันปิดไว้เป็นค่าเริ่มต้น ซึ่งกับ 38 GB
# คือความต่างระหว่างไม่กี่นาทีกับเป็นชั่วโมง
& $Python -m pip install -q -U "huggingface_hub[hf_xet]"
$env:HF_XET_HIGH_PERFORMANCE = "1"
$env:HF_HUB_DISABLE_XET = "0"
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
p = hf_hub_download(repo, filename, local_dir=target)
print(p)
'@ | Set-Content -Path $dlPy -Encoding UTF8

function Get-Model($repo, $file, $dir) {
    Write-Host ">> $file"
    & $Python $dlPy $repo $file $dir
    if ($LASTEXITCODE -ne 0) { Write-Host "โหลด $file ไม่สำเร็จ"; exit 1 }
}

# --- 3. โมเดล รวม 38.0 GB ----------------------------------------------------
# fl2va ไม่ใช่ ref2va -- อยู่รีโปเดียวกัน ต่างกันคำเดียว แต่ workflow เรียก fl2va
foreach ($sub in @("diffusion_models", "text_encoders", "vae", "loras")) {
    New-Item -ItemType Directory -Force (Join-Path $Comfy "models\$sub") | Out-Null
}
Get-Model "tsolful/Minimax_H3_INT4MixedConvRot" "minimax_h3_fl2va_pruned_INT4Q.safetensors" (Join-Path $Comfy "models\diffusion_models")
Get-Model "Comfy-Org/MiniMax-H3" "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" (Join-Path $Comfy "models")
Get-Model "Comfy-Org/MiniMax-H3" "vae/minimax_h3_video_vae_fp16.safetensors" (Join-Path $Comfy "models")
Get-Model "Comfy-Org/MiniMax-H3" "vae/minimax_h3_audio_vae_fp32.safetensors" (Join-Path $Comfy "models")
Get-Model "larryvrh/MiniMax-H3-Turbo-Lora" "minimax_h3_turbo_v4_step600_ema.safetensors" (Join-Path $Comfy "models\loras")

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
Get-Node "https://github.com/Larryvrh/ComfyUI-MiniMax-H3-Turbo" "ComfyUI-MiniMax-H3-Turbo" "55fee86"
Get-Node "https://github.com/kijai/ComfyUI-KJNodes"             "comfyui-kjnodes"          "dcfcb5d"
Get-Node "https://github.com/kijai/ComfyUI-SolAttn_triton"      "ComfyUI-SolAttn_triton"   "1b8dece"

# --- 5. แพตช์โหนด turbo ------------------------------------------------------
# โหนดต้นฉบับตายทันทีที่ต่อ <Audio N> เดี่ยวๆ คลิปที่มีบทพูดจึงรันไม่ได้เลยถ้าไม่แพตช์
# ของเดิมเก็บไว้ที่ __init__.py.stock -- ดู NOTICE ที่รากรีโป
$node = Join-Path $Comfy "custom_nodes\ComfyUI-MiniMax-H3-Turbo"
$stock = Join-Path $node "__init__.py.stock"
if (-not (Test-Path $stock)) { Copy-Item (Join-Path $node "__init__.py") $stock }
Copy-Item (Join-Path $HERE "h3turbo_patched__init__.py") (Join-Path $node "__init__.py") -Force
Write-Host "แพตช์ ref_audio แล้ว (ของเดิมเก็บไว้ที่ __init__.py.stock)"

# --- 6. เปิดใหม่ -------------------------------------------------------------
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

# --- 7. จดไว้ ----------------------------------------------------------------
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
