#!/usr/bin/env python3
"""Run a ResNet-20 fixed-point operator smoke or staged evaluation.

F4/F5 use the same actual INT8/INT32 software inference backend.  The script
consumes F1/F2/F3 metadata and emits debug JSON only; it does not generate RTL
memh, task sequences, or memory reuse maps.
"""

from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path
from typing import Any

import torch
import torch.nn as nn
import torch.nn.functional as F

from export_resnet20_bn_folded import build_folded_model
from resnet20_cifar10_common import ARCH, deterministic_json_dump, evaluate_model_detailed, get_dataset, load_checkpoint
from search_resnet20_requant_plan import search_multiplier_shift


R0_5_UNFINISHED = [
    "full_cifar10_fixed_point_eval",
    "accuracy_gate_80_percent",
    "int8_weights_memh",
    "int32_folded_bias_memh",
    "final_task_sequence",
    "one_mb_memory_reuse_map",
]


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="ascii"))


def round_half_away_from_zero(tensor: torch.Tensor) -> torch.Tensor:
    data = tensor.to(torch.float64)
    return torch.sign(data) * torch.floor(torch.abs(data) + 0.5)


def quantize_to_int8(x_float: torch.Tensor, scale: float) -> torch.Tensor:
    if not math.isfinite(scale) or scale <= 0.0:
        raise ValueError(f"invalid INT8 quant scale {scale!r}")
    q = round_half_away_from_zero(x_float / float(scale))
    return torch.clamp(q, -128, 127).to(torch.int64)


def dequantize_from_int8(x_int: torch.Tensor, scale: float) -> torch.Tensor:
    return x_int.to(torch.float32) * float(scale)


def cifar_normalized_to_input_int8(images: torch.Tensor) -> torch.Tensor:
    """Convert normalized CIFAR NCHW float to the R0.5 uint8_minus_128 INT8 input."""

    u8 = torch.clamp(torch.round((images * 0.5 + 0.5) * 255.0), 0, 255).to(torch.int16)
    signed = torch.clamp(u8 - 128, -128, 127)
    return signed.to(torch.int64)


def round_shift_half_away(value: torch.Tensor, shift: int) -> torch.Tensor:
    if shift < 0:
        raise ValueError(f"negative shift {shift}")
    data = value.to(torch.int64)
    if shift == 0:
        return data
    abs_data = torch.abs(data)
    rounded = (abs_data + (1 << (shift - 1))) >> shift
    return torch.where(data < 0, -rounded, rounded)


def requantize_int64(
    value: torch.Tensor,
    requant: dict[str, Any],
    *,
    clamp_int8: bool,
    saturation: "SaturationCollector | None" = None,
    saturation_layer: str | None = None,
) -> torch.Tensor:
    multiplier = requant.get("multiplier_int")
    shift = requant.get("shift")
    if multiplier is None or shift is None or requant.get("status") != "searched":
        raise ValueError(f"invalid requant plan {requant}")
    product = value.to(torch.int64) * int(multiplier)
    rounded = round_shift_half_away(product, int(shift))
    if clamp_int8:
        if saturation is not None and saturation_layer is not None:
            saturation.record(saturation_layer, rounded)
        rounded = torch.clamp(rounded, -128, 127)
    return rounded.to(torch.int64)


def ratio_requant(src_scale: float, dst_scale: float) -> dict[str, Any]:
    if not math.isfinite(src_scale) or not math.isfinite(dst_scale) or src_scale <= 0.0 or dst_scale <= 0.0:
        raise ValueError(f"invalid scale conversion {src_scale!r} -> {dst_scale!r}")
    return search_multiplier_shift(float(src_scale) / float(dst_scale))


