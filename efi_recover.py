#!/usr/bin/env python3
# efi_recover.py — driverless recovery for a chime-cap boot after a failed
# driver experiment: controller PCI D3hot->D0 cycle (BCLK interruption clears
# the latched clock fault), full EFI state replay, 4 s verification tone,
# then back to post-chime state. Proven procedure (efi_driver_emul.py S5).
#
# If snd_hda_intel is loaded, first (as root):
#   systemctl --user -M thomas@ stop wireplumber pipewire pipewire-pulse
#   rmmod snd_hda_codec_cs420x snd_hda_codec_hdmi snd_hda_intel 2>/dev/null
#   modprobe -r snd_hda_intel
#
# Run:  sudo python3 efi_recover.py 2>&1 | tee efi_chime_capture/recover.log

import ctypes, math, mmap, os, struct, sys, time

PCIDEV = "/sys/bus/pci/devices/0000:00:1b.0"
CAD = 0
RATE, CH, AMP = 44100, 4, 18000
N_PAGES = 64
PAGE = 4096
TAG = 1

EFI_COEF = {i: 0 for i in range(0x40)}
EFI_COEF.update({
    0x00: 0x00c4, 0x02: 0x003a, 0x03: 0x0baa, 0x04: 0x0c04, 0x05: 0x1000,
    0x06: 0x9f9f, 0x07: 0x9f9f, 0x08: 0x1f1f, 0x09: 0x1f1f, 0x0a: 0x1f1f,
    0x0b: 0x1f1f, 0x0c: 0x9f9f, 0x0d: 0x9f9f, 0x0e: 0x9f9f, 0x0f: 0x9f9f,
    0x10: 0x1f1f, 0x11: 0x1f1f, 0x12: 0x1f1f, 0x13: 0x1f1f,
    0x18: 0x0400, 0x19: 0x0088, 0x1a: 0x00f3, 0x1b: 0x0002, 0x1c: 0x0103,
    0x1d: 0x0bdf, 0x1e: 0x016d, 0x22: 0x0080, 0x25: 0x0001,
    0x33: 0x0821, 0x34: 0x3b21, 0x36: 0x0034,
})
EFI_GATED = {i: 0 for i in range(0x41, 0x80)}
EFI_GATED.update({
    0x41: 0x8000, 0x42: 0x006a, 0x44: 0x2200, 0x45: 0x80d8, 0x48: 0x0c72,
    0x49: 0x0023, 0x4a: 0x4664, 0x4b: 0xc900, 0x4c: 0x2492, 0x4d: 0x2492,
    0x4e: 0x2492, 0x4f: 0x2492, 0x50: 0x00cb, 0x51: 0x9005, 0x52: 0x0012,
    0x58: 0x0300, 0x59: 0x9000, 0x5a: 0x54bb, 0x5b: 0xae50, 0x5c: 0x0c40,
    0x5d: 0x035b, 0x5e: 0x02aa, 0x5f: 0x3000, 0x60: 0x8a2d, 0x61: 0x6db4,
    0x62: 0xa0e0, 0x63: 0x3840, 0x64: 0x38da, 0x65: 0x7f04, 0x66: 0x0923,
    0x67: 0x0005, 0x69: 0xf800, 0x6a: 0x000c, 0x6b: 0x1000,
})
EFI_PINCFG = {n: 0x400000f0 for n in list(range(0x11, 0x18)) +
              list(range(0x1a, 0x1d)) + list(range(0x1e, 0x23))}
EFI_PINCFG.update({0x10: 0x002b4020, 0x18: 0x00ab9030,
                   0x19: 0x90a60100, 0x1d: 0x90100110})

if os.path.exists(f"{PCIDEV}/driver"):
    sys.exit("ABORT: a driver is bound to 00:1b.0 — rmmod the hda stack first "
             "(see header).")
if os.path.exists("/sys/module/snd_hda_intel"):
    sys.exit("ABORT: snd_hda_intel still loaded — modprobe -r it first.")
grp = f"{PCIDEV}/iommu_group"
if os.path.islink(grp):
    gid = os.path.basename(os.path.realpath(grp))
    tpath = f"/sys/kernel/iommu_groups/{gid}/type"
    if open(tpath).read().strip() != "identity":
        with open(tpath, "w") as f:
            f.write("identity")
        if open(tpath).read().strip() != "identity":
            sys.exit(f"ABORT: IOMMU group {gid} not switchable to identity.")

