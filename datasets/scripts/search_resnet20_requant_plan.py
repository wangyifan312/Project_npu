#!/usr/bin/env python3
"""Search ResNet-20 requant multiplier/shift planning metadata.

F3 converts F2 scale metadata into reproducible multiplier/shift candidates and
plans residual ADD branch alignment.  It does not run complete fixed-point
inference and does not generate RTL handoff assets.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

from resnet20_cifar10_common import ARCH, deterministic_json_dump


INT32_MAX = (1 << 31) - 1
R0_5_UNFINISHED = [
    "actual_fixed_point_inference",
    "accuracy_gate_80_percent",
    "real_cifar10_full_fixed_point_eval",
    "int8_weights_memh",
    "int32_folded_bias_memh",
    "final_task_sequence",
    "one_mb_memory_reuse_map",
]


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="ascii"))


def search_multiplier_shift(real_multiplier: float, *, max_shift: int = 31) -> dict[str, Any]:
    if not math.isfinite(real_multiplier) or real_multiplier <= 0.0:
        return {
            "real_multiplier": real_multiplier,
            "multiplier_int": None,
            "shift": None,
            "approx_multiplier": None,
            "absolute_error": None,
            "relative_error": None,
            "status": "invalid_scale",
        }

    best: dict[str, Any] | None = None
    for shift in range(max_shift + 1):
        scaled = real_multiplier * float(1 << shift)
        multiplier_int = int(round(scaled))
        if multiplier_int <= 0 or multiplier_int > INT32_MAX:
            continue
        approx = float(multiplier_int) / float(1 << shift)
        abs_error = abs(approx - real_multiplier)
        rel_error = abs_error / abs(real_multiplier)
        candidate = {
            "real_multiplier": real_multiplier,
            "multiplier_int": multiplier_int,
            "shift": shift,
            "approx_multiplier": approx,
            "absolute_error": abs_error,
            "relative_error": rel_error,
            "status": "searched",
        }
        if best is None or rel_error < float(best["relative_error"]):
            best = candidate
    if best is None:
        return {
            "real_multiplier": real_multiplier,
            "multiplier_int": None,
            "shift": None,
            "approx_multiplier": None,
            "absolute_error": None,
            "relative_error": None,
            "status": "no_int32_solution",
        }
    return best


def ratio(src_scale: Any, dst_scale: Any) -> float | None:
    if src_scale is None or dst_scale is None:
        return None
    src = float(src_scale)
    dst = float(dst_scale)
    if src <= 0.0 or dst <= 0.0:
        return None
    return src / dst


def add_error(errors: list[float], result: dict[str, Any]) -> None:
    if result.get("status") == "searched" and result.get("relative_error") is not None:
        errors.append(float(result["relative_error"]))


def main() -> int:
    parser = argparse.ArgumentParser(description="Search ResNet-20 requant multiplier/shift plan")
    parser.add_argument("--quant-params", required=True)
    parser.add_argument("--requant-plan", required=True)
    parser.add_argument("--folded-layers", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    quant_params = read_json(Path(args.quant_params))
    requant_plan = read_json(Path(args.requant_plan))
    folded_layers = read_json(Path(args.folded_layers))

    if quant_params.get("arch") != ARCH:
        raise SystemExit(f"quant params arch mismatch: {quant_params.get('arch')!r}")
    if requant_plan.get("arch") != ARCH:
        raise SystemExit(f"requant plan arch mismatch: {requant_plan.get('arch')!r}")
    if folded_layers.get("arch") != ARCH:
        raise SystemExit(f"folded layers arch mismatch: {folded_layers.get('arch')!r}")

    conv_fc_items = requant_plan.get("conv_fc", [])
    add_items = requant_plan.get("residual_add", [])
    if len(conv_fc_items) != 22:
        raise SystemExit(f"expected 22 conv/fc items, got {len(conv_fc_items)}")
    if len(add_items) != 9:
        raise SystemExit(f"expected 9 residual add items, got {len(add_items)}")
    f2_same_scale_pending = int(requant_plan.get("same_scale_pending_count", 0))

    errors: list[float] = []
    invalid_scale_count = 0
    conv_fc_results: list[dict[str, Any]] = []
    for item in conv_fc_items:
        real = item.get("accumulator_scale")
        output_scale = item.get("output_scale")
        if real is None or output_scale is None or float(output_scale) <= 0.0:
            result = search_multiplier_shift(float("nan"))
            invalid_scale_count += 1
        else:
            result = search_multiplier_shift(float(real) / float(output_scale))
            if result["status"] != "searched":
                invalid_scale_count += 1
        add_error(errors, result)
        conv_fc_results.append({
            "op": item.get("op"),
            "op_type": item.get("op_type"),
            "input_tensor": item.get("input_tensor"),
            "output_tensor": item.get("output_tensor"),
            "input_scale": item.get("input_scale"),
            "weight_scale": item.get("weight_scale"),
            "accumulator_scale": item.get("accumulator_scale"),
            "output_scale": output_scale,
            "requant": result,
            "status": result["status"],
        })

    add_results: list[dict[str, Any]] = []
    for item in add_items:
        main_real = ratio(item.get("main_branch_scale"), item.get("target_add_scale"))
        shortcut_real = ratio(item.get("shortcut_branch_scale"), item.get("target_add_scale"))
        main_result = search_multiplier_shift(float("nan") if main_real is None else main_real)
        shortcut_result = search_multiplier_shift(float("nan") if shortcut_real is None else shortcut_real)
        for result in (main_result, shortcut_result):
            if result["status"] != "searched":
                invalid_scale_count += 1
            add_error(errors, result)
        add_results.append({
            "op": item.get("op"),
            "main_branch_tensor": item.get("main_branch_tensor"),
            "shortcut_branch_tensor": item.get("shortcut_branch_tensor"),
            "target_tensor": item.get("target_tensor"),
            "post_relu_tensor": item.get("post_relu_tensor"),
            "main_branch_scale": item.get("main_branch_scale"),
            "shortcut_branch_scale": item.get("shortcut_branch_scale"),
            "target_add_scale": item.get("target_add_scale"),
            "post_relu_scale": item.get("post_relu_scale"),
            "alignment_policy": "align_both_branches_to_target_add_scale",
            "main_to_target": main_result,
            "shortcut_to_target": shortcut_result,
            "same_scale_status": "planned_alignment_not_end_to_end_verified",
            "source_same_scale_status": item.get("same_scale_status"),
        })

    max_relative_error = max(errors) if errors else None
    mean_relative_error = sum(errors) / len(errors) if errors else None
    warning = bool(max_relative_error is None or max_relative_error > 1e-6 or invalid_scale_count)

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    deterministic_json_dump(out_dir / "conv_fc_requant.json", {
        "arch": ARCH,
        "source_quant_params": args.quant_params,
        "source_requant_plan": args.requant_plan,
        "conv_fc_requant_count": len(conv_fc_results),
        "items": conv_fc_results,
        "status": "searched_not_end_to_end_verified",
    })
    deterministic_json_dump(out_dir / "residual_add_alignment.json", {
        "arch": ARCH,
        "source_requant_plan": args.requant_plan,
        "residual_add_alignment_count": len(add_results),
        "alignment_policy": "align_both_branches_to_target_add_scale",
        "items": add_results,
        "same_scale_status": "planned_alignment_not_end_to_end_verified",
    })
    deterministic_json_dump(out_dir / "multiplier_shift_check.json", {
        "arch": ARCH,
        "search": {
            "formula": "multiplier_int = round(real_multiplier * 2^shift)",
            "shift_range": [0, 31],
            "int32_max": INT32_MAX,
        },
        "checked_conversion_count": len(errors),
        "invalid_scale_count": invalid_scale_count,
        "max_relative_error": max_relative_error,
        "mean_relative_error": mean_relative_error,
        "warning": warning,
    })
    deterministic_json_dump(out_dir / "summary.json", {
        "arch": ARCH,
        "status": "requant_search_skeleton",
        "source_quant_params": args.quant_params,
        "source_requant_plan": args.requant_plan,
        "source_folded_layers": args.folded_layers,
        "conv_fc_requant_count": len(conv_fc_results),
        "residual_add_alignment_count": len(add_results),
        "f2_same_scale_pending_count": f2_same_scale_pending,
        "residual_same_scale_status": "planned_alignment_not_end_to_end_verified",
        "invalid_scale_count": invalid_scale_count,
        "max_relative_error": max_relative_error,
        "mean_relative_error": mean_relative_error,
        "warning": warning,
        "outputs": {
            "conv_fc_requant": "conv_fc_requant.json",
            "residual_add_alignment": "residual_add_alignment.json",
            "multiplier_shift_check": "multiplier_shift_check.json",
        },
        "fixed_point_status": "not_implemented",
        "fixed_point_accuracy_gate": {
            "required_accuracy": 0.80,
            "status": "not_evaluated",
            "reason": "requant planning does not run actual end-to-end fixed-point inference",
        },
        "generated_memh_files": [],
        "task_sequence": None,
        "memory_reuse_map": None,
        "r0_5_unfinished": R0_5_UNFINISHED,
    })
    print(out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
