#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""หาว่าการ์ดใบนี้เจนคลิปได้ยาวสุดกี่เฟรม ก่อนที่มันจะเริ่มล้นออก RAM

    python3 find_ceiling.py                  # ไล่ทีละขั้นจนเจอเพดาน
    python3 find_ceiling.py --mp 0.6         # ทดสอบที่ความละเอียดอื่น

ทำไมต้องมีสคริปต์นี้:

คู่มือชุดนี้เขียนมาจากการ์ด 16 GB ใบหนึ่ง ซึ่งเจนได้ถึงราว 294 เฟรมแล้วพัง
ที่ 362 เฟรม -- ช้าลง 2.6 เท่าทั้งที่ยังเรนเดอร์ออกมาได้ **ตัวเลขนั้นเป็นของการ์ดใบนั้น
ไม่ใช่ของคุณ** การ์ด 24 GB จะไปได้ไกลกว่า การ์ด 12 GB จะพังก่อน ถ้าเชื่อตัวเลขในคู่มือ
คุณจะตัดคลิปสั้นเกินจำเป็น หรือไม่ก็เจอหน้าผาโดยไม่รู้ว่าเกิดอะไรขึ้น

อาการเวลาล้นมันไม่ได้ error มันแค่ช้าลงเฉยๆ วิธีจับคือดู **กำลังไฟ**:
GPU ที่ทำงานจริงจะกินไฟใกล้ค่าสูงสุดของมัน ส่วน GPU ที่กำลังรูดข้อมูลไปกลับกับ RAM
จะแสดง util 100% แต่กินไฟแค่เศษเสี้ยว -- ที่วัดได้คือ 48 W บนการ์ดที่กินได้ 180 W