cfgfd = open(f"{PCIDEV}/config", "r+b", buffering=0)

def pci_cmd_enable():
    cfgfd.seek(4)
    cmd = struct.unpack("<H", cfgfd.read(2))[0]
    if (cmd & 0x6) != 0x6:
        cfgfd.seek(4)
        cfgfd.write(struct.pack("<H", cmd | 0x6))

def pm_cap():
    cfgfd.seek(0x34)
    ptr = cfgfd.read(1)[0]
    while ptr:
        cfgfd.seek(ptr)
        capid, nxt = cfgfd.read(1)[0], cfgfd.read(1)[0]
        if capid == 0x01:
            return ptr
        ptr = nxt
    return None

def pci_set_power(d):
    p = pm_cap()
    cfgfd.seek(p + 4)
    pmcsr = struct.unpack("<H", cfgfd.read(2))[0]
    cfgfd.seek(p + 4)
    cfgfd.write(struct.pack("<H", (pmcsr & ~0x3) | d))
    time.sleep(0.05)

pci_cmd_enable()
pci_set_power(0)

fd = os.open(f"{PCIDEV}/resource0", os.O_RDWR | os.O_SYNC)
bar = mmap.mmap(fd, 0x4000)

def rd32(o): return struct.unpack_from("<I", bar, o)[0]
def rd16(o): return struct.unpack_from("<H", bar, o)[0]
def rd8(o):  return bar[o]
def wr32(o, v): struct.pack_into("<I", bar, o, v)
def wr16(o, v): struct.pack_into("<H", bar, o, v)
def wr8(o, v):  bar[o] = v

GCTL, STATESTS, ICOI, ICII, ICIS = 0x08, 0x0E, 0x60, 0x64, 0x68
gcap = rd16(0x00)
iss = (gcap >> 8) & 0xF
SD = 0x80 + iss * 0x20

def link_up():
    if rd32(GCTL) & 1:
        return
    wr32(GCTL, 1)
    for _ in range(1000):
        if rd32(GCTL) & 1: break
        time.sleep(0.0001)
    time.sleep(0.005)
    for _ in range(200):
        if rd16(STATESTS) & 1: break
        time.sleep(0.001)

def icmd(word):
    for _ in range(1000):
        if not (rd16(ICIS) & 1): break
        time.sleep(0.0001)
    else:
        raise TimeoutError("ICB busy")
    wr16(ICIS, 0x2)
    wr32(ICOI, word)
    wr16(ICIS, 0x1)
    for _ in range(1000):
        s = rd16(ICIS)
        if not (s & 1):
            if not (s & 2):
                raise IOError(f"no response cmd 0x{word:08x}")
            return rd32(ICII)
        time.sleep(0.0001)
    raise TimeoutError("verb timeout")

def verb(nid, v, payload):
    return icmd((CAD << 28) | (nid << 20) | (v << 8) | payload)

def verb16(nid, v, payload):
    return icmd((CAD << 28) | (nid << 20) | (v << 16) | payload)

def verb_retry(nid, v, payload, tries=50):
    for _ in range(tries):
        try:
            return verb(nid, v, payload)
        except (IOError, TimeoutError):
            time.sleep(0.01)
    raise IOError("codec not responding")

def rdcoef(i):
    verb16(0x24, 0x5, i)
    return verb(0x24, 0xC00, 0)

def wrcoef(i, val):
    verb16(0x24, 0x5, i)
    verb16(0x24, 0x4, val)

def shutdown():
    try:
        wr8(SD + 0x00, 0x00)
        verb(0x01, 0x715, 0x00)
        verb(0x24, 0x7F0, 0x00)
        verb(0x0A, 0x706, 0x00)
        verb(0x0A, 0x705, 0x03)
    except Exception:
        pass

import atexit
atexit.register(shutdown)

