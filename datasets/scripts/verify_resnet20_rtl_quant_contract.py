#!/usr/bin/env python3
"""Generate ResNet-20 RTL-lock quantization contract review vectors.

This script compares the ResNet-20 R0.5 software fixed-point helper contract
against the existing LeNet/NPU requant primitive contract.  It only emits JSON
review assets; it does not generate RTL memh files, task sequences, or memory
reuse maps.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

from resnet20_cifar10_common import ARCH, deterministic_json_dump


INSPECTED_SOURCES = [
    {
        "path": "rtl/npu/requant_i32_to_i8.v",
        "role": "RTL requant primitive",
        "conclusion": "round-half-away-from-zero after acc*multiplier/2^shift, then clamp to signed INT8",
    },
    {
        "path": "tb/unit/tb_requant_i32_to_i8.v",
        "role": "RTL unit vector evidence",
        "conclusion": "covers negative half-away and INT8 clamp boundary cases",
    },
    {
        "path": "datasets/scripts/requant_utils.py",
        "role": "LeNet software requant reference",
        "conclusion": "documents and implements the same round-half-away + clamp formula",
    },
    {
        "path": "datasets/scripts/run_resnet20_fixed_point_smoke.py",
        "role": "ResNet fixed-point software helper",
        "conclusion": "uses integer product, half-away shift rounding, and signed INT8 clamp",
    },
    {
        "path": "datasets/scripts/search_resnet20_requant_plan.py",
        "role": "ResNet multiplier/shift search",
        "conclusion": "searches positive int32 multipliers and shifts in 0..31",
    },
    {
        "path": "rtl/npu/task_checker.v",
        "role": "runtime requant parameter legality",
        "conclusion": "requires non-zero multiplier and shift <= 31 for requant tasks",
    },
    {
        "path": "rtl/npu/npu_ctrl.v",
        "role": "AXI-Lite requant register contract",
        "conclusion": "exposes layer-wise multiplier and 6-bit shift slots",
    },
    {
        "path": "rtl/npu/npu_top.v",
        "role": "NPU requant datapath integration",
        "conclusion": "instantiates requant_i32_to_i8 for INT32->INT8 requant output",
    },
    {
        "path": "docs/LENET_MNIST_SPEC.md",
        "role": "current LeNet numerical contract",
        "conclusion": "fixes multiplier + shift + round-half-away-from-zero + clamp",
    },
    {
        "path": "docs/REAL_WEIGHT_FLOW.md",
        "role": "real-weight flow contract",
        "conclusion": "uses acc*multiplier, shift, half-away rounding, and signed INT8 clamp",
    },
    {
        "path": "docs/RESNET20_SOFTWARE_GOLDEN_PLAN.md",
        "role": "ResNet planned numerical contract",
        "conclusion": "requires INT8/INT32 operators and existing project requant semantics",
    },
    {
        "path": "docs/RESNET20_FIXED_POINT_GOLDEN_PLAN.md",
        "role": "ResNet fixed-point status",
        "conclusion": "records F5 full fixed-point gate pass and pending RTL-lock review",
    },
]


UNRESOLVED_ITEMS = [
    {
        "item": "folded_bias_int32_rounding",
        "status": "needs_rtl_owner_decision",
        "detail": (
            "ResNet software uses round-half-away-from-zero for folded_bias / accumulator_scale. "
            "The existing LeNet requant primitive matches the rounding rule, but there is no "
            "current ResNet bias export/RTL consumption path to lock yet."
        ),
    },
    {
        "item": "gap_reciprocal_shift_contract",
        "status": "needs_rtl_owner_decision",
        "detail": (
            "ResNet software GAP uses fixed-point ratio requantization over the spatial sum. "
            "Existing RTL does not yet provide a ResNet GAP datapath to compare."
        ),
    },
    {
        "item": "residual_add_datapath_contract",
        "status": "needs_rtl_owner_decision",
        "detail": (
            "F3/F5 execute planned same-scale branch alignment with the same requant primitive. "
            "The future ADD RTL must explicitly adopt this contract before R1 handoff."
        ),
    },
]


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="ascii"))


def round_half_away_rational(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        raise ValueError("denominator must be positive")
    sign = -1 if numerator < 0 else 1
    abs_num = abs(numerator)
    quotient = abs_num // denominator
    remainder = abs_num % denominator
    rounded_abs = quotient + (1 if (2 * remainder) >= denominator else 0)
    return sign * rounded_abs


def requantize_int(acc: int, multiplier: int, shift: int) -> dict[str, Any]:
    if multiplier < 0:
        raise ValueError("contract assumes non-negative multiplier")
    if shift < 0:
        raise ValueError("shift must be non-negative")
    product = int(acc) * int(multiplier)
    sign = -1 if product < 0 else 1
    abs_product = abs(product)
    if shift == 0:
        rounded_abs = abs_product
    else:
        rounded_abs = (abs_product + (1 << (shift - 1))) >> shift
    rounded = sign * rounded_abs
    clamped = max(-128, min(127, rounded))
    return {
        "acc": int(acc),
        "multiplier_int": int(multiplier),
        "shift": int(shift),
        "product": int(product),
        "rounded": int(rounded),
        "clamped_int8": int(clamped),
    }


def validate_requant_item(item: dict[str, Any], source: str) -> list[str]:
    errors: list[str] = []
    requant = item.get("requant", item)
    multiplier = requant.get("multiplier_int")
    shift = requant.get("shift")
    status = requant.get("status")
    if status != "searched":
        errors.append(f"{source}:{item.get('op', '<unknown>')} status {status!r} is not searched")
    if not isinstance(multiplier, int) or multiplier <= 0 or multiplier > 0x7FFF_FFFF:
        errors.append(f"{source}:{item.get('op', '<unknown>')} invalid multiplier {multiplier!r}")
    if not isinstance(shift, int) or shift < 0 or shift > 31:
        errors.append(f"{source}:{item.get('op', '<unknown>')} invalid shift {shift!r}")
    return errors


def build_rounding_vectors() -> dict[str, Any]:
    cases = [
        ("zero", 0, 1),
        ("positive_half", 1, 2),
        ("negative_half", -1, 2),
        ("positive_one_point_five", 3, 2),
        ("negative_one_point_five", -3, 2),
        ("positive_below_half", 49, 100),
        ("negative_below_half", -49, 100),
        ("positive_above_half", 51, 100),
        ("negative_above_half", -51, 100),
        ("positive_near_int8_max_half", 253, 2),
        ("negative_near_int8_min_half", -255, 2),
    ]
    vectors = []
    for name, numerator, denominator in cases:
        vectors.append({
            "name": name,
            "numerator": numerator,
            "denominator": denominator,
            "expected_round_half_away": round_half_away_rational(numerator, denominator),
        })
    return {
        "contract": "round_half_away_from_zero",
        "vectors": vectors,
    }


def pick_requant_examples(conv_fc: dict[str, Any], residual_add: dict[str, Any]) -> list[dict[str, Any]]:
    examples: list[dict[str, Any]] = []
    conv_items = conv_fc.get("items", [])
    for item in conv_items[:5]:
        examples.append({
            "source": "conv_fc",
            "op": item.get("op"),
            "requant": item.get("requant", {}),
        })
    if conv_items:
        examples.append({
            "source": "conv_fc",
            "op": conv_items[-1].get("op"),
            "requant": conv_items[-1].get("requant", {}),
        })
    for item in residual_add.get("items", [])[:3]:
        examples.append({
            "source": "residual_add_main_to_target",
            "op": item.get("op"),
            "requant": item.get("main_to_target", {}),
        })
        examples.append({
            "source": "residual_add_shortcut_to_target",
            "op": item.get("op"),
            "requant": item.get("shortcut_to_target", {}),
        })
    return examples


def build_requant_vectors(conv_fc: dict[str, Any], residual_add: dict[str, Any]) -> dict[str, Any]:
    base_cases = [
        ("zero_identity", 0, 1, 0),
        ("positive_half", 1, 1, 1),
        ("negative_half", -1, 1, 1),
        ("rtl_unit_negative_half_away", -101, 1, 1),
        ("rtl_unit_clamp_pos", 255, 1, 1),
        ("rtl_unit_clamp_neg", -300, 1, 1),
        ("near_clamp_pos_half", 253, 1, 1),
        ("near_clamp_neg_half", -255, 1, 1),
        ("large_acc_pos", 2_147_483_647, 1, 24),
        ("large_acc_neg", -2_147_483_648, 1, 24),
    ]
    deterministic = []
    for name, acc, multiplier, shift in base_cases:
        deterministic.append({"name": name, **requantize_int(acc, multiplier, shift)})

    representative_acc = [-4096, -257, -1, 0, 1, 257, 4096]
    plan_examples = []
    for example in pick_requant_examples(conv_fc, residual_add):
        requant = example["requant"]
        multiplier = int(requant["multiplier_int"])
        shift = int(requant["shift"])
        plan_examples.append({
            "source": example["source"],
            "op": example["op"],
            "multiplier_int": multiplier,
            "shift": shift,
            "real_multiplier": requant.get("real_multiplier"),
            "relative_error": requant.get("relative_error"),
            "vectors": [requantize_int(acc, multiplier, shift) for acc in representative_acc],
        })

    return {
        "contract": "clamp(round_half_away_from_zero(acc * multiplier / 2^shift), -128, 127)",
        "deterministic_vectors": deterministic,
        "f3_plan_examples": plan_examples,
    }


def collect_relative_errors(conv_fc: dict[str, Any], residual_add: dict[str, Any]) -> list[float]:
    errors: list[float] = []
    for item in conv_fc.get("items", []):
        requant = item.get("requant", {})
        if isinstance(requant.get("relative_error"), (int, float)) and math.isfinite(float(requant["relative_error"])):
            errors.append(float(requant["relative_error"]))
    for item in residual_add.get("items", []):
        for key in ("main_to_target", "shortcut_to_target"):
            requant = item.get(key, {})
            if isinstance(requant.get("relative_error"), (int, float)) and math.isfinite(float(requant["relative_error"])):
                errors.append(float(requant["relative_error"]))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify ResNet-20 RTL quantization contract")
    parser.add_argument("--fixed-eval", required=True)
    parser.add_argument("--conv-fc-requant", required=True)
    parser.add_argument("--residual-add-alignment", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    fixed_eval_path = Path(args.fixed_eval)
    conv_fc_path = Path(args.conv_fc_requant)
    residual_path = Path(args.residual_add_alignment)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    fixed_eval = read_json(fixed_eval_path)
    conv_fc = read_json(conv_fc_path)
    residual_add = read_json(residual_path)

    validation_errors: list[str] = []
    for name, data in (("fixed_eval", fixed_eval), ("conv_fc_requant", conv_fc), ("residual_add_alignment", residual_add)):
        if data.get("arch") != ARCH:
            validation_errors.append(f"{name} arch {data.get('arch')!r} does not match {ARCH!r}")
    if int(conv_fc.get("conv_fc_requant_count", len(conv_fc.get("items", [])))) != 22:
        validation_errors.append("conv/fc requant count is not 22")
    if int(residual_add.get("residual_add_alignment_count", len(residual_add.get("items", [])))) != 9:
        validation_errors.append("residual ADD alignment count is not 9")
    for item in conv_fc.get("items", []):
        validation_errors.extend(validate_requant_item(item, "conv_fc"))
    for item in residual_add.get("items", []):
        validation_errors.extend(validate_requant_item({"op": item.get("op"), **item.get("main_to_target", {})}, "residual_add.main"))
        validation_errors.extend(validate_requant_item({"op": item.get("op"), **item.get("shortcut_to_target", {})}, "residual_add.shortcut"))

    rounding_vectors = build_rounding_vectors()
    requant_vectors = build_requant_vectors(conv_fc, residual_add)

    errors = collect_relative_errors(conv_fc, residual_add)
    max_relative_error = max(errors) if errors else None
    mean_relative_error = sum(errors) / len(errors) if errors else None

    fixed_accuracy = float(fixed_eval.get("fixed_point_accuracy", 0.0))
    gate = fixed_eval.get("fixed_point_accuracy_gate", {})
    gate_status = gate.get("status", "unknown")

    rtl_lock_status = "reviewed_with_open_items"
    summary = {
        "arch": ARCH,
        "source_full_eval": str(fixed_eval_path),
        "source_conv_fc_requant": str(conv_fc_path),
        "source_residual_add_alignment": str(residual_path),
        "fixed_point_accuracy": fixed_accuracy,
        "fixed_point_correct": fixed_eval.get("fixed_point_correct"),
        "fixed_point_total": fixed_eval.get("sample_count"),
        "gate_status": gate_status,
        "rtl_lock_status": rtl_lock_status,
        "rounding_contract": {
            "status": "match_existing_requant_primitive",
            "rule": "round_half_away_from_zero",
            "rtl_source": "rtl/npu/requant_i32_to_i8.v",
            "software_source": "datasets/scripts/run_resnet20_fixed_point_smoke.py",
        },
        "saturation_contract": {
            "status": "match_existing_requant_primitive",
            "int8_min": -128,
            "int8_max": 127,
            "rtl_source": "rtl/npu/requant_i32_to_i8.v",
        },
        "requant_contract": {
            "status": "match_for_existing_multiplier_shift_primitive",
            "formula": "clamp(round_half_away_from_zero(acc * multiplier / 2^shift), -128, 127)",
            "multiplier_domain": "positive_uint32_restricted_to_signed_int32_by_resnet_f3_search",
            "shift_domain": "0..31",
            "conv_fc_requant_count": len(conv_fc.get("items", [])),
            "residual_add_alignment_count": len(residual_add.get("items", [])),
            "max_relative_error": max_relative_error,
            "mean_relative_error": mean_relative_error,
        },
        "contract_comparison": {
            "round_half_away_from_zero": "match",
            "round_shift_half_away": "match",
            "requantize_int64": "match_for_existing_primitive",
            "int8_clamp": "match",
            "bias_int32_rounding": "unresolved_needs_rtl_owner_decision",
            "gap_reciprocal_shift": "unresolved_needs_rtl_owner_decision",
            "residual_add_same_scale_alignment": "planned_with_matching_requant_primitive_but_add_rtl_not_started",
        },
        "inspected_sources": INSPECTED_SOURCES,
        "unresolved_items": UNRESOLVED_ITEMS,
        "validation_errors": validation_errors,
        "rounding_vectors": "rounding_vectors.json",
        "requant_vectors": "requant_vectors.json",
        "next_allowed_stage": "resolve_open_items_or_waiver",
        "rtl_memh_generated": False,
        "rtl_task_sequence_generated": False,
        "one_mb_memory_reuse_map_generated": False,
        "rtl_r1_started": False,
    }
    if validation_errors:
        summary["rtl_lock_status"] = "mismatch_found"

    deterministic_json_dump(output_dir / "rounding_vectors.json", rounding_vectors)
    deterministic_json_dump(output_dir / "requant_vectors.json", requant_vectors)
    deterministic_json_dump(output_dir / "summary.json", summary)

    print(f"Wrote {output_dir / 'summary.json'}")
    print(f"rtl_lock_status={summary['rtl_lock_status']}")
    print(f"fixed_point_accuracy={fixed_accuracy}")
    print(f"unresolved_items={len(UNRESOLVED_ITEMS)}")
    return 1 if validation_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
