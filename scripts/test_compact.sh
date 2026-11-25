#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/sim/compact"
mkdir -p "$out"
python3 "$root/sim/engines/generate_vectors.py" --algorithm sha3 --output "$out/vectors.txt"
verilator --cc --exe --build -j 4 --top-module hash_rm --Mdir "$out/obj" \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
    "$root/rtl/sha3/experiments/hash_sha3_compact.sv" "$root/rtl/rm/sha3_compact.sv" \
    "$root/sim/engines/test_engine.cpp"
"$out/obj/Vhash_rm" "$out/vectors.txt" 1
