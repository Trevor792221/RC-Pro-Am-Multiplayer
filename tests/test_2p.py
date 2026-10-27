#!/usr/bin/env python3
"""2 player scenarios, played by autopilots in the test emulator.

usage: RCPA_ROM=original.nes tests/test_2p.py [outdir]
Writes a contact sheet of screenshots per scenario into outdir (optional).
"""
import os
import sys

import numpy as np

from harness import (NES, PATCHED, A, B, SELECT, START, UP, DOWN, Bot, labels, need_rom, racing,
                     record_path, start_game)

FAILED = []


def check(cond, what):
    print(('  ok    ' if cond else '  FAIL  ') + what)
    if not cond:
        FAILED.append(what)


def sheet(images, path):
    if not path:
        return
    from PIL import Image
    from nes import PALETTE  # noqa
    cols = 4
    while len(images) % cols:
        images.append(np.zeros_like(images[0]))
    rows = [np.hstack(images[i:i + cols]) for i in range(0, len(images), cols)]
    Image.fromarray(np.vstack(rows)).save(path)


class Run:
    """A 2 player game positioned at the first frame of the first race."""

    def __init__(self):
        self.n = NES(PATCHED)
        start_game(self.n, two_players=True)
        self.L = labels()
        self.path = record_path(self.n, 2)      # car 2 is a CPU car
        self.b1 = Bot(self.path, 0)
        self.b2 = Bot(self.path, 1)
        self.start = self.n.save()

    def reset(self):
        self.n.load(self.start)
        self.b1.idx = self.b2.idx = 0

    def var(self, name, off=0):
        return self.n[self.L[name] + off]

    def race(self, p1='bot', p2='bot', frames=4000, every=None, hook=None):
        """Play until the race is over.  p1/p2: 'bot' or 'idle'."""
        n = self.n
        shots = []
        for i in range(frames):
            if n[0x0D] not in (2, 0xFF):
                break
            a = self.b1.pads(n) if p1 == 'bot' else 0
            b = self.b2.pads(n) if p2 == 'bot' else 0
            if hook:
                a, b = hook(i, a, b)
            n.frame(1, pads=a | (b << 8))
            if every and i % every == 0:
                shots.append(n.image())
            assert not n.jammed(), 'CPU jammed at %04X' % n.pc
        return i, shots


