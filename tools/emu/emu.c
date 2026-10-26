/*
 * Minimal NES emulator used for testing the patch.
 * Supports NROM / MMC1 / AxROM, scanline renderer, standard controllers and
 * the NES Four Score adapter.  Includes debugging hooks (breakpoints, memory
 * watches, execution counters) exposed through a small C API for ctypes.
 */
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

typedef struct {
    /* CPU */
    uint8_t a, x, y, s, p;
    uint16_t pc;
    uint64_t cycles;
    int nmi_pending;
    int irq_line;
    /* memory */
    uint8_t ram[0x800];
    uint8_t wram[0x2000];
    /* PPU */
    uint8_t vram[0x1000];
    uint8_t chrram[0x2000];
    uint8_t pal[32];
    uint8_t oam[256];
    uint8_t ctrl, mask, status, oamaddr;
    uint16_t v, t;
    uint8_t fx, w, rbuf;
    int scanline, dot;
    uint64_t frame;
    int frame_done;
    uint16_t line_v;
    uint8_t line_fx;
    int odd;
    /* mapper */
    int mapper;
    uint8_t m1_shift, m1_count, m1_ctrl, m1_chr0, m1_chr1, m1_prg;
    uint8_t ax_bank;
    /* input */
    uint32_t pads;       /* p1 | p2<<8 | p3<<16 | p4<<24 */
    uint32_t sh[2];
    int strobe;
    int fourscore;
    /* open bus */
    uint8_t bus;
} State;

static State S;
static uint8_t *prg = 0; static uint32_t prg_size = 0;
static uint8_t *chr = 0; static uint32_t chr_size = 0;
static int chr_is_ram = 0;
static int mirroring_v = 0;
uint8_t fb[256 * 240];

/* debug */
uint32_t exec_addr[65536];
uint32_t *exec_prg = 0;   /* per PRG-ROM byte */
uint8_t bp[65536];
uint8_t wwatch[65536];
uint8_t rwatch[65536];
typedef struct { uint32_t frame; uint16_t pc; uint16_t addr; uint8_t val; uint8_t kind; uint8_t a, x, y, s; uint16_t line; uint32_t icount; } Ev;
uint32_t icount = 0;
#define MAXEV 4000000
Ev events[MAXEV];
uint32_t nevents = 0;
int hit = 0; uint16_t hit_pc = 0; uint16_t cur_pc = 0;
#define TRACE_N (1 << 20)
uint32_t trace_buf[TRACE_N][2];
uint32_t trace_pos = 0;
int trace_on = 0;

static inline uint32_t prg_off(uint16_t addr) {
    if (S.mapper == 1) {
        int mode = (S.m1_ctrl >> 2) & 3;
        uint32_t nb = prg_size / 0x4000;
        uint32_t bank;
        if (mode < 2) {
            bank = (S.m1_prg & 0x0E) % nb;
            return (bank * 0x4000 + (addr - 0x8000)) % prg_size;
        } else if (mode == 2) {
            bank = addr < 0xC000 ? 0 : (S.m1_prg & 0x0F) % nb;
        } else {
            bank = addr < 0xC000 ? (S.m1_prg & 0x0F) % nb : nb - 1;
        }
        return bank * 0x4000 + (addr & 0x3FFF);
    } else if (S.mapper == 7) {
        return ((S.ax_bank & 7) * 0x8000 + (addr - 0x8000)) % prg_size;
    }
    return (addr - 0x8000) % prg_size;
}

static inline uint8_t *chr_ptr(uint16_t addr) {
    if (chr_is_ram) return &S.chrram[addr & 0x1FFF];
    if (S.mapper == 1) {
        uint32_t off;
        if (S.m1_ctrl & 0x10) {
            uint32_t b = addr < 0x1000 ? S.m1_chr0 : S.m1_chr1;
            off = b * 0x1000 + (addr & 0xFFF);
        } else {
            off = (S.m1_chr0 & 0x1E) * 0x1000 + (addr & 0x1FFF);
        }
        return &chr[off % chr_size];
    }
    return &chr[addr % chr_size];
}

static inline uint16_t nt_addr(uint16_t addr) {
    addr &= 0xFFF;
    if (S.mapper == 1) {
        switch (S.m1_ctrl & 3) {
        case 0: return addr & 0x3FF;
        case 1: return 0x400 | (addr & 0x3FF);
        case 2: return addr & 0x7FF;               /* vertical */
        default: return ((addr >> 1) & 0x400) | (addr & 0x3FF); /* horizontal */
        }
    } else if (S.mapper == 7) {
        return (S.ax_bank & 0x10 ? 0x400 : 0) | (addr & 0x3FF);
    }
    return mirroring_v ? (addr & 0x7FF) : (((addr >> 1) & 0x400) | (addr & 0x3FF));
}

