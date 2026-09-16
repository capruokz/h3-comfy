#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ตรวจว่าเครื่องนี้ติดตั้ง ComfyUI + H3 ได้มั้ย — รันได้บนเครื่องที่ยังไม่มีอะไรเลย

    python3 precheck.py
    python3 precheck.py --target /workspace     # ระบุที่ที่จะติดตั้ง

**ต่างจาก check_stack.py ตรงไหน**

check_stack.py ตรวจว่า *เครื่องที่มีของครบแล้ว* ตั้งค่าถูกมั้ย มันต้อง import torch ได้ก่อน
ตัวนี้ตรวจ *เครื่องเปล่า* ว่าคุ้มที่จะติดตั้งมั้ย จึงใช้แต่ของที่มีมากับ Python
กับคำสั่ง nvidia-smi ที่ติดมากับไดรเวอร์ ไม่ต้องลงอะไรก่อนสักอย่าง

ลำดับที่ถูกคือ  precheck.py -> ติดตั้ง -> check_stack.py
"""
import argparse
import ctypes
import platform
import shutil
import subprocess
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

NEED_DISK_GB = 100          # โมเดล 38 GB + ComfyUI ~5 GB + ที่เหลือไว้เก็บคลิป
NEED_VRAM_GB = 15
BLACKWELL = (10, 0)         # compute capability ของ RTX 50 ซีรีส์ = 12.0 · B200 = 10.0
ADA = (8, 9)                # RTX 40 ซีรีส์ ใช้ได้แบบทดลอง: int8 ได้ แต่ NVFP4 ต้องคลายตอนคำนวณ

rows = []
stop = None                 # เหตุผลที่ติดตั้งไม่ได้ ถ้ามี


def row(name, value, level, note=""):
    """level: ok / warn / bad"""
    rows.append((level, name, value, note))


def ram_gb():
    s = platform.system()
    try:
        if s == "Linux":
            for line in Path("/proc/meminfo").read_text().splitlines():
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) / 2**20
        elif s == "Windows":
            class M(ctypes.Structure):
                _fields_ = [("l", ctypes.c_ulong), ("mL", ctypes.c_ulong),
                            ("tp", ctypes.c_ulonglong), ("ap", ctypes.c_ulonglong),
                            ("tpf", ctypes.c_ulonglong), ("apf", ctypes.c_ulonglong),
                            ("tv", ctypes.c_ulonglong), ("av", ctypes.c_ulonglong),
                            ("ae", ctypes.c_ulonglong)]
            m = M(); m.l = ctypes.sizeof(M)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m))
            return m.tp / 2**30
        elif s == "Darwin":
            o = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True)
            return int(o.stdout.strip()) / 2**30
    except Exception:
        pass
    return None


def smi(fields):
    """ถาม nvidia-smi ตรงๆ ไม่ต้องมี torch — คืน list ของแถว หรือ None ถ้าไม่มีการ์ด"""
    try:
        o = subprocess.run(["nvidia-smi", f"--query-gpu={fields}",
                            "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=15)
        if o.returncode != 0 or not o.stdout.strip():
            return None
        return [[c.strip() for c in line.split(",")] for line in o.stdout.strip().splitlines()]
    except Exception:
        return None


def find_comfy():
    """หา ComfyUI ที่ติดตั้งอยู่แล้ว ถ้ามีจะได้ไม่ลงซ้ำ"""
    cands = [Path("/workspace/ComfyUI"), Path("/opt/workspace-internal/ComfyUI"),
             Path.home() / "ComfyUI", Path("C:/ComfyUI_windows_portable/ComfyUI"),
             Path("B:/ComfyUI_windows_portable/ComfyUI")]
    return next((p for p in cands if (p / "main.py").exists()), None)


def main():
    global stop
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", help="โฟลเดอร์ที่จะติดตั้ง (ใช้เช็คพื้นที่ว่าง)")
    a = ap.parse_args()

    # ---- ระบบ ----
    osname = platform.system()
    row("ระบบปฏิบัติการ", f"{osname} {platform.release()}",
        "ok" if osname in ("Linux", "Windows") else "bad",
        "" if osname in ("Linux", "Windows") else "H3 ต้องใช้การ์ด NVIDIA ซึ่ง macOS ไม่มี")
    if osname == "Darwin":
        stop = "mac"

    py = sys.version_info
    row("Python", f"{py.major}.{py.minor}.{py.micro}",
        "ok" if py >= (3, 10) else "bad",
        "" if py >= (3, 10) else "ComfyUI ต้องการ 3.10 ขึ้นไป")
    if py < (3, 10):
        stop = stop or "python"

    # ---- การ์ดจอ ----
    g = smi("name,compute_cap,memory.total,driver_version")
    if not g:
        row("การ์ดจอ", "ไม่พบการ์ด NVIDIA", "bad",
            "เครื่องนี้ไม่มีการ์ด NVIDIA หรือยังไม่ได้ลงไดรเวอร์")
        stop = stop or "nogpu"
    else:
        name, cap_s, vram_mib, drv = g[0]
        try:
            cap = tuple(int(x) for x in cap_s.split(".")[:2])
        except ValueError:
            cap = (0, 0)
        vram = float(vram_mib) / 1024
        blackwell = cap >= BLACKWELL
        ada = ADA <= cap < BLACKWELL

        if blackwell:
            row("การ์ดจอ", f"{name}  (compute {cap_s})", "ok")
        elif ada:
            row("การ์ดจอ", f"{name}  (compute {cap_s})", "warn",
                "RTX 40 ซีรีส์ ใช้ได้แบบทดลอง ตัวอ่านพรอมป์ท NVFP4 จะคลายตอนคำนวณ (ช้าลงเล็กน้อย)")
        else:
            row("การ์ดจอ", f"{name}  (compute {cap_s})", "bad",
                "ชุดนี้รองรับเฉพาะ RTX 50 ซีรีส์ขึ้นไป (RTX 40 ซีรีส์แบบทดลอง)")
            stop = stop or "oldgpu"

        row("ไดรเวอร์", drv, "ok")

        if vram >= 30:
            n = "เหลือเฟือ คลิปยาวได้สบาย"
        elif vram >= 23:
            n = "สบาย เป็นช่วงที่คุ้มที่สุด"
        elif vram >= NEED_VRAM_GB:
            n = "ใช้ได้ เป็นระดับเดียวกับการ์ดที่ใช้เขียนคู่มือนี้"
        else:
            n = "น้อยเกินไป อาจเจนไม่ผ่าน"
        row("VRAM", f"{vram:.0f} GB", "ok" if vram >= NEED_VRAM_GB else "warn", n)

    # ---- แรม / ซีพียู ----
    r = ram_gb()
    if r:
        row("RAM", f"{r:.0f} GB", "ok" if r >= 16 else "warn",
            "" if r >= 16 else "น้อยกว่า 16 GB อาจไม่พอตอนโหลดโมเดล")

    # ---- พื้นที่ ----
    target = Path(a.target) if a.target else Path.cwd()
    probe = target
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    try:
        free = shutil.disk_usage(probe).free / 2**30
        ok = free >= NEED_DISK_GB
        row("พื้นที่ว่าง", f"{free:.0f} GB ที่ {probe}", "ok" if ok else "bad",
            "" if ok else f"ต้องการอย่างน้อย {NEED_DISK_GB} GB — ต้องเคลียร์อีก {NEED_DISK_GB - free:.0f} GB")
        if not ok:
            stop = stop or "disk"
    except Exception:
        row("พื้นที่ว่าง", "ตรวจไม่ได้", "warn")

    # ---- ComfyUI มีอยู่แล้วมั้ย ----
    c = find_comfy()
    row("ComfyUI", str(c) if c else "ยังไม่มี", "ok",
        "ใช้ตัวนี้ได้เลย ข้ามขั้นติดตั้ง ComfyUI" if c else "ต้องติดตั้งก่อน")

    # ---- สรุป ----
    mark = {"ok": "ผ่าน", "warn": "ควรรู้", "bad": "ไม่ผ่าน"}
    w = max(len(x[1]) for x in rows)
    print()
    for level, name, value, note in rows:
        print(f"  [{mark[level]}] {name:<{w}}  {value}")
        if note:
            print(f"          {note}")
    print()

    if stop:
        msg = {
            "mac": "เครื่อง Mac ใช้ไม่ได้ เพราะ H3 ต้องการการ์ด NVIDIA",
            "nogpu": "เครื่องนี้ไม่มีการ์ด NVIDIA ที่ใช้งานได้",
            "oldgpu": "การ์ดใบนี้เก่ากว่าที่ชุดนี้รองรับ (ต้องเป็น RTX 50 ซีรีส์ขึ้นไป)",
            "disk": "พื้นที่ว่างไม่พอ",
            "python": "Python เก่าเกินไป",
        }[stop]
        print(f"ติดตั้งบนเครื่องนี้ไม่ได้ — {msg}")
        print()
        if stop in ("mac", "nogpu", "oldgpu"):
            print("  ทางออก: เช่าเครื่องที่มีการ์ด RTX 50 ซีรีส์แทน ชั่วโมงละราว 20-40 บาท")
            print("  อ่าน guides/01-rent-vast.md")
        elif stop == "disk":
            print("  ทางออก: เคลียร์พื้นที่ก่อน หรือระบุไดรฟ์อื่นด้วย --target")
        sys.exit(1)

    print("เครื่องนี้ติดตั้งได้")
    print()
    if c:
        print(f"  มี ComfyUI อยู่แล้วที่ {c}")
        print("  ขั้นต่อไป:  export HF_TOKEN=hf_xxxx  แล้ว  bash setup.sh")
    else:
        print("  ยังไม่มี ComfyUI ขั้นต่อไป:  bash install_comfy.sh")
        print("  แล้วค่อย  export HF_TOKEN=hf_xxxx  และ  bash setup.sh")


if __name__ == "__main__":
    main()
