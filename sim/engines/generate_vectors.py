#!/usr/bin/env python3
"""Deterministic independent hashes; the DUT never computes expected answers."""
import argparse
import hashlib
import json
import random
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--algorithm", choices=("sha3", "sha256", "blake2s"), default="sha3")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
rng = random.Random(0xDF02026)
lengths = [0, 1, 2, 3, 7, 8, 9, 31, 32, 33, 55, 56, 57, 63, 64, 65,
           119, 120, 121, 127, 128, 129, 134, 135, 136, 137, 138, 255, 256,
           257, 271, 272, 273, 511, 512, 513, 1024, 4096, 65536, 1048576]
cases = [(f"random_{n}", rng.randbytes(n)) for n in lengths]
cases += [("ascii_abc", b"abc"), ("zero", b"\x00"), ("ff", b"\xff")]
cases += [(f"seeded_{i}", rng.randbytes(rng.randrange(1, 4097))) for i in range(32)]
ordered = bytes(range(256)) * 3
cases += [("ordered", ordered), ("dropped", ordered[:117]+ordered[118:]),
          ("duplicated", ordered[:117]+ordered[116:]),
          ("reordered", ordered[:117]+ordered[118:129]+ordered[117:118]+ordered[129:])]
ref = {"sha3": hashlib.sha3_256, "sha256": hashlib.sha256,
       "blake2s": hashlib.blake2s}[args.algorithm]
args.output.parent.mkdir(parents=True, exist_ok=True)
with args.output.open("w") as out:
    for name, payload in cases:
        out.write(f"{name} {len(payload)} {payload.hex() or '-'} {ref(payload).hexdigest()}\n")
print(json.dumps({"algorithm": args.algorithm, "vectors": len(cases),
                  "bytes": sum(len(p) for _,p in cases), "seed": "0xDF02026"}))
