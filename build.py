#!/usr/bin/env python3
"""Build the R.C. Pro-Am 2 player patch.

usage: build.py path/to/R.C._Pro-Am_(USA)_(Rev_1).nes [out_dir]

Assembles src/mp.s with ca65/ld65, applies the hooks below to a copy of the
original ROM and writes:
  out_dir/rcproam_2p.nes   patched ROM (for testing)
  out_dir/../rcproam_2p.ips (the patch, written to the repository root)
"""
import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PRG_MD5 = None  # filled from the header check below
ROM_MD5 = '6e628438de2d8d4c2f3166461cd441ab'   # md5 of PRG+CHR (no header), USA Rev 1


def assemble(build_dir):
    os.makedirs(build_dir, exist_ok=True)
    obj = os.path.join(build_dir, 'mp.o')
    subprocess.check_call(['ca65', '-g', os.path.join(HERE, 'src', 'mp.s'), '-o', obj,
                           '-l', os.path.join(build_dir, 'mp.lst')])
    subprocess.check_call(['ld65', '-C', os.path.join(HERE, 'src', 'mp.cfg'), obj,
                           '-o', os.path.join(build_dir, 'mp.bin'),
                           '-Ln', os.path.join(build_dir, 'mp.lbl'),
                           '-m', os.path.join(build_dir, 'mp.map')], cwd=build_dir)
    syms = {}
    for line in open(os.path.join(build_dir, 'mp.lbl')):
        parts = line.split()
        if len(parts) == 3 and parts[0] == 'al':
            syms[parts[2].lstrip('.')] = int(parts[1], 16)
    payload = open(os.path.join(build_dir, 'mp.bin'), 'rb').read()
    loader = open(os.path.join(build_dir, 'loader.bin'), 'rb').read()
    return syms, payload, loader


def lo(v): return v & 0xFF
def hi(v): return v >> 8
def jsr(v): return [0x20, lo(v), hi(v)]
def jmp(v): return [0x4C, lo(v), hi(v)]
NOP = 0xEA


def hooks(s):
    """(cpu address, original bytes, new bytes)"""
    return [
        # boot: copy the add-on code to PRG-RAM
        (0x8028, [0x20, 0x0C, 0xA1], jsr(0xF8D1)),
        # object loop, cars 0-3
        (0x9BBF, [0x20, 0x68, 0x80], jsr(s['h_dispatch'])),
        # per-frame work after the objects moved
        (0x9BF2, [0x20, 0xD9, 0xBB], jsr(s['h_items'])),
        (0x9BF5, [0x20, 0xB9, 0x93], jsr(s['h_frame'])),
        (0x9BF8, [0x20, 0x6A, 0xEC], jsr(s['h_oam'])),
        # scenery/items around the followed car
        (0xBBD9, [0xAD, 0x3C, 0x05], [0xAD, lo(s['cam_sector']), hi(s['cam_sector'])]),
        (0xBBE7, [0xAD, 0x3C, 0x05], [0xAD, lo(s['cam_sector']), hi(s['cam_sector'])]),
        (0xBBED, [0xAD, 0x3C, 0x05], [0xAD, lo(s['cam_sector']), hi(s['cam_sector'])]),
        # camera (calls from the player car code)
        (0xB63D, [0x20, 0x48, 0xA7], jsr(s['h_camera'])),
        (0xB491, [0x20, 0x48, 0xA7], jsr(s['h_camera'])),
        # player car sprite (normal / spinning)
        (0xB645, [0xA9, 0x7C, 0x99, 0x02, 0x03, 0xA9], jsr(s['h_plsprite']) + jmp(0xB657)),
        (0xB657, [0x8A, 0x85, 0x14], jsr(s['h_pal'])),
        (0xB690, [0x8A, 0x99, 0x07, 0x03], jsr(s['h_owner']) + [NOP]),
        # player car sprite (crashed)
        (0xB4A3, [0xA9, 0x7C, 0x99, 0x02, 0x03, 0xA9], jsr(s['h_plsprite']) + jmp(0xB4AD)),
        (0xB4B2, [0xA9, 0x00, 0x99, 0x03, 0x03, 0x99, 0x05, 0x03], [NOP] + jmp(0xB4BA)),
        (0xB4BA, [0x8A, 0x99, 0x06, 0x03], jsr(s['h_pal7']) + [NOP]),
        (0xB4CB, [0x8A, 0x99, 0x07, 0x03], jsr(s['h_owner']) + [NOP]),
        # race result
        (0xAA31, [0xAD, 0x50, 0x04], jsr(s['h_finish'])),
        # title screen
        (0xD0D1, [0xA2, 0x33, 0xA0, 0xD0], [0xA2, lo(s['title_text']), 0xA0, hi(s['title_text'])]),
        (0xD120, [0x4C, 0xB6, 0x91], jmp(s['h_title'])),
    ]


