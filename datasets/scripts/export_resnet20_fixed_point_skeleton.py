#!/usr/bin/env python3
"""Export ResNet-20 fixed-point golden skeleton metadata.

This script deliberately does not generate memh files, task sequences, or
memory reuse maps.  It only freezes the planned layer/operator inventory for
later fixed-point implementation.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import torch

from resnet20_cifar10_common import ARCH, deterministic_json_dump


R0_5_UNFINISHED = [
    "actual_fixed_point_inference",
    "accuracy_gate_80_percent",
    "real_cifar10_full_fixed_point_eval",
    "int8_weights_memh",
    "int32_folded_bias_memh",
    "final_task_sequence",
    "one_mb_memory_reuse_map",
]


def read_float_accuracy(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {
            "float_eval": None,
            "float_accuracy": 0.8648,
            "float_correct": 8648,
            "float_total": 10000,
        }
    payload = json.loads(path.read_text(encoding="ascii"))
    return {
        "float_eval": str(path),
        "float_accuracy": float(payload.get("accuracy", 0.8648)),
        "float_correct": int(payload.get("correct", 8648)),
        "float_total": int(payload.get("total", 10000)),
    }


def conv_op(
    name: str,
    input_shape: list[int],
    output_shape: list[int],
    kernel: int,
    stride: int,
    padding: int,
    *,
    has_bn: bool,
    shortcut_type: str = "none",
) -> dict[str, Any]:
    return {
        "name": name,
        "op_type": "conv",
        "input_shape": input_shape,
        "output_shape": output_shape,
        "kernel": [kernel, kernel],
        "stride": [stride, stride],
        "padding": [padding, padding],
        "has_bn": has_bn,
        "has_bias_after_folding": has_bn,
        "shortcut_type": shortcut_type,
        "quant_status": "not_implemented",
        "requant_status": "not_implemented",
    }


def add_op(name: str, shape: list[int], shortcut_type: str) -> dict[str, Any]:
    return {
        "name": name,
        "op_type": "residual_add",
        "input_shape": [shape, shape],
        "output_shape": shape,
        "kernel": None,
        "stride": None,
        "padding": None,
        "has_bn": False,
        "has_bias_after_folding": False,
        "shortcut_type": shortcut_type,
        "add_contract": "int32_same_scale",
        "postproc_options": ["ADD", "ADD_RELU", "ADD_REQUANT", "ADD_RELU_REQUANT"],
        "quant_status": "not_implemented",
        "requant_status": "not_implemented",
    }


def layer_skeleton() -> list[dict[str, Any]]:
    layers: list[dict[str, Any]] = []
    layers.append(conv_op("conv1", [3, 32, 32], [16, 32, 32], 3, 1, 1, has_bn=True))

    in_channels = 16
    spatial = 32
    for layer_name, channels, first_stride in (
        ("layer1", 16, 1),
        ("layer2", 32, 2),
        ("layer3", 64, 2),
    ):
        for block_idx in range(3):
            stride = first_stride if block_idx == 0 else 1
            out_spatial = spatial // stride
            input_shape = [in_channels, spatial, spatial]
            block_shape = [channels, out_spatial, out_spatial]
            shortcut_type = "projection_conv1x1_stride2" if stride != 1 or in_channels != channels else "identity"
            prefix = f"{layer_name}.{block_idx}"
            layers.append(conv_op(
                f"{prefix}.conv1",
                input_shape,
                block_shape,
                3,
                stride,
                1,
                has_bn=True,
                shortcut_type=shortcut_type,
            ))
            layers.append(conv_op(
                f"{prefix}.conv2",
                block_shape,
                block_shape,
                3,
                1,
                1,
                has_bn=True,
                shortcut_type=shortcut_type,
            ))
            if shortcut_type != "identity":
                layers.append(conv_op(
                    f"{prefix}.shortcut.proj",
                    input_shape,
                    block_shape,
                    1,
                    stride,
                    0,
                    has_bn=True,
                    shortcut_type=shortcut_type,
                ))
            layers.append(add_op(f"{prefix}.add", block_shape, shortcut_type))
            in_channels = channels
            spatial = out_spatial

    layers.append({
        "name": "global_average_pool",
        "op_type": "gap",
        "input_shape": [64, 8, 8],
        "output_shape": [64],
        "kernel": [8, 8],
        "stride": None,
        "padding": None,
        "has_bn": False,
        "has_bias_after_folding": False,
        "shortcut_type": "none",
        "gap_contract": "int32_input_int32_output_reciprocal_shift_no_divider",
        "quant_status": "not_implemented",
        "requant_status": "not_implemented",
    })
    layers.append({
        "name": "fc",
        "op_type": "fc",
        "input_shape": [64],
        "output_shape": [10],
        "kernel": None,
        "stride": None,
        "padding": None,
        "has_bn": False,
        "has_bias_after_folding": True,
        "shortcut_type": "none",
        "quant_status": "not_implemented",
        "requant_status": "not_implemented",
    })
    return layers


def main() -> int:
    parser = argparse.ArgumentParser(description="Export ResNet-20 fixed-point skeleton metadata")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--float-eval", default="")
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    checkpoint = Path(args.checkpoint)
    payload = torch.load(checkpoint, map_location="cpu")
    arch = payload.get("arch")
    if arch != ARCH:
        raise SystemExit(f"unsupported checkpoint arch {arch!r}, expected {ARCH!r}")
    if not isinstance(payload.get("model_state_dict"), dict):
        raise SystemExit("checkpoint missing model_state_dict")

    out_dir = Path(args.output_dir)
    weights_dir = out_dir / "weights"
    weights_dir.mkdir(parents=True, exist_ok=True)

    layers = layer_skeleton()
    deterministic_json_dump(out_dir / "layers.json", {
        "arch": ARCH,
        "source_checkpoint": str(checkpoint),
        "status": "fixed_point_layer_skeleton",
        "layers": layers,
        "operator_count": len(layers),
    })

    deterministic_json_dump(weights_dir / "summary.json", {
        "status": "skeleton_only",
        "source_checkpoint": str(checkpoint),
        "int8_weights": "not_generated",
        "int32_folded_bias": "not_generated",
        "memh_files": [],
        "preload_maps": [],
        "layout_target": {
            "conv_weight": "[in_c][k_h][k_w][out_c]",
            "fc_weight": "[out_neuron][in_neuron]",
            "bias": "[out_channel_or_neuron]",
        },
        "todo": [
            "fold batch norm into conv weights and int32 bias",
            "choose int8 quantization scales",
            "generate int8 weight memh",
            "generate int32 folded bias memh",
            "generate preload maps after memory reuse map is fixed",
        ],
    })

    float_eval_path = Path(args.float_eval) if args.float_eval else None
    float_info = read_float_accuracy(float_eval_path)
    summary = {
        "status": "fixed_point_golden_skeleton",
        "source_checkpoint": str(checkpoint),
        **float_info,
        "arch": ARCH,
        "fixed_point_status": "skeleton_only",
        "fixed_point_accuracy_gate": {
            "required_accuracy": 0.80,
            "status": "not_evaluated",
            "reason": "actual fixed-point inference is not implemented",
        },
        "numerical_contract": {
            "input": "INT8 HWC",
            "input_quantization": "uint8_minus_128_or_final_selected_input_quantization",
            "conv_fc_weight": "INT8",
            "conv_fc_accumulate": "INT32",
            "folded_bias": "INT32",
            "relu_domain": "INT32_before_requant",
            "requant": "round_half_away_from_zero",
            "add": "INT32_same_scale",
            "gap": "fixed_point_reciprocal_shift_no_divider",
        },
        "explicitly_not_implemented_v1": [
            "per_channel_quantization",
            "dual_branch_add_rescale",
            "asymmetric_zero_point",
            "rtl_changes",
        ],
        "generated": {
            "layers_json": "layers.json",
            "weights_summary": "weights/summary.json",
            "memh_files": [],
            "task_sequence": None,
            "memory_reuse_map": None,
        },
        "r0_5_unfinished": R0_5_UNFINISHED,
    }
    deterministic_json_dump(out_dir / "summary.json", summary)
    print(out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
