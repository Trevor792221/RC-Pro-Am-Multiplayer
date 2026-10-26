"""Shared helpers for the tests: emulator, a simple autopilot and game flow.

The original ROM is not part of the repository; pass its path in the
RCPA_ROM environment variable.  build.py must have been run first.
"""
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools', 'emu'))

from nes import NES, A, B, SELECT, START, UP, DOWN, LEFT, RIGHT  # noqa: E402,F401

ROM = os.environ.get('RCPA_ROM')
PATCHED = os.path.join(ROOT, 'build', 'rcproam_2p.nes')
PAYLOAD = os.path.join(ROOT, 'build', 'mp.bin')


def labels():
    syms = {}
    for line in open(os.path.join(ROOT, 'build', 'mp.lbl')):
        p = line.split()
        if len(p) == 3:
            syms[p[2].lstrip('.')] = int(p[1], 16)
    return syms


def need_rom():
    if not ROM or not os.path.exists(ROM):
        sys.exit('set RCPA_ROM to the original R.C. Pro-Am (USA) (Rev 1) ROM')
    if not os.path.exists(PATCHED):
        sys.exit('run build.py first')


def racing(n):
    return n[0x0D] == 2 and n[0x3F6] == 1


def car_pos(n, slot):
    return (n[0x4EC + slot] * 256 + n[0x49C + slot], n[0x514 + slot] * 256 + n[0x4C4 + slot])


def record_path(n, slot, frames=9000, pads=0):
    """Positions of a CPU car driving the track (the state is restored)."""
    st = n.save()
    path = []
    for _ in range(frames):
        n.frame(1, pads=pads)
        p = car_pos(n, slot)
        if not path or abs(p[0] - path[-1][0]) + abs(p[1] - path[-1][1]) > 40:
            path.append(p)
        if n[0x0D] not in (2, 0xFF):
            break
    n.load(st)
    return path


class Bot:
    """Steers car `slot` along a recorded path, holding the accelerator."""

    def __init__(self, path, slot=0, look=3):
        self.path, self.slot, self.look, self.idx = path, slot, look, 0

    def pads(self, n):
        x, y = car_pos(n, self.slot)
        size = len(self.path)
        best = None
        for k in range(-5, 40):
            j = (self.idx + k) % size
            px, py = self.path[j]
            d = (px - x) ** 2 + (py - y) ** 2
            if best is None or d < best[0]:
                best = (d, j)
        if best[0] > 400 ** 2:
            best = min(((px - x) ** 2 + (py - y) ** 2, j) for j, (px, py) in enumerate(self.path))
        self.idx = best[1]
        tx, ty = self.path[(self.idx + self.look) % size]
        h = (math.atan2(-(tx - x), ty - y) / (2 * math.pi) * 256) % 256
        diff = ((h - n[0x5CC + self.slot] + 128) % 256) - 128
        p = B
        if diff > 6:
            p |= RIGHT
        elif diff < -6:
            p |= LEFT
        return p


def start_game(n, two_players=False):
    """From power-on to the first frame of the first race."""
    n.frame(300, pads=0)
    n.frame(5, pads=START)
    n.frame(60, pads=0)
    if two_players:
        n.frame(3, pads=SELECT)
        n.frame(30, pads=0)
    n.frame(5, pads=START)
    for _ in range(3000):
        n.frame(1, pads=0)
        if racing(n):
            return
    raise RuntimeError('race did not start')


def install_payload(n):
    """Copy the add-on code into PRG-RAM and initialise it like the boot code
    does (used after loading a state that was made with the original ROM)."""
    data = open(PAYLOAD, 'rb').read()
    for i, v in enumerate(data):
        n[0x6000 + i] = v
    syms = labels()
    for i in range(18):
        n[syms['title_text'] + i] = data[syms['title_1p'] - 0x6000 + i]
