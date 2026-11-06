#!/usr/bin/env python3
"""Facts from an Apple-compiled Assets.car, as JSON, for AssetKit's tests.

usage: genoracle.py FILE.car PLIST_JSON > Tests/AssetKitTests/Fixtures/MacOracle/oracle/CASE.json

FILE.car is Apple actool's output for the case's inputs (see MacOracleTests);
PLIST_JSON its partial Info.plist as JSON.
Rendition keys are written as "<asset name>|Attr=value,..." with the
identifier replaced by the asset name (identifiers are name hashes that
differ between Apple and AssetKit) and zero values left out.
"""
import json, struct, sys

ATTR = {1: "Element", 2: "Part", 3: "Size", 4: "Direction", 5: "Placeholder", 6: "Value",
        7: "Appearance", 8: "Dimension1", 9: "Dimension2", 10: "State", 11: "Layer",
        12: "Scale", 13: "Localization", 14: "PresentationState", 15: "Idiom", 16: "Subtype",
        17: "Identifier", 18: "PreviousValue", 19: "PreviousState", 20: "SizeClassH",
        21: "SizeClassV", 22: "MemoryClass", 23: "GraphicsClass", 24: "DisplayGamut",
        25: "DeploymentTarget", 26: "GlyphWeight", 27: "GlyphSize"}


class BOM:
    def __init__(self, data):
        self.d = data
        assert data[:8] == b"BOMStore", "not a BOM store"
        _, nblocks, idx_off, idx_len, vars_off, vars_len = struct.unpack(">6I", data[8:32])
        count = struct.unpack(">I", data[idx_off:idx_off + 4])[0]
        self.blocks = [struct.unpack(">II", data[idx_off + 4 + 8 * i: idx_off + 12 + 8 * i])
                       for i in range(count)]
        self.vars = {}
        n = struct.unpack(">I", data[vars_off:vars_off + 4])[0]
        p = vars_off + 4
        for _ in range(n):
            bid, ln = struct.unpack(">IB", data[p:p + 5])
            self.vars[data[p + 5:p + 5 + ln].decode()] = bid
            p += 5 + ln

    def block(self, i):
        a, l = self.blocks[i]
        return self.d[a:a + l]

    def var(self, name):
        return self.block(self.vars[name]) if name in self.vars else None

    def tree(self, name):
        """(key bytes, value bytes) pairs of a BOM tree variable, in order."""
        if name not in self.vars:
            return []
        t = self.block(self.vars[name])
        assert t[:4] == b"tree", name
        child = struct.unpack(">I", t[8:12])[0]
        out = []
        node = self.block(child)
        # descend to the leftmost leaf
        while struct.unpack(">H", node[0:2])[0] == 0:
            child = struct.unpack(">I", node[12:16])[0]
            node = self.block(child)
        while True:
            is_leaf, count, fwd, _ = struct.unpack(">HHII", node[:12])
            for i in range(count):
                v, k = struct.unpack(">II", node[12 + 8 * i: 20 + 8 * i])
                out.append((self.block(k), self.block(v)))
            if fwd == 0:
                break
            node = self.block(fwd)
        return out


def cstr(b):
    return b.split(b"\0", 1)[0].decode(errors="replace")


def csi_summary(v):
    if v[:4] != b"ISTC":
        return f"<{v[:4]!r}>"
    version, flags, w, h, scale, pixfmt, cs = struct.unpack("<IIIIIII", v[4:32])
    meta_mod, layout, zero, name = struct.unpack("<IHH128s", v[32:168])
    tlv_len, = struct.unpack("<I", v[168:172])
    fmt = pixfmt.to_bytes(4, "little").decode(errors="replace")[::-1]
    tlvs = []
    p, end = 184, 184 + tlv_len
    while p + 8 <= end:
        tag, ln = struct.unpack("<II", v[p:p + 8])
        tlvs.append(f"{tag:#x}:{ln}")
        p += 8 + ln
    return (f"layout={layout} {w}x{h} scale={scale / 100:g} fmt={fmt!r} flags={flags:#x} "
            f"cs={cs} name={cstr(name)!r} tlv=[{' '.join(tlvs)}] body={len(v) - end}")



car, plist = sys.argv[1], json.loads(sys.argv[2])
bom = BOM(open(car, "rb").read())
h = bom.var("CARHEADER")
key_semantics = struct.unpack("<I", h[432:436])[0]
m = bom.var("EXTENDED_METADATA")
k = bom.var("KEYFORMAT")
n = struct.unpack("<I", k[8:12])[0]
fmt = list(struct.unpack(f"<{n}I", k[12:12 + 4 * n]))

facets, by_id = {}, {}
for kk, vv in bom.tree("FACETKEYS"):
    cnt = struct.unpack("<H", vv[4:6])[0]
    pairs = dict(struct.unpack("<HH", vv[6 + 4 * i:10 + 4 * i]) for i in range(cnt))
    facets[kk.decode()] = pairs.get(2, 0)
    by_id[pairs.get(17, 0)] = kk.decode()

renditions = []
for kk, vv in bom.tree("RENDITIONS"):
    vals = dict(zip(fmt, struct.unpack(f"<{len(kk) // 2}H", kk)))
    name = by_id.get(vals.get(17, 0), "")
    attrs = ",".join(f"{ATTR[a]}={v}" for a, v in zip(fmt, [vals[a] for a in fmt]) if v and a != 17)
    renditions.append(f"{name}|{attrs}")

bitmap = {}
t = bom.var("BITMAPKEYS")
node = bom.block(struct.unpack(">I", t[8:12])[0])
while True:
    _, count, fwd, _ = struct.unpack(">HHII", node[:12])
    for i in range(count):
        v, key = struct.unpack(">II", node[12 + 8 * i: 20 + 8 * i])
        vb = bom.block(v)
        bitmap[by_id.get(key, str(key))] = list(struct.unpack(f"<{len(vb) // 4}I", vb))
    if fwd == 0:
        break
    node = bom.block(fwd)

json.dump({
    "keySemantics": key_semantics,
    "platform": cstr(m[516:772]),
    "keyFormat": fmt,
    "appearances": {kk.decode(): struct.unpack("<H", vv[:2])[0] for kk, vv in bom.tree("APPEARANCEKEYS")},
    "facets": facets,
    "renditions": sorted(renditions),
    "bitmapKeys": bitmap,
    "partialPlist": plist,
}, sys.stdout, indent=1, sort_keys=True)
print()