def make_ips(orig, new):
    out = bytearray(b'PATCH')
    n = len(new)
    i = 0
    orig = orig + bytes(max(0, n - len(orig)))
    while i < n:
        if new[i] == orig[i] and i < len(orig):
            i += 1
            continue
        # start of a changed run; extend while different (allow small equal gaps)
        j = i
        while j < n and j - i < 0xFFFF:
            if new[j] != orig[j]:
                j += 1
                continue
            k = j
            while k < n and new[k] == orig[k] and k - j < 6:
                k += 1
            if k < n and k - j < 6 and new[k] != orig[k]:
                j = k
                continue
            break
        chunk = new[i:j]
        if i == 0x454F46:
            raise Exception('IPS offset collides with EOF marker')
        # RLE for long runs of one byte
        if len(chunk) > 8 and chunk.count(chunk[0]) == len(chunk):
            out += i.to_bytes(3, 'big') + b'\0\0' + len(chunk).to_bytes(2, 'big') + bytes([chunk[0]])
        else:
            out += i.to_bytes(3, 'big') + len(chunk).to_bytes(2, 'big') + chunk
        i = j
    out += b'EOF'
    return bytes(out)


def main():
    rom_path = sys.argv[1]
    build_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, 'build')
    orig = open(rom_path, 'rb').read()
    if orig[:4] != b'NES\x1a' or hashlib.md5(orig[16:]).hexdigest() != ROM_MD5:
        sys.exit('expected R.C. Pro-Am (USA) (Rev 1) - md5 of PRG+CHR does not match')
    syms, payload, loader = assemble(build_dir)
    assert len(payload) == 0x2000 and len(loader) <= 47

    rom = bytearray(orig)
    prg = 16

    def put(addr, old, new):
        off = prg + addr - 0x8000
        cur = list(rom[off:off + len(old)])
        if cur != old:
            sys.exit('unexpected bytes at %04X: %s' % (addr, ' '.join('%02X' % b for b in cur)))
        assert len(new) <= len(old) or old == [], hex(addr)
        rom[off:off + len(new)] = bytes(new)

    put(0xF8D1, [0xFF] * len(loader), list(loader))
    for addr, old, new in hooks(syms):
        put(addr, old, new)

    # header: NES 2.0, mapper 1, 32KB PRG, 64KB CHR, 8KB PRG-RAM
    rom[4] = 2
    rom[5] = 8
    rom[6] = 0x10
    rom[7] = 0x08
    rom[8] = 0
    rom[9] = 0
    rom[10] = 0x07
    rom[11] = 0
    rom[12] = 0
    rom[13:16] = b'\0\0\0'
    # CHR banks 8+9: add-on code, 10-15: unused
    rom += payload + bytes(0x6000)

    out_rom = os.path.join(build_dir, 'rcproam_2p.nes')
    open(out_rom, 'wb').write(rom)
    ips = make_ips(orig, bytes(rom))
    open(os.path.join(HERE, 'rcproam_2p.ips'), 'wb').write(ips)
    print('wrote', out_rom, 'and rcproam_2p.ips (%d bytes)' % len(ips))


if __name__ == '__main__':
    main()
