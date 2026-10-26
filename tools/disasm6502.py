"""Coverage-assisted 6502 disassembler used to study the original game.

usage: dis.py prg.bin base coverage.npy out.s [labels.txt]
Code is anything executed in the coverage map plus anything statically
reachable from it; everything else is emitted as data bytes.
"""
import sys
import numpy as np

OPS = {}
_tbl = """
00 brk imp;01 ora izx;05 ora zp;06 asl zp;08 php imp;09 ora imm;0a asl acc;0d ora abs;0e asl abs
10 bpl rel;11 ora izy;15 ora zpx;16 asl zpx;18 clc imp;19 ora aby;1d ora abx;1e asl abx
20 jsr abs;21 and izx;24 bit zp;25 and zp;26 rol zp;28 plp imp;29 and imm;2a rol acc;2c bit abs;2d and abs;2e rol abs
30 bmi rel;31 and izy;35 and zpx;36 rol zpx;38 sec imp;39 and aby;3d and abx;3e rol abx
40 rti imp;41 eor izx;45 eor zp;46 lsr zp;48 pha imp;49 eor imm;4a lsr acc;4c jmp abs;4d eor abs;4e lsr abs
50 bvc rel;51 eor izy;55 eor zpx;56 lsr zpx;58 cli imp;59 eor aby;5d eor abx;5e lsr abx
60 rts imp;61 adc izx;65 adc zp;66 ror zp;68 pla imp;69 adc imm;6a ror acc;6c jmp ind;6d adc abs;6e ror abs
70 bvs rel;71 adc izy;75 adc zpx;76 ror zpx;78 sei imp;79 adc aby;7d adc abx;7e ror abx
81 sta izx;84 sty zp;85 sta zp;86 stx zp;88 dey imp;8a txa imp;8c sty abs;8d sta abs;8e stx abs
90 bcc rel;91 sta izy;94 sty zpx;95 sta zpx;96 stx zpy;98 tya imp;99 sta aby;9a txs imp;9d sta abx
a0 ldy imm;a1 lda izx;a2 ldx imm;a4 ldy zp;a5 lda zp;a6 ldx zp;a8 tay imp;a9 lda imm;aa tax imp;ac ldy abs;ad lda abs;ae ldx abs
b0 bcs rel;b1 lda izy;b4 ldy zpx;b5 lda zpx;b6 ldx zpy;b8 clv imp;b9 lda aby;ba tsx imp;bc ldy abx;bd lda abx;be ldx aby
c0 cpy imm;c1 cmp izx;c4 cpy zp;c5 cmp zp;c6 dec zp;c8 iny imp;c9 cmp imm;ca dex imp;cc cpy abs;cd cmp abs;ce dec abs
d0 bne rel;d1 cmp izy;d5 cmp zpx;d6 dec zpx;d8 cld imp;d9 cmp aby;dd cmp abx;de dec abx
e0 cpx imm;e1 sbc izx;e4 cpx zp;e5 sbc zp;e6 inc zp;e8 inx imp;e9 sbc imm;ea nop imp;ec cpx abs;ed sbc abs;ee inc abs
f0 beq rel;f1 sbc izy;f5 sbc zpx;f6 inc zpx;f8 sed imp;f9 sbc aby;fd sbc abx;fe inc abx
"""
for line in _tbl.split('\n'):
    for item in line.split(';'):
        item = item.strip()
        if item:
            h, m, mode = item.split()
            OPS[int(h, 16)] = (m, mode)
SIZE = {'imp': 1, 'acc': 1, 'imm': 2, 'zp': 2, 'zpx': 2, 'zpy': 2, 'izx': 2, 'izy': 2, 'rel': 2,
        'abs': 3, 'abx': 3, 'aby': 3, 'ind': 3}


def load_labels(path):
    labels = {}
    if path:
        for line in open(path):
            line = line.split('#')[0].strip()
            if not line:
                continue
            a, name = line.split()[:2]
            labels[int(a, 16)] = name
    return labels


