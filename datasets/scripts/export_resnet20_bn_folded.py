#!/usr/bin/env python3
"""Export ResNet-20 Conv+BN folded-float metadata and equivalence checks.

F1 is still a software fixed-point golden prerequisite.  This script only
exports JSON metadata and a folded-float equivalence report; it does not
generate INT8/INT32 memh files, RTL task sequences, or memory reuse maps.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import torch
import torch.nn as nn
import torch.nn.functional as F

from resnet20_cifar10_common import (
    ARCH,
    deterministic_json_dump,
    evaluate_model_detailed,
    get_dataset,
    load_checkpoint,
)


R0_5_UNFINISHED = [
    "actual_fixed_point_inference",
    "accuracy_gate_80_percent",
    "real_cifar10_full_fixed_point_eval",
    "int8_weights_memh",
    "int32_folded_bias_memh",
    "final_task_sequence",
    "one_mb_memory_reuse_map",
]


def stats(tensor: torch.Tensor) -> dict[str, Any]:
    data = tensor.detach().cpu().to(torch.float32)
    return {
        "shape": list(tensor.shape),
        "dtype": str(tensor.dtype),
        "min": float(data.min().item()) if data.numel() else None,
        "max": float(data.max().item()) if data.numel() else None,
        "mean": float(data.mean().item()) if data.numel() else None,
    }


def fold_conv_bn(state: dict[str, torch.Tensor], conv_name: str, bn_name: str) -> tuple[torch.Tensor, torch.Tensor, dict[str, Any]]:
    conv_weight = state[f"{conv_name}.weight"].detach().cpu()
    gamma = state[f"{bn_name}.weight"].detach().cpu()
    beta = state[f"{bn_name}.bias"].detach().cpu()
    running_mean = state[f"{bn_name}.running_mean"].detach().cpu()
    running_var = state[f"{bn_name}.running_var"].detach().cpu()
    eps = 1e-5
    scale = gamma / torch.sqrt(running_var + eps)
    folded_weight = conv_weight * scale[:, None, None, None]
    folded_bias = beta - running_mean * scale
    meta = {
        "conv": conv_name,
        "bn": bn_name,
        "source_tensors": {
            "conv_weight": f"{conv_name}.weight",
            "bn_gamma": f"{bn_name}.weight",
            "bn_beta": f"{bn_name}.bias",
            "bn_running_mean": f"{bn_name}.running_mean",
            "bn_running_var": f"{bn_name}.running_var",
        },
        "source_stats": {
            "conv_weight": stats(conv_weight),
            "bn_gamma": stats(gamma),
            "bn_beta": stats(beta),
            "bn_running_mean": stats(running_mean),
            "bn_running_var": stats(running_var),
        },
        "folded_stats": {
            "scale": stats(scale),
            "folded_weight": stats(folded_weight),
            "folded_bias": stats(folded_bias),
        },
        "formula": {
            "scale": "gamma / sqrt(running_var + eps)",
            "folded_weight": "conv_weight * scale[:, None, None, None]",
            "folded_bias": "beta - running_mean * scale",
            "eps": eps,
        },
    }
    return folded_weight, folded_bias, meta


class FoldedBasicBlock(nn.Module):
    def __init__(self, in_planes: int, planes: int, stride: int) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(in_planes, planes, kernel_size=3, stride=stride, padding=1, bias=True)
        self.conv2 = nn.Conv2d(planes, planes, kernel_size=3, stride=1, padding=1, bias=True)
        if stride != 1 or in_planes != planes:
            self.shortcut = nn.Conv2d(in_planes, planes, kernel_size=1, stride=stride, bias=True)
        else:
            self.shortcut = nn.Identity()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = F.relu(self.conv1(x))
        out = self.conv2(out)
        out = out + self.shortcut(x)
        return F.relu(out)


class FoldedCifarResNet20(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.in_planes = 16
        self.conv1 = nn.Conv2d(3, 16, kernel_size=3, stride=1, padding=1, bias=True)
        self.layer1 = self._make_layer(16, blocks=3, stride=1)
        self.layer2 = self._make_layer(32, blocks=3, stride=2)
        self.layer3 = self._make_layer(64, blocks=3, stride=2)
        self.fc = nn.Linear(64, 10)

    def _make_layer(self, planes: int, blocks: int, stride: int) -> nn.Sequential:
        strides = [stride] + [1] * (blocks - 1)
        layers = []
        for block_stride in strides:
            layers.append(FoldedBasicBlock(self.in_planes, planes, block_stride))
            self.in_planes = planes
        return nn.Sequential(*layers)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = F.relu(self.conv1(x))
        out = self.layer1(out)
        out = self.layer2(out)
        out = self.layer3(out)
        out = F.avg_pool2d(out, out.shape[-1])
        out = torch.flatten(out, 1)
        return self.fc(out)


def set_conv(conv: nn.Conv2d, weight: torch.Tensor, bias: torch.Tensor) -> None:
    conv.weight.data.copy_(weight)
    conv.bias.data.copy_(bias)


def build_folded_model(state: dict[str, torch.Tensor]) -> tuple[FoldedCifarResNet20, list[dict[str, Any]]]:
    model = FoldedCifarResNet20()
    folded_layers: list[dict[str, Any]] = []

    weight, bias, meta = fold_conv_bn(state, "conv1", "bn1")
    meta.update({
        "name": "conv1",
        "is_projection": False,
        "input_shape": [3, 32, 32],
        "output_shape": [16, 32, 32],
    })
    set_conv(model.conv1, weight, bias)
    folded_layers.append(meta)

    in_channels = 16
    spatial = 32
    for layer_name, channels, first_stride in (
        ("layer1", 16, 1),
        ("layer2", 32, 2),
        ("layer3", 64, 2),
    ):
        layer_module = getattr(model, layer_name)
        for block_idx in range(3):
            stride = first_stride if block_idx == 0 else 1
            out_spatial = spatial // stride
            block = layer_module[block_idx]
            prefix = f"{layer_name}.{block_idx}"
            for conv_idx in (1, 2):
                conv_name = f"{prefix}.conv{conv_idx}"
                bn_name = f"{prefix}.bn{conv_idx}"
                weight, bias, meta = fold_conv_bn(state, conv_name, bn_name)
                meta.update({
                    "name": conv_name,
                    "is_projection": False,
                    "input_shape": [in_channels, spatial, spatial] if conv_idx == 1 else [channels, out_spatial, out_spatial],
                    "output_shape": [channels, out_spatial, out_spatial],
                })
                set_conv(getattr(block, f"conv{conv_idx}"), weight, bias)
                folded_layers.append(meta)
            if isinstance(block.shortcut, nn.Conv2d):
                conv_name = f"{prefix}.shortcut.0"
                bn_name = f"{prefix}.shortcut.1"
                weight, bias, meta = fold_conv_bn(state, conv_name, bn_name)
                meta.update({
                    "name": f"{prefix}.shortcut.projection",
                    "is_projection": True,
                    "input_shape": [in_channels, spatial, spatial],
                    "output_shape": [channels, out_spatial, out_spatial],
                })
                set_conv(block.shortcut, weight, bias)
                folded_layers.append(meta)
            in_channels = channels
            spatial = out_spatial

    model.fc.weight.data.copy_(state["fc.weight"])
    model.fc.bias.data.copy_(state["fc.bias"])
    model.eval()
    return model, folded_layers


@torch.no_grad()
def logit_diff(
    original: nn.Module,
    folded: nn.Module,
    images: torch.Tensor,
    batch_size: int,
    device: str,
) -> dict[str, float]:
    device_obj = torch.device(device)
    original.to(device_obj).eval()
    folded.to(device_obj).eval()
    max_abs = 0.0
    sum_abs = 0.0
    count = 0
    for start in range(0, images.shape[0], batch_size):
        xb = images[start:start + batch_size].to(device_obj)
        diff = (original(xb) - folded(xb)).abs().detach().cpu()
        max_abs = max(max_abs, float(diff.max().item()) if diff.numel() else 0.0)
        sum_abs += float(diff.sum().item())
        count += int(diff.numel())
    return {
        "max_abs_logit_diff": max_abs,
        "mean_abs_logit_diff": float(sum_abs / count) if count else 0.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Export ResNet-20 BN-folded float metadata")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--cifar10-tar", default="datasets/cifar10/cifar-10-python.tar.gz")
    parser.add_argument("--dataset-npz", default="")
    parser.add_argument("--split", choices=["train", "test"], default="test")
    parser.add_argument("--count", type=int, default=256)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    original_model, payload = load_checkpoint(Path(args.checkpoint))
    if payload.get("arch") != ARCH:
        raise SystemExit(f"unsupported checkpoint arch {payload.get('arch')!r}, expected {ARCH!r}")
    state = payload.get("model_state_dict")
    if not isinstance(state, dict):
        raise SystemExit("checkpoint missing model_state_dict")

    folded_model, folded_layers = build_folded_model(state)
    fc_meta = {
        "name": "fc",
        "op_type": "fc",
        "source_tensors": {
            "weight": "fc.weight",
            "bias": "fc.bias",
        },
        "source_stats": {
            "weight": stats(state["fc.weight"]),
            "bias": stats(state["fc.bias"]),
        },
        "folding": "not_applicable_no_bn",
    }

    images, labels, dataset_source = get_dataset(args, default_split=args.split)
    diff = logit_diff(original_model, folded_model, images, args.batch_size, args.device)
    original_stats = evaluate_model_detailed(original_model, images, labels, args.batch_size, device=args.device)
    folded_stats = evaluate_model_detailed(folded_model, images, labels, args.batch_size, device=args.device)
    accuracy_match = int(original_stats["correct"]) == int(folded_stats["correct"])

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    folded_payload = {
        "checkpoint": args.checkpoint,
        "arch": ARCH,
        "status": "bn_folded_float_metadata",
        "fold_formula": {
            "scale": "gamma / sqrt(running_var + eps)",
            "folded_weight": "conv_weight * scale[:, None, None, None]",
            "folded_bias": "beta - running_mean * scale",
        },
        "conv_bn_pair_count": len(folded_layers),
        "projection_shortcut_fold_count": sum(1 for item in folded_layers if item["is_projection"]),
        "folded_layers": folded_layers,
        "fc": fc_meta,
        "generated_memh_files": [],
        "task_sequence": None,
        "memory_reuse_map": None,
        "fixed_point_status": "not_implemented",
    }
    equivalence = {
        "checkpoint": args.checkpoint,
        "dataset_source": dataset_source,
        "split": args.split,
        "checked_sample_count": int(labels.numel()),
        **diff,
        "acceptance_target": {
            "max_abs_logit_diff_lte": 1e-4,
            "accuracy_match_required": True,
        },
        "original_correct": int(original_stats["correct"]),
        "original_total": int(original_stats["total"]),
        "original_accuracy": float(original_stats["accuracy"]),
        "folded_correct": int(folded_stats["correct"]),
        "folded_total": int(folded_stats["total"]),
        "folded_accuracy": float(folded_stats["accuracy"]),
        "accuracy_match": bool(accuracy_match),
        "pass": bool(diff["max_abs_logit_diff"] <= 1e-4 and accuracy_match),
    }
    summary = {
        "checkpoint": args.checkpoint,
        "arch": ARCH,
        "status": "bn_folding_metadata_complete",
        "conv_bn_pair_count": len(folded_layers),
        "projection_shortcut_fold_count": sum(1 for item in folded_layers if item["is_projection"]),
        "fc_recorded": True,
        "outputs": {
            "folded_layers": "folded_layers.json",
            "equivalence_check": "equivalence_check.json",
        },
        "equivalence_check": {
            "checked_sample_count": equivalence["checked_sample_count"],
            "max_abs_logit_diff": equivalence["max_abs_logit_diff"],
            "mean_abs_logit_diff": equivalence["mean_abs_logit_diff"],
            "original_accuracy": equivalence["original_accuracy"],
            "folded_accuracy": equivalence["folded_accuracy"],
            "accuracy_match": equivalence["accuracy_match"],
            "pass": equivalence["pass"],
        },
        "fixed_point_status": "not_implemented",
        "fixed_point_accuracy_gate": {
            "required_accuracy": 0.80,
            "status": "not_evaluated",
            "reason": "BN folding equivalence is folded-float only, not fixed-point inference",
        },
        "generated_memh_files": [],
        "task_sequence": None,
        "memory_reuse_map": None,
        "r0_5_unfinished": R0_5_UNFINISHED,
    }

    deterministic_json_dump(out_dir / "folded_layers.json", folded_payload)
    deterministic_json_dump(out_dir / "equivalence_check.json", equivalence)
    deterministic_json_dump(out_dir / "summary.json", summary)
    print(out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