static uint8_t ppu_rd(uint16_t addr) {
    addr &= 0x3FFF;
    if (addr < 0x2000) return *chr_ptr(addr);
    if (addr < 0x3F00) return S.vram[nt_addr(addr)];
    addr &= 0x1F;
    if ((addr & 0x13) == 0x10) addr &= 0x0F;
    return S.pal[addr];
}
static void ppu_wr(uint16_t addr, uint8_t v) {
    addr &= 0x3FFF;
    if (addr < 0x2000) { if (chr_is_ram) S.chrram[addr] = v; return; }
    if (addr < 0x3F00) { S.vram[nt_addr(addr)] = v; return; }
    addr &= 0x1F;
    if ((addr & 0x13) == 0x10) addr &= 0x0F;
    S.pal[addr] = v & 0x3F;
}

/* ---------------- rendering ---------------- */
static void render_line(int y) {
    uint8_t bgpix[256], bgop[256];
    uint8_t *out = &fb[y * 256];
    uint16_t v = S.line_v;
    int fx = S.line_fx;
    int show_bg = S.mask & 0x08, show_sp = S.mask & 0x10;
    memset(bgop, 0, 256);
    if (show_bg) {
        int fine_y = (v >> 12) & 7;
        int x = -fx;
        for (int tile = 0; tile < 33; tile++) {
            uint16_t ntad = 0x2000 | (v & 0x0FFF);
            uint8_t tidx = ppu_rd(ntad);
            uint16_t atad = 0x23C0 | (v & 0x0C00) | ((v >> 4) & 0x38) | ((v >> 2) & 0x07);
            uint8_t at = ppu_rd(atad);
            int shift = ((v >> 4) & 4) | (v & 2);
            int palhi = (at >> shift) & 3;
            uint16_t pt = ((S.ctrl & 0x10) ? 0x1000 : 0) + tidx * 16 + fine_y;
            uint8_t lo = ppu_rd(pt), hi = ppu_rd(pt + 8);
            for (int b = 0; b < 8; b++, x++) {
                if (x < 0 || x > 255) continue;
                int c = ((lo >> (7 - b)) & 1) | (((hi >> (7 - b)) & 1) << 1);
                bgpix[x] = c ? (palhi << 2 | c) : 0;
                bgop[x] = c != 0;
            }
            /* increment coarse x */
            if ((v & 0x1F) == 31) { v &= ~0x1F; v ^= 0x400; } else v++;
        }
        if (!(S.mask & 0x02)) for (int i = 0; i < 8; i++) { bgpix[i] = 0; bgop[i] = 0; }
    } else memset(bgpix, 0, 256);
    for (int i = 0; i < 256; i++) out[i] = ppu_rd(0x3F00 + (bgop[i] ? bgpix[i] : 0));
    if (show_sp) {
        int h = (S.ctrl & 0x20) ? 16 : 8;
        int count = 0;
        uint8_t spdone[256]; memset(spdone, 0, 256);
        for (int i = 0; i < 64; i++) {
            int sy = S.oam[i * 4] + 1;
            if (y < sy || y >= sy + h) continue;
            if (++count > 8) { S.status |= 0x20; break; }
            uint8_t tidx = S.oam[i * 4 + 1], attr = S.oam[i * 4 + 2];
            int sx = S.oam[i * 4 + 3];
            int row = y - sy;
            if (attr & 0x80) row = h - 1 - row;
            uint16_t pt;
            if (h == 16) {
                pt = ((tidx & 1) ? 0x1000 : 0) + (tidx & 0xFE) * 16;
                if (row >= 8) { pt += 16; row -= 8; }
            } else pt = ((S.ctrl & 0x08) ? 0x1000 : 0) + tidx * 16;
            uint8_t lo = ppu_rd(pt + row), hi = ppu_rd(pt + row + 8);
            for (int b = 0; b < 8; b++) {
                int px = sx + b;
                if (px > 255) break;
                int bit = (attr & 0x40) ? b : 7 - b;
                int c = ((lo >> bit) & 1) | (((hi >> bit) & 1) << 1);
                if (!c) continue;
                if (px < 8 && !(S.mask & 0x04)) continue;
                if (i == 0 && bgop[px] && px != 255 && show_bg) S.status |= 0x40;
                if (spdone[px]) continue;
                spdone[px] = 1;
                if ((attr & 0x20) && bgop[px]) continue;
                out[px] = ppu_rd(0x3F10 + ((attr & 3) << 2) + c);
            }
        }
    }
}

