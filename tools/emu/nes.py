"""ctypes wrapper around libemu.so (the small test emulator in emu.c)."""
import ctypes, math, os
import numpy as np

_here = os.path.dirname(os.path.abspath(__file__))
_count = [0]


def _load_lib():
    """Each emulator instance gets its own copy of the library (own globals)."""
    import shutil, tempfile
    _count[0] += 1
    path = os.path.join(tempfile.gettempdir(), 'libemu_%d_%d.so' % (os.getpid(), _count[0]))
    shutil.copy(os.path.join(_here, 'libemu.so'), path)
    lib = ctypes.CDLL(path)
    os.unlink(path)
    for name, res in [('emu_fb', ctypes.POINTER(ctypes.c_uint8)), ('emu_oam', ctypes.POINTER(ctypes.c_uint8)),
                      ('emu_exec', ctypes.POINTER(ctypes.c_uint32)), ('emu_exec_prg', ctypes.POINTER(ctypes.c_uint32)),
                      ('emu_bp', ctypes.POINTER(ctypes.c_uint8)), ('emu_ww', ctypes.POINTER(ctypes.c_uint8)),
                      ('emu_rw', ctypes.POINTER(ctypes.c_uint8)), ('emu_events', ctypes.c_void_p),
                      ('emu_trace_buf', ctypes.c_void_p), ('emu_nevents', ctypes.c_uint32),
                      ('emu_trace_pos', ctypes.c_uint32), ('emu_peek', ctypes.c_uint8), ('emu_ppu_peek', ctypes.c_uint8),
                      ('emu_prg_off', ctypes.c_uint32), ('emu_icount', ctypes.c_uint32), ('emu_cycles', ctypes.c_uint64)]:
        getattr(lib, name).restype = res
    lib.emu_set_pads.argtypes = [ctypes.c_uint32]
    return lib



def _palette():
    pal = []
    lo = [-0.12, 0.00, 0.31, 0.72]
    hi = [0.40, 0.68, 1.00, 1.00]
    black, white = 0.518 - 0.518, 1.962 - 0.518
    for idx in range(64):
        color, level = idx & 15, idx >> 4
        if color >= 14:
            pal.append((0, 0, 0)); continue
        y = i = q = 0.0
        for p in range(12):
            if color == 0:
                v = hi[level]
            elif color == 13:
                v = lo[level]
            else:
                v = hi[level] if (color + p) % 12 < 6 else lo[level]
            y += v / 12
            i += v * math.cos(math.pi * (p + 3.5) / 6) / 12 * 2
            q += v * math.sin(math.pi * (p + 3.5) / 6) / 12 * 2
        r = y + 0.946882 * i + 0.623557 * q
        g = y - 0.274788 * i - 0.635691 * q
        b = y - 1.108545 * i + 1.709007 * q
        pal.append(tuple(max(0, min(255, int(c * 255 / 1.0))) for c in (r, g, b)))
    return np.array(pal, dtype=np.uint8)


PALETTE = _palette()

# controller bits
A, B, SELECT, START, UP, DOWN, LEFT, RIGHT = 1, 2, 4, 8, 16, 32, 64, 128


