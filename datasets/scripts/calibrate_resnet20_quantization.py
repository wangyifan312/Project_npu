#!/usr/bin/env python3
"""Collect ResNet-20 activation calibration and quantization skeleton metadata.

F2 remains a software metadata stage.  It records activation ranges, initial
per-tensor symmetric INT8 scales, and planned requant relationships.  It does
not run actual fixed-point inference and does not generate RTL memh/task/memory
map assets.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import torch
import torch.nn as nn
import torch.nn.functional as F

from export_resnet20_bn_folded import build_folded_model
from resnet20_cifar10_common import ARCH, deterministic_json_dump, get_dataset, load_checkpoint


R0_5_UNFINISHED = [
    "actual_fixed_point_inference",
    "accuracy_gate_80_percent",
    "real_cifar10_full_fixed_point_eval",
    "int8_weights_memh",
    "int32_folded_bias_memh",
    "final_task_sequence",
    "one_mb_memory_reuse_map",
]


class TensorStats:
    def __init__(self) -> None:
        self.count = 0
        self.sum = 0.0
        self.min_value: float | None = None
        self.max_value: float | None = None
        self.max_abs = 0.0
        self.shape: list[int] | None = None

    def update(self, tensor: torch.Tensor) -> None:
        data = tensor.detach().cpu().to(torch.float32)
        if data.numel() == 0:
            return
        self.count += int(data.numel())
        self.sum += float(data.sum().item())
        min_v = float(data.min().item())
        max_v = float(data.max().item())
        self.min_value = min_v if self.min_value is None else min(self.min_value, min_v)
        self.max_value = max_v if self.max_value is None else max(self.max_value, max_v)
        self.max_abs = max(self.max_abs, abs(min_v), abs(max_v))
        self.shape = list(data.shape[1:]) if data.dim() > 1 else list(data.shape)

    def as_dict(self) -> dict[str, Any]:
        scale = self.max_abs / 127.0 if self.max_abs > 0.0 else 1.0
        return {
            "shape": self.shape,
            "count": self.count,
            "min": self.min_value,
            "max": self.max_value,
            "mean": float(self.sum / self.count) if self.count else 0.0,
            "max_abs": float(self.max_abs),
            "int8_symmetric_scale": float(scale),
            "zero_range_protected": bool(self.max_abs == 0.0),
        }


def scale_from_tensor(tensor: torch.Tensor) -> dict[str, Any]:
    data = tensor.detach().cpu().to(torch.float32)
    max_abs = float(data.abs().max().item()) if data.numel() else 0.0
    return {
        "shape": list(data.shape),
        "dtype": str(tensor.dtype),
        "min": float(data.min().item()) if data.numel() else None,
        "max": float(data.max().item()) if data.numel() else None,
        "mean": float(data.mean().item()) if data.numel() else None,
        "max_abs": max_abs,
        "int8_symmetric_scale": float(max_abs / 127.0) if max_abs > 0.0 else 1.0,
        "zero_range_protected": bool(max_abs == 0.0),
    }


def collect_activations(model: nn.Module, images: torch.Tensor, batch_size: int, device: str) -> dict[str, TensorStats]:
    stats: dict[str, TensorStats] = {}

    def record(name: str, tensor: torch.Tensor) -> None:
        stats.setdefault(name, TensorStats()).update(tensor)

    device_obj = torch.device(device)
    model.to(device_obj).eval()
    with torch.no_grad():
        for start in range(0, images.shape[0], batch_size):
            x = images[start:start + batch_size].to(device_obj)
            record("input", x)
            out = F.relu(model.conv1(x))
            record("conv1.relu", out)

            for layer_name in ("layer1", "layer2", "layer3"):
                layer = getattr(model, layer_name)
                for block_idx, block in enumerate(layer):
                    prefix = f"{layer_name}.{block_idx}"
                    shortcut_in = out
                    main1 = F.relu(block.conv1(out))
                    record(f"{prefix}.conv1.relu", main1)
                    main2 = block.conv2(main1)
                    record(f"{prefix}.conv2.pre_add_main", main2)
                    shortcut = block.shortcut(shortcut_in)
                    record(f"{prefix}.shortcut.pre_add", shortcut)
                    add_pre = main2 + shortcut
                    record(f"{prefix}.add.pre_relu", add_pre)
                    out = F.relu(add_pre)
                    record(f"{prefix}.add.relu", out)

            record("gap.input", out)
            gap = F.avg_pool2d(out, out.shape[-1])
            gap_flat = torch.flatten(gap, 1)
            record("gap.output", gap_flat)
            logits = model.fc(gap_flat)
            record("fc.logits", logits)

    return stats


def module_weight_scales(model: nn.Module) -> dict[str, dict[str, Any]]:
    weights = {}
    for name, module in model.named_modules():
        if isinstance(module, (nn.Conv2d, nn.Linear)):
            weights[name] = {
                "op_type": "conv" if isinstance(module, nn.Conv2d) else "fc",
                "weight": scale_from_tensor(module.weight),
                "bias": scale_from_tensor(module.bias) if module.bias is not None else None,
                "quantization": "per_tensor_symmetric_int8",
                "per_channel_quantization": "not_implemented",
            }
    return weights


def activation_scale(activation_stats: dict[str, Any], name: str) -> float | None:
    item = activation_stats.get(name)
    if item is None:
        return None
    return float(item["int8_symmetric_scale"])


def build_requant_plan(
    activation_stats: dict[str, Any],
    weight_scales: dict[str, dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    conv_fc_plan: list[dict[str, Any]] = []
    add_plan: list[dict[str, Any]] = []

    def add_conv_fc(
        name: str,
        input_tensor: str,
        output_tensor: str,
        module_name: str,
        op_type: str,
    ) -> None:
        input_scale = activation_scale(activation_stats, input_tensor)
        output_scale = activation_scale(activation_stats, output_tensor)
        weight_scale = float(weight_scales[module_name]["weight"]["int8_symmetric_scale"])
        conv_fc_plan.append({
            "op": name,
            "op_type": op_type,
            "input_tensor": input_tensor,
            "output_tensor": output_tensor,
            "input_scale": input_scale,
            "weight_scale": weight_scale,
            "accumulator_scale": float(input_scale * weight_scale) if input_scale is not None else None,
            "output_scale": output_scale,
            "requant_status": "planned_not_verified",
            "multiplier_shift_status": "not_searched",
        })

    add_conv_fc("conv1", "input", "conv1.relu", "conv1", "conv")
    previous_output = "conv1.relu"
    for layer_name in ("layer1", "layer2", "layer3"):
        for block_idx in range(3):
            prefix = f"{layer_name}.{block_idx}"
            conv1_out = f"{prefix}.conv1.relu"
            conv2_out = f"{prefix}.conv2.pre_add_main"
            shortcut_out = f"{prefix}.shortcut.pre_add"
            add_pre = f"{prefix}.add.pre_relu"
            add_relu = f"{prefix}.add.relu"
            add_conv_fc(f"{prefix}.conv1", previous_output, conv1_out, f"{prefix}.conv1", "conv")
            add_conv_fc(f"{prefix}.conv2", conv1_out, conv2_out, f"{prefix}.conv2", "conv")
            if f"{prefix}.shortcut" in weight_scales:
                add_conv_fc(f"{prefix}.shortcut.projection", previous_output, shortcut_out, f"{prefix}.shortcut", "conv_projection")

            main_scale = activation_scale(activation_stats, conv2_out)
            shortcut_scale = activation_scale(activation_stats, shortcut_out)
            target_scale = activation_scale(activation_stats, add_pre)
            same_scale = main_scale == shortcut_scale
            add_plan.append({
                "op": f"{prefix}.add",
                "main_branch_tensor": conv2_out,
                "shortcut_branch_tensor": shortcut_out,
                "target_tensor": add_pre,
                "post_relu_tensor": add_relu,
                "main_branch_scale": main_scale,
                "shortcut_branch_scale": shortcut_scale,
                "target_add_scale": target_scale,
                "post_relu_scale": activation_scale(activation_stats, add_relu),
                "same_scale_status": "same_scale" if same_scale else "pending_same_scale_alignment",
                "requant_status": "planned_not_verified",
            })
            previous_output = add_relu

    add_conv_fc("fc", "gap.output", "fc.logits", "fc", "fc")
    return conv_fc_plan, add_plan


def main() -> int:
    parser = argparse.ArgumentParser(description="Calibrate ResNet-20 activation ranges and quantization skeleton")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--cifar10-tar", default="datasets/cifar10/cifar-10-python.tar.gz")
    parser.add_argument("--folded-layers", default="datasets/cifar10/resnet20_bn_folded/folded_layers.json")
    parser.add_argument("--dataset-npz", default="")
    parser.add_argument("--split", choices=["train", "test"], default="train")
    parser.add_argument("--count", type=int, default=512)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    model, payload = load_checkpoint(Path(args.checkpoint))
    if payload.get("arch") != ARCH:
        raise SystemExit(f"unsupported checkpoint arch {payload.get('arch')!r}, expected {ARCH!r}")
    state = payload.get("model_state_dict")
    if not isinstance(state, dict):
        raise SystemExit("checkpoint missing model_state_dict")
    folded_model, folded_layers = build_folded_model(state)

    folded_layers_path = Path(args.folded_layers)
    folded_metadata = json.loads(folded_layers_path.read_text(encoding="ascii")) if folded_layers_path.exists() else {}

    images, labels, dataset_source = get_dataset(args, default_split=args.split)
    activation_collector = collect_activations(folded_model, images, args.batch_size, args.device)
    activation_stats = {name: stat.as_dict() for name, stat in sorted(activation_collector.items())}
    weight_scales = module_weight_scales(folded_model)
    conv_fc_plan, residual_add_plan = build_requant_plan(activation_stats, weight_scales)
    same_scale_pending = sum(1 for item in residual_add_plan if item["same_scale_status"] != "same_scale")

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    deterministic_json_dump(out_dir / "activation_stats.json", {
        "checkpoint": args.checkpoint,
        "arch": ARCH,
        "dataset_source": dataset_source,
        "split": args.split,
        "calibration_sample_count": int(labels.numel()),
        "activation_tensor_count": len(activation_stats),
        "activation_stats": activation_stats,
        "activation_quantization": {
            "dtype": "INT8",
            "scheme": "per_tensor_symmetric_signed",
            "scale_formula": "max_abs / 127",
            "zero_range_protection": "scale=1.0 when max_abs==0",
        },
    })

    deterministic_json_dump(out_dir / "quant_params.json", {
        "checkpoint": args.checkpoint,
        "arch": ARCH,
        "folded_layers_source": str(folded_layers_path),
        "folded_layers_count_from_script": len(folded_layers),
        "folded_layers_count_from_metadata": len(folded_metadata.get("folded_layers", [])) if isinstance(folded_metadata, dict) else None,
        "activation_scales": {
            name: {
                "scale": item["int8_symmetric_scale"],
                "max_abs": item["max_abs"],
                "zero_range_protected": item["zero_range_protected"],
            }
            for name, item in activation_stats.items()
        },
        "weight_scales": weight_scales,
        "weight_quantization": {
            "dtype": "INT8",
            "scheme": "per_tensor_symmetric_signed",
            "scale_formula": "max_abs / 127",
            "per_channel_quantization": "not_implemented",
        },
        "fixed_point_status": "not_implemented",
    })

    deterministic_json_dump(out_dir / "requant_plan.json", {
        "checkpoint": args.checkpoint,
        "arch": ARCH,
        "conv_fc_quant_param_count": len(conv_fc_plan),
        "residual_add_count": len(residual_add_plan),
        "same_scale_pending_count": same_scale_pending,
        "conv_fc": conv_fc_plan,
        "residual_add": residual_add_plan,
        "requant_status": "planned_not_verified",
        "multiplier_shift_search_status": "not_implemented",
        "same_scale_policy": "do_not_claim_solved_when_branch_scales_differ",
    })

    deterministic_json_dump(out_dir / "summary.json", {
        "checkpoint": args.checkpoint,
        "arch": ARCH,
        "status": "quant_calibration_skeleton",
        "dataset_source": dataset_source,
        "split": args.split,
        "calibration_sample_count": int(labels.numel()),
        "activation_tensor_count": len(activation_stats),
        "conv_fc_quant_param_count": len(conv_fc_plan),
        "residual_add_count": len(residual_add_plan),
        "same_scale_pending_count": same_scale_pending,
        "outputs": {
            "activation_stats": "activation_stats.json",
            "quant_params": "quant_params.json",
            "requant_plan": "requant_plan.json",
        },
        "fixed_point_status": "not_implemented",
        "fixed_point_accuracy_gate": {
            "required_accuracy": 0.80,
            "status": "not_evaluated",
            "reason": "calibration skeleton does not run actual fixed-point inference",
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