static void cpu_nmi(void);
static inline int rendering(void) { return S.mask & 0x18; }

static void ppu_step(void) {
    /* one dot */
    if (S.scanline < 240) {
        if (S.dot == 1) { S.line_v = S.v; S.line_fx = S.fx; }
        if (S.dot == 256) {
            render_line(S.scanline);
            if (rendering()) {
                /* increment y */
                if ((S.v & 0x7000) != 0x7000) S.v += 0x1000;
                else {
                    S.v &= ~0x7000;
                    int cy = (S.v & 0x3E0) >> 5;
                    if (cy == 29) { cy = 0; S.v ^= 0x800; }
                    else if (cy == 31) cy = 0;
                    else cy++;
                    S.v = (S.v & ~0x3E0) | (cy << 5);
                }
            }
        }
        if (S.dot == 257 && rendering()) S.v = (S.v & ~0x41F) | (S.t & 0x41F);
    } else if (S.scanline == 241 && S.dot == 1) {
        S.status |= 0x80;
        if (S.ctrl & 0x80) S.nmi_pending = 1;
        S.frame_done = 1;
    } else if (S.scanline == 261) {
        if (S.dot == 1) S.status &= ~0xE0;
        if (S.dot == 257 && rendering()) S.v = (S.v & ~0x41F) | (S.t & 0x41F);
        if (S.dot >= 280 && S.dot <= 304 && rendering()) S.v = (S.v & ~0x7BE0) | (S.t & 0x7BE0);
    }
    if (++S.dot > 340) {
        S.dot = 0;
        if (++S.scanline > 261) { S.scanline = 0; S.frame++; S.odd ^= 1; }
    }
}

static uint8_t ppu_reg_rd(int r) {
    uint8_t v = S.bus;
    switch (r) {
    case 2:
        v = (S.status & 0xE0) | (S.bus & 0x1F);
        S.status &= ~0x80; S.w = 0;
        break;
    case 4: v = S.oam[S.oamaddr]; break;
    case 7:
        if ((S.v & 0x3FFF) < 0x3F00) { v = S.rbuf; S.rbuf = ppu_rd(S.v); }
        else { v = ppu_rd(S.v); S.rbuf = ppu_rd(S.v - 0x1000); }
        S.v += (S.ctrl & 4) ? 32 : 1;
        break;
    }
    return v;
}
static void ppu_reg_wr(int r, uint8_t v) {
    switch (r) {
    case 0:
        if (!(S.ctrl & 0x80) && (v & 0x80) && (S.status & 0x80)) S.nmi_pending = 1;
        S.ctrl = v; S.t = (S.t & ~0xC00) | ((v & 3) << 10); break;
    case 1: S.mask = v; break;
    case 3: S.oamaddr = v; break;
    case 4: S.oam[S.oamaddr++] = v; break;
    case 5:
        if (!S.w) { S.t = (S.t & ~0x1F) | (v >> 3); S.fx = v & 7; S.w = 1; }
        else { S.t = (S.t & ~0x73E0) | ((v & 7) << 12) | ((v & 0xF8) << 2); S.w = 0; }
        break;
    case 6:
        if (!S.w) { S.t = (S.t & 0xFF) | ((v & 0x3F) << 8); S.w = 1; }
        else { S.t = (S.t & 0xFF00) | v; S.v = S.t; S.w = 0; }
        break;
    case 7:
        ppu_wr(S.v, v);
        S.v += (S.ctrl & 4) ? 32 : 1;
        break;
    }
}

/* ---------------- bus ---------------- */
static void tick(int n) {
    for (int i = 0; i < n * 3; i++) ppu_step();
    S.cycles += n;
}

static uint8_t pad_bit(int port) {
    uint8_t r;
    if (S.strobe) {
        r = (port == 0 ? S.pads : S.pads >> 8) & 1;
        return r;
    }
    r = S.sh[port] & 1;
    S.sh[port] = (S.sh[port] >> 1) | 0x80000000u;
    return r;
}
static void pad_latch(void) {
    uint32_t p1 = S.pads & 0xFF, p2 = (S.pads >> 8) & 0xFF, p3 = (S.pads >> 16) & 0xFF, p4 = S.pads >> 24;
    if (S.fourscore) {
        S.sh[0] = p1 | (p3 << 8) | (0x08u << 16) | 0xFF000000u;
        S.sh[1] = p2 | (p4 << 8) | (0x04u << 16) | 0xFF000000u;
    } else {
        S.sh[0] = p1 | 0xFFFFFF00u;
        S.sh[1] = p2 | 0xFFFFFF00u;
    }
}

