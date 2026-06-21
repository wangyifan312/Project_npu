#!/usr/bin/env python3
"""Validate a ResNet-20 R0.5 INT8/INT32/requant export package."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from resnet20_cifar10_common import ARCH, deterministic_json_dump


INT32_MAX = (1 << 31) - 1
INT32_MIN = -(1 << 31)


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="ascii"))


def product(values: list[int]) -> int:
    out = 1
    for value in values:
        out *= int(value)
    return out


def parse_memh(path: Path, *, bits: int) -> list[int]:
    values: list[int] = []
    sign_bit = 1 << (bits - 1)
    full = 1 << bits
    for raw in path.read_text(encoding="ascii").splitlines():
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        token = line.split()[0]
        value = int(token, 16)
        if value & sign_bit:
            value -= full
        values.append(value)
    return values


def check_requant_item(item: dict[str, Any], errors: list[str], context: str) -> None:
    requant = item.get("requant", item)
    multiplier = requant.get("multiplier_int")
    shift = requant.get("shift")
    if not isinstance(multiplier, int) or multiplier <= 0 or multiplier > INT32_MAX:
        errors.append(f"{context}: invalid multiplier_int {multiplier!r}")
    if not isinstance(shift, int) or shift < 0 or shift > 31:
        errors.append(f"{context}: invalid shift {shift!r}")


def validate_memh_entries(
    package_dir: Path,
    entries: list[dict[str, Any]],
    *,
    bits: int,
    min_value: int,
    max_value: int,
    errors: list[str],
    label: str,
) -> None:
    for entry in entries:
        rel = entry.get("file")
        path = package_dir / str(rel)
        if not path.exists():
            errors.append(f"{label}: missing memh {rel}")
            continue
        values = parse_memh(path, bits=bits)
        expected_count = product([int(v) for v in entry.get("shape", [])])
        if len(values) != expected_count:
            errors.append(f"{label}:{rel}: element count {len(values)} != shape product {expected_count}")
        if len(values) != int(entry.get("element_count", -1)):
            errors.append(f"{label}:{rel}: element count {len(values)} != metadata {entry.get('element_count')}")
        out_of_range = [v for v in values if v < min_value or v > max_value]
        if out_of_range:
            errors.append(f"{label}:{rel}: {len(out_of_range)} values out of range [{min_value},{max_value}]")
        if values and min(values) != int(entry.get("min")):
            errors.append(f"{label}:{rel}: min mismatch")
        if values and max(values) != int(entry.get("max")):
            errors.append(f"{label}:{rel}: max mismatch")
        if sum(values) != int(entry.get("checksum", 0)):
            errors.append(f"{label}:{rel}: checksum mismatch")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate ResNet-20 export package")
    parser.add_argument("--package-dir", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    package_dir = Path(args.package_dir)
    output_path = Path(args.output)
    errors: list[str] = []
    warnings: list[str] = []

    manifest_path = package_dir / "manifest.json"
    if not manifest_path.exists():
        errors.append("manifest.json missing")
        manifest: dict[str, Any] = {}
    else:
        manifest = read_json(manifest_path)
    if manifest.get("arch") != ARCH:
        errors.append(f"manifest arch mismatch: {manifest.get('arch')!r}")

    for rel in manifest.get("weights", []):
        if not (package_dir / rel).exists():
            errors.append(f"manifest references missing weight file {rel}")
    for rel in manifest.get("bias", []):
        if not (package_dir / rel).exists():
            errors.append(f"manifest references missing bias file {rel}")
    for key, rel in manifest.get("requant", {}).items():
        if not (package_dir / rel).exists():
            errors.append(f"manifest references missing requant {key}: {rel}")

    if manifest.get("final_task_sequence_generated"):
        task_sequence = manifest.get("task_sequence")
        if not task_sequence or not (package_dir / str(task_sequence)).exists():
            errors.append("final_task_sequence_generated is true but task_sequence is missing")
    elif manifest.get("task_sequence") is not None:
        errors.append("task_sequence is set but final_task_sequence_generated is false")
    if manifest.get("one_mb_memory_reuse_map_generated"):
        memory_map = manifest.get("memory_map")
        if not memory_map or not (package_dir / str(memory_map)).exists():
            errors.append("one_mb_memory_reuse_map_generated is true but memory_map is missing")
    elif manifest.get("memory_map") is not None:
        errors.append("memory_map is set but one_mb_memory_reuse_map_generated is false")

    weights_summary_path = package_dir / "weights" / "summary.json"
    bias_summary_path = package_dir / "bias" / "summary.json"
    requant_summary_path = package_dir / "requant" / "summary.json"
    for path in (weights_summary_path, bias_summary_path, requant_summary_path):
        if not path.exists():
            errors.append(f"missing {path.relative_to(package_dir)}")

    weights_summary = read_json(weights_summary_path) if weights_summary_path.exists() else {}
    bias_summary = read_json(bias_summary_path) if bias_summary_path.exists() else {}
    requant_summary = read_json(requant_summary_path) if requant_summary_path.exists() else {}

    weight_entries = weights_summary.get("entries", [])
    bias_entries = bias_summary.get("entries", [])
    if int(weights_summary.get("weight_file_count", len(weight_entries))) != 22 or len(weight_entries) != 22:
        errors.append(f"weight file count is {len(weight_entries)}, expected 22")
    if int(bias_summary.get("bias_file_count", len(bias_entries))) != 22 or len(bias_entries) != 22:
        errors.append(f"bias file count is {len(bias_entries)}, expected 22")
    validate_memh_entries(package_dir, weight_entries, bits=8, min_value=-128, max_value=127, errors=errors, label="weights")
    validate_memh_entries(package_dir, bias_entries, bits=32, min_value=INT32_MIN, max_value=INT32_MAX, errors=errors, label="bias")

    conv_fc_path = package_dir / "requant" / "conv_fc_requant.json"
    residual_path = package_dir / "requant" / "residual_add_alignment.json"
    gap_path = package_dir / "requant" / "gap_requant.json"
    conv_fc = read_json(conv_fc_path) if conv_fc_path.exists() else {}
    residual = read_json(residual_path) if residual_path.exists() else {}
    gap = read_json(gap_path) if gap_path.exists() else {}
    conv_items = conv_fc.get("items", [])
    residual_items = residual.get("items", [])
    if len(conv_items) != 22 or int(conv_fc.get("conv_fc_requant_count", len(conv_items))) != 22:
        errors.append(f"conv/fc requant count is {len(conv_items)}, expected 22")
    if len(residual_items) != 9 or int(residual.get("residual_add_alignment_count", len(residual_items))) != 9:
        errors.append(f"residual ADD alignment count is {len(residual_items)}, expected 9")
    for item in conv_items:
        check_requant_item(item.get("requant", {}), errors, f"conv_fc:{item.get('op')}")
    for item in residual_items:
        check_requant_item(item.get("main_to_target", {}), errors, f"residual_main:{item.get('op')}")
        check_requant_item(item.get("shortcut_to_target", {}), errors, f"residual_shortcut:{item.get('op')}")
    check_requant_item(gap.get("requant", {}), errors, "gap")

    validation_pass = not errors
    report = {
        "arch": ARCH,
        "package_dir": str(package_dir),
        "validation_status": "pass" if validation_pass else "fail",
        "errors": errors,
        "warnings": warnings,
        "weight_file_count": len(weight_entries),
        "bias_file_count": len(bias_entries),
        "conv_fc_requant_count": len(conv_items),
        "residual_add_alignment_count": len(residual_items),
        "gap_requant_status": gap.get("requant", {}).get("status"),
        "task_sequence_generated": bool(manifest.get("final_task_sequence_generated")),
        "one_mb_memory_reuse_map_generated": bool(manifest.get("one_mb_memory_reuse_map_generated")),
    }
    deterministic_json_dump(output_path, report)
    print(f"Wrote {output_path}")
    print(f"validation_status={report['validation_status']}")
    print(f"error_count={len(errors)}")
    return 0 if validation_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