def disassemble(prg, base, cov, labels):
    n = len(prg)
    code = np.zeros(n, bool)
    start = np.zeros(n, bool)
    todo = [i for i in range(n) if cov[i]]
    seen = set()
    while todo:
        i = todo.pop()
        while 0 <= i < n and i not in seen:
            op = prg[i]
            if op not in OPS:
                break
            m, mode = OPS[op]
            sz = SIZE[mode]
            if i + sz > n:
                break
            seen.add(i)
            start[i] = True
            code[i:i + sz] = True
            if mode == 'rel':
                t = i + 2 + (prg[i + 1] - 256 if prg[i + 1] > 127 else prg[i + 1])
                todo.append(t)
            if m == 'jsr' or (m == 'jmp' and mode == 'abs'):
                t = prg[i + 1] | prg[i + 2] << 8
                if base <= t < base + n:
                    todo.append(t - base)
            if m in ('rts', 'rti', 'brk') or m == 'jmp':
                break
            if m == 'jsr' and not cov[i + 3] and cov[i]:
                # could be a jsr to a routine that does not return (jump table); trust coverage
                pass
            i += sz
    # collect referenced labels
    refs = set()
    for i in range(n):
        if start[i]:
            m, mode = OPS[prg[i]]
            if mode == 'rel':
                refs.add(base + i + 2 + (prg[i + 1] - 256 if prg[i + 1] > 127 else prg[i + 1]))
            elif mode in ('abs', 'abx', 'aby', 'ind'):
                refs.add(prg[i + 1] | prg[i + 2] << 8)
    return code, start, refs


def fmt_operand(mode, val, name):
    return {'imp': '', 'acc': 'a', 'imm': '#$%02X' % val, 'zp': name, 'zpx': name + ',x', 'zpy': name + ',y',
            'izx': '(%s,x)' % name, 'izy': '(%s),y' % name, 'rel': name, 'abs': name, 'abx': name + ',x',
            'aby': name + ',y', 'ind': '(%s)' % name}[mode]


def main():
    prg = open(sys.argv[1], 'rb').read()
    base = int(sys.argv[2], 16)
    cov = np.load(sys.argv[3])
    out = open(sys.argv[4], 'w')
    labels = load_labels(sys.argv[5] if len(sys.argv) > 5 else None)
    code, start, refs = disassemble(prg, base, cov, labels)

    def lab(a, zp=False):
        if a in labels:
            return labels[a]
        if base <= a < base + len(prg) and (a in refs):
            return 'L%04X' % a
        return ('$%02X' % a) if zp else ('$%04X' % a)

    i = 0
    n = len(prg)
    while i < n:
        a = base + i
        if a in labels or (a in refs and base <= a):
            out.write('%s:\n' % lab(a))
        if start[i]:
            m, mode = OPS[prg[i]]
            sz = SIZE[mode]
            if mode in ('zp', 'zpx', 'zpy', 'izx', 'izy'):
                v = prg[i + 1]; name = labels.get(v, '$%02X' % v)
            elif mode == 'imm':
                v = prg[i + 1]; name = ''
            elif mode == 'rel':
                v = base + i + 2 + (prg[i + 1] - 256 if prg[i + 1] > 127 else prg[i + 1]); name = lab(v)
            elif sz == 3:
                v = prg[i + 1] | prg[i + 2] << 8; name = lab(v)
            else:
                v = 0; name = ''
            c = ' ' if cov[i] else '?'
            out.write('  %04X %-9s %s %s %s\n' % (a, ' '.join('%02X' % b for b in prg[i:i + sz]), c, m, fmt_operand(mode, v, name)))
            i += sz
        else:
            j = i
            while j < n and not start[j] and j - i < 8 and not (j > i and ((base + j) in refs or (base + j) in labels)):
                j += 1
            out.write('  %04X .byte %s\n' % (a, ','.join('$%02X' % b for b in prg[i:j])))
            i = j


if __name__ == '__main__':
    main()
