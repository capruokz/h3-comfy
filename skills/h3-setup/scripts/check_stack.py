#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ตรวจว่าเครื่องที่เช่ามาพร้อมใช้งานจริงมั้ย ก่อนจ่ายค่าโหลดไฟล์ 38 GB

    python3 check_stack.py

**ชุดนี้รองรับเฉพาะการ์ด NVIDIA ตระกูล Blackwell (RTX 50 ซีรีส์) ขึ้นไป**
เป็นการจำกัดขอบเขตโดยตั้งใจ ไม่ใช่ข้อจำกัดทางเทคนิค: ทุกตัวเลขในเอกสารชุดนี้
วัดมาจากการ์ดตระกูลนี้ จึงกล้ารับประกันเฉพาะตระกูลนี้ การ์ดรุ่นเก่ากว่ารันได้เหมือนกัน
แต่เราไม่มีตัวเลขยืนยัน และไม่อยากให้ใครเอาเลขที่วัดจากการ์ดคนละตระกูลไปวางแผนงาน

**ทำไมต้องตรวจก่อนโหลด** — เครื่องที่ตั้งค่ามาผิดจะยังเจนคลิปออกมาได้ปกติ ไม่มี error
อะไรเลย แค่ช้ากว่าที่ควรหลายเท่า เคยวัดได้ว่าช้ากว่าที่ควร 5.2 เท่าจากสองสาเหตุรวมกัน
คลิปก็ออกมาสวยดี แค่จ่ายค่าเช่าเพิ่มสามเท่าโดยไม่รู้ตัว
"""
import importlib.metadata as md
import sys

sys.stdout.reconfigure(encoding="utf-8")

BLACKWELL = (10, 0)          # sm_100 = B200 · sm_120 = RTX 50 ซีรีส์ · ต่ำกว่านี้คือรุ่นเก่ากว่า
WANT_CUDA = (13, 0)          # cu128 วัดได้ว่าช้ากว่า 1.84 เท่าบน sm_120
WANT_SAGE = (2, 2)           # 1.x ไม่มี path ของ Blackwell เลย ใส่แล้วแอบช้า

OLDER = {                    # เอาไว้บอกชื่อรุ่นตอนที่การ์ดเก่าเกินไป จะได้ไม่ต้องเดาเอง
    (9, 0): "Hopper (H100 / H200)",
    (8, 9): "Ada (RTX 4090 / 4080 / L40S)",
    (8, 6): "Ampere (RTX 3090 / 3080 / A10)",
    (8, 0): "Ampere ศูนย์ข้อมูล (A100)",
    (7, 5): "Turing (RTX 2080 Ti / T4)",
}

rows, fatal = [], 0


def row(name, got, level, fix=""):
    global fatal
    rows.append((level, name, got, fix))
    if level == "FAIL":
        fatal += 1


def name_of(cap):
    for sm in sorted(OLDER, reverse=True):
        if cap >= sm:
            return OLDER[sm]
    return "รุ่นเก่ากว่าที่รู้จัก"


too_old = False
cap = None

try:
    import torch
except Exception as e:                                             # noqa: BLE001
    row("torch", f"นำเข้าไม่ได้: {e}", "FAIL",
        "เครื่องนี้ยังไม่มี PyTorch — ตอนเช่าให้เลือกเทมเพลตที่มี ComfyUI")
    torch = None

if torch is not None:
    cu = tuple(int(x) for x in (torch.version.cuda or "0.0").split(".")[:2])
    row("torch", f"{torch.__version__} (CUDA {'.'.join(map(str, cu))})", "PASS")

    if not torch.cuda.is_available():
        row("การ์ดจอ", "มองไม่เห็นการ์ด", "FAIL",
            "เครื่องนี้ไม่มี GPU หรือไดรเวอร์ไม่ทำงาน — กลับไปหน้า Instances กด Destroy "
            "แล้วเลือกเครื่องใหม่")
    else:
        cap = torch.cuda.get_device_capability(0)
        gpu = torch.cuda.get_device_name(0)

        if cap < BLACKWELL:
            too_old = True
            row("การ์ดจอ", f"{gpu}  (sm_{cap[0]}{cap[1]} · {name_of(cap)})", "FAIL",
                "ชุดนี้รองรับเฉพาะ RTX 50 ซีรีส์ขึ้นไป — ดูวิธีเลือกเครื่องใหม่ข้างล่าง")
        else:
            row("การ์ดจอ", f"{gpu}  (sm_{cap[0]}{cap[1]} · Blackwell)", "PASS")

            # torch build มาสำหรับสถาปัตยกรรมชุดหนึ่ง ถ้าการ์ดใบนี้ไม่อยู่ในชุดนั้น
            # มันจะช้ามากหรือพังไปเลย เช็คตรงๆ ดีกว่าเดาจากเลขเวอร์ชัน
            mine = f"sm_{cap[0]}{cap[1]}"
            arch = torch.cuda.get_arch_list()
            has = any(a.replace("compute_", "sm_") == mine for a in arch)
            row("torch รองรับการ์ดใบนี้มั้ย", f"{mine} {'อยู่ใน' if has else 'ไม่อยู่ใน'} {arch}",
                "PASS" if has else "FAIL",
                "PyTorch ในเครื่องนี้ build มาโดยไม่รองรับการ์ดใบนี้ — รัน  bash setup.sh --fix")

            row("CUDA เวอร์ชัน", f"cu{cu[0]}{cu[1]}", "PASS" if cu >= WANT_CUDA else "FAIL",
                "cu128 บนการ์ด Blackwell วัดได้ว่าช้ากว่า cu130 อยู่ 1.84 เท่า — "
                "รัน  bash setup.sh --fix")

            # VRAM ไม่ใช่เกณฑ์ผ่าน/ไม่ผ่าน แต่กำหนดว่าคลิปยาวได้แค่ไหน
            vram = torch.cuda.get_device_properties(0).total_memory / 2**30
            if vram >= 30:
                note = "เหลือเฟือ คลิปยาวได้มากกว่าที่คู่มือเขียนไว้"
            elif vram >= 23:
                note = "สบาย เป็นช่วงที่คุ้มค่าเช่าที่สุด"
            elif vram >= 15:
                note = "ใช้ได้ เป็นการ์ดที่ใช้เขียนคู่มือชุดนี้ทั้งหมด"
            else:
                note = "น้อย ต้องเจนคลิปสั้นและลดความละเอียด"
            row("VRAM", f"{vram:.0f} GB — {note}", "PASS" if vram >= 15 else "WARN",
                "" if vram >= 15 else "ต่ำกว่า 15 GB อาจเจนไม่ผ่าน ลองได้แต่เตรียมใจ")

# ตัวเร่งความเร็ว — เช็คเฉพาะเมื่อการ์ดอยู่ในขอบเขตที่รองรับ ไม่งั้นเป็นเสียงรบกวน
if not too_old:
    try:
        v = md.version("sageattention")
        maj = tuple(int(x) for x in v.split("+")[0].split(".")[:2])
        row("SageAttention", v, "PASS" if maj >= WANT_SAGE else "FAIL",
            "รุ่น 1.x ไม่มี path ของ Blackwell เลย --use-sage-attention จะแอบวิ่งทางเก่า "
            "และช้าลงโดยไม่ฟ้อง — รัน  bash setup.sh --fix")
    except Exception:
        row("SageAttention", "ยังไม่ได้ติดตั้ง", "FAIL",
            "รัน  bash setup.sh --fix  (ใช้เวลา build ราว 5-10 นาที)")

    for pkg in ("triton", "triton-windows"):
        try:
            row("triton", f"{pkg} {md.version(pkg)}", "PASS")
            break
        except Exception:
            continue
    else:
        row("triton", "ยังไม่ได้ติดตั้ง", "WARN",
            "pip install triton — ถ้าไม่ลง ให้ลบโหนด SolAttnPatch (214) ออกจาก workflow")

w = max(len(r[1]) for r in rows)
mark = {"PASS": "ผ่าน", "WARN": "ควรรู้", "FAIL": "ต้องแก้"}
print()
for level, name, got, fix in rows:
    print(f"  [{mark[level]}] {name:<{w}}  {got}")
    if fix and level != "PASS":
        print(f"          -> {fix}")
print()

if too_old:
    print("การ์ดใบนี้เก่ากว่าที่ชุดนี้รองรับ")
    print()
    print("  ชุดนี้รองรับเฉพาะ NVIDIA ตระกูล Blackwell ขึ้นไป ได้แก่")
    print("    RTX 5060 Ti · 5070 · 5070 Ti · 5080 · 5090 · RTX PRO 6000 Blackwell · B200")
    print()
    print("  ทำยังไงต่อ:")
    print("    1. กลับไปหน้า Instances บน vast.ai แล้วกด Destroy เครื่องนี้")
    print("       (ยังไม่ได้โหลดไฟล์ 38 GB จึงยังไม่เสียค่าเน็ตก้อนใหญ่)")
    print("    2. ที่หน้า Search พิมพ์ค้นว่า  5090  หรือ  5080  หรือ  5060")
    print("    3. เช่าใหม่แล้วเริ่มจากคู่มือ 3 ขั้นที่ 1 อีกครั้ง")
    print()
    print("  การ์ดรุ่นเก่ากว่านี้รันโมเดลนี้ได้เหมือนกัน แต่เราไม่มีตัวเลขที่วัดเองยืนยัน")
    print("  จึงไม่รับประกัน ถ้าอยากลองเองจริงๆ ใช้  FORCE=1 bash setup.sh")
    sys.exit(1)

if fatal:
    print(f"มี {fatal} ข้อที่ต้องแก้ก่อน — ถ้าปล่อยไว้จะช้ากว่าที่ควรมากโดยไม่มีอะไรฟ้อง")
    print("วิธีแก้:  bash setup.sh --fix")
    print("ถ้ารู้ตัวว่ากำลังทำอะไรและอยากข้าม:  FORCE=1 bash setup.sh")
    sys.exit(1)

print("เครื่องนี้พร้อมแล้ว ไปขั้นต่อไปได้")
