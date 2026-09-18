# -*- coding: utf-8 -*-
"""ขับ ComfyUI ผ่าน HTTP API จาก Python และเชื่อมคลิปด้วยเฟรมสุดท้าย

ใช้เป็นโมดูล:

    import comfy_run as cr
    wf = cr.load(r"C:\\...\\EP01_v2_LC01.json")
    cr.set_input(wf, "129", "noise_seed", 12345)
    cr.set_input(wf, "92", "filename_prefix", "video/clip1")
    v = cr.run(wf, out=Path("G:/out/clip1.mp4"), tag="clip1")
    ref = cr.last_frame(v)                       # -> "clip1_last.png" พร้อมใช้แล้ว
    cr.add_load_image(wf2, ref, "202")           # คลิปถัดไปอ้างเฟรมนี้

หรือจาก command line:

    python comfy_run.py status
    python comfy_run.py last-frame G:\\out\\clip1.mp4
    python comfy_run.py concat G:\\out c1.mp4 c2.mp4 c3.mp4 --out full.mp4
    python comfy_run.py stash-latents shot01            # ดราฟ Singularity -> input/shot01_v.latent, _a.latent

ทุก setter มี assert เพราะความพังที่แพงที่สุดคือความพังที่เงียบ: node id ผิดตัวเดียว
แล้วโปรแกรมยังวิ่งจนจบ ได้คลิปที่ไม่มีการแก้อยู่ในนั้นเลย เสียเวลาเรนเดอร์ไปเปล่าๆ
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

# ไม่ hardcode path ของเครื่องใดเครื่องหนึ่ง เรียงลำดับ:
#   1. ตัวแปรระบบ COMFY_ROOT ที่ผู้ใช้ตั้งเอง
#   2. machine.json ที่ setup.sh เขียนไว้ตอนติดตั้ง
#
# **อย่าเดาจากดิสก์** เครื่องเช่าบางเทมเพลตมี ComfyUI สองชุด และตัวที่หาเจอก่อน
# ไม่ใช่ตัวที่รันอยู่ การเดาจึงเขียนไฟล์ลงที่ที่ไม่มีใครอ่าน
#
# และอย่าหวังพึ่ง /system_stats ด้วย — เช็คแล้ว มันไม่ได้บอก path ของตัวเองเลย
# (คีย์ที่มีคือ os, ram, เวอร์ชัน, pytorch เท่านั้น) ตอนติดตั้ง comfy_env.sh รู้คำตอบอยู่แล้ว
# จากโปรเซสที่รันอยู่ จึงให้มันจดลง machine.json ไว้ตั้งแต่ตอนนั้น
API = os.environ.get("COMFY_API", "http://127.0.0.1:8188")
_root = os.environ.get("COMFY_ROOT")
MACHINE = Path(__file__).resolve().parents[3] / "machine.json"


def _discover_root():
    global _root
    if _root:
        return Path(_root)
    if MACHINE.exists():
        v = json.loads(MACHINE.read_text(encoding="utf-8")).get("comfy_root")
        if v:
            _root = v
            return Path(v)
    raise SystemExit(
        "หา ComfyUI ไม่เจอ\n"
        f"  ไม่มี comfy_root ใน {MACHINE} และไม่ได้ตั้ง COMFY_ROOT\n"
        "  แก้ด้วยวิธีใดวิธีหนึ่ง:\n"
        "    export COMFY_ROOT=/path/to/ComfyUI\n"
        "    หรือรัน skills/h3-setup/scripts/setup.sh ให้จบ (มันจะจดให้เอง)")


def comfy_out():
    return _discover_root() / "output"


def comfy_in():
    return _discover_root() / "input"


# ---------------------------------------------------------------- HTTP

def _api(path, data=None, timeout=300):
    req = urllib.request.Request(
        API + path, data=data,
        headers={"Content-Type": "application/json"} if data else {})
    return urllib.request.urlopen(req, timeout=timeout).read()


def alive():
    """เซิร์ฟเวอร์ตอบมั้ย — เช็คก่อนคิวทุกครั้ง ไม่งั้นจะได้ traceback แทนคำตอบ"""
    try:
        return json.loads(_api("/system_stats", timeout=5))
    except Exception:
        return None


# ---------------------------------------------------------------- workflow

def load(path):
    """อ่าน workflow แบบ API format — ปฏิเสธไฟล์ UI format ทันที"""
    wf = json.loads(Path(path).read_text(encoding="utf-8"))
    assert "nodes" not in wf, (
        f"{path} เป็น UI format (มีคีย์ 'nodes') /prompt ไม่รับ "
        f"ต้อง export ใหม่ด้วย Save (API Format)")
    assert wf and all("class_type" in v for v in wf.values()), \
        f"{path} ไม่ใช่ API format: ทุกโหนดต้องมี class_type"
    return wf


def set_input(wf, nid, key, value):
    """เซ็ตค่า widget พร้อมพิสูจน์ว่ามีโหนดและคีย์นั้นจริง

    นี่คือจุดที่ assert คุ้มที่สุด: `wf["129"]["inputs"]["seed"] = s` ในกราฟที่คีย์จริง
    ชื่อ `noise_seed` จะไม่ error มันแค่เพิ่มคีย์ที่ไม่มีใครอ่าน แล้วเรนเดอร์ด้วย
    seed เดิมจนจบ
    """
    nid = str(nid)
    assert nid in wf, f"ไม่มีโหนด {nid} ในกราฟ (มี {len(wf)} โหนด)"
    ins = wf[nid]["inputs"]
    assert key in ins, (
        f"โหนด {nid} ({wf[nid]['class_type']}) ไม่มี input ชื่อ {key!r} — "
        f"ที่มีคือ {sorted(ins)}")
    ins[key] = value
    return wf


def drop_inputs(wf, nid, prefix):
    """ลบ input แบบ dynamic ที่ขึ้นต้นด้วย prefix (เช่น 'ref_images.')

    โหนดที่รับ reference หลายช่องจะสะสมคีย์เก่าไว้ ถ้าคลิปนี้ใช้ ref น้อยกว่าคลิปก่อน
    ช่องเก่าจะยังต่ออยู่เงียบๆ — ล้างก่อนต่อใหม่ทุกครั้ง
    """
    nid = str(nid)
    for k in [k for k in wf[nid]["inputs"] if k.startswith(prefix)]:
        del wf[nid]["inputs"][k]
    return wf


def add_load_image(wf, filename, nid, wire_to=None, wire_key=None):
    """แทรกโหนด LoadImage เข้ากราฟ แล้ว (ถ้าสั่ง) ต่อสายเข้าโหนดปลายทาง

    filename ต้องเป็น *ชื่อไฟล์เปล่า* ที่วางอยู่ใน ComfyUI/input แล้ว ไม่ใช่ path เต็ม
    """
    nid = str(nid)
    assert "\\" not in filename and "/" not in filename, \
        f"LoadImage รับชื่อไฟล์ใน input/ ไม่ใช่ path: {filename}"
    assert (comfy_in() / filename).exists(), \
        f"{filename} ยังไม่อยู่ใน {comfy_in()} — เรียก last_frame() หรือ install() ก่อน"
    wf[nid] = {"inputs": {"image": filename}, "class_type": "LoadImage"}
    if wire_to is not None:
        wf[str(wire_to)]["inputs"][wire_key] = [nid, 0]
    return wf


# ---------------------------------------------------------------- run

def queue(wf, client_id="comfy_run"):
    body = json.dumps({"prompt": wf, "client_id": client_id}).encode()
    try:
        return json.loads(_api("/prompt", body))["prompt_id"]
    except urllib.error.HTTPError as e:
        # 400 จาก /prompt คือ validation error และมันบอกชัดว่าโหนดไหนพัง — อย่ากลืน
        raise SystemExit("คิวไม่ผ่าน:\n" + e.read().decode("utf-8", "replace")[:2000])


def wait(pid, timeout=3600, poll=4, tag=""):
    """รอจนงานจบ คืน list ของ path (relative กับ ComfyUI/output)

    `/history/<pid>` คืน {} ตลอดเวลาที่ยังทำงานอยู่ — ว่างไม่ได้แปลว่าพัง
    """
    t0 = time.time()
    while time.time() - t0 < timeout:
        h = json.loads(_api(f"/history/{pid}", timeout=60))
        if not h:
            time.sleep(poll)
            continue
        rec = h[pid]
        status = rec["status"]["status_str"]
        files = [Path(f.get("subfolder", "")) / f["filename"]
                 for o in rec.get("outputs", {}).values()
                 for key in ("images", "videos", "gifs")
                 for f in o.get(key, [])]
        if status != "success" or not files:
            raise SystemExit(f"{tag or pid} ล้มเหลว ({status}):\n"
                             + json.dumps(rec["status"], ensure_ascii=False)[:2000])
        return files, time.time() - t0
    raise SystemExit(f"{tag or pid} เกิน {timeout}s")


def run(wf, out=None, tag="", client_id="comfy_run", timeout=3600):
    """คิว + รอ + คัดลอกผลลัพธ์ตัวแรกไปที่ out คืน path ปลายทาง"""
    assert alive(), f"ComfyUI ไม่ตอบที่ {API}"
    pid = queue(wf, client_id)
    print(f"{tag or pid}  queued", flush=True)
    files, secs = wait(pid, timeout=timeout, tag=tag)
    src = comfy_out() / files[0]
    if out is None:
        print(f"{tag or pid}  {secs:.0f}s  -> {src}", flush=True)
        return src
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(src.read_bytes())
    print(f"{tag or pid}  {secs:.0f}s  -> {out.name}", flush=True)
    return out


# ---------------------------------------------------------------- เฟรมสุดท้าย

def install(path):
    """คัดลอกไฟล์เข้า ComfyUI/input คืนชื่อไฟล์เปล่าที่ LoadImage ใช้ได้"""
    path = Path(path)
    comfy_in().mkdir(parents=True, exist_ok=True)
    shutil.copy(path, comfy_in() / path.name)
    return path.name


def last_frame(video, png=None, install_to_input=True):
    """ดึงเฟรมสุดท้ายของคลิปเป็น PNG แล้ววางใน ComfyUI/input

    `-sseof -0.5` กรอไปครึ่งวินาทีสุดท้ายแล้วเขียนทับด้วย `-update 1` ทุกเฟรม
    ตัวที่เขียนค้างไว้ตอนจบจึงเป็นเฟรมสุดท้ายจริง และไม่ต้องถอดทั้งคลิป

    **ชื่อไฟล์ต้องไม่ซ้ำระหว่างคลิป** ตั้งตามชื่อคลิป อย่าใช้ last.png ร่วมกัน —
    คิวที่ยิงรัวจะอ่านไฟล์ที่ถูกทับไปแล้ว
    """
    video = Path(video)
    png = Path(png) if png else video.with_name(video.stem + "_last.png")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-sseof", "-0.5",
                    "-i", str(video), "-update", "1", str(png)], check=True)
    assert png.exists() and png.stat().st_size > 0, f"ffmpeg ไม่ได้เขียน {png}"
    return install(png) if install_to_input else png.name


def stash_latents(name, prefix="h3_latent/clip"):
    """ย้าย latent ของดราฟ Singularity จาก output/ ไป input/ ให้ LoadLatent ของ workflow final อ่านได้

    workflow ดราฟเซฟสองไฟล์ (ภาพ `<prefix>_v_*.latent` กับเสียง `<prefix>_a_*.latent`)
    เพราะ SaveLatent เก็บ latent ภาพ+เสียงรวมกันไม่ได้ ฟังก์ชันนี้หยิบไฟล์ล่าสุดของแต่ละชุด
    แล้ววางเป็น `<name>_v.latent` / `<name>_a.latent` คืน (ชื่อภาพ, ชื่อเสียง) ไว้เซ็ตให้โหนด 511 512

    **ตั้ง prefix ในโหนด 509 510 ไม่ให้ซ้ำต่อคลิป** ไม่งั้นไฟล์ล่าสุดอาจเป็นของคลิปอื่นที่คิวรัว
    """
    out = []
    for part in ("v", "a"):
        src = sorted(comfy_out().glob(f"{prefix}_{part}_*.latent"), key=lambda f: f.stat().st_mtime)
        assert src, f"ไม่เจอ {prefix}_{part}_*.latent ใน {comfy_out()} -- รันดราฟก่อน"
        dst = f"{name}_{part}.latent"
        shutil.copy(src[-1], comfy_in() / dst)
        out.append(dst)
    return tuple(out)


def concat(clips, out, cwd=None):
    """ต่อคลิปที่พารามิเตอร์เข้ารหัสเหมือนกัน โดยไม่เข้ารหัสใหม่"""
    clips = [Path(c) for c in clips]
    cwd = Path(cwd or clips[0].parent)
    lst = cwd / (Path(out).stem + "_list.txt")
    lst.write_text("".join(f"file '{c.name}'\n" for c in clips), encoding="utf-8")
    out = cwd / Path(out).name
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat",
                    "-safe", "0", "-i", str(lst), "-c", "copy", str(out)],
                   cwd=str(cwd), check=True)
    return out


# ---------------------------------------------------------------- CLI

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd == "status":
        s = alive()
        if not s:
            print(f"ComfyUI ไม่ตอบที่ {API}")
            return
        d = s["devices"][0]
        print(f"{s['system']['comfyui_version']}  {d['name']}")
        print(f"VRAM free {d['vram_free']/2**30:.1f} / {d['vram_total']/2**30:.1f} GB")
        print("หมายเหตุ: ตัวเลขนี้เห็นแค่ pool ของ torch ไม่เห็นส่วนที่ driver spill "
              "ออก RAM — ถ้าสงสัยว่าล้น ให้ดู power draw จาก nvidia-smi")
        q = json.loads(_api("/queue"))
        print(f"queue running {len(q['queue_running'])}  pending {len(q['queue_pending'])}")
    elif cmd == "last-frame":
        for v in sys.argv[2:]:
            print(last_frame(v), "-> ", comfy_in())
    elif cmd == "stash-latents":
        print(stash_latents(*sys.argv[2:4]), "-> ", comfy_in())
    elif cmd == "concat":
        args = sys.argv[2:]
        out = "full.mp4"
        if "--out" in args:
            i = args.index("--out"); out = args[i + 1]; args = args[:i] + args[i + 2:]
        print(concat(args[1:], out, cwd=args[0]))
    else:
        raise SystemExit(f"ไม่รู้จักคำสั่ง {cmd}")


if __name__ == "__main__":
    main()