def replay_regs():
    verb_retry(0x01, 0x705, 0x00)
    time.sleep(0.02)
    verb(0x24, 0x703, 0x01)
    for i in range(0x40):
        if i == 0x1f: continue
        wrcoef(i, EFI_COEF[i])
    wrcoef(0x40, 0x9999)
    for i in range(0x41, 0x80):
        wrcoef(i, EFI_GATED[i])
    wrcoef(0x40, 0)
    for nid, cfg in EFI_PINCFG.items():
        verb(nid, 0x71C, cfg & 0xFF);         verb(nid, 0x71D, (cfg >> 8) & 0xFF)
        verb(nid, 0x71E, (cfg >> 16) & 0xFF); verb(nid, 0x71F, (cfg >> 24) & 0xFF)
        verb(nid, 0x707, 0x40 if nid == 0x1d else 0x00)
    verb(0x0a, 0x70D, 0x11)
    verb(0x0a, 0x70E, 0x01)
    verb(0x0a, 0x72D, 0x03)
    verb16(0x0a, 0x2, 0x4013)
    verb(0x01, 0x716, 0x09)
    verb(0x01, 0x717, 0x01)
    verb(0x01, 0x715, 0x01)

# --- D3hot cycle ---
print("D3hot -> D0 cycle (BCLK interruption)...", flush=True)
pci_set_power(3)
time.sleep(0.3)
pci_set_power(0)
pci_cmd_enable()
link_up()
vid = verb_retry(0x00, 0xF00, 0)
if vid != 0x10134208:
    sys.exit(f"ABORT: codec id 0x{vid:08x} != CS4208")
print(f"coef 0x1f right after D3 cycle (pre-replay) = 0x{rdcoef(0x1f):04x}  "
      f"(0x0000 = latch cleared by the cycle)", flush=True)
print("replaying full EFI state...", flush=True)
replay_regs()
print(f"coef 0x1f after EFI replay = 0x{rdcoef(0x1f):04x}", flush=True)

# --- verification tone ---
total = (1 + N_PAGES) * PAGE
buf = mmap.mmap(-1, total)
buf.write(b"\x00" * total)
addr = ctypes.addressof(ctypes.c_char.from_buffer(buf))
libc = ctypes.CDLL("libc.so.6", use_errno=True)
if libc.mlock(ctypes.c_void_p(addr), ctypes.c_size_t(total)):
    sys.exit(f"ABORT: mlock failed errno={ctypes.get_errno()}")
frames = N_PAGES * (PAGE // (CH * 2))
cycles = round(440 * frames / RATE)
freq = cycles * RATE / frames
pcm = bytearray()
for i in range(frames):
    s = int(AMP * math.sin(2 * math.pi * freq * i / RATE))
    pcm += struct.pack("<hhhh", s, s, s, s)
buf.seek(PAGE)
buf.write(bytes(pcm))
pagemap = open("/proc/self/pagemap", "rb")
def phys(va):
    pagemap.seek((va // PAGE) * 8)
    e = struct.unpack("<Q", pagemap.read(8))[0]
    if not (e & (1 << 63)):
        sys.exit("ABORT: page not present after mlock")
    return (e & ((1 << 55) - 1)) * PAGE
bdl_phys = phys(addr)
for i in range(N_PAGES):
    struct.pack_into("<QII", buf, i * 16, phys(addr + (1 + i) * PAGE), PAGE, 0)

wr8(SD + 0x00, 0x01)
for _ in range(1000):
    if rd8(SD + 0x00) & 1: break
    time.sleep(0.0001)
wr8(SD + 0x00, 0x00)
for _ in range(1000):
    if not (rd8(SD + 0x00) & 1): break
    time.sleep(0.0001)
wr8(SD + 0x03, 0x1C)
wr32(SD + 0x18, bdl_phys & 0xFFFFFFFF)
wr32(SD + 0x1C, bdl_phys >> 32)
wr32(SD + 0x08, N_PAGES * PAGE)
wr16(SD + 0x0C, N_PAGES - 1)
wr16(SD + 0x12, 0x4013)
wr8(SD + 0x02, TAG << 4)
verb(0x0A, 0x705, 0x00)
time.sleep(0.02)
verb(0x0A, 0x706, (TAG << 4) | 0)
verb(0x24, 0x7F0, 0x01)
verb(0x01, 0x715, 0x01)
wr8(SD + 0x00, 0x02)
time.sleep(0.1)
l0 = rd32(SD + 0x04); time.sleep(0.2); l1 = rd32(SD + 0x04)
print(f"DMA: LPIB {l0} -> {l1} ({'MOVING' if l1 != l0 else 'STUCK!'})")
print(f"coef 0x1f during playback = 0x{rdcoef(0x1f):04x}", flush=True)
print("*** verification tone — 4 s ***", flush=True)
time.sleep(4)
print("recovery done (tone heard = state recovered); codec back to "
      "post-chime state on exit.")