class RunningTensorStats:
    def __init__(self, logical_dtype: str, scale: float | None) -> None:
        self.logical_dtype = logical_dtype
        self.scale = scale
        self.shape: list[int] | None = None
        self.count = 0
        self.sum = 0.0
        self.min_value: float | None = None
        self.max_value: float | None = None

    def update(self, tensor: torch.Tensor) -> None:
        data = tensor.detach().cpu().to(torch.float64)
        if data.numel() == 0:
            return
        self.shape = list(data.shape[1:]) if data.dim() > 1 else list(data.shape)
        self.count += int(data.numel())
        self.sum += float(data.sum().item())
        min_value = float(data.min().item())
        max_value = float(data.max().item())
        self.min_value = min_value if self.min_value is None else min(self.min_value, min_value)
        self.max_value = max_value if self.max_value is None else max(self.max_value, max_value)

    def as_dict(self) -> dict[str, Any]:
        return {
            "shape": self.shape,
            "logical_dtype": self.logical_dtype,
            "scale": self.scale,
            "count": self.count,
            "min": self.min_value,
            "max": self.max_value,
            "sum": self.sum,
        }


class LayerChecksumCollector:
    def __init__(self) -> None:
        self._stats: dict[str, RunningTensorStats] = {}

    def record(self, name: str, tensor: torch.Tensor, *, logical_dtype: str, scale: float | None) -> None:
        self._stats.setdefault(name, RunningTensorStats(logical_dtype, scale)).update(tensor)

    def as_dict(self) -> dict[str, Any]:
        return {name: stat.as_dict() for name, stat in sorted(self._stats.items())}


class SaturationStats:
    def __init__(self) -> None:
        self.clamp_min_count = 0
        self.clamp_max_count = 0
        self.total_count = 0

    def update(self, pre_clamp: torch.Tensor) -> None:
        data = pre_clamp.detach().cpu().to(torch.int64)
        self.clamp_min_count += int((data < -128).sum().item())
        self.clamp_max_count += int((data > 127).sum().item())
        self.total_count += int(data.numel())

    def as_dict(self) -> dict[str, Any]:
        return {
            "clamp_min_count": self.clamp_min_count,
            "clamp_max_count": self.clamp_max_count,
            "total_count": self.total_count,
            "clamp_min_ratio": float(self.clamp_min_count / self.total_count) if self.total_count else 0.0,
            "clamp_max_ratio": float(self.clamp_max_count / self.total_count) if self.total_count else 0.0,
        }


class SaturationCollector:
    def __init__(self) -> None:
        self._stats: dict[str, SaturationStats] = {}

    def record(self, name: str, pre_clamp: torch.Tensor) -> None:
        self._stats.setdefault(name, SaturationStats()).update(pre_clamp)

    def as_dict(self) -> dict[str, Any]:
        return {name: stat.as_dict() for name, stat in sorted(self._stats.items())}

    def max_risk_layer(self) -> dict[str, Any] | None:
        if not self._stats:
            return None
        items = self.as_dict()
        name, stat = max(
            items.items(),
            key=lambda item: float(item[1]["clamp_min_ratio"]) + float(item[1]["clamp_max_ratio"]),
        )
        return {
            "layer": name,
            **stat,
            "total_clamp_ratio": float(stat["clamp_min_ratio"]) + float(stat["clamp_max_ratio"]),
        }


