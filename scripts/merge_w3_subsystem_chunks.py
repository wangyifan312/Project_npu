#!/usr/bin/env python3
"""Merge W3 subsystem chunk results into a resumable full-set summary."""
from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path


FIELDNAMES = [
    "sample_name",
    "expected",
    "predicted",
    "status",
    "pass_fail",
    "total_cycles",
    "total_mac",
    "total_read_beats",
    "total_write_beats",
    "total_read_active",
    "total_write_active",
    "total_array_active",
    "total_array_stall",
    "total_cluster_active",
    "total_cluster_stall",
]


def to_int(row: dict[str, str], key: str) -> int:
    value = row.get(key, "")
    return int(value) if value not in ("", None) else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="results/w3_subsystem_full_10000_candidate_final_chunked")
    parser.add_argument("--manifest", default="datasets/mnist/lenet_requant_candidate_final_manifest_10000/manifest.json")
    parser.add_argument("--chunk-size", type=int, default=250)
    parser.add_argument("--allow-partial", action="store_true")
    args = parser.parse_args()

    root = Path(args.root)
    manifest_path = Path(args.manifest)
    merged_dir = root / "merged"
    merged_dir.mkdir(parents=True, exist_ok=True)

    manifest = json.loads(manifest_path.read_text())
    manifest_samples = [entry["dir"] for entry in manifest]
    manifest_order = {name: idx for idx, name in enumerate(manifest_samples)}

    rows_by_sample: dict[str, dict[str, str]] = {}
    duplicate_samples: list[str] = []
    chunk_summaries: list[dict[str, object]] = []
    chunk_re = re.compile(r"^chunk_(\d{5})_(\d{5})$")

    for chunk_dir in sorted(p for p in root.iterdir() if p.is_dir() and chunk_re.match(p.name)):
        start, end = map(int, chunk_re.match(chunk_dir.name).groups())  # type: ignore[union-attr]
        csv_path = chunk_dir / "per_sample.csv"
        summary_path = chunk_dir / "summary.json"
        if not csv_path.exists() or not summary_path.exists():
            chunk_summaries.append({
                "chunk": chunk_dir.name,
                "start": start,
                "end": end,
                "complete": False,
                "reason": "missing per_sample.csv or summary.json",
            })
            continue

        summary = json.loads(summary_path.read_text())
        expected_total = end - start + 1
        complete = int(summary.get("total", -1)) == expected_total
        chunk_summaries.append({
            "chunk": chunk_dir.name,
            "start": start,
            "end": end,
            "complete": complete,
            "total": int(summary.get("total", 0)),
            "correct": int(summary.get("correct", 0)),
            "accuracy": float(summary.get("accuracy", 0.0)),
        })

        for row in csv.DictReader(csv_path.open(newline="")):
            sample = row["sample_name"]
            if sample in rows_by_sample:
                duplicate_samples.append(sample)
                continue
            rows_by_sample[sample] = row

    unknown_samples = sorted(sample for sample in rows_by_sample if sample not in manifest_order)
    if duplicate_samples or unknown_samples:
        error = {
            "duplicate_samples": duplicate_samples,
            "unknown_samples": unknown_samples,
        }
        (merged_dir / "merge_error.json").write_text(json.dumps(error, indent=2) + "\n", encoding="ascii")
        raise SystemExit("merge refused: duplicate or unknown samples found")

    ordered_rows = [rows_by_sample[name] for name in manifest_samples if name in rows_by_sample]
    missing_samples = [name for name in manifest_samples if name not in rows_by_sample]

    with (merged_dir / "per_sample.csv").open("w", newline="", encoding="ascii") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(ordered_rows)

    total = len(ordered_rows)
    correct = sum(1 for row in ordered_rows if row.get("status") == "PASS")
    first_fail = next((row for row in ordered_rows if row.get("status") != "PASS"), None)
    is_complete = total == len(manifest_samples) and not missing_samples

    sum_cycles = sum(to_int(row, "total_cycles") for row in ordered_rows)
    sum_mac = sum(to_int(row, "total_mac") for row in ordered_rows)
    sum_read_beats = sum(to_int(row, "total_read_beats") for row in ordered_rows)
    sum_write_beats = sum(to_int(row, "total_write_beats") for row in ordered_rows)
    sum_read_active = sum(to_int(row, "total_read_active") for row in ordered_rows)
    sum_write_active = sum(to_int(row, "total_write_active") for row in ordered_rows)
    sum_array_active = sum(to_int(row, "total_array_active") for row in ordered_rows)
    sum_array_stall = sum(to_int(row, "total_array_stall") for row in ordered_rows)
    sum_cluster_active = sum(to_int(row, "total_cluster_active") for row in ordered_rows)
    sum_cluster_stall = sum(to_int(row, "total_cluster_stall") for row in ordered_rows)

    summary = {
        "level": "subsystem",
        "run_label": "w3_subsystem_full_10000_chunked_merged",
        "manifest_path": str(manifest_path),
        "target_total": len(manifest_samples),
        "total": total,
        "correct": correct,
        "accuracy": (correct / total) if total else 0.0,
        "is_complete": is_complete,
        "chunk_size": args.chunk_size,
        "completed_chunks": sum(1 for item in chunk_summaries if item.get("complete")),
        "observed_chunks": len(chunk_summaries),
        "missing_samples": len(missing_samples),
        "first_missing_sample": missing_samples[0] if missing_samples else None,
        "first_failing_sample": first_fail["sample_name"] if first_fail else None,
        "first_failing_expected": first_fail["expected"] if first_fail else None,
        "first_failing_predicted": first_fail["predicted"] if first_fail else None,
        "total_cycles": sum_cycles,
        "avg_cycles": (sum_cycles / total) if total else 0.0,
        "total_mac": sum_mac,
        "avg_mac": (sum_mac / total) if total else 0.0,
        "total_read_beats": sum_read_beats,
        "avg_read_beats": (sum_read_beats / total) if total else 0.0,
        "total_write_beats": sum_write_beats,
        "avg_write_beats": (sum_write_beats / total) if total else 0.0,
        "beat_bytes": 32,
        "total_read_bytes": sum_read_beats * 32,
        "total_write_bytes": sum_write_beats * 32,
        "total_read_active": sum_read_active,
        "total_write_active": sum_write_active,
        "avg_read_bw_util": (sum_read_beats / sum_read_active) if sum_read_active else 0.0,
        "avg_write_bw_util": (sum_write_beats / sum_write_active) if sum_write_active else 0.0,
        "total_array_active": sum_array_active,
        "total_array_stall": sum_array_stall,
        "total_cluster_active": sum_cluster_active,
        "total_cluster_stall": sum_cluster_stall,
        "avg_array_util": (sum_array_active / sum_cycles) if sum_cycles else 0.0,
        "avg_cluster_util": (sum_cluster_active / sum_cycles) if sum_cycles else 0.0,
        "chunks": chunk_summaries,
    }

    (merged_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="ascii")

    if not args.allow_partial and not is_complete:
        raise SystemExit("merge produced partial result; pass --allow-partial while full-set is in progress")

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
