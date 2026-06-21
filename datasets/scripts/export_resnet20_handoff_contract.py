#!/usr/bin/env python3
"""Export ResNet-20 R0.5 RTL handoff contract JSON.

F6b closes the handoff *contract* for folded bias, GAP, and residual ADD.  It
does not generate final RTL memh files, task sequences, or the 1 MB memory map.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from resnet20_cifar10_common import ARCH, deterministic_json_dump


R0_5_UNFINISHED = [
    "int8_weights_memh",
    "int32_folded_bias_memh",
    "final_task_sequence",
    "one_mb_memory_reuse_map",
    "rtl_r1_implementation",
]


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="ascii"))


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def folded_bias_contract() -> dict[str, Any]:
    return {
        "status": "closed_for_export",
        "rtl_consumption": "rtl_consumption_required_in_R1",
        "formula": {
            "folded_bias": "beta - running_mean * gamma / sqrt(running_var + eps)",
            "bias_int32": "round_half_away_from_zero(folded_bias / accumulator_scale)",
            "accumulator_scale": "input_activation_scale * weight_scale",
        },
        "dtype": "signed_int32",
        "layout": "one_bias_per_output_channel_or_output_neuron",
        "ordering": {
            "conv": "output_channel_order",
            "fc": "output_neuron_order",
        },
        "rounding": "round_half_away_from_zero",
        "generated_memh": False,
    }


def gap_contract() -> dict[str, Any]:
    return {
        "status": "closed_for_export",
        "rtl_datapath": "rtl_datapath_required_in_R1",
        "op_class": "GAP8x8",
        "input": {
            "tensor": "final_residual_block_activation",
            "dtype": "INT8",
            "shape": "N x 64 x 8 x 8 logical feature tensor",
        },
        "operation": {
            "sum": "sum 8x8 spatial region per channel in INT32",
            "divide": "divide by 64 using fixed shift/reciprocal contract",
            "requant": "convert to gap.output scale with multiplier/shift",
            "hardware_divider": "not_allowed",
        },
        "output": {
            "dtype": "INT8",
            "length": 64,
        },
        "implementation_policy": "dedicated_GAP_task_or_explicit_task_sequence_macro_allowed_if_contract_preserved",
        "generated_memh": False,
    }


def residual_add_contract(residual_add: dict[str, Any]) -> dict[str, Any]:
    return {
        "status": "closed_for_export",
        "rtl_datapath": "rtl_datapath_required_in_R1",
        "source": "datasets/cifar10/resnet20_requant_plan/residual_add_alignment.json",
        "alignment_policy": residual_add.get("alignment_policy", "align_both_branches_to_target_add_scale"),
        "same_scale_status": "closed_for_export_using_planned_alignment",
        "residual_add_count": int(residual_add.get("residual_add_alignment_count", len(residual_add.get("items", [])))),
        "branch_alignment": {
            "main": "requant main branch to target_add_scale",
            "shortcut": "requant shortcut branch to target_add_scale",
        },
        "add": "INT32 aligned main + INT32 aligned shortcut",
        "postprocess": [
            "ReLU in INT32 domain",
            "requant to post_relu_scale",
            "clamp signed INT8 [-128,127]",
        ],
        "task_expression": "ADD task or postprocess op placeholder allowed as contract; RTL datapath required in R1",
        "generated_task_sequence": False,
    }


def build_numerical_contract(
    quant_params: dict[str, Any],
    conv_fc: dict[str, Any],
    residual_add: dict[str, Any],
) -> dict[str, Any]:
    return {
        "arch": ARCH,
        "rounding": {
            "rule": "round_half_away_from_zero",
            "status": "closed_for_export",
            "source": "F6a reviewed existing requant_i32_to_i8 match",
        },
        "saturation": {
            "activation_int8": {"min": -128, "max": 127},
            "status": "closed_for_export",
        },
        "requant": {
            "formula": "clamp(round_half_away_from_zero(acc * multiplier / 2^shift), -128, 127)",
            "multiplier_domain": "positive int32-compatible integer",
            "shift_domain": "0..31",
            "conv_fc_requant_count": int(conv_fc.get("conv_fc_requant_count", len(conv_fc.get("items", [])))),
            "residual_add_alignment_count": int(residual_add.get("residual_add_alignment_count", len(residual_add.get("items", [])))),
            "status": "closed_for_export",
        },
        "weight_quantization": {
            "dtype": "INT8",
            "scheme": "per_tensor_symmetric_signed_int8",
            "per_channel_quantization": "not_implemented_v1",
            "source": "datasets/cifar10/resnet20_quant_calibration/quant_params.json",
            "weight_tensor_count": len(quant_params.get("weight_scales", {})),
            "status": "closed_for_export",
        },
        "bias_quantization": folded_bias_contract(),
        "activation_quantization": {
            "dtype": "INT8",
            "scheme": "per_tensor_symmetric_signed_int8",
            "input_layout": "HWC",
            "input_quantization": "uint8_minus_128",
            "activation_tensor_count": len(quant_params.get("activation_scales", {})),
            "status": "closed_for_export",
        },
        "GAP": gap_contract(),
        "residual_ADD": residual_add_contract(residual_add),
    }


def build_op_contract() -> dict[str, Any]:
    return {
        "arch": ARCH,
        "status": "closed_for_export",
        "op_classes": {
            "CONV3x3": {
                "input_dtype": "INT8",
                "weight_dtype": "INT8",
                "bias_dtype": "INT32",
                "accumulate_dtype": "INT32",
                "postprocess": ["optional_ReLU", "requant_to_INT8"],
                "rtl_requirement": "R1 generalized conv datapath must support kernel3x3",
            },
            "CONV1x1_PROJECTION": {
                "input_dtype": "INT8",
                "weight_dtype": "INT8",
                "bias_dtype": "INT32",
                "accumulate_dtype": "INT32",
                "stride": 2,
                "postprocess": ["requant_to_INT8"],
                "rtl_requirement": "R1 projection conv datapath required for downsample shortcuts",
            },
            "RESIDUAL_ADD": {
                "input_dtype": "INT8 branches with planned same-scale alignment",
                "aligned_dtype": "INT32",
                "output_dtype": "INT8 after ReLU/requant/clamp",
                "rtl_requirement": "R1 ADD datapath or explicit postprocess op required",
            },
            "GAP8x8": {
                "input_dtype": "INT8",
                "accumulate_dtype": "INT32",
                "output_dtype": "INT8",
                "rtl_requirement": "R1 GAP datapath or explicit task sequence macro required; no hardware divider",
            },
            "FC10": {
                "input_dtype": "INT8",
                "weight_dtype": "INT8",
                "bias_dtype": "INT32",
                "accumulate_dtype": "INT32",
                "output": "10 logits",
                "rtl_requirement": "arrayized FC path with folded bias and fixed requant contract",
            },
        },
    }


def build_export_manifest_schema() -> dict[str, Any]:
    return {
        "schema": "resnet20_r0_5_export_manifest_v1",
        "status": "schema_only_no_assets_generated",
        "required_files": {
            "weights": {
                "glob": "weights/*.memh",
                "description": "INT8 weights in RTL handoff layout",
                "generated_in_f6b": False,
            },
            "bias": {
                "glob": "bias/*.memh",
                "description": "INT32 folded bias in output channel/neuron order",
                "generated_in_f6b": False,
            },
            "requant": {
                "glob": "requant/*.json or requant/*.memh",
                "description": "multiplier/shift parameters for Conv/FC, residual alignment, GAP, and post-ReLU requant",
                "generated_in_f6b": False,
            },
            "task_sequence": {
                "path": "task_sequence.json",
                "description": "ordered ResNet-20 task list for the single-task register-triggered model",
                "generated_in_f6b": False,
            },
            "memory_map": {
                "path": "memory_map.json",
                "description": "1 MB shared-memory reuse map respecting 64B alignment",
                "generated_in_f6b": False,
            },
            "fixture": {
                "path": "fixture/",
                "description": "sample inputs, labels, expected predictions, and debug metadata",
                "generated_in_f6b": False,
            },
            "manifest": {
                "path": "manifest.json",
                "description": "top-level export manifest referencing all handoff assets",
                "generated_in_f6b": False,
            },
            "summary": {
                "path": "summary.json",
                "description": "export summary with source checkpoint, fixed-point eval evidence, and contract versions",
                "generated_in_f6b": False,
            },
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Export ResNet-20 RTL handoff contract")
    parser.add_argument("--fixed-eval", required=True)
    parser.add_argument("--rtl-lock-review", required=True)
    parser.add_argument("--conv-fc-requant", required=True)
    parser.add_argument("--residual-add-alignment", required=True)
    parser.add_argument("--quant-params", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    fixed_eval_path = Path(args.fixed_eval)
    rtl_lock_path = Path(args.rtl_lock_review)
    conv_fc_path = Path(args.conv_fc_requant)
    residual_path = Path(args.residual_add_alignment)
    quant_path = Path(args.quant_params)
    output_dir = Path(args.output_dir)

    fixed_eval = read_json(fixed_eval_path)
    rtl_lock = read_json(rtl_lock_path)
    conv_fc = read_json(conv_fc_path)
    residual_add = read_json(residual_path)
    quant_params = read_json(quant_path)

    validation_errors: list[str] = []
    for label, payload in (
        ("fixed_eval", fixed_eval),
        ("rtl_lock_review", rtl_lock),
        ("conv_fc_requant", conv_fc),
        ("residual_add_alignment", residual_add),
        ("quant_params", quant_params),
    ):
        require(payload.get("arch") == ARCH, f"{label} arch mismatch: {payload.get('arch')!r}", validation_errors)
    fixed_accuracy = float(fixed_eval.get("fixed_point_accuracy", 0.0))
    gate_status = fixed_eval.get("fixed_point_accuracy_gate", {}).get("status", rtl_lock.get("gate_status", "unknown"))
    require(gate_status == "passed", f"gate_status is {gate_status!r}, expected 'passed'", validation_errors)
    require(fixed_accuracy >= 0.80, f"fixed_point_accuracy {fixed_accuracy} is below 0.80", validation_errors)
    require(
        rtl_lock.get("rtl_lock_status") == "reviewed_with_open_items",
        f"rtl_lock_status is {rtl_lock.get('rtl_lock_status')!r}, expected reviewed_with_open_items",
        validation_errors,
    )

    numerical = build_numerical_contract(quant_params, conv_fc, residual_add)
    op_contract = build_op_contract()
    export_schema = build_export_manifest_schema()

    closed_items = [
        {
            "item": "folded_bias_int32_rounding",
            "status": "closed_for_export",
            "rtl_requirement": "rtl_consumption_required_in_R1",
        },
        {
            "item": "gap_reciprocal_shift_contract",
            "status": "closed_for_export",
            "rtl_requirement": "rtl_datapath_required_in_R1",
        },
        {
            "item": "residual_add_datapath_contract",
            "status": "closed_for_export",
            "rtl_requirement": "rtl_datapath_required_in_R1",
        },
    ]
    waiver_items: list[dict[str, Any]] = []
    unresolved_items: list[dict[str, Any]] = []
    handoff_status = "unresolved" if validation_errors else "reviewed_contract_closed_for_export"

    summary = {
        "arch": ARCH,
        "source_fixed_eval": str(fixed_eval_path),
        "source_rtl_lock_review": str(rtl_lock_path),
        "source_conv_fc_requant": str(conv_fc_path),
        "source_residual_add_alignment": str(residual_path),
        "source_quant_params": str(quant_path),
        "fixed_point_accuracy": fixed_accuracy,
        "fixed_point_correct": fixed_eval.get("fixed_point_correct"),
        "fixed_point_total": fixed_eval.get("sample_count"),
        "gate_status": gate_status,
        "f6a_previous_status": rtl_lock.get("rtl_lock_status"),
        "handoff_contract_status": handoff_status,
        "closed_items": closed_items,
        "waiver_items": waiver_items,
        "unresolved_items": unresolved_items,
        "validation_errors": validation_errors,
        "next_allowed_stage": "export_int8_int32_assets" if not validation_errors else "resolve_open_items_or_waiver",
        "rtl_r1_started": False,
        "rtl_memh_generated": False,
        "rtl_task_sequence_generated": False,
        "one_mb_memory_reuse_map_generated": False,
        "generated_files": [
            "summary.json",
            "numerical_contract.json",
            "op_contract.json",
            "export_manifest_schema.json",
        ],
        "r0_5_unfinished": R0_5_UNFINISHED,
    }

    deterministic_json_dump(output_dir / "summary.json", summary)
    deterministic_json_dump(output_dir / "numerical_contract.json", numerical)
    deterministic_json_dump(output_dir / "op_contract.json", op_contract)
    deterministic_json_dump(output_dir / "export_manifest_schema.json", export_schema)

    print(f"Wrote {output_dir / 'summary.json'}")
    print(f"handoff_contract_status={handoff_status}")
    print(f"next_allowed_stage={summary['next_allowed_stage']}")
    print(f"closed_items={len(closed_items)}")
    print(f"unresolved_items={len(unresolved_items)}")
    return 1 if validation_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
