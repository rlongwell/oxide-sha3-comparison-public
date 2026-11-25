#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
result_prefix="${1:-baseline}"
case "$result_prefix" in
    baseline) core_source="$project_root/reference/oxide/hdl/ip/vhd/sha3/sha3_256.vhd" ;;
    oxide_no_digest) core_source="$project_root/rtl/sha3/oxide_no_digest/sha3_256.vhd" ;;
    *) echo "Unknown core selection: $result_prefix" >&2; exit 2 ;;
esac
(cd "$project_root/reference/oxide" && sha256sum --check SHA256SUMS)
tool_root="$("$project_root/scripts/setup_nvc.sh")"
run_root="$project_root/build/sim/$result_prefix"
reference="$project_root/reference/oxide/hdl/ip/vhd"
mkdir -p "$run_root" "$project_root/results"
python3 "$project_root/sim/baseline/generate_vectors.py" --output "$run_root"
for buffering in false true; do
    for gaps in false true; do
        run_dir="$run_root/db_${buffering}_gaps_${gaps}"
        mkdir -p "$run_dir"
        cp "$run_root/vectors.txt" "$run_dir/vectors.txt"
        (
            cd "$run_dir"
            nvc=("$tool_root/usr/bin/nvc" --std=2019 -L "$tool_root/usr/lib/x86_64-linux-gnu/nvc" --work=baseline)
            "${nvc[@]}" -a "$reference/axi_blocks/axist_if_2k19_pkg.vhd" \
                "$reference/common/utils/calc_pkg.vhd" "$reference/sha3/keccak_pkg.vhd" \
                "$core_source" "$project_root/sim/baseline/baseline_tb.vhd"
            "${nvc[@]}" -e "-gDB=$buffering" "-gSOURCE_GAPS=$gaps" baseline_tb -r baseline_tb > simulation.log 2>&1
            rg 'ALL PASS' simulation.log
        )
        cp "$run_dir/cycles.csv" "$project_root/results/${result_prefix}_db_${buffering}_gaps_${gaps}_cycles.csv"
        cp "$run_dir/simulation.log" "$project_root/results/${result_prefix}_db_${buffering}_gaps_${gaps}_simulation.log"
    done
done
python3 - "$project_root" "$result_prefix" "$core_source" <<'PY'
import csv, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
result_prefix = sys.argv[2]
core_source = pathlib.Path(sys.argv[3])
results = []
for buffering in ('false', 'true'):
    for gaps in ('false', 'true'):
        path = root / 'results' / f'{result_prefix}_db_{buffering}_gaps_{gaps}_cycles.csv'
        rows = list(csv.DictReader(path.open()))
        large = max(rows, key=lambda row: int(row['bytes']))
        results.append({'double_buffer': buffering == 'true', 'source_gaps': gaps == 'true',
                        'passed_cases': len(rows), 'largest_message': {k: int(v) for k, v in large.items()},
                        'largest_message_MB_s_at_100MHz': int(large['bytes']) * 100 / int(large['total_cycles'])})
(root / 'results' / f'{result_prefix}_simulation.json').write_text(json.dumps({
    'simulator': 'NVC 1.23.1', 'reference': 'Python hashlib.sha3_256', 'seed': 20261111,
    'source_revision': 'c0ccf08525f30c43f4c773c2295dabe80f97cd0e',
    'variant': result_prefix, 'core_source': str(core_source.relative_to(root)),
    'core_sha256': __import__('hashlib').sha256(core_source.read_bytes()).hexdigest(),
    'cycle_convention': 'Inclusive clocks from first accepted byte to final byte / digest_valid.',
    'empty_input': 'Unsupported by unchanged upstream stream port; not a baseline passing vector.',
    'additional_checks': ['stable digest', 'messages without init', 'source gaps', 'backpressure',
                          'held init with active input', 'async reset during absorb', 'async reset during permutation', 'recovery'],
    'configurations': results}, indent=2) + '\n')
print(f'{result_prefix} simulation passed in all four configurations.')
PY