static uint8_t rd(uint16_t addr) {
    uint8_t v;
    if (addr < 0x2000) v = S.ram[addr & 0x7FF];
    else if (addr < 0x4000) v = ppu_reg_rd(addr & 7);
    else if (addr == 0x4016) v = (S.bus & 0xE0) | pad_bit(0);
    else if (addr == 0x4017) v = (S.bus & 0xE0) | pad_bit(1);
    else if (addr < 0x6000) v = S.bus;
    else if (addr < 0x8000) v = S.wram[addr & 0x1FFF];
    else v = prg[prg_off(addr)];
    if (rwatch[addr]) {
        if (nevents < MAXEV) events[nevents++] = (Ev){(uint32_t)S.frame, cur_pc, addr, v, 0, S.a, S.x, S.y, S.s, (uint16_t)S.scanline, icount};
        if (rwatch[addr] & 2) { hit = 1; hit_pc = cur_pc; }
    }
    S.bus = v;
    return v;
}

static void mapper_wr(uint16_t addr, uint8_t v) {
    if (S.mapper == 1) {
        if (v & 0x80) { S.m1_shift = 0; S.m1_count = 0; S.m1_ctrl |= 0x0C; return; }
        S.m1_shift |= (v & 1) << S.m1_count;
        if (++S.m1_count == 5) {
            uint8_t d = S.m1_shift;
            switch ((addr >> 13) & 3) {
            case 0: S.m1_ctrl = d; break;
            case 1: S.m1_chr0 = d; break;
            case 2: S.m1_chr1 = d; break;
            case 3: S.m1_prg = d; break;
            }
            S.m1_shift = 0; S.m1_count = 0;
        }
    } else if (S.mapper == 7) {
        S.ax_bank = v;
    }
}

static void wr(uint16_t addr, uint8_t v) {
    if (wwatch[addr]) {
        if (nevents < MAXEV) events[nevents++] = (Ev){(uint32_t)S.frame, cur_pc, addr, v, 1, S.a, S.x, S.y, S.s, (uint16_t)S.scanline, icount};
        if (wwatch[addr] & 2) { hit = 1; hit_pc = cur_pc; }
    }
    S.bus = v;
    if (addr < 0x2000) S.ram[addr & 0x7FF] = v;
    else if (addr < 0x4000) ppu_reg_wr(addr & 7, v);
    else if (addr == 0x4014) {
        for (int i = 0; i < 256; i++) S.oam[(S.oamaddr + i) & 0xFF] = rd((v << 8) | i);
        tick(513 + (S.cycles & 1));
    } else if (addr == 0x4016) {
        int ns = v & 1;
        if (S.strobe && !ns) pad_latch();
        if (ns) pad_latch();
        S.strobe = ns;
    } else if (addr < 0x6000) { /* APU ignored */ }
    else if (addr < 0x8000) S.wram[addr & 0x1FFF] = v;
    else mapper_wr(addr, v);
}

/* ---------------- CPU ---------------- */
#define FC 0x01
#define FZ 0x02
#define FI 0x04
#define FD 0x08
#define FB 0x10
#define FU 0x20
#define FV 0x40
#define FN 0x80
static inline void setzn(uint8_t v) { S.p = (S.p & ~(FZ | FN)) | (v ? 0 : FZ) | (v & 0x80); }
static inline void push(uint8_t v) { wr(0x100 | S.s--, v); }
static inline uint8_t pop(void) { return rd(0x100 | ++S.s); }

static void cpu_nmi(void) {
    push(S.pc >> 8); push(S.pc & 0xFF); push((S.p | FU) & ~FB);
    S.p |= FI;
    S.pc = rd(0xFFFA) | (rd(0xFFFB) << 8);
    tick(7);
}
static void cpu_irq(void) {
    push(S.pc >> 8); push(S.pc & 0xFF); push((S.p | FU) & ~FB);
    S.p |= FI;
    S.pc = rd(0xFFFE) | (rd(0xFFFF) << 8);
    tick(7);
}

static const uint8_t cyc[256] = {
 7,6,2,8,3,3,5,5,3,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
 6,6,2,8,3,3,5,5,4,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
 6,6,2,8,3,3,5,5,3,2,2,2,3,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
 6,6,2,8,3,3,5,5,4,2,2,2,5,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
 2,6,2,6,3,3,3,3,2,2,2,2,4,4,4,4, 2,6,2,6,4,4,4,4,2,5,2,5,5,5,5,5,
 2,6,2,6,3,3,3,3,2,2,2,2,4,4,4,4, 2,5,2,5,4,4,4,4,2,4,2,4,4,4,4,4,
 2,6,2,8,3,3,5,5,2,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
 2,6,2,8,3,3,5,5,2,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7 };

