#!/usr/bin/env python3
"""1 player games must be unchanged.

The original and the patched ROM are started from the very same machine state
(the patched one additionally gets the add-on code in PRG-RAM) and are fed the
same input; RAM and picture are compared on every frame.  Covers races played
by an autopilot (several levels, game over, continue) and the attract demo.

usage: RCPA_ROM=original.nes tests/test_1p_identical.py [frames]
"""
import sys

from harness import NES, ROM, PATCHED, A, START, Bot, need_rom, racing, record_path, install_payload


def compare(a, b, frames, drive):
    paths = {}
    bot = None
    t = 0
    for f in range(frames):
        if drive and racing(a):
            if bot is None:
                lvl = (a[0x44B], a[0x44C])
                if lvl not in paths:
                    paths[lvl] = record_path(a, 1)
                bot = Bot(paths[lvl])
            p = bot.pads(a) | (A if f % 45 == 0 else 0)
        elif drive:
            bot = None
            t += 1
            p = START if (t // 30) % 4 == 0 else 0
        else:
            p = 0
        a.frame(1, pads=p)
        b.frame(1, pads=p)
        ra, rb = a.ram(), b.ram()
        # $1A/$1B: pointer to the title text, which lives elsewhere;
        # $0180-$01FF: stack garbage below the stack pointer
        ra = ra[:0x1A] + ra[0x1C:0x180] + ra[0x200:]
        rb = rb[:0x1A] + rb[0x1C:0x180] + rb[0x200:]
        if ra != rb or a.fb.tobytes() != b.fb.tobytes():
            diff = [j for j in range(len(ra)) if ra[j] != rb[j]]
            return 'frame %d (mode %02X): RAM diff %s, picture %s' % (
                f, a[0x0D], diff[:10], a.fb.tobytes() != b.fb.tobytes())
    return None


def main():
    need_rom()
    frames = int(sys.argv[1]) if len(sys.argv) > 1 else 30000
    ok = True

    # races
    a = NES(ROM)
    b = NES(PATCHED)
    a.frame(300, pads=0)
    a.frame(5, pads=START)
    a.frame(240, pads=0)
    a.frame(5, pads=START)
    while not racing(a):
        a.frame(1, pads=0)
    b.load(a.save())
    install_payload(b)
    err = compare(a, b, frames, True)
    print('races:', err or 'identical for %d frames (level %d reached)' % (frames, a[0x44B]))
    ok &= err is None

    # title screen and attract demo
    a = NES(ROM)
    b = NES(PATCHED)
    a.frame(200, pads=0)
    b.load(a.save())
    install_payload(b)
    err = compare(a, b, min(frames, 15000), False)
    print('attract mode:', err or 'identical')
    ok &= err is None
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
