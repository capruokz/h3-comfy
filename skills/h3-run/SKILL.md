---
name: h3-run
description: สั่งเจนคลิป H3 เป็นชุดผ่าน ComfyUI API ด้วยสคริปต์ Python และเชื่อมคลิปให้ต่อเนื่องด้วยการแคปเฟรมสุดท้ายไปเข้าโหนด LoadImage ของคลิปถัดไป ครอบคลุมการแก้ค่าในกราฟอย่างปลอดภัย คิว/รอ/เก็บผล และการต่อคลิปเป็นไฟล์เดียว. Use when rendering many H3 clips from a script, when chaining clips so each continues from the previous one, when extracting a last frame to use as a reference, when a batch render silently ignored a setting, or when joining rendered clips into one file.
---

# สั่งเจนเป็นชุด + เชื่อมคลิป

ตัวขับอยู่ที่ [scripts/comfy_run.py](scripts/comfy_run.py) นำเข้าเป็นโมดูล อย่าเขียน urllib เองใหม่

**ต้องติดตั้งให้จบก่อน** — `setup.sh` เป็นคนจดว่า ComfyUI อยู่ไหนลง `machine.json`
ถ้ายังไม่ได้รัน ให้ตั้ง `COMFY_ROOT` เอง

## โครงสคริปต์ที่ใช้ได้จริง

```python
import sys; sys.path.insert(0, "<repo>/skills/h3-run/scripts")
import comfy_run as cr
from pathlib import Path

WF = Path("<repo>/workflow/h3_ref2video_api.json")
OUT = Path("./clips"); OUT.mkdir(exist_ok=True)
clips, prev = [], None

for i, text in enumerate(PROMPTS):            # สร้าง+ตรวจ prompt ให้ครบก่อนยิงคลิปแรก
    wf = cr.load(WF)                          # โหลดใหม่ทุกคลิป ไม่แก้ทับตัวเดิม
    cr.set_input(wf, "137", "prompt", text)
    cr.set_input(wf, "129", "noise_seed", SEEDS[i])
    cr.set_input(wf, "133", "value", 10)                     # ความยาว (วินาที)
    cr.set_input(wf, "115", "megapixels", 0.6)
    cr.set_input(wf, "92", "filename_prefix", f"video/c{i+1}")   # ต้องไม่ซ้ำ
    cr.drop_inputs(wf, "137", "ref_images.")                 # ล้างช่องเก่าก่อนต่อใหม่
    if prev:
        cr.add_load_image(wf, prev, "202", wire_to="137", wire_key="ref_images.ref_image_2")
    v = cr.run(wf, out=OUT / f"c{i+1}.mp4", tag=f"c{i+1}")
    clips.append(v)
    prev = cr.last_frame(v)                   # แคป + วางใน input/ คืนชื่อไฟล์
cr.concat(clips, "FULL.mp4")
```

## แผนที่โหนดในกราฟชุดนี้

ทุกคนใช้ `workflow/h3_ref2video_api.json` ตัวเดียวกัน หมายเลขจึงตรงกันเสมอ

| โหนด | คือ | แก้ด้วย |
|---|---|---|
| `137` | `MiniMaxH3ReferenceToVideo` | `prompt`, `ref_images.*`, `ref_audios.*` |
| `129` | `RandomNoise` | `noise_seed` — **ชื่อคีย์ไม่ใช่ `seed`** |
| `133` | `PrimitiveFloat` | `value` = ความยาวคลิปเป็นวินาที |
| `115` | `ResolutionSelector` | `megapixels`, `aspect_ratio` |
| `124` | `BasicScheduler` | `steps` (turbo LoRA ใช้ 4) |
| `134` | `MiniMaxH3TurboLoRA` | `lora_name` |
| `92` | `SaveVideo` | `filename_prefix` |
| `200` `201` | `LoadImage` | รูปตัวละคร |
| `210` `211` | `LoadAudio` | ไฟล์เสียงอ้างอิง |
| `215` `216` | `H3ReferenceAudio` | `max_seconds` = 0.6 ตัดเสียงอ้างอิงให้สั้นก่อนเข้า `137` |
| `127` | `UNETLoader` | `unet_name` = `minimax_h3_fl2va_pruned_INT4Q` คู่กับ turbo_v4 LoRA ห้ามเปลี่ยนโดยไม่วัดเทียบ |

## กฎที่ทำให้ลูปนี้ไม่พังเงียบ

