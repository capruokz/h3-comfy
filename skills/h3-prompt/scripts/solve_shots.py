# -*- coding: utf-8 -*-
"""หาความยาวช็อตที่ถูกกฎ แทนการคิดเอง

    python solve_shots.py --secs 10.125 --kind dialogue \
        --shots S,L,L --lines "ฝ่าบาท ยามนี้ดึกแล้ว" "เงียบเสีย ไร้คนนอก"

    python solve_shots.py --frames                    # ตารางความยาวคลิปที่ลงตัว
    python solve_shots.py --secs 8 --kind dialogue --shots S,L,L --suggest
                                                      # บอกว่าบทควรยาวกี่ตัวอักษร

`--shots` คือรูปแบบช็อต: S = เงียบ, L = มีบทพูด (เรียงตามลำดับใน --lines)

เขียนขึ้นเพราะการคิดความยาวช็อตด้วยมือพลาดทุกครั้ง การสแนป 0.25 วิ ทิ้งเวลาได้ถึง
0.25 วิต่อจุดตัด ซึ่งในคลิปสั้นมากพอจะทำให้สัดส่วนบทพูดตกเกณฑ์ทั้งที่จริงๆ จัดลงได้
สคริปต์นี้ค้นทั้งกริด ถ้ามีคำตอบมันหาเจอ ถ้าไม่มีมันบอกว่าต้องตัดกี่ตัวอักษร
"""
import argparse
import itertools
import sys

sys.stdout.reconfigure(encoding="utf-8")

SLACK_MIN, SLACK_MAX = 0.10, 0.45
FLOOR = {"dialogue": 0.70, "montage": 0.25, "action": 0.45, "footage": 0.0, "product": 0.0}
SHOT_FLOOR = 1.25          # เพดานล่างเด็ดขาด ต่ำกว่านี้ H3 รวมช็อตแล้วด้นสด
CLOSING_FLOOR = 2.06       # P25 ของช็อตปิด


def dur(line):
    """วินาทีที่บทพูดกิน — สูตรเดียวกับ h3-drama"""
    return len(line.replace(" ", "")) / 11.5 + 0.25


def frames_for(secs_wanted):
    """ความยาวจริงที่ H3 เรนเดอร์ เมื่อสั่ง DUR = round(secs_wanted)"""
    d = round(secs_wanted)
    n = max(5, round(d * 24))
    f = n + (5 - n % 17) % 17
    return d, f, f / 24


def solve(secs, pattern, lines, floor):
    """ค้นทั้งกริด 0.25 วิ คืนชุดที่ 'แบน' ที่สุด (H3 drama ไม่เร่งจังหวะตอนท้าย)"""
    grid = [round(x * 0.25, 2) for x in range(int(SHOT_FLOOR * 4), int((secs - SHOT_FLOOR) * 4) + 1)]
    tail = round(secs - int(secs * 4) / 4, 4)      # เศษที่ไม่ลงกริด ให้ช็อตปิดรับไป
    per, li = [], 0
    for kind in pattern:
        if kind == "S":
            per.append(grid)
        else:
            d = dur(lines[li]); li += 1
            per.append([g for g in grid if SLACK_MIN - 1e-9 <= g - d <= SLACK_MAX + 1e-9])
    if any(not p for p in per):
        return None
    best = None
    for combo in itertools.product(*per):
        combo = list(combo)
        combo[-1] = round(combo[-1] + tail, 4)
        if abs(sum(combo) - secs) > 1e-9 or combo[-1] < CLOSING_FLOOR or any(c < SHOT_FLOOR for c in combo):
            continue
        spread = max(combo) - min(combo)
        if best is None or spread < best[0]:
            best = (spread, combo)
    return best[1] if best else None


