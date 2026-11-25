# SHA3-256 implementation and benchmark notes

The board experiment compares an unchanged Quartz core and an independent compact SystemVerilog core. A second experiment isolates one storage optimization in the original Quartz VHDL. [Project overview and demo](../README.md)

## Data paths and controls

Both board images use the same Zybo Z7-20, static shell, message source, 100 MHz clock and reconfigurable partition interface. Both cores implement SHA3-256 with a 1,600-bit Keccak state, a 136-byte rate and one permutation round per clock. They differ in how data is staged around those 24 rounds.

- **Quartz.** A local elastic adapter presents consecutive bytes from the shared 64-bit stream to the byte-wide VHDL input. Two rate-block buffers let the input collect the next block during permutation. The upstream VHDL keeps a separate digest register. The baseline is pinned to Quartz revision `c0ccf08525f30c43f4c773c2295dabe80f97cd0e`. [Reference source inventory](../reference/oxide/SOURCE.md) · [Stream adapter](../rtl/sha3/oxide_compare/axis_bytes_elastic.sv)
- **Compact.** A beat register captures the incoming word and its valid-byte count. The absorption step XORs those bytes into the rate lanes of the state. Capture and absorption take separate cycles, and the permutation occupies 24 clocks per block. The final state is held until the consumer accepts the digest. [Compact RTL](../rtl/sha3/experiments/hash_sha3_compact.sv) · [Partition interface](../rtl/rm/sha3_compact.sv)

The results describe this Zybo integration. Quartz’s original application hashes data supplied by SPI-NOR flash. [Upstream architecture notes](../reference/oxide/hdl/ip/vhd/sha3/docs/sha3_256.adoc)

## Timing boundaries and results

FPGA replay preloads a 128 KiB pattern and repeats it to form larger messages. The hardware timer covers the memory reader, framing and hash core from job start through digest completion. The preload finishes before the timer starts. The replay sweep uses powers of two from 64 B through 1 GiB, with one warmup and seven timed trials per core at each of the 25 sizes. Every returned digest matched the expected SHA3-256 value.

| 1 GiB replay, seven-trial median | Oxide Quartz | Compact |
| --- | ---: | ---: |
| Job start to digest | 10.737419 s | 4.500242 s |
| Payload throughput | 100.000 MB/s | 238.596 MB/s |

Throughput is payload bytes divided by the median elapsed time, in decimal MB/s. Speedup is the Quartz median time divided by the compact median time at the same message size. Select rows with `mode=replay` to reproduce the curves. [Charts from the demo](../README.md#what-the-board-measured) · [Individual trials](../evidence/sweep/samples.csv) · [Per-size medians](../evidence/sweep/summary.csv) · [Test plan](../evidence/sweep/plan.json)

Routed utilization is scoped to the hash partition. Quartz uses 5,854 LUTs and 4,222 flip-flops. The compact core uses 4,572 LUTs and 1,774 flip-flops. Both partition implementations use zero block RAMs and zero DSPs. The static shell includes memory used by the benchmark. Both images met the 100 MHz timing constraint. [Routed counts and timing](../evidence/routed/summary.json)

## Removing the Quartz digest register

The patch removes the separately stored 256-bit result. While digest-valid is asserted, it drives the output from the held permutation state and otherwise drives zero. Buffering, round logic and valid/ready timing follow the upstream design. These stand-alone numbers come from flattened-port, out-of-context Vivado 2024.2 builds on `xc7z020clg400-1` with a 10 ns clock. The board comparison above includes the reconfigurable partition wrapper and uses the original baseline. [VHDL patch source and provenance](../rtl/sha3/oxide_no_digest/SOURCE.json)

| Configuration | Routed LUTs | Routed flip-flops | Simulated clocks for 64 KiB |
| --- | ---: | ---: | ---: |
| Quartz, one buffer | 4,504 | 2,989 | 78,084 |
| Patched, one buffer | 4,369 | 2,724 | 78,084 |
| Quartz, two buffers | 5,406 | 4,075 | 65,578 |
| Patched, two buffers | 5,223 | 3,820 | 65,578 |

Cycles count from the first accepted byte through digest-valid, inclusive, with continuous source traffic. The simulation also exercises source gaps, backpressure, resets and digest stability against Python SHA3-256. [Original route](../evidence/digest-register/baseline_implementation.json) · [Patched route](../evidence/digest-register/oxide_no_digest_implementation.json) · [Original simulation](../evidence/digest-register/baseline_simulation.json) · [Patched simulation](../evidence/digest-register/oxide_no_digest_simulation.json)

## Verify from this repository

Recompute the sweep medians from the recorded board trials with Python 3. The checker validates the plan and sample hashes, checks digest and timer records, and compares its output with the saved summary.

```sh
python3 scripts/verify_sweep.py
```

For RTL simulation on x86-64 Ubuntu 24.04, install Python 3, Verilator, Make, a C++ compiler, ripgrep, curl and dpkg-deb. The VHDL script downloads a checksum-pinned NVC into the local tool directory. Run from the repository root.

```sh
./scripts/test_compact.sh
./scripts/test_baseline.sh
./scripts/test_baseline.sh oxide_no_digest
```