int jammed = 0;

static void adc(uint8_t m) {
    unsigned r = S.a + m + (S.p & FC);
    S.p = (S.p & ~(FC | FV)) | (r > 0xFF ? FC : 0) | ((~(S.a ^ m) & (S.a ^ r) & 0x80) ? FV : 0);
    S.a = r; setzn(S.a);
}
static void cmp(uint8_t r, uint8_t m) { S.p = (S.p & ~FC) | (r >= m ? FC : 0); setzn(r - m); }

static int step_cpu(void) {
    if (S.nmi_pending) { S.nmi_pending = 0; cpu_nmi(); }
    else if (S.irq_line && !(S.p & FI)) cpu_irq();
    cur_pc = S.pc;
    icount++;
    exec_addr[S.pc]++;
    if (S.pc >= 0x8000 && exec_prg) exec_prg[prg_off(S.pc)]++;
    if (trace_on) { trace_buf[trace_pos][0] = S.pc | (S.a << 16) | (S.x << 24); trace_buf[trace_pos][1] = S.y | (S.s << 8) | (S.p << 16) | ((uint32_t)(S.cycles & 0xFF) << 24); trace_pos = (trace_pos + 1) & (TRACE_N - 1); }
    if (bp[S.pc]) { hit = 1; hit_pc = S.pc; if (bp[S.pc] & 4) { bp[S.pc] = 0; } return 1; }
    uint8_t op = rd(S.pc++);
    int extra = 0;
    uint16_t ad = 0;
    uint8_t m;
    /* addressing */
    int mode;
    static const uint8_t modes[256] = {
    /* 0 imp,1 imm,2 zp,3 zpx,4 zpy,5 abs,6 abx,7 aby,8 izx,9 izy,10 rel,11 ind,12 acc */
     0,8,0,8,2,2,2,2,0,1,12,1,5,5,5,5, 10,9,0,9,3,3,3,3,0,7,0,7,6,6,6,6,
     5,8,0,8,2,2,2,2,0,1,12,1,5,5,5,5, 10,9,0,9,3,3,3,3,0,7,0,7,6,6,6,6,
     0,8,0,8,2,2,2,2,0,1,12,1,5,5,5,5, 10,9,0,9,3,3,3,3,0,7,0,7,6,6,6,6,
     0,8,0,8,2,2,2,2,0,1,12,1,11,5,5,5, 10,9,0,9,3,3,3,3,0,7,0,7,6,6,6,6,
     1,8,1,8,2,2,2,2,0,1,0,1,5,5,5,5, 10,9,0,9,3,3,4,4,0,7,0,7,6,6,7,7,
     1,8,1,8,2,2,2,2,0,1,0,1,5,5,5,5, 10,9,0,9,3,3,4,4,0,7,0,7,6,6,7,7,
     1,8,1,8,2,2,2,2,0,1,0,1,5,5,5,5, 10,9,0,9,3,3,3,3,0,7,0,7,6,6,6,6,
     1,8,1,8,2,2,2,2,0,1,0,1,5,5,5,5, 10,9,0,9,3,3,3,3,0,7,0,7,6,6,6,6 };
    mode = modes[op];
    int pagex = 0;
    switch (mode) {
    case 1: ad = S.pc++; break;
    case 2: ad = rd(S.pc++); break;
    case 3: ad = (rd(S.pc++) + S.x) & 0xFF; break;
    case 4: ad = (rd(S.pc++) + S.y) & 0xFF; break;
    case 5: ad = rd(S.pc) | (rd(S.pc + 1) << 8); S.pc += 2; break;
    case 6: { uint16_t b = rd(S.pc) | (rd(S.pc + 1) << 8); S.pc += 2; ad = b + S.x; pagex = (b ^ ad) & 0x100; } break;
    case 7: { uint16_t b = rd(S.pc) | (rd(S.pc + 1) << 8); S.pc += 2; ad = b + S.y; pagex = (b ^ ad) & 0x100; } break;
    case 8: { uint8_t z = rd(S.pc++) + S.x; ad = rd(z) | (rd((uint8_t)(z + 1)) << 8); } break;
    case 9: { uint8_t z = rd(S.pc++); uint16_t b = rd(z) | (rd((uint8_t)(z + 1)) << 8); ad = b + S.y; pagex = (b ^ ad) & 0x100; } break;
    case 10: ad = S.pc++; break;
    case 11: { uint16_t b = rd(S.pc) | (rd(S.pc + 1) << 8); S.pc += 2; ad = rd(b) | (rd((b & 0xFF00) | ((b + 1) & 0xFF)) << 8); } break;
    }
#define RD() rd(ad)
#define BR(c) do { int8_t off = (int8_t)rd(ad); if (c) { uint16_t np = S.pc + off; extra += 1 + (((np ^ S.pc) & 0x100) ? 1 : 0); S.pc = np; } } while (0)
#define PX() do { if (pagex) extra++; } while (0)
    switch (op) {
    /* loads/stores */
    case 0xA9: case 0xA5: case 0xB5: case 0xAD: case 0xBD: case 0xB9: case 0xA1: case 0xB1: S.a = RD(); setzn(S.a); PX(); break;
    case 0xA2: case 0xA6: case 0xB6: case 0xAE: case 0xBE: S.x = RD(); setzn(S.x); PX(); break;
    case 0xA0: case 0xA4: case 0xB4: case 0xAC: case 0xBC: S.y = RD(); setzn(S.y); PX(); break;
    case 0x85: case 0x95: case 0x8D: case 0x9D: case 0x99: case 0x81: case 0x91: wr(ad, S.a); break;
    case 0x86: case 0x96: case 0x8E: wr(ad, S.x); break;
    case 0x84: case 0x94: case 0x8C: wr(ad, S.y); break;
    /* transfers */
    case 0xAA: S.x = S.a; setzn(S.x); break;
    case 0xA8: S.y = S.a; setzn(S.y); break;
    case 0x8A: S.a = S.x; setzn(S.a); break;
    case 0x98: S.a = S.y; setzn(S.a); break;
    case 0xBA: S.x = S.s; setzn(S.x); break;
    case 0x9A: S.s = S.x; break;
    /* stack */
    case 0x48: push(S.a); break;
    case 0x08: push(S.p | FB | FU); break;
    case 0x68: S.a = pop(); setzn(S.a); break;
    case 0x28: S.p = (pop() & ~FB) | FU; break;
    /* logic */
    case 0x29: case 0x25: case 0x35: case 0x2D: case 0x3D: case 0x39: case 0x21: case 0x31: S.a &= RD(); setzn(S.a); PX(); break;
    case 0x09: case 0x05: case 0x15: case 0x0D: case 0x1D: case 0x19: case 0x01: case 0x11: S.a |= RD(); setzn(S.a); PX(); break;
    case 0x49: case 0x45: case 0x55: case 0x4D: case 0x5D: case 0x59: case 0x41: case 0x51: S.a ^= RD(); setzn(S.a); PX(); break;
    case 0x24: case 0x2C: m = RD(); S.p = (S.p & ~(FZ | FV | FN)) | ((S.a & m) ? 0 : FZ) | (m & 0xC0); break;
    /* arith */
    case 0x69: case 0x65: case 0x75: case 0x6D: case 0x7D: case 0x79: case 0x61: case 0x71: adc(RD()); PX(); break;
    case 0xE9: case 0xE5: case 0xF5: case 0xED: case 0xFD: case 0xF9: case 0xE1: case 0xF1: case 0xEB: adc(~RD()); PX(); break;
    case 0xC9: case 0xC5: case 0xD5: case 0xCD: case 0xDD: case 0xD9: case 0xC1: case 0xD1: cmp(S.a, RD()); PX(); break;
    case 0xE0: case 0xE4: case 0xEC: cmp(S.x, RD()); break;
    case 0xC0: case 0xC4: case 0xCC: cmp(S.y, RD()); break;
    /* inc/dec */
    case 0xE6: case 0xF6: case 0xEE: case 0xFE: m = RD() + 1; wr(ad, m); setzn(m); break;
    case 0xC6: case 0xD6: case 0xCE: case 0xDE: m = RD() - 1; wr(ad, m); setzn(m); break;
    case 0xE8: S.x++; setzn(S.x); break;
    case 0xCA: S.x--; setzn(S.x); break;
    case 0xC8: S.y++; setzn(S.y); break;
    case 0x88: S.y--; setzn(S.y); break;
    /* shifts */
    case 0x0A: S.p = (S.p & ~FC) | (S.a >> 7); S.a <<= 1; setzn(S.a); break;
    case 0x4A: S.p = (S.p & ~FC) | (S.a & 1); S.a >>= 1; setzn(S.a); break;
    case 0x2A: { uint8_t c = S.p & FC; S.p = (S.p & ~FC) | (S.a >> 7); S.a = (S.a << 1) | c; setzn(S.a); } break;
    case 0x6A: { uint8_t c = S.p & FC; S.p = (S.p & ~FC) | (S.a & 1); S.a = (S.a >> 1) | (c << 7); setzn(S.a); } break;
    case 0x06: case 0x16: case 0x0E: case 0x1E: m = RD(); S.p = (S.p & ~FC) | (m >> 7); m <<= 1; wr(ad, m); setzn(m); break;
    case 0x46: case 0x56: case 0x4E: case 0x5E: m = RD(); S.p = (S.p & ~FC) | (m & 1); m >>= 1; wr(ad, m); setzn(m); break;
    case 0x26: case 0x36: case 0x2E: case 0x3E: { m = RD(); uint8_t c = S.p & FC; S.p = (S.p & ~FC) | (m >> 7); m = (m << 1) | c; wr(ad, m); setzn(m); } break;
    case 0x66: case 0x76: case 0x6E: case 0x7E: { m = RD(); uint8_t c = S.p & FC; S.p = (S.p & ~FC) | (m & 1); m = (m >> 1) | (c << 7); wr(ad, m); setzn(m); } break;
    /* jumps */
    case 0x4C: case 0x6C: S.pc = ad; break;
    case 0x20: { uint16_t ret = S.pc - 1; push(ret >> 8); push(ret & 0xFF); S.pc = ad; } break;
    case 0x60: { uint16_t l = pop(); uint16_t h = pop(); S.pc = ((h << 8) | l) + 1; } break;
    case 0x40: { S.p = (pop() & ~FB) | FU; uint16_t l = pop(); uint16_t h = pop(); S.pc = (h << 8) | l; } break;
    case 0x00: { S.pc++; push(S.pc >> 8); push(S.pc & 0xFF); push(S.p | FB | FU); S.p |= FI; S.pc = rd(0xFFFE) | (rd(0xFFFF) << 8); } break;
    /* branches */
    case 0x10: BR(!(S.p & FN)); break;
    case 0x30: BR(S.p & FN); break;
    case 0x50: BR(!(S.p & FV)); break;
    case 0x70: BR(S.p & FV); break;
    case 0x90: BR(!(S.p & FC)); break;
    case 0xB0: BR(S.p & FC); break;
    case 0xD0: BR(!(S.p & FZ)); break;
    case 0xF0: BR(S.p & FZ); break;
    /* flags */
    case 0x18: S.p &= ~FC; break;
    case 0x38: S.p |= FC; break;
    case 0x58: S.p &= ~FI; break;
    case 0x78: S.p |= FI; break;
    case 0xB8: S.p &= ~FV; break;
    case 0xD8: S.p &= ~FD; break;
    case 0xF8: S.p |= FD; break;
    /* nops */
    case 0xEA: case 0x1A: case 0x3A: case 0x5A: case 0x7A: case 0xDA: case 0xFA: break;
    case 0x80: case 0x82: case 0x89: case 0xC2: case 0xE2: case 0x04: case 0x44: case 0x64: case 0x14: case 0x34: case 0x54: case 0x74: case 0xD4: case 0xF4: case 0x0C: RD(); break;
    case 0x1C: case 0x3C: case 0x5C: case 0x7C: case 0xDC: case 0xFC: RD(); PX(); break;
    /* a few unofficial */
    case 0xA7: case 0xB7: case 0xAF: case 0xBF: case 0xA3: case 0xB3: S.a = S.x = RD(); setzn(S.a); PX(); break;
    case 0x87: case 0x97: case 0x8F: case 0x83: wr(ad, S.a & S.x); break;
    case 0xC7: case 0xD7: case 0xCF: case 0xDF: case 0xDB: case 0xC3: case 0xD3: m = RD() - 1; wr(ad, m); cmp(S.a, m); break;
    case 0xE7: case 0xF7: case 0xEF: case 0xFF: case 0xFB: case 0xE3: case 0xF3: m = RD() + 1; wr(ad, m); adc(~m); break;
    default:
        jammed = 1; hit = 1; hit_pc = cur_pc; S.pc = cur_pc; return 1;
    }
    tick(cyc[op] + extra);
    return 0;
}