def suggest(secs, pattern, floor, span=(9, 46)):
    """ไม่มีบท หรือบทไม่ลงตัว — บอกว่าแต่ละบทควรยาวกี่ตัวอักษร"""
    n_lines = pattern.count("L")
    out = []
    for chars in itertools.product(range(*span), repeat=n_lines):
        fake = ["ก" * c for c in chars]
        if sum(dur(f) for f in fake) / secs < floor:
            continue
        if solve(secs, pattern, fake, floor):
            out.append((sum(chars), chars))
    out.sort(reverse=True)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secs", type=float)
    ap.add_argument("--kind", default="dialogue", choices=sorted(FLOOR))
    ap.add_argument("--shots", help="รูปแบบช็อต เช่น S,L,L")
    ap.add_argument("--lines", nargs="*", default=[])
    ap.add_argument("--suggest", action="store_true")
    ap.add_argument("--frames", action="store_true")
    a = ap.parse_args()

    if a.frames:
        print(f"{'DUR':>4} {'frames':>7} {'seconds':>9}")
        for want in range(3, 21):
            d, f, s = frames_for(want)
            flag = "  <-- ลงตัว" if abs(s - want) < 1e-6 else ""
            over = "   OVER ~300 frame ceiling" if f > 300 else ""
            print(f"{d:>4} {f:>7} {s:>9.4f}{flag}{over}")
        return

    if not a.secs or not a.shots:
        ap.error("--secs และ --shots ต้องระบุ (หรือใช้ --frames)")
    pattern = [p.strip().upper() for p in a.shots.split(",")]
    assert all(p in ("S", "L") for p in pattern), "--shots รับเฉพาะ S กับ L"
    floor = FLOOR[a.kind]

    d, f, real = frames_for(a.secs)
    if abs(real - a.secs) > 5e-4:
        print(f"!! {a.secs}s ไม่ลงตัว: DUR={d} เรนเดอร์ออกมา {real:.4f}s ({f} เฟรม)")
        print(f"   ใช้ --secs {real:.4f} แทน\n")
    if f > 300:
        print(f"!! {f} เฟรม เกินเพดาน ~300 ของการ์ด 16 GB — จะตกหน้าผา 2.6 เท่า\n")

    if a.suggest or not a.lines:
        opts = suggest(a.secs, pattern, floor)
        if not opts:
            print(f"ไม่มีความยาวบทใดที่ลงตัวกับรูปแบบ {a.shots} ที่ {a.secs}s พื้น {floor}")
            print("ลองเปลี่ยนจำนวนช็อต หรือย้ายช็อตเงียบ (ช็อตเงียบห้ามอยู่ท้ายถ้าคลิปสั้น)")
            return
        print(f"บทที่ลงตัวกับ {a.shots} ที่ {a.secs}s พื้น {floor} (ยาวที่สุดก่อน, หน่วยเป็นตัวอักษรไม่นับเว้นวรรค):")
        for total, chars in opts[:8]:
            print(f"    {chars}  รวม {total}  ratio {sum(dur('ก'*c) for c in chars)/a.secs:.2f}")
        return

    assert len(a.lines) == pattern.count("L"), \
        f"--shots มีช็อตพูด {pattern.count('L')} ช็อต แต่ --lines ให้มา {len(a.lines)} บท"
    ratio = sum(dur(l) for l in a.lines) / a.secs
    got = solve(a.secs, pattern, a.lines, floor)
    print(f"kind {a.kind}  พื้นบทพูด {floor}  ได้ {ratio:.2f}" + ("" if ratio >= floor else "   ** ต่ำกว่าพื้น **"))
    for l in a.lines:
        print(f"    {dur(l):5.2f}s  {len(l.replace(' ', '')):>3} ตัวอักษร  {l}")
    if got:
        print("\nOK  " + "  ".join(f"{x:g}" for x in got))
        cuts = [sum(got[:i + 1]) for i in range(len(got) - 1)]
        print("    จุดตัด " + "  ".join(f"{c:g}" for c in cuts))
    else:
        need = a.secs * 0.78
        have = sum(dur(l) for l in a.lines)
        print(f"\nไม่มีชุดที่ถูกกฎ  บทรวม {have:.2f}s ควรอยู่แถว {need:.2f}s "
              f"({int(abs(have-need)*11.5)} ตัวอักษร{'มากไป' if have > need else 'น้อยไป'})")
        print("รัน --suggest เพื่อดูความยาวบทที่ลงตัว")


if __name__ == "__main__":
    main()
