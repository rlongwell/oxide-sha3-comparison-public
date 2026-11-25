#!/usr/bin/env python3
"""Recompute stored medians from timer counts and digest-checked board samples."""
import hashlib
import json
from pathlib import Path

from plot_size_sweep import summarize


def main():
    sweep = Path(__file__).resolve().parents[1] / "evidence" / "sweep"
    plan_bytes = (sweep / "plan.json").read_bytes()
    report_bytes = (sweep / "results.json").read_bytes()
    plan = json.loads(plan_bytes)
    report = json.loads(report_bytes)
    saved = json.loads((sweep / "summary.json").read_bytes())
    if report["plan_sha256"] != hashlib.sha256(plan_bytes).hexdigest():
        raise ValueError("The plan differs from the one used for the sweep")
    if saved["source_sha256"] != hashlib.sha256(report_bytes).hexdigest():
        raise ValueError("The samples differ from the recorded summary source")
    rows = summarize(report, plan)
    if rows != saved["rows"]:
        raise ValueError("Recomputed measurements differ from the retained summary")
    for row in rows:
        if row["bytes"] == 2**30:
            print(f'{row["mode"]} at 1 GiB: {row["oxide_MB_per_second"]:.3f} MB/s Quartz, '
                  f'{row["compact_MB_per_second"]:.3f} MB/s compact, {row["speedup"]:.3f}x')
    warmups = sum(row["warmup"] for row in report["rows"])
    print(f'Checked {len(report["rows"]) - warmups} timed trials and {warmups} warmups.')


if __name__ == "__main__":
    main()