1. **`set_input` เสมอ อย่าเขียน `wf["129"]["inputs"]["seed"]=s` ตรงๆ** คีย์จริงชื่อ `noise_seed`
   การเขียนตรงๆ ไม่ error มันแค่เพิ่มคีย์ที่ไม่มีใครอ่าน แล้วเรนเดอร์จนจบด้วยค่าเดิม
   `set_input` assert ทั้ง node id และชื่อคีย์ แล้วบอกว่าคีย์ที่มีจริงคืออะไร
2. **สร้างและตรวจ prompt ทุกตัวให้จบก่อนยิงงานแรก** พังที่คลิป 12 หลังเรนเดอร์ไปชั่วโมงหนึ่งคือของแพง
3. **`filename_prefix` ต้องไม่ซ้ำต่อคลิป** ไม่งั้น `/history` ชี้ไปที่ไฟล์ของงานก่อน
4. **`/history/<pid>` คืน `{}` ตลอดเวลาที่ยังทำงาน** ว่าง ≠ พัง เช็ค `status_str == "success"` ต่างหาก
   ส่วน `/prompt` ที่ตอบ 400 คือ validation error และบอกชัดว่าโหนดไหน — อย่ากลืน exception
5. **ล้าง input แบบ dynamic ก่อนต่อใหม่** ช่อง ref ของคลิปก่อนจะค้างอยู่เงียบๆ
6. **ไฟล์เสียงอ้างอิงต้องผ่าน `H3ReferenceAudio` (`215` `216`) ที่ `max_seconds` 0.6** ถ้าต่อ `LoadAudio` ตรงเข้า `137`
   H3 จะพูดคำที่อยู่ในไฟล์เสียงออกมาทับบท (ไฟล์ยาว 2.5 วิก็ยังรั่ว) เมื่อต่อ ref เสียงใหม่ให้ต่อผ่านโหนดนี้เสมอ
7. **คลิปไหนไม่มีบทพูด อย่าต่อไฟล์เสียงอ้างอิง** และอย่าประกาศ `<Audio N>` ในพรอมป์ต —
   ref เสียงที่ไม่มีบทคือวิธีที่ H3 ถูกชวนให้แต่งบทพูดขึ้นมาเอง
8. **ลูปยาวให้รันแบบ background** แล้วเฝ้าจากฝั่งที่มองเห็น PID ของ OS นั้นจริงๆ

## เฟรมสุดท้าย → โหนด LoadImage

```python
ref = cr.last_frame(video)      # ffmpeg + คัดลอกเข้า input/ คืน "clip1_last.png"
cr.add_load_image(wf, ref, "202", wire_to="137", wire_key="ref_images.ref_image_2")
```
หรือจาก command line: `python comfy_run.py last-frame clip.mp4`

- คำสั่งจริงคือ `ffmpeg -sseof -0.5 -i v.mp4 -update 1 out.png` — กรอไปครึ่งวินาทีสุดท้าย
  แล้วเขียนทับทุกเฟรม ตัวที่ค้างอยู่ตอนจบคือเฟรมสุดท้ายจริง ไม่ต้องถอดทั้งคลิป
- **LoadImage อ่านจาก `<ComfyUI>/input` เท่านั้น** path เต็มใช้ไม่ได้ `last_frame()` คัดลอกให้แล้ว
- **ชื่อไฟล์ต้องไม่ซ้ำระหว่างคลิป** อย่าใช้ `last.png` ร่วมกัน
- **โหนด `202` เป็นการแทรกโหนดใหม่** ไม่ใช่โหนดที่มีอยู่ เลือก id ที่ยังว่าง
- **ทิศทางของโซ่เลือกตามว่าฉากเคลื่อนหรือนิ่ง** ฉากนิ่งอ้างคลิปแรกตลอด ฉากเดินหน้าอ้างคลิปก่อนหน้า
  ผิดแบบแล้วพังคนละอาการ — ดู [h3-prompt](../h3-prompt/SKILL.md)

## ต่อคลิป

`cr.concat(clips, "FULL.mp4")` ใช้ `ffmpeg -f concat -c copy` **ไม่เข้ารหัสใหม่**
ใช้ได้เมื่อทุกคลิปมาจาก workflow เดียวกัน ถ้าความละเอียดหรือ fps ต่างกันต้องเข้ารหัสใหม่แทน

## เช็คก่อนยิง

`python comfy_run.py status` — เวอร์ชัน, VRAM, ความยาวคิว

`vram_free` ที่รายงานมาเห็นแค่ pool ของ torch **ไม่เห็นส่วนที่ driver ดันออก RAM**
ถ้าสงสัยว่าล้น ดู power draw จาก `nvidia-smi`: util 100% ที่ไฟต่ำกว่าครึ่งของค่าสูงสุด
คือกำลังรูด RAM ไม่ใช่กำลังทำงาน (ดู [h3-setup](../h3-setup/SKILL.md))
