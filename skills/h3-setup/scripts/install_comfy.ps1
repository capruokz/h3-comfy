# ติดตั้ง ComfyUI portable ลงเครื่อง Windows ที่ยังไม่มี แล้วเปิดให้พร้อมใช้
#
#   powershell -ExecutionPolicy Bypass -File install_comfy.ps1
#   powershell -ExecutionPolicy Bypass -File install_comfy.ps1 -Dest D:\AI
#
# รัน precheck.py ก่อนเสมอ ตัวนี้ไม่ตรวจสเปคซ้ำ
#
# ใช้ tar ที่ติดมากับ Windows แตกไฟล์ .7z -- ตรวจแล้วว่า bsdtar ใน Windows 11
# แตก 7z ได้จริง ผู้ใช้จึงไม่ต้องไปลง 7-Zip ก่อน
[CmdletBinding()]
param(
    [string]$Dest = "C:\ComfyUI",
    [int]$Port = 8188
)
$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$REPO = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$root = Join-Path $Dest "ComfyUI_windows_portable"

function Test-ComfyAlive {
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$Port/system_stats" -TimeoutSec 3 | Out-Null
        return $true
    } catch { return $false }
}

# --- 0. เครื่องนี้ใช่มั้ย -----------------------------------------------------
if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
    Write-Host "ไม่พบ nvidia-smi -- เครื่องนี้ไม่มีการ์ด NVIDIA หรือยังไม่ได้ลงไดรเวอร์"
    Write-Host "รัน precheck.py เพื่อดูรายละเอียด"
    exit 1
}
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Write-Host "ไม่พบคำสั่ง tar -- Windows รุ่นนี้เก่าเกินไป"
    Write-Host "ทางออก: ลง 7-Zip แล้วแตกไฟล์เอง หรืออัปเดต Windows"
    exit 1
}

# --- 1. มีอยู่แล้วมั้ย --------------------------------------------------------
if (Test-Path (Join-Path $root "ComfyUI\main.py")) {
    Write-Host "มี ComfyUI อยู่แล้วที่ $root -- ข้ามการติดตั้ง"
} else {
    # --- 2. หาไฟล์รุ่นล่าสุด --------------------------------------------------
    # ถามหน้า release ว่าไฟล์ชื่ออะไร แทนที่จะฝังชื่อไว้ เพราะชื่อกับเวอร์ชันเปลี่ยนได้
    Write-Host ">> ถามหารุ่นล่าสุดของ ComfyUI"
    $rel = Invoke-RestMethod "https://api.github.com/repos/comfyanonymous/ComfyUI/releases/latest" `
        -Headers @{ "User-Agent" = "h3-comfy" }
    $asset = $rel.assets | Where-Object { $_.name -eq "ComfyUI_windows_portable_nvidia.7z" } | Select-Object -First 1
    if (-not $asset) {
        $asset = $rel.assets | Where-Object { $_.name -like "*windows_portable_nvidia*.7z" } | Select-Object -First 1
    }
    if (-not $asset) {
        Write-Host "หาไฟล์ portable สำหรับ NVIDIA ในรุ่น $($rel.tag_name) ไม่เจอ"
        Write-Host "โหลดเองได้ที่ https://github.com/comfyanonymous/ComfyUI/releases"
        exit 1
    }
    $sizeMB = [math]::Round($asset.size / 1MB)
    Write-Host "   รุ่น $($rel.tag_name) : $($asset.name)  ($sizeMB MB)"

    # --- 3. โหลด -------------------------------------------------------------
    New-Item -ItemType Directory -Force $Dest | Out-Null
    $tmp = Join-Path $env:TEMP $asset.name
    if ((Test-Path $tmp) -and ((Get-Item $tmp).Length -eq $asset.size)) {
        Write-Host ">> มีไฟล์ที่โหลดไว้แล้วครบขนาด ใช้ตัวเดิม"
    } else {
        Write-Host ">> โหลด $sizeMB MB (ใช้เวลาสักพักตามความเร็วเน็ต)"
        # curl.exe ติดมากับ Windows 10 ขึ้นไป และเร็วกว่า Invoke-WebRequest มากกับไฟล์ใหญ่
        & curl.exe -L --fail --progress-bar -o $tmp $asset.browser_download_url
        if ($LASTEXITCODE -ne 0) { Write-Host "โหลดไม่สำเร็จ"; exit 1 }
    }

    # --- 4. แตกไฟล์ ----------------------------------------------------------
    Write-Host ">> แตกไฟล์ไปที่ $Dest"
    & tar -xf $tmp -C $Dest
    if ($LASTEXITCODE -ne 0) { Write-Host "แตกไฟล์ไม่สำเร็จ"; exit 1 }
    if (-not (Test-Path (Join-Path $root "ComfyUI\main.py"))) {
        Write-Host "แตกไฟล์แล้วแต่ไม่เจอ ComfyUI\main.py ใน $root -- โครงไฟล์อาจเปลี่ยนไป"
        exit 1
    }
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

$comfy = Join-Path $root "ComfyUI"
$py    = Join-Path $root "python_embeded\python.exe"
if (-not (Test-Path $py)) { Write-Host "ไม่เจอ python_embeded ที่ $py"; exit 1 }

# --- 5. เปิด ------------------------------------------------------------------
if (Test-ComfyAlive) {
    Write-Host ">> มี ComfyUI ตอบอยู่ที่พอร์ต $Port แล้ว"
} else {
    Write-Host ">> เปิด ComfyUI ที่พอร์ต $Port"
    $log = Join-Path $root "comfy.log"
    Start-Process -FilePath $py `
        -ArgumentList "-s", (Join-Path $comfy "main.py"), "--windows-standalone-build",
                      "--listen", "127.0.0.1", "--port", "$Port" `
        -WorkingDirectory $root -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
        -WindowStyle Hidden
    Write-Host "   log อยู่ที่ $log"
    $ok = $false
    foreach ($i in 1..60) {
        Start-Sleep -Seconds 3
        if (Test-ComfyAlive) { $ok = $true; break }
    }
    if (-not $ok) {
        Write-Host "!! ComfyUI ไม่ตอบภายใน 3 นาที -- ดูสาเหตุที่ $log"
        if (Test-Path "$log.err") { Get-Content "$log.err" -Tail 20 }
        exit 1
    }
}

# --- 6. จดไว้ให้สคริปต์ตัวอื่นใช้ --------------------------------------------
$mj = Join-Path $REPO "machine.json"
$d = if (Test-Path $mj) { Get-Content $mj -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$d | Add-Member -NotePropertyName comfy_root -NotePropertyValue $comfy -Force
$d | Add-Member -NotePropertyName comfy_api  -NotePropertyValue "http://127.0.0.1:$Port" -Force
$d | Add-Member -NotePropertyName python     -NotePropertyValue $py -Force
$d | ConvertTo-Json -Depth 10 | Set-Content $mj
Write-Host "จด comfy_root ลง $mj"

@"

ComfyUI พร้อมแล้วที่ $comfy  (พอร์ต $Port)
เปิดหน้าเว็บได้ที่ http://127.0.0.1:$Port

ขั้นต่อไป -- ลงตัวโมเดล H3:
  `$env:HF_TOKEN = "hf_xxxx"
  powershell -ExecutionPolicy Bypass -File setup.ps1
"@