def main():
    need_rom()
    out = sys.argv[1] if len(sys.argv) > 1 else None
    if out:
        os.makedirs(out, exist_ok=True)

    # title screen
    print('title screen')
    n = NES(PATCHED)
    L = labels()
    n.frame(300, pads=0)
    n.frame(5, pads=START)
    n.frame(60, pads=0)
    seq = []
    for pad in (DOWN, UP, SELECT, SELECT, START << 8, START << 8, UP):
        n.frame(3, pads=pad)
        n.frame(10, pads=0)
        seq.append(n[L['twop']])
    check(seq == [1, 0, 1, 0, 1, 1, 0], 'menu: down/up/SELECT/controller 2 START %s' % seq)
    shown = []
    for i in range(40):
        n.frame(1, pads=0)
        shown.append((n.ppu(0x226B) != 0, n.ppu(0x22AB) != 0))
    check(all(s[1] for s in shown) and not all(s[0] for s in shown) and any(s[0] for s in shown),
          'both lines shown, the selected one blinks')

    r = Run()
    n = r.n
    check(n[0x475] == 12, 'car 1 starts out as a CPU car before the race begins')

    print('both players drive')
    r.reset()
    frames, shots = r.race(every=150)
    sheet(shots, out and os.path.join(out, 'both_drive.png'))
    check(n[0x475] == 4 and n[0x0D] != 2, 'race finished with player 2 in car 1 (%d frames)' % frames)
    check(n[0x5FC] >= 1 and n[0x5FD] >= 1, 'both humans completed laps %s' % [n[0x5FC + k] for k in range(4)])

    print('player 2 idle: pulled along behind player 1')
    r.reset()
    warps = [0]
    prev = [0]

    def count_warps(i, a, b):
        c = r.var('off_cnt')
        if prev[0] >= 19 and c == 0:
            warps[0] += 1
        prev[0] = c
        return a, b
    frames, shots = r.race(p2='idle', every=150, hook=count_warps)
    sheet(shots, out and os.path.join(out, 'p2_idle.png'))
    check(warps[0] > 3, 'player 2 was pulled along %d times' % warps[0])
    check(n[0x5FD] >= 1, 'idle player 2 still completed laps (%d)' % n[0x5FD])

    print('player 1 idle: camera follows player 2')
    r.reset()
    leads = []

    def note_leader(i, a, b):
        if i > 600:
            leads.append(r.var('leader'))
        return a, b
    frames, shots = r.race(p1='idle', every=150, hook=note_leader)
    sheet(shots, out and os.path.join(out, 'p1_idle.png'))
    check(leads and sum(leads) / len(leads) > 0.9, 'player 2 leads and is followed')
    lap_pts = n[0x3E8] * 100 + n[0x3E9] - 2000     # minus the bonus for 1st place
    check(lap_pts >= 100 * n[0x5FD], 'player 2 scores lap bonuses (%d points)' % lap_pts)

    print('qualifying')
    for forced, expect_over in (('p1', False), ('p2', False), ('both', True)):
        r.reset()

        def last(i, a, b):
            if racing(n) and n[0x450] == 0:
                for s in {'p1': [0], 'p2': [1], 'both': [0, 1]}[forced]:
                    n[0x5FC + s] = 0
                    n[0x5F8 + s] = 0
            return a, b
        r.race(hook=last)
        modes = []
        for i in range(600):
            n.frame(1, pads=0)
            modes.append(n[0x0D])
        over = 0x0E in modes
        check(over == expect_over, '%s last: %s' % (forced, 'game over' if over else 'next race'))

    print('player 2 weapons and pickups')
    r.reset()

    def fire(i, a, b):
        if i == 5:
            n[r.L['p2ammo']] = 5
            n[r.L['p2weap']] = 1
        if i in (300, 400, 500):
            b |= A
        return a, b
    r.race(frames=600, hook=fire)
    check(r.var('p2ammo') == 2 and n[0x459] == 0, 'player 2 fired 3 missiles from its own ammo')
    r.reset()
    t = 0
    races = 0
    bot = None
    for f in range(12000):              # 3 races, player 1 does not drive
        if racing(n):
            if bot is None:
                bot = Bot(record_path(n, 2), 1)
                races += 1
            pads = bot.pads(n) << 8
        else:
            if bot is not None and races == 3:
                break
            bot = None
            t += 1
            pads = START if (t // 30) % 4 == 0 else 0
        n.frame(1, pads=pads)
    upg = [r.var('p2upg', k) for k in range(3)] + [r.var('p2ammo')]
    check(sum(upg) > 0 and n[0x453] + n[0x454] + n[0x455] + n[0x459] == 0,
          'pickups go to player 2 only (p2 %s)' % upg)

    print('player 2 crash')
    r.reset()
    seen = []

    def crash(i, a, b):
        if i > 300:
            a &= ~B                     # player 1 waits
        if i == 320:
            n[0x475] = 7
            n[0x5BD] = 0x30
        if 320 < i < 370:
            seen.append((n[0x475], r.var('pvis', 1)))
        return a, b
    r.race(frames=400, hook=crash)
    check(any(s == 7 for s, v in seen) and all(v for s, v in seen) and n[0x475] == 5,
          'crashed player 2 is drawn and recovers')

    print('several races')
    r.reset()
    races = 0
    t = 0
    bots = None
    for f in range(30000):
        if racing(n):
            if bots is None:
                p = record_path(n, 2)
                bots = (Bot(p, 0), Bot(p, 1))
                races += 1
            pads = bots[0].pads(n) | (bots[1].pads(n) << 8)
        else:
            bots = None
            t += 1
            pads = START if (t // 30) % 4 == 0 else 0
        n.frame(1, pads=pads)
        assert not n.jammed()
        if races > 5:
            break
    check(races > 5, 'played %d races in a row' % races)

    print('FAILED: %s' % FAILED if FAILED else 'all passed')
    sys.exit(1 if FAILED else 0)


if __name__ == '__main__':
    main()
