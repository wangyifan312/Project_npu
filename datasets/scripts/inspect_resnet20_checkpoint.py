#!/usr/bin/env python3
"""Inspect a ResNet-20 float checkpoint for R0.5 fixed-point planning."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import torch

from resnet20_cifar10_common import ARCH, deterministic_json_dump


def tensor_stats(name: str, tensor: torch.Tensor) -> dict[str, Any]:
    data = tensor.detach().cpu()
    as_float = data.to(torch.float32)
    return {
        "name": name,
        "shape": list(data.shape),
        "dtype": str(data.dtype),
        "min": float(as_float.min().item()) if data.numel() else None,
        "max": float(as_float.max().item()) if data.numel() else None,
        "mean": float(as_float.mean().item()) if data.numel() else None,
    }


def classify_tensor(name: str) -> str:
    if name.endswith(".weight") and (".conv" in name or name.startswith("conv") or ".shortcut.0" in name):
        return "conv_weight"
    if ".bn" in name or name.startswith("bn") or ".shortcut.1" in name:
        return "batch_norm"
    if name.startswith("fc."):
        return "fc"
    return "other"


def block_structure() -> dict[str, Any]:
    blocks = []
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
            shortcut = "projection_conv1x1_stride2" if stride != 1 or in_channels != channels else "identity"
            blocks.append({
                "name": f"{layer_name}.{block_idx}",
                "input_shape": [in_channels, spatial, spatial],
                "output_shape": [channels, out_spatial, out_spatial],
                "conv1": {
                    "weight": f"{layer_name}.{block_idx}.conv1.weight",
                    "bn": f"{layer_name}.{block_idx}.bn1",
                    "kernel": [3, 3],
                    "stride": stride,
                    "padding": 1,
                },
                "conv2": {
                    "weight": f"{layer_name}.{block_idx}.conv2.weight",
                    "bn": f"{layer_name}.{block_idx}.bn2",
                    "kernel": [3, 3],
                    "stride": 1,
                    "padding": 1,
                },
                "shortcut": shortcut,
            })
            in_channels = channels
            spatial = out_spatial
    return {
        "initial": {
            "conv": "conv1.weight",
            "bn": "bn1",
            "input_shape": [3, 32, 32],
            "output_shape": [16, 32, 32],
        },
        "blocks": blocks,
        "gap": {"input_shape": [64, 8, 8], "output_shape": [64]},
        "fc": {"weight": "fc.weight", "bias": "fc.bias", "input_shape": [64], "output_shape": [10]},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect ResNet-20 checkpoint tensors")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    checkpoint = Path(args.checkpoint)
    payload = torch.load(checkpoint, map_location="cpu")
    arch = payload.get("arch")
    if arch != ARCH:
        raise SystemExit(f"unsupported checkpoint arch {arch!r}, expected {ARCH!r}")
    state = payload.get("model_state_dict")
    if not isinstance(state, dict):
        raise SystemExit("checkpoint missing model_state_dict")

    tensors = []
    class_counts: dict[str, int] = {}
    for name in sorted(state.keys()):
        tensor = state[name]
        if not isinstance(tensor, torch.Tensor):
            continue
        item = tensor_stats(name, tensor)
        cls = classify_tensor(name)
        item["class"] = cls
        tensors.append(item)
        class_counts[cls] = class_counts.get(cls, 0) + 1

    summary = {
        "checkpoint": str(checkpoint),
        "arch": arch,
        "status": "checkpoint_inspect",
        "tensor_count": len(tensors),
        "tensor_class_counts": class_counts,
        "tensors": tensors,
        "layer_graph": block_structure(),
        "pending_fixed_point_fields": {
            "fold_bn_status": "not_implemented",
            "int8_weight_export_status": "not_implemented",
            "int32_bias_export_status": "not_implemented",
            "requant_search_status": "not_implemented",
        },
        "fixed_point_status": "not_implemented",
        "fixed_point_accuracy_gate": {
            "required_accuracy": 0.80,
            "status": "not_evaluated",
        },
    }
    deterministic_json_dump(Path(args.output), summary)
    print(Path(args.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
