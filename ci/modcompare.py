#!/usr/bin/env python3
"""Compare a rebuilt kernel's module ABI with the modules an official CoreELEC SYSTEM ships.

usage: modcompare.py LABEL OUR_Module.symvers OFFICIAL_MODULES_DIR OUR_MODULES_DIR

For every official .ko: read its __versions (symbol -> CRC), vermagic and
srcversion straight out of the ELF (arch-independent, no kmod needed), and
check each CRC against the rebuilt kernel's Module.symvers. Also compare
vermagic and srcversion with the same-named module we built. Exit 1 if any
CRC differs from the rebuilt kernel (the official modules would then fail to
load on it).
"""
import os
import struct
import sys

label, symvers_path, off_dir, our_dir = sys.argv[1:5]


def elf_sections(path):
    d = open(path, "rb").read()
    if d[:4] != b"\x7fELF" or d[4] != 2:
        raise SystemExit("%s: not ELF64" % path)
    little = d[5] == 1
    e = "<" if little else ">"
    shoff, = struct.unpack(e + "Q", d[0x28:0x30])
    shentsize, shnum, shstrndx = struct.unpack(e + "HHH", d[0x3A:0x40])
    hdrs = []
    for i in range(shnum):
        h = d[shoff + i * shentsize: shoff + (i + 1) * shentsize]
        name, typ, flags, addr, off, size = struct.unpack(e + "IIQQQQ", h[:40])
        hdrs.append((name, off, size))
    stroff = hdrs[shstrndx][1]
    out = {}
    for name, off, size in hdrs:
        n = d[stroff + name: d.index(b"\0", stroff + name)].decode()
        out[n] = d[off: off + size]
    return out, e


def module_info(path):
    secs, e = elf_sections(path)
    vers = {}
    v = secs.get("__versions", b"")
    for i in range(0, len(v) - 63, 64):
        crc, = struct.unpack(e + "Q", v[i:i + 8])
        sym = v[i + 8:i + 64].split(b"\0", 1)[0].decode()
        if sym:
            vers[sym] = crc & 0xFFFFFFFF
    info = {}
    for ent in secs.get(".modinfo", b"").split(b"\0"):
        if b"=" in ent:
            k, val = ent.split(b"=", 1)
            info[k.decode()] = val.decode(errors="replace")
    return vers, info


symvers = {}
for line in open(symvers_path):
    parts = line.split()
    if len(parts) >= 2:
        symvers[parts[1]] = int(parts[0], 16) & 0xFFFFFFFF

our_mods = {}
for root, _, files in os.walk(our_dir):
    for f in files:
        if f.endswith(".ko"):
            our_mods[f] = os.path.join(root, f)

n_mod = n_sym = n_ok = n_bad = n_missing = 0
bad = []
vermagics = set()
src_same = src_diff = src_none = 0
diffs = []
for root, _, files in os.walk(off_dir):
    for f in sorted(files):
        if not f.endswith(".ko"):
            continue
        n_mod += 1
        vers, info = module_info(os.path.join(root, f))
        vermagics.add(info.get("vermagic", "?"))
        for sym, crc in vers.items():
            n_sym += 1
            ours = symvers.get(sym)
            if ours is None:
                # exported by another module (its CRC lives in that module's own symvers entry too)
                n_missing += 1
            elif ours == crc:
                n_ok += 1
            else:
                n_bad += 1
                bad.append("%s: %s official 0x%08x rebuilt 0x%08x" % (f, sym, crc, ours))
        if f in our_mods:
            _, oinfo = module_info(our_mods[f])
            if "srcversion" in info and "srcversion" in oinfo:
                if info["srcversion"] == oinfo["srcversion"]:
                    src_same += 1
                else:
                    src_diff += 1
                    diffs.append("%s: srcversion official %s rebuilt %s" % (f, info["srcversion"], oinfo["srcversion"]))
            else:
                src_none += 1
            if oinfo.get("vermagic") != info.get("vermagic"):
                diffs.append("%s: vermagic official %r rebuilt %r" % (f, info.get("vermagic"), oinfo.get("vermagic")))

print("[%s] official modules: %d; symbol CRCs checked: %d; match rebuilt kernel: %d; MISMATCH: %d; not in rebuilt Module.symvers: %d"
      % (label, n_mod, n_sym, n_ok, n_bad, n_missing))
print("[%s] official vermagic(s): %s" % (label, ", ".join(sorted(vermagics))))
print("[%s] same-named modules rebuilt: %d; srcversion identical: %d, different: %d, absent: %d"
      % (label, src_same + src_diff + src_none, src_same, src_diff, src_none))
for line in bad[:40]:
    print("  CRC " + line)
for line in diffs[:40]:
    print("  " + line)
sys.exit(1 if n_bad else 0)
