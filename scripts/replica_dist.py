#!/usr/bin/env python3
"""Measure physical separation of TMR replica flops in a placed DEF.

Groups same-bit replica trios by normalizing the replica letter in the
instance path (u_ch_a/u_ch_b/u_ch_c, u_ff_a/b/c, u_rs_a/b/c). The MINIMUM
pairwise distance within a trio is the number that matters: defeating the
bitwise voter needs the SAME logical bit upset in two replicas at once.
"""
import re
import sys
from collections import defaultdict

DEF_PATH = sys.argv[1]
REP = re.compile(r"(u_(?:ch|ff|rs)_)([abc])([/.])")

text = open(DEF_PATH).read()
scale = int(re.search(r"UNITS DISTANCE MICRONS (\d+)", text).group(1))

comp_re = re.compile(r"- (\S+) (\S+) \+ (?:PLACED|FIXED) \( (-?\d+) (-?\d+) \)")
pos, celltype = {}, {}
for name, cell, x, y in comp_re.findall(text):
    pos[name] = (int(x) / scale, int(y) / scale)
    celltype[name] = cell

def dist(p, q):
    return ((p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2) ** 0.5

# group: normalized name -> {replica_letter: instance}
trios = defaultdict(dict)
for name in pos:
    if "dfrbpq" not in celltype[name]:
        continue
    m = REP.search(name)
    if m:
        key = name[:m.start(2)] + "?" + name[m.end(2):]
        trios[key][m.group(2)] = name

groups = defaultdict(list)  # block prefix -> list of min distances
for key, members in trios.items():
    if len(members) == 3:
        pa, pb, pc = (pos[members[r]] for r in "abc")
        dmin = min(dist(pa, pb), dist(pb, pc), dist(pa, pc))
        block = key.split("?")[0].rsplit("u_", 1)[0] or key
        groups[block].append(dmin)

print(f"DEF: {DEF_PATH}  ({len(pos)} components, {sum(len(v) for v in groups.values())} same-bit trios)")
print()
grand = []
for block in sorted(groups):
    mins = sorted(groups[block])
    grand += mins
    n = len(mins)
    print(f"{block:38s} bits={n:3d}  min={mins[0]:6.2f}  med={mins[n//2]:6.2f}  "
          f"max={mins[-1]:6.2f} um  <5um:{sum(d<5 for d in mins):3d}  <10um:{sum(d<10 for d in mins):3d}")

grand.sort()
n = len(grand)
print()
print(f"TOTAL: {n} trios   worst same-bit separation: {grand[0]:.2f} um")
for t in (2, 5, 10, 20):
    c = sum(1 for d in grand if d < t)
    print(f"  same-bit pair closer than {t:2d} um: {c:4d}  ({100*c/n:5.1f}%)")
