#!/usr/bin/env python3
"""Validate ResNet-20 task_sequence.json and memory_map.json."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from resnet20_cifar10_common import ARCH, deterministic_json_dump


MEMORY_BYTES = 1 << 20
ALIGN_BYTES = 64
EXPECTED_OP_COUNTS = {
    "CONV3x3": 19,
    "CONV1x1_PROJECTION": 2,
    "RESIDUAL_ADD": 9,
    "GAP8x8": 1,
    "FC10": 1,
}


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="ascii"))


def file_part(ref: str | None) -> str | None:
    if not ref:
        return None
    return ref.split("#", 1)[0]


def live_overlap(a: dict[str, Any], b: dict[str, Any]) -> bool:
    ar = a["lifetime"]
    br = b["lifetime"]
    return int(ar["start_task"]) <= int(br["end_task"]) and int(br["start_task"]) <= int(ar["end_task"])


def addr_overlap(a: dict[str, Any], b: dict[str, Any]) -> bool:
    return int(a["base_addr"]) < int(b["end_addr"]) and int(b["base_addr"]) < int(a["end_addr"])


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate ResNet-20 task sequence and memory map")
    parser.add_argument("--package-dir", required=True)
    parser.add_argument("--task-sequence", required=True)
    parser.add_argument("--memory-map", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    package_dir = Path(args.package_dir)
    task_path = Path(args.task_sequence)
    memory_path = Path(args.memory_map)
    output_path = Path(args.output)
    errors: list[str] = []
    warnings: list[str] = []

    if not task_path.exists():
        errors.append("task_sequence.json missing")
        tasks = []
        task_sequence: dict[str, Any] = {}
    else:
        task_sequence = read_json(task_path)
        tasks = task_sequence.get("tasks", [])
    if not memory_path.exists():
        errors.append("memory_map.json missing")
        memory_map: dict[str, Any] = {}
    else:
        memory_map = read_json(memory_path)

    if task_sequence.get("arch") != ARCH:
        errors.append(f"task_sequence arch mismatch: {task_sequence.get('arch')!r}")
    if memory_map.get("arch") != ARCH:
        errors.append(f"memory_map arch mismatch: {memory_map.get('arch')!r}")
    if int(task_sequence.get("task_count", len(tasks))) != len(tasks):
        errors.append("task_count does not match tasks[] length")
    if len(tasks) != 32:
        errors.append(f"task_count is {len(tasks)}, expected 32")

    op_counts: dict[str, int] = {}
    for task in tasks:
        op_type = task.get("op_type")
        op_counts[op_type] = op_counts.get(op_type, 0) + 1
    conv_count = op_counts.get("CONV3x3", 0) + op_counts.get("CONV1x1_PROJECTION", 0)
    if conv_count != 21:
        errors.append(f"conv task count is {conv_count}, expected 21")
    for op_type, expected in EXPECTED_OP_COUNTS.items():
        if op_counts.get(op_type, 0) != expected:
            errors.append(f"{op_type} count is {op_counts.get(op_type, 0)}, expected {expected}")

    tensors = {item["name"]: item for item in memory_map.get("tensors", [])}
    null_address_errors = 0
    for tensor in tensors.values():
        base = int(tensor.get("base_addr", -1))
        end = int(tensor.get("end_addr", -1))
        if base == 0:
            null_address_errors += 1
            errors.append(f"tensor {tensor['name']} base_addr is 0; address 0 is reserved/null")
        if base % ALIGN_BYTES != 0:
            errors.append(f"tensor {tensor['name']} base_addr not 64B aligned")
        if end > MEMORY_BYTES:
            errors.append(f"tensor {tensor['name']} end_addr exceeds 1MB")
        if end <= base:
            errors.append(f"tensor {tensor['name']} invalid address range")

    for i, a in enumerate(memory_map.get("tensors", [])):
        for b in memory_map.get("tensors", [])[i + 1:]:
            if addr_overlap(a, b) and live_overlap(a, b):
                errors.append(f"live range overlap with address overlap: {a['name']} / {b['name']}")

    for task in tasks:
        task_id = int(task["task_id"])
        for tensor in task.get("input_tensors", []):
            if tensor not in tensors:
                errors.append(f"task {task['name']} input tensor missing from memory map: {tensor}")
                continue
            if int(task.get("memory", {}).get("inputs", {}).get(tensor, -1)) == 0:
                null_address_errors += 1
                errors.append(f"task {task['name']} input tensor {tensor} uses reserved/null address 0")
            lifetime = tensors[tensor]["lifetime"]
            if not (int(lifetime["start_task"]) <= task_id <= int(lifetime["end_task"])):
                errors.append(f"task {task['name']} consumes tensor outside lifetime: {tensor}")
        output = task.get("output_tensor")
        if output not in tensors:
            errors.append(f"task {task['name']} output tensor missing from memory map: {output}")
        elif int(task.get("memory", {}).get("output", -1)) == 0:
            null_address_errors += 1
            errors.append(f"task {task['name']} output tensor {output} uses reserved/null address 0")
        for key in ("weight_file", "bias_file", "requant_ref", "residual_add_ref"):
            rel = file_part(task.get(key))
            if rel and not (package_dir / rel).exists():
                errors.append(f"task {task['name']} references missing {key}: {rel}")

    for task in tasks:
        if task.get("op_type") == "RESIDUAL_ADD":
            for tensor in task.get("input_tensors", []):
                lifetime = tensors.get(tensor, {}).get("lifetime", {})
                if not lifetime or int(lifetime.get("end_task", -1)) < int(task["task_id"]):
                    errors.append(f"residual ADD {task['name']} input not live: {tensor}")
    gap_tasks = [task for task in tasks if task.get("op_type") == "GAP8x8"]
    fc_tasks = [task for task in tasks if task.get("op_type") == "FC10"]
    if gap_tasks and gap_tasks[0].get("input_tensors") != ["layer3.2.add.relu"]:
        errors.append("GAP input is not final residual activation")
    if fc_tasks and fc_tasks[0].get("input_tensors") != ["gap.output"]:
        errors.append("FC input is not GAP output")

    memory_total = int(memory_map.get("memory_total_bytes", MEMORY_BYTES))
    memory_peak = int(memory_map.get("memory_peak_live_bytes", 0))
    memory_max_end = int(memory_map.get("memory_max_end_address", 0))
    report = {
        "arch": ARCH,
        "validation_status": "pass" if not errors else "fail",
        "errors": errors,
        "warnings": warnings,
        "task_count": len(tasks),
        "conv_task_count": conv_count,
        "residual_add_task_count": op_counts.get("RESIDUAL_ADD", 0),
        "gap_task_count": op_counts.get("GAP8x8", 0),
        "fc_task_count": op_counts.get("FC10", 0),
        "memory_total_bytes": memory_total,
        "memory_peak_live_bytes": memory_peak,
        "memory_max_end_address": memory_max_end,
        "alignment_status": "pass" if not any("aligned" in err for err in errors) else "fail",
        "null_address_status": "pass" if null_address_errors == 0 else "fail",
        "null_address_error_count": null_address_errors,
        "live_range_overlap_status": "pass" if not any("overlap" in err for err in errors) else "fail",
        "task_sequence": str(task_path),
        "memory_map": str(memory_path),
    }
    deterministic_json_dump(output_path, report)
    print(f"Wrote {output_path}")
    print(f"validation_status={report['validation_status']}")
    print(f"error_count={len(errors)}")
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