class FixedPointResNet20:
    def __init__(
        self,
        folded_model: nn.Module,
        quant_params: dict[str, Any],
        conv_fc_requant: dict[str, Any],
        residual_add_alignment: dict[str, Any],
    ) -> None:
        self.model = folded_model.eval()
        self.activation_scales = quant_params["activation_scales"]
        self.weight_scales = quant_params["weight_scales"]
        self.conv_plans = {item["op"]: item for item in conv_fc_requant["items"]}
        self.add_plans = {item["op"]: item for item in residual_add_alignment["items"]}
        self.weight_cache: dict[str, torch.Tensor] = {}
        self.bias_cache: dict[str, torch.Tensor] = {}
        self.post_relu_requant_sources: dict[str, str] = {}
        self.gap_requant_source = "computed_in_smoke_from_f2_scales_using_multiplier_shift"

    def activation_scale(self, name: str) -> float:
        item = self.activation_scales.get(name)
        if item is None:
            raise KeyError(f"missing activation scale for {name}")
        return float(item["scale"])

    def module_weight_scale(self, module_name: str) -> float:
        item = self.weight_scales.get(module_name)
        if item is None:
            raise KeyError(f"missing weight scale for {module_name}")
        return float(item["weight"]["int8_symmetric_scale"])

    def module_int_params(self, module_name: str, accumulator_scale: float) -> tuple[torch.Tensor, torch.Tensor | None]:
        cache_key = f"{module_name}:{accumulator_scale:.18e}"
        if cache_key in self.weight_cache:
            return self.weight_cache[cache_key], self.bias_cache.get(cache_key)
        module = self.model.get_submodule(module_name)
        weight_scale = self.module_weight_scale(module_name)
        weight_int = quantize_to_int8(module.weight.detach().cpu(), weight_scale)
        bias_int = None
        if module.bias is not None:
            bias_int = round_half_away_from_zero(module.bias.detach().cpu() / float(accumulator_scale)).to(torch.int64)
        self.weight_cache[cache_key] = weight_int
        if bias_int is not None:
            self.bias_cache[cache_key] = bias_int
        return weight_int, bias_int

    def conv(
        self,
        module_name: str,
        plan_name: str,
        x_int8: torch.Tensor,
        *,
        relu_before_requant: bool,
        saturation: SaturationCollector | None = None,
        saturation_layer: str | None = None,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        plan = self.conv_plans[plan_name]
        module = self.model.get_submodule(module_name)
        accumulator_scale = float(plan["accumulator_scale"])
        weight_int, bias_int = self.module_int_params(module_name, accumulator_scale)
        acc = F.conv2d(
            x_int8.to(torch.float32),
            weight_int.to(torch.float32),
            bias_int.to(torch.float32) if bias_int is not None else None,
            stride=module.stride,
            padding=module.padding,
            dilation=module.dilation,
            groups=module.groups,
        )
        acc_i64 = torch.round(acc).to(torch.int64)
        if relu_before_requant:
            acc_i64 = torch.clamp(acc_i64, min=0)
        out_i8 = requantize_int64(
            acc_i64,
            plan["requant"],
            clamp_int8=True,
            saturation=saturation,
            saturation_layer=saturation_layer,
        )
        return acc_i64, out_i8

    def linear(
        self,
        module_name: str,
        plan_name: str,
        x_int8: torch.Tensor,
        *,
        clamp_int8: bool,
        saturation: SaturationCollector | None = None,
        saturation_layer: str | None = None,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        plan = self.conv_plans[plan_name]
        module = self.model.get_submodule(module_name)
        accumulator_scale = float(plan["accumulator_scale"])
        weight_int, bias_int = self.module_int_params(module_name, accumulator_scale)
        acc = F.linear(
            x_int8.to(torch.float32),
            weight_int.to(torch.float32),
            bias_int.to(torch.float32) if bias_int is not None else None,
        )
        acc_i64 = torch.round(acc).to(torch.int64)
        out = requantize_int64(
            acc_i64,
            plan["requant"],
            clamp_int8=clamp_int8,
            saturation=saturation,
            saturation_layer=saturation_layer,
        )
        return acc_i64, out

    def add_block(
        self,
        prefix: str,
        main_int8: torch.Tensor,
        shortcut_int8: torch.Tensor,
        checksums: LayerChecksumCollector,
        saturation: SaturationCollector,
    ) -> torch.Tensor:
        plan = self.add_plans[f"{prefix}.add"]
        main_aligned = requantize_int64(main_int8, plan["main_to_target"], clamp_int8=False)
        shortcut_aligned = requantize_int64(shortcut_int8, plan["shortcut_to_target"], clamp_int8=False)
        add_pre = main_aligned + shortcut_aligned
        add_relu = torch.clamp(add_pre, min=0)
        post_requant = ratio_requant(float(plan["target_add_scale"]), float(plan["post_relu_scale"]))
        self.post_relu_requant_sources[f"{prefix}.add.relu"] = "computed_in_smoke_from_f3_target_and_post_relu_scales"
        add_relu_i8 = requantize_int64(
            add_relu,
            post_requant,
            clamp_int8=True,
            saturation=saturation,
            saturation_layer=f"{prefix}.add.relu",
        )
        checksums.record(f"{prefix}.add.relu", add_relu_i8, logical_dtype="INT8", scale=float(plan["post_relu_scale"]))
        return add_relu_i8

    def gap(
        self,
        x_int8: torch.Tensor,
        input_scale: float,
        output_scale: float,
        saturation: SaturationCollector,
    ) -> torch.Tensor:
        summed = x_int8.to(torch.int64).sum(dim=(2, 3))
        kernel_area = int(x_int8.shape[2] * x_int8.shape[3])
        conversion = ratio_requant(float(input_scale), float(output_scale) * float(kernel_area))
        return requantize_int64(
            summed,
            conversion,
            clamp_int8=True,
            saturation=saturation,
            saturation_layer="gap.output",
        )

    @torch.no_grad()
    def forward(
        self,
        images: torch.Tensor,
        checksums: LayerChecksumCollector,
        saturation: SaturationCollector,
    ) -> torch.Tensor:
        x = cifar_normalized_to_input_int8(images.cpu())
        _conv1_acc, out = self.conv(
            "conv1",
            "conv1",
            x,
            relu_before_requant=True,
            saturation=saturation,
            saturation_layer="conv1.relu",
        )
        checksums.record("conv1.relu", out, logical_dtype="INT8", scale=self.activation_scale("conv1.relu"))

        for layer_name in ("layer1", "layer2", "layer3"):
            layer = self.model.get_submodule(layer_name)
            for block_idx, block in enumerate(layer):
                prefix = f"{layer_name}.{block_idx}"
                shortcut_in = out
                _conv1_acc, conv1 = self.conv(f"{prefix}.conv1", f"{prefix}.conv1", out, relu_before_requant=True)
                _conv2_acc, main = self.conv(f"{prefix}.conv2", f"{prefix}.conv2", conv1, relu_before_requant=False)
                if isinstance(block.shortcut, nn.Conv2d):
                    _shortcut_acc, shortcut = self.conv(
                        f"{prefix}.shortcut",
                        f"{prefix}.shortcut.projection",
                        shortcut_in,
                        relu_before_requant=False,
                    )
                else:
                    shortcut = shortcut_in
                out = self.add_block(prefix, main, shortcut, checksums, saturation)

        checksums.record("gap.input", out, logical_dtype="INT8", scale=self.activation_scale("gap.input"))
        gap_out = self.gap(out, self.activation_scale("gap.input"), self.activation_scale("gap.output"), saturation)
        checksums.record("gap.output", gap_out, logical_dtype="INT8", scale=self.activation_scale("gap.output"))
        _fc_acc, logits = self.linear(
            "fc",
            "fc",
            gap_out,
            clamp_int8=True,
            saturation=saturation,
            saturation_layer="fc.logits",
        )
        checksums.record("fc.logits", logits, logical_dtype="INT8", scale=self.activation_scale("fc.logits"))
        return logits


def prediction_failure_modes(predictions: list[dict[str, Any]], limit: int = 8) -> list[dict[str, Any]]:
    failures = []
    for item in predictions:
        if not item["correct"]:
            failures.append({
                "sample_index": item["sample_index"],
                "label": item["label"],
                "predicted_class_fixed": item["predicted_class_fixed"],
                "predicted_class_float": item.get("predicted_class_float"),
            })
            if len(failures) >= limit:
                break
    return failures


def build_mismatch_summary(predictions: list[dict[str, Any]], limit: int = 12) -> dict[str, Any]:
    fixed_float_match = 0
    fixed_float_mismatch = 0
    fixed_only_correct = 0
    float_only_correct = 0
    both_wrong = 0
    examples = []
    for item in predictions:
        fixed_correct = bool(item["correct"])
        float_correct = bool(item["float_correct"])
        if item["predicted_class_fixed"] == item["predicted_class_float"]:
            fixed_float_match += 1
        else:
            fixed_float_mismatch += 1
            if len(examples) < limit:
                examples.append({
                    "sample_index": item["sample_index"],
                    "label": item["label"],
                    "predicted_class_fixed": item["predicted_class_fixed"],
                    "predicted_class_float": item["predicted_class_float"],
                    "fixed_correct": fixed_correct,
                    "float_correct": float_correct,
                })
        if fixed_correct and not float_correct:
            fixed_only_correct += 1
        elif float_correct and not fixed_correct:
            float_only_correct += 1
        elif not fixed_correct and not float_correct:
            both_wrong += 1
    total = len(predictions)
    return {
        "total": total,
        "fixed_float_prediction_match_count": fixed_float_match,
        "fixed_float_prediction_mismatch_count": fixed_float_mismatch,
        "fixed_float_prediction_match_ratio": float(fixed_float_match / total) if total else 0.0,
        "fixed_float_prediction_mismatch_ratio": float(fixed_float_mismatch / total) if total else 0.0,
        "fixed_only_correct_count": fixed_only_correct,
        "float_only_correct_count": float_only_correct,
        "both_wrong_count": both_wrong,
        "first_mismatch_examples": examples,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run ResNet-20 fixed-point operator smoke")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--cifar10-tar", default="datasets/cifar10/cifar-10-python.tar.gz")
    parser.add_argument("--dataset-npz", default="")
    parser.add_argument("--split", choices=["train", "test"], default="test")
    parser.add_argument("--count", type=int, default=64)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--folded-layers", default="datasets/cifar10/resnet20_bn_folded/folded_layers.json")
    parser.add_argument("--quant-params", default="datasets/cifar10/resnet20_quant_calibration/quant_params.json")
    parser.add_argument("--conv-fc-requant", default="datasets/cifar10/resnet20_requant_plan/conv_fc_requant.json")
    parser.add_argument("--residual-add-alignment", default="datasets/cifar10/resnet20_requant_plan/residual_add_alignment.json")
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    if args.device != "cpu":
        raise SystemExit("F4 fixed-point smoke currently supports --device cpu only")

    float_model, payload = load_checkpoint(Path(args.checkpoint))
    if payload.get("arch") != ARCH:
        raise SystemExit(f"unsupported checkpoint arch {payload.get('arch')!r}, expected {ARCH!r}")
    state = payload.get("model_state_dict")
    if not isinstance(state, dict):
        raise SystemExit("checkpoint missing model_state_dict")

    folded_model, _folded_layers_from_checkpoint = build_folded_model(state)
    folded_layers = read_json(Path(args.folded_layers))
    quant_params = read_json(Path(args.quant_params))
    conv_fc_requant = read_json(Path(args.conv_fc_requant))
    residual_add_alignment = read_json(Path(args.residual_add_alignment))
    for name, data in (
        ("folded_layers", folded_layers),
        ("quant_params", quant_params),
        ("conv_fc_requant", conv_fc_requant),
        ("residual_add_alignment", residual_add_alignment),
    ):
        if data.get("arch") != ARCH:
            raise SystemExit(f"{name} arch mismatch: {data.get('arch')!r}")

    images, labels, dataset_source = get_dataset(args, default_split=args.split)
    runtime_start = time.perf_counter()
    float_eval = evaluate_model_detailed(float_model, images, labels, args.batch_size, device="cpu")
    fixed = FixedPointResNet20(folded_model, quant_params, conv_fc_requant, residual_add_alignment)
    checksums = LayerChecksumCollector()
    saturation = SaturationCollector()

    fixed_predictions: list[int] = []
    for start in range(0, images.shape[0], args.batch_size):
        logits = fixed.forward(images[start:start + args.batch_size], checksums, saturation)
        fixed_predictions.extend(int(v) for v in logits.argmax(dim=1).cpu().tolist())
    total_runtime_sec = time.perf_counter() - runtime_start

    labels_list = [int(v) for v in labels.cpu().tolist()]
    float_pred = [int(v) for v in float_eval["predicted_class"]]
    predictions = []
    fixed_correct = 0
    for idx, (label, pred_fixed, pred_float) in enumerate(zip(labels_list, fixed_predictions, float_pred)):
        correct = int(pred_fixed) == int(label)
        fixed_correct += int(correct)
        predictions.append({
            "sample_index": idx,
            "label": int(label),
            "predicted_class_fixed": int(pred_fixed),
            "predicted_class_float": int(pred_float),
            "correct": bool(correct),
            "float_correct": bool(int(pred_float) == int(label)),
        })

    total = len(labels_list)
    fixed_accuracy = float(fixed_correct / total) if total else 0.0
    samples_per_sec = float(total / total_runtime_sec) if total_runtime_sec > 0.0 else 0.0
    is_full_cifar10_fixed_point_eval = bool(args.split == "test" and total == 10000)
    staged_eval_status = "full_10000" if is_full_cifar10_fixed_point_eval else "staged_subset"
    fixed_point_status = "full_eval_complete" if is_full_cifar10_fixed_point_eval else "staged_eval_subset"
    gate_status = (
        "passed" if is_full_cifar10_fixed_point_eval and fixed_accuracy >= 0.80
        else "failed" if is_full_cifar10_fixed_point_eval
        else "not_evaluated_staged_subset"
    )
    mismatch_summary = build_mismatch_summary(predictions)
    saturation_summary = {
        "arch": ARCH,
        "checkpoint": args.checkpoint,
        "coverage": "conv1.relu, residual add ReLU outputs, GAP output, FC logits",
        "layers": saturation.as_dict(),
        "max_risk_layer": saturation.max_risk_layer(),
    }
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    deterministic_json_dump(out_dir / "predictions.json", {
        "arch": ARCH,
        "checkpoint": args.checkpoint,
        "split": args.split,
        "dataset_source": dataset_source,
        "total": total,
        "correct": fixed_correct,
        "accuracy": fixed_accuracy,
        "predictions": predictions,
    })
    deterministic_json_dump(out_dir / "mismatch_summary.json", {
        "arch": ARCH,
        "checkpoint": args.checkpoint,
        "split": args.split,
        "dataset_source": dataset_source,
        "fixed_point_correct": fixed_correct,
        "fixed_point_accuracy": fixed_accuracy,
        "float_reference_correct": int(float_eval["correct"]),
        "float_reference_accuracy": float(float_eval["accuracy"]),
        **mismatch_summary,
    })
    deterministic_json_dump(out_dir / "saturation_summary.json", saturation_summary)
    deterministic_json_dump(out_dir / "layer_checksums.json", {
        "arch": ARCH,
        "checkpoint": args.checkpoint,
        "layer_checksum_scope": "conv1, residual add ReLU outputs, GAP, FC logits",
        "checksums": checksums.as_dict(),
    })
    deterministic_json_dump(out_dir / "fixed_point_config.json", {
        "arch": ARCH,
        "checkpoint": args.checkpoint,
        "source_folded_layers": args.folded_layers,
        "source_quant_params": args.quant_params,
        "source_conv_fc_requant": args.conv_fc_requant,
        "source_residual_add_alignment": args.residual_add_alignment,
        "input_layout": "HWC",
        "input_quantization": "uint8_minus_128_then_symmetric_scale_from_f2_input",
        "weight_quantization": "per_tensor_symmetric_INT8_from_F2",
        "bias_quantization": "INT32_round_folded_bias_div_accumulator_scale",
        "rounding_status": "software_reference_round_half_away_from_zero_not_rtl_locked",
        "saturation_status": "clamp_to_INT8_range_after_activation_requant",
        "conv_accumulation_backend": "torch_conv2d_float_kernel_with_integer_operands_then_integer_round",
        "fc_accumulation_backend": "torch_linear_float_kernel_with_integer_operands_then_integer_round",
        "requant_source": "F3_multiplier_shift_for_conv_fc_and_residual_branch_alignment",
        "post_relu_requant_source": fixed.post_relu_requant_sources,
        "gap_status": fixed.gap_requant_source,
        "residual_add_alignment_executed": True,
        "f3_multiplier_shift_used": True,
        "fixed_point_status": fixed_point_status,
        "full_cifar10_fixed_point_eval": is_full_cifar10_fixed_point_eval,
        "staged_eval_status": staged_eval_status,
        "saturation_summary": "saturation_summary.json",
        "mismatch_summary": "mismatch_summary.json",
        "fixed_point_accuracy_gate": {
            "required_accuracy": 0.80,
            "status": gate_status,
        },
        "rtl_memh_generated": False,
        "rtl_task_sequence_generated": False,
        "one_mb_memory_reuse_map_generated": False,
    })
    deterministic_json_dump(out_dir / "summary.json", {
        "arch": ARCH,
        "status": "actual_fixed_point_staged_eval",
        "checkpoint": args.checkpoint,
        "dataset_source": dataset_source,
        "split": args.split,
        "sample_count": total,
        "batch_size": int(args.batch_size),
        "device": args.device,
        "total_runtime_sec": total_runtime_sec,
        "samples_per_sec": samples_per_sec,
        "fixed_point_correct": fixed_correct,
        "fixed_point_accuracy": fixed_accuracy,
        "float_reference_correct": int(float_eval["correct"]),
        "float_reference_accuracy": float(float_eval["accuracy"]),
        "fixed_float_prediction_match_count": mismatch_summary["fixed_float_prediction_match_count"],
        "fixed_float_prediction_mismatch_count": mismatch_summary["fixed_float_prediction_mismatch_count"],
        "fixed_only_correct_count": mismatch_summary["fixed_only_correct_count"],
        "float_only_correct_count": mismatch_summary["float_only_correct_count"],
        "both_wrong_count": mismatch_summary["both_wrong_count"],
        "first_observed_failure_modes": prediction_failure_modes(predictions),
        "first_mismatch_examples": mismatch_summary["first_mismatch_examples"],
        "saturation_max_risk_layer": saturation.max_risk_layer(),
        "saturation_coverage": saturation_summary["coverage"],
        "rounding_status": "software_reference_round_half_away_from_zero_not_rtl_locked",
        "saturation_status": "clamp_to_INT8_range_after_activation_requant",
        "f3_multiplier_shift_used": True,
        "residual_add_planned_alignment_executed": True,
        "fixed_point_status": fixed_point_status,
        "full_cifar10_fixed_point_eval": is_full_cifar10_fixed_point_eval,
        "staged_eval_status": staged_eval_status,
        "fixed_point_accuracy_gate": {
            "required_accuracy": 0.80,
            "status": gate_status,
        },
        "rtl_memh_generated": False,
        "rtl_task_sequence_generated": False,
        "one_mb_memory_reuse_map_generated": False,
        "r0_5_unfinished": R0_5_UNFINISHED,
    })

    print(f"fixed_point_smoke {fixed_correct}/{total} accuracy={fixed_accuracy:.6f}")
    print(f"float_reference {float_eval['correct']}/{total} accuracy={float(float_eval['accuracy']):.6f}")
    print(f"fixed_float_mismatch {mismatch_summary['fixed_float_prediction_mismatch_count']}/{total}")
    print(f"runtime_sec {total_runtime_sec:.3f} samples_per_sec {samples_per_sec:.3f}")
    print(f"wrote {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