/* ---------------- API ---------------- */
int emu_load(const uint8_t *data, int len) {
    if (len < 16 || memcmp(data, "NES\x1a", 4)) return -1;
    int prgb = data[4], chrb = data[5];
    int mapper = (data[6] >> 4) | (data[7] & 0xF0);
    if ((data[7] & 0x0C) == 0x08) mapper = (data[6] >> 4) | (data[7] & 0xF0);
    memset(&S, 0, sizeof S);
    free(prg); free(chr); free(exec_prg);
    prg_size = prgb * 0x4000; chr_size = chrb * 0x2000;
    prg = malloc(prg_size); memcpy(prg, data + 16, prg_size);
    exec_prg = calloc(prg_size, 4);
    if (chr_size) { chr = malloc(chr_size); memcpy(chr, data + 16 + prg_size, chr_size); chr_is_ram = 0; }
    else { chr = 0; chr_is_ram = 1; }
    mirroring_v = data[6] & 1;
    S.mapper = mapper;
    S.m1_ctrl = 0x0C;
    S.s = 0xFD; S.p = FI | FU;
    S.pc = rd(0xFFFC) | (rd(0xFFFD) << 8);
    S.scanline = 0; S.dot = 0;
    return mapper;
}
void emu_reset(void) {
    S.s -= 3; S.p |= FI; S.m1_ctrl |= 0x0C;
    S.pc = rd(0xFFFC) | (rd(0xFFFD) << 8);
}
void emu_set_pads(uint32_t p) { S.pads = p; }
void emu_set_fourscore(int f) { S.fourscore = f; }
/* run until end of frame; returns 1 if a breakpoint/watch hit */
int emu_frame(void) {
    hit = 0;
    if (bp[S.pc]) { uint16_t pc0 = S.pc; uint8_t sv = bp[pc0]; bp[pc0] = 0; step_cpu(); bp[pc0] = sv; if (S.frame_done) { S.frame_done = 0; return 0; } }
    while (!S.frame_done) {
        if (step_cpu() || hit) {
            if (hit) return 1;
        }
    }
    S.frame_done = 0;
    return 0;
}
/* continue after a breakpoint (executes the instruction at the breakpoint) */
int emu_step(void) {
    uint8_t save = bp[S.pc]; bp[S.pc] = 0;
    hit = 0;
    int r = step_cpu();
    bp[cur_pc] = save;
    return r;
}
int emu_state_size(void) { return sizeof(State); }
void emu_save(uint8_t *out) { memcpy(out, &S, sizeof S); }
void emu_load_state(const uint8_t *in) { memcpy(&S, in, sizeof S); }
uint8_t emu_peek(uint16_t a) {
    if (a < 0x2000) return S.ram[a & 0x7FF];
    if (a >= 0x6000 && a < 0x8000) return S.wram[a & 0x1FFF];
    if (a >= 0x8000) return prg[prg_off(a)];
    return 0;
}
void emu_poke(uint16_t a, uint8_t v) {
    if (a < 0x2000) S.ram[a & 0x7FF] = v;
    else if (a >= 0x6000 && a < 0x8000) S.wram[a & 0x1FFF] = v;
}
uint8_t emu_ppu_peek(uint16_t a) { return ppu_rd(a); }
uint32_t emu_prg_off(uint16_t a) { return prg_off(a); }
void *emu_state_ptr(void) { return &S; }
int emu_reg(int i) {
    switch (i) { case 0: return S.a; case 1: return S.x; case 2: return S.y; case 3: return S.s; case 4: return S.p; case 5: return S.pc; case 6: return S.scanline; case 7: return S.dot; case 8: return (int)S.frame; }
    return 0;
}
void emu_set_reg(int i, int v) {
    switch (i) { case 0: S.a = v; break; case 1: S.x = v; break; case 2: S.y = v; break; case 3: S.s = v; break; case 4: S.p = v; break; case 5: S.pc = v; break; }
}
uint8_t *emu_fb(void) { return fb; }
uint8_t *emu_oam(void) { return S.oam; }
uint32_t *emu_exec(void) { return exec_addr; }
uint32_t *emu_exec_prg(void) { return exec_prg; }
uint8_t *emu_bp(void) { return bp; }
uint8_t *emu_ww(void) { return wwatch; }
uint8_t *emu_rw(void) { return rwatch; }
void *emu_events(void) { return events; }
uint32_t emu_nevents(void) { uint32_t n = nevents; return n; }
void emu_clear_events(void) { nevents = 0; }
int emu_ev_size(void) { return sizeof(Ev); }
void emu_trace(int on) { trace_on = on; if (on) trace_pos = 0; }
uint32_t emu_icount(void) { return icount; }
void *emu_trace_buf(void) { return trace_buf; }
uint32_t emu_trace_pos(void) { return trace_pos; }
int emu_hit_pc(void) { return hit_pc; }
int emu_jammed(void) { return jammed; }
uint64_t emu_cycles(void) { return S.cycles; }
