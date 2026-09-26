#!/usr/bin/env python3
"""Split an Android boot image (header v0) into kernel / ramdisk / second and print its header.

usage: split_bootimg.py BOOTIMG OUTDIR
"""
import os
import struct
import sys

img, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
data = open(img, "rb").read()
if data[:8] != b"ANDROID!":
    sys.exit("%s: not an Android boot image (magic %r)" % (img, data[:8]))
ks, ka, rs, ra, ss, sa, tags, page = struct.unpack("<8I", data[8:40])
hdr_ver, os_ver = struct.unpack("<II", data[40:48])
name = data[48:64].rstrip(b"\0").decode(errors="replace")
cmdline = data[64:576].rstrip(b"\0").decode(errors="replace")
def pages(n):
    return (n + page - 1) // page * page
off = page
parts = []
for label, size in (("kernel", ks), ("ramdisk", rs), ("second", ss)):
    if size:
        blob = data[off:off + size]
        with open(os.path.join(out, label), "wb") as f:
            f.write(blob)
        parts.append("%s=%d bytes (head %s)" % (label, size, blob[:4].hex()))
    off += pages(size)
print("boot image: total=%d page=%d hdr_ver=%d os_ver=0x%x name=%r cmdline=%r" % (len(data), page, hdr_ver, os_ver, name, cmdline))
print("  kernel @0x%x  ramdisk @0x%x  second @0x%x  tags @0x%x" % (ka, ra, sa, tags))
for p in parts:
    print("  " + p)