หมายเหตุ: /system_stats ของ ComfyUI บอกความจริงไม่หมด มันเห็นแค่หน่วยความจำที่ torch
จองไว้ ไม่เห็นส่วนที่ไดรเวอร์ดันออกไป RAM สคริปต์นี้จึงอ่านจาก nvidia-smi แทน
"""
import argparse
import json
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
WF = REPO / "workflow" / "h3_ref2video_api.json"
OUT = REPO / "machine.json"

PROMPT = ("detailed_description:\n"
          "A single candle standing on a dark wooden table in an empty room, its flame leaning "
          "slowly in a draught. Nobody is present and nobody speaks.\n\n"
          "non_diegetic_music:\nThere is no music at all in this video.\n")


def frames_for(dur):
    """ความยาวจริงที่ H3 เรนเดอร์ เมื่อสั่ง DUR = dur วินาที"""
    n = max(5, round(dur * 24))
    return n + (5 - n % 17) % 17


def smi():
    """คืน (กำลังไฟที่ใช้อยู่, กำลังไฟสูงสุด, VRAM ที่ใช้, VRAM ทั้งหมด) หน่วยเป็น W และ MiB"""
    q = "power.draw,power.limit,memory.used,memory.total"
    try:
        o = subprocess.run(["nvidia-smi", f"--query-gpu={q}", "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=10).stdout.strip().splitlines()[0]
        return [float(x) for x in o.split(",")]
    except Exception:
        return [0.0, 0.0, 0.0, 0.0]


class Watch(threading.Thread):
    """เฝ้ากำลังไฟระหว่างที่งานกำลังรัน แล้วเก็บค่ามัธยฐานไว้"""

    def __init__(self):
        super().__init__(daemon=True)
        self.samples, self.stop = [], False

    def run(self):
        while not self.stop:
            p, lim, used, total = smi()
            if p > 0:
                self.samples.append((p, lim, used, total))
            time.sleep(2)

    def result(self):
        if not self.samples:
            return None
        s = sorted(self.samples, key=lambda x: x[0])
        p, lim, used, total = s[len(s) // 2]
        return dict(watt=round(p), watt_limit=round(lim),
                    vram_used=round(used), vram_total=round(total),
                    watt_pct=round(p / lim * 100) if lim else 0)


def api(base, path, data=None, timeout=300):
    req = urllib.request.Request(base + path, data=data,
                                 headers={"Content-Type": "application/json"} if data else {})
    return urllib.request.urlopen(req, timeout=timeout).read()


def render(base, dur, mp, seed):
    wf = json.loads(WF.read_text(encoding="utf-8"))
    node = wf["137"]["inputs"]
    node["prompt"] = PROMPT
    for k in [k for k in node if k.startswith(("ref_images.", "ref_videos.",
                                               "ref_audios.", "ref_video_audios."))]:
        del node[k]
    wf["134"]["inputs"]["lora_name"] = "minimax_h3_turbo_v4_step600_ema.safetensors"
    wf["115"]["inputs"]["megapixels"] = mp
    wf["124"]["inputs"]["steps"] = 4
    wf["133"]["inputs"]["value"] = dur
    wf["129"]["inputs"]["noise_seed"] = seed
    wf["92"]["inputs"]["filename_prefix"] = f"ceiling/d{dur}"

    pid = json.loads(api(base, "/prompt", json.dumps(
        {"prompt": wf, "client_id": "find_ceiling"}).encode()))["prompt_id"]
    w = Watch(); w.start()
    t0 = time.time()
    while time.time() - t0 < 5400:
        h = json.loads(api(base, f"/history/{pid}", timeout=60))
        if h:
            w.stop = True
            ok = h[pid]["status"]["status_str"] == "success"
            return ok, time.time() - t0, w.result()
        time.sleep(4)
    w.stop = True
    return False, time.time() - t0, w.result()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default="http://127.0.0.1:8188")
    ap.add_argument("--mp", type=float, default=0.6)
    ap.add_argument("--start", type=int, default=6, help="เริ่มทดสอบที่กี่วินาที")
    ap.add_argument("--step", type=int, default=3)
    ap.add_argument("--max", type=int, default=21)
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")

    assert WF.exists(), f"ไม่เจอ workflow ที่ {WF}"
    try:
        urllib.request.urlopen(a.api + "/system_stats", timeout=5)
    except Exception:
        raise SystemExit(f"ComfyUI ไม่ตอบที่ {a.api} -- เปิดเซิร์ฟเวอร์ก่อน")

    print(f"ทดสอบที่ {a.mp} MP  ไล่จาก {a.start} ถึง {a.max} วินาที ทีละ {a.step}\n")
    print(f"{'วินาที':>6} {'เฟรม':>6} {'เวลา':>8} {'วิ/เฟรม':>9} {'ไฟ':>10} {'VRAM':>12}")
    rows, ceiling, base_rate = [], None, None
    for dur in range(a.start, a.max + 1, a.step):
        f = frames_for(dur)
        ok, secs, w = render(a.api, dur, a.mp, 4242 + dur)
        rate = secs / f
        if not ok:
            print(f"{dur:>6} {f:>6}  เจนไม่ผ่าน (น่าจะ OOM) -- เพดานอยู่ก่อนหน้านี้")
            break
        watt = f"{w['watt']}/{w['watt_limit']}W" if w else "?"
        vram = f"{w['vram_used']}/{w['vram_total']}" if w else "?"
        print(f"{dur:>6} {f:>6} {secs:>7.0f}s {rate:>8.2f} {watt:>10} {vram:>12}")
        rows.append(dict(dur=dur, frames=f, secs=round(secs), sec_per_frame=round(rate, 3), **(w or {})))

        if base_rate is None:
            base_rate = rate
        # หน้าผา: ต้นทุนต่อเฟรมพุ่งขึ้นเกิน 1.8 เท่าของขั้นแรก ทั้งที่ยังเรนเดอร์ผ่าน
        elif rate > base_rate * 1.8:
            low = w and w["watt_pct"] < 45
            print(f"\n>> เจอหน้าผาที่ {f} เฟรม: ต้นทุนต่อเฟรม {rate/base_rate:.1f} เท่าของตอนคลิปสั้น"
                  + ("  และกำลังไฟตกเหลือ %d%% ของสูงสุด ซึ่งยืนยันว่ากำลังรูด RAM อยู่"
                     % w["watt_pct"] if low else ""))
            ceiling = rows[-2]["frames"] if len(rows) > 1 else f
            break

    if ceiling is None and rows:
        ceiling = rows[-1]["frames"]
        print(f"\n>> ยังไม่เจอหน้าผาถึง {ceiling} เฟรม การ์ดใบนี้ไปได้ไกลกว่าที่ทดสอบ "
              f"-- เพิ่ม --max แล้วรันใหม่ถ้าอยากรู้ขีดจริง")

    _, _, _, total = smi()
    # เขียนทับเฉพาะคีย์ของเรา อย่าล้าง comfy_root ที่ setup.sh จดไว้
    data = json.loads(OUT.read_text(encoding="utf-8")) if OUT.exists() else {}
    data.update(mp=a.mp, frame_ceiling=ceiling,
                vram_total_mib=round(total), runs=rows,
                note="วัดด้วย find_ceiling.py บนเครื่องนี้เอง ไม่ใช่ค่าจากคู่มือ")
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"\nเพดานของเครื่องนี้: {ceiling} เฟรม ที่ {a.mp} MP")
    print(f"เขียนลง {OUT} แล้ว -- ตอนออกแบบคลิป อย่าให้เกินตัวเลขนี้")


if __name__ == "__main__":
    main()