class NES:
    def __init__(self, path_or_bytes, fourscore=False):
        self._lib = _load_lib()
        data = path_or_bytes if isinstance(path_or_bytes, (bytes, bytearray)) else open(path_or_bytes, 'rb').read()
        buf = ctypes.create_string_buffer(bytes(data), len(data))
        self.mapper = self._lib.emu_load(buf, len(data))
        self.prg_size = data[4] * 0x4000
        self._lib.emu_set_fourscore(1 if fourscore else 0)
        n = self._lib.emu_state_size()
        self._ssize = n
        self.fb = np.ctypeslib.as_array(self._lib.emu_fb(), (240, 256))
        self.oam = np.ctypeslib.as_array(self._lib.emu_oam(), (256,))
        self.exec = np.ctypeslib.as_array(self._lib.emu_exec(), (65536,))
        self.exec_prg = np.ctypeslib.as_array(self._lib.emu_exec_prg(), (self.prg_size,))
        self.bp = np.ctypeslib.as_array(self._lib.emu_bp(), (65536,))
        self.ww = np.ctypeslib.as_array(self._lib.emu_ww(), (65536,))
        self.rw = np.ctypeslib.as_array(self._lib.emu_rw(), (65536,))
        self.bp[:] = 0; self.ww[:] = 0; self.rw[:] = 0; self.exec[:] = 0
        self.pads = 0

    def fourscore(self, on):
        self._lib.emu_set_fourscore(1 if on else 0)

    def frame(self, n=1, pads=None):
        if pads is not None:
            self.pads = pads
        self._lib.emu_set_pads(self.pads)
        for _ in range(n):
            if self._lib.emu_frame():
                return True
        return False

    def step(self):
        return self._lib.emu_step()

    def save(self):
        b = ctypes.create_string_buffer(self._ssize)
        self._lib.emu_save(b)
        return b.raw

    def load(self, st):
        self._lib.emu_load_state(ctypes.create_string_buffer(st, len(st)))

    def __getitem__(self, a):
        if isinstance(a, slice):
            return bytes(self._lib.emu_peek(x) for x in range(a.start, a.stop))
        return self._lib.emu_peek(a)

    def __setitem__(self, a, v):
        self._lib.emu_poke(a, v)

    def ram(self):
        return bytes(self._lib.emu_peek(x) for x in range(0x800))

    def ppu(self, a):
        return self._lib.emu_ppu_peek(a)

    def reg(self, i):
        return self._lib.emu_reg(i)

    @property
    def pc(self): return self._lib.emu_reg(5)
    @property
    def a(self): return self._lib.emu_reg(0)
    @property
    def x(self): return self._lib.emu_reg(1)
    @property
    def y(self): return self._lib.emu_reg(2)
    @property
    def s(self): return self._lib.emu_reg(3)
    @property
    def scanline(self): return self._lib.emu_reg(6)
    @property
    def frame_no(self): return self._lib.emu_reg(8)

    def set_reg(self, i, v):
        self._lib.emu_set_reg(i, v)

    def hit_pc(self):
        return self._lib.emu_hit_pc()

    def jammed(self):
        return self._lib.emu_jammed()

    def prg_off(self, a):
        return self._lib.emu_prg_off(a)

    def events(self, clear=True):
        n = self._lib.emu_nevents()
        es = self._lib.emu_ev_size()
        raw = ctypes.string_at(self._lib.emu_events(), n * es)
        dt = np.dtype([('frame', '<u4'), ('pc', '<u2'), ('addr', '<u2'), ('val', 'u1'), ('kind', 'u1'),
                       ('a', 'u1'), ('x', 'u1'), ('y', 'u1'), ('s', 'u1'), ('line', '<u2'), ('icount', '<u4')], align=True)
        assert dt.itemsize == es, (dt.itemsize, es)
        arr = np.frombuffer(raw, dtype=dt).copy()
        if clear:
            self._lib.emu_clear_events()
        return arr

    def cycles(self):
        return self._lib.emu_cycles()

    def icount(self):
        return self._lib.emu_icount()

    def trace(self, on):
        self._lib.emu_trace(1 if on else 0)

    def trace_get(self):
        n = self._lib.emu_trace_pos()
        raw = ctypes.string_at(self._lib.emu_trace_buf(), n * 8)
        arr = np.frombuffer(raw, dtype='<u4').reshape(-1, 2)
        return arr

    def image(self):
        return PALETTE[self.fb & 0x3F]

    def screenshot(self, path, scale=1):
        from PIL import Image
        im = Image.fromarray(self.image())
        if scale != 1:
            im = im.resize((256 * scale, 240 * scale), Image.NEAREST)
        im.save(path)
