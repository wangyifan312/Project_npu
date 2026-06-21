#!/usr/bin/env python3
"""Export ResNet-20 INT8/INT32/requant package assets for RTL handoff.

F6c generates data assets consumed by later task-sequence and memory-map work.
It does not generate final task_sequence.json, memory_map.json, or start RTL R1.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import torch
import torch.nn as nn

from export_resnet20_bn_folded import build_folded_model
from resnet20_cifar10_common import ARCH, deterministic_json_dump, load_checkpoint
from search_resnet20_requant_plan import search_multiplier_shift


INT32_MAX = (1 << 31) - 1
INT32_MIN = -(1 << 31)


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="ascii"))


def round_half_away_from_zero(tensor: torch.Tensor) -> torch.Tensor:
    data = tensor.to(torch.float64)
    return torch.sign(data) * torch.floor(torch.abs(data) + 0.5)


def quantize_to_int8(tensor: torch.Tensor, scale: float) -> torch.Tensor:
    if not math.isfinite(scale) or scale <= 0.0:
        raise ValueError(f"invalid weight scale {scale!r}")
    q = round_half_away_from_zero(tensor.detach().cpu() / float(scale))
    return torch.clamp(q, -128, 127).to(torch.int64)


def quantize_bias_to_int32(tensor: torch.Tensor, accumulator_scale: float) -> torch.Tensor:
    if not math.isfinite(accumulator_scale) or accumulator_scale <= 0.0:
        raise ValueError(f"invalid accumulator scale {accumulator_scale!r}")
    q = round_half_away_from_zero(tensor.detach().cpu() / float(accumulator_scale)).to(torch.int64)
    if int(q.min().item()) < INT32_MIN or int(q.max().item()) > INT32_MAX:
        raise ValueError("bias quantization exceeded signed INT32 range")
    return q


def safe_name(name: str) -> str:
    return name.replace(".", "_").replace("/", "_")


def product(values: list[int]) -> int:
    out = 1
    for value in values:
        out *= int(value)
    return out


def tensor_stats(values: torch.Tensor) -> dict[str, Any]:
    data = values.detach().cpu().to(torch.int64).reshape(-1)
    return {
        "element_count": int(data.numel()),
        "min": int(data.min().item()) if data.numel() else None,
        "max": int(data.max().item()) if data.numel() else None,
        "checksum": int(data.sum().item()) if data.numel() else 0,
        "abs_checksum": int(data.abs().sum().item()) if data.numel() else 0,
    }


def twos_complement_hex(value: int, bits: int) -> str:
    mask = (1 << bits) - 1
    width = bits // 4
    return f"{int(value) & mask:0{width}x}"


def write_memh(path: Path, values: torch.Tensor, *, bits: int, header: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flat = values.detach().cpu().to(torch.int64).reshape(-1)
    lines = [
        "// ResNet-20 R0.5 export package",
        *[f"// {key}: {value}" for key, value in header.items()],
    ]
    lines.extend(twos_complement_hex(int(value), bits) for value in flat.tolist())
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def module_to_plan_name(module_name: str) -> str:
    if module_name.endswith(".shortcut"):
        return f"{module_name}.projection"
    return module_name


def source_tensor_name(module_name: str) -> str:
    if module_name.endswith(".shortcut"):
        prefix = module_name.rsplit(".", 1)[0]
        return f"{prefix}.shortcut.0.weight"
    return f"{module_name}.weight"


def target_weight_tensor(module: nn.Module, module_name: str) -> tuple[torch.Tensor, str, list[int]]:
    weight = module.weight.detach().cpu()
    if isinstance(module, nn.Conv2d):
        target = weight.permute(1, 2, 3, 0).contiguous()
        return target, "conv_weight_IHWO_from_pytorch_OIHW", list(target.shape)
    if isinstance(module, nn.Linear):
        return weight.contiguous(), "fc_weight_OI", list(weight.shape)
    raise TypeError(f"unsupported module {module_name}")


def collect_export_modules(model: nn.Module) -> list[tuple[str, nn.Module]]:
    items: list[tuple[str, nn.Module]] = []
    for name, module in model.named_modules():
        if isinstance(module, (nn.Conv2d, nn.Linear)):
            items.append((name, module))
    return items


def build_plan_map(conv_fc: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {str(item["op"]): item for item in conv_fc.get("items", [])}


def precheck(
    fixed_eval: dict[str, Any],
    handoff: dict[str, Any],
    errors: list[str],
) -> None:
    gate_status = fixed_eval.get("fixed_point_accuracy_gate", {}).get("status")
    if gate_status != "passed":
        errors.append(f"fixed eval gate status is {gate_status!r}, expected passed")
    if float(fixed_eval.get("fixed_point_accuracy", 0.0)) < 0.80:
        errors.append(f"fixed eval accuracy {fixed_eval.get('fixed_point_accuracy')} is below 0.80")
    if handoff.get("handoff_contract_status") != "reviewed_contract_closed_for_export":
        errors.append(f"handoff status is {handoff.get('handoff_contract_status')!r}")
    if handoff.get("next_allowed_stage") != "export_int8_int32_assets":
        errors.append(f"handoff next stage is {handoff.get('next_allowed_stage')!r}")


def export_weights_and_biases(
    model: nn.Module,
    quant_params: dict[str, Any],
    plan_map: dict[str, dict[str, Any]],
    output_dir: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    weight_root = output_dir / "weights"
    bias_root = output_dir / "bias"
    weight_entries: list[dict[str, Any]] = []
    bias_entries: list[dict[str, Any]] = []
    weight_scales = quant_params.get("weight_scales", {})

    for module_name, module in collect_export_modules(model):
        plan_name = module_to_plan_name(module_name)
        if plan_name not in plan_map:
            raise KeyError(f"missing requant plan for {plan_name}")
        if module_name not in weight_scales:
            raise KeyError(f"missing weight scale for {module_name}")
        plan = plan_map[plan_name]
        scale_item = weight_scales[module_name]
        weight_scale = float(scale_item["weight"]["int8_symmetric_scale"])
        target_weight, layout, target_shape = target_weight_tensor(module, module_name)
        weight_int8 = quantize_to_int8(target_weight, weight_scale)
        file_name = f"{safe_name(plan_name)}.memh"
        weight_path = weight_root / file_name
        weight_stats = tensor_stats(weight_int8)
        weight_header = {
            "layer": plan_name,
            "source_tensor": source_tensor_name(module_name),
            "shape": target_shape,
            "scale": weight_scale,
            "layout": layout,
            "dtype": "INT8",
        }
        write_memh(weight_path, weight_int8, bits=8, header=weight_header)
        weight_entries.append({
            "layer": plan_name,
            "module_name": module_name,
            "file": f"weights/{file_name}",
            "source_tensor": source_tensor_name(module_name),
            "source_layout": "pytorch_OIHW" if isinstance(module, nn.Conv2d) else "pytorch_OI",
            "layout": layout,
            "shape": target_shape,
            "scale": weight_scale,
            "dtype": "INT8",
            **weight_stats,
        })

        if module.bias is None:
            raise ValueError(f"module {module_name} missing folded bias")
        accumulator_scale = float(plan["accumulator_scale"])
        bias_int32 = quantize_bias_to_int32(module.bias, accumulator_scale)
        bias_file = f"{safe_name(plan_name)}.memh"
        bias_path = bias_root / bias_file
        bias_stats = tensor_stats(bias_int32)
        bias_header = {
            "layer": plan_name,
            "source_tensor": f"{module_name}.bias",
            "shape": list(bias_int32.shape),
            "accumulator_scale": accumulator_scale,
            "ordering": "output_channel_or_neuron_order",
            "dtype": "INT32",
        }
        write_memh(bias_path, bias_int32, bits=32, header=bias_header)
        bias_entries.append({
            "layer": plan_name,
            "module_name": module_name,
            "file": f"bias/{bias_file}",
            "source_tensor": f"{module_name}.bias",
            "shape": list(bias_int32.shape),
            "accumulator_scale": accumulator_scale,
            "ordering": "output_channel_or_neuron_order",
            "dtype": "INT32",
            **bias_stats,
        })

    deterministic_json_dump(weight_root / "summary.json", {
        "arch": ARCH,
        "status": "weights_exported",
        "dtype": "INT8",
        "weight_file_count": len(weight_entries),
        "layout_policy": {
            "conv": "IHWO_from_pytorch_OIHW",
            "fc": "OI",
        },
        "entries": weight_entries,
    })
    deterministic_json_dump(bias_root / "summary.json", {
        "arch": ARCH,
        "status": "bias_exported",
        "dtype": "INT32",
        "bias_file_count": len(bias_entries),
        "ordering": "output_channel_or_neuron_order",
        "entries": bias_entries,
    })
    return weight_entries, bias_entries


def export_requant(
    quant_params: dict[str, Any],
    conv_fc: dict[str, Any],
    residual_add: dict[str, Any],
    output_dir: Path,
) -> dict[str, Any]:
    requant_root = output_dir / "requant"
    requant_root.mkdir(parents=True, exist_ok=True)
    conv_fc_norm = {
        "arch": ARCH,
        "status": "exported_from_f3",
        "conv_fc_requant_count": int(conv_fc.get("conv_fc_requant_count", len(conv_fc.get("items", [])))),
        "items": conv_fc.get("items", []),
    }
    residual_norm = {
        "arch": ARCH,
        "status": "exported_from_f3",
        "residual_add_alignment_count": int(residual_add.get("residual_add_alignment_count", len(residual_add.get("items", [])))),
        "alignment_policy": residual_add.get("alignment_policy", "align_both_branches_to_target_add_scale"),
        "items": residual_add.get("items", []),
    }

    activation_scales = quant_params["activation_scales"]
    gap_input_scale = float(activation_scales["gap.input"]["scale"])
    gap_output_scale = float(activation_scales["gap.output"]["scale"])
    kernel_area = 64
    real_multiplier = gap_input_scale / (gap_output_scale * float(kernel_area))
    gap_requant = search_multiplier_shift(real_multiplier)
    gap_meta = {
        "arch": ARCH,
        "status": "searched",
        "op": "gap.output",
        "operation": "sum_8x8_int8_spatial_per_channel_then_requant_to_gap_output_scale",
        "kernel_area": kernel_area,
        "source_scale_names": {
            "input_scale": "gap.input",
            "output_scale": "gap.output",
        },
        "input_scale": gap_input_scale,
        "output_scale": gap_output_scale,
        "real_multiplier": real_multiplier,
        "requant": gap_requant,
        "hardware_divider": "not_allowed",
    }

    deterministic_json_dump(requant_root / "conv_fc_requant.json", conv_fc_norm)
    deterministic_json_dump(requant_root / "residual_add_alignment.json", residual_norm)
    deterministic_json_dump(requant_root / "gap_requant.json", gap_meta)
    summary = {
        "arch": ARCH,
        "status": "requant_exported",
        "conv_fc_requant_count": conv_fc_norm["conv_fc_requant_count"],
        "residual_add_alignment_count": residual_norm["residual_add_alignment_count"],
        "gap_requant_status": gap_requant.get("status"),
        "files": {
            "conv_fc_requant": "requant/conv_fc_requant.json",
            "residual_add_alignment": "requant/residual_add_alignment.json",
            "gap_requant": "requant/gap_requant.json",
        },
    }
    deterministic_json_dump(requant_root / "summary.json", summary)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Export ResNet-20 INT8/INT32/requant package")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--folded-layers", required=True)
    parser.add_argument("--quant-params", required=True)
    parser.add_argument("--conv-fc-requant", required=True)
    parser.add_argument("--residual-add-alignment", required=True)
    parser.add_argument("--fixed-eval", required=True)
    parser.add_argument("--handoff-contract", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    fixed_eval = read_json(Path(args.fixed_eval))
    handoff = read_json(Path(args.handoff_contract))
    folded_layers = read_json(Path(args.folded_layers))
    quant_params = read_json(Path(args.quant_params))
    conv_fc = read_json(Path(args.conv_fc_requant))
    residual_add = read_json(Path(args.residual_add_alignment))

    errors: list[str] = []
    for label, payload in (
        ("fixed_eval", fixed_eval),
        ("handoff_contract", handoff),
        ("folded_layers", folded_layers),
        ("quant_params", quant_params),
        ("conv_fc_requant", conv_fc),
        ("residual_add_alignment", residual_add),
    ):
        if payload.get("arch") != ARCH:
            errors.append(f"{label} arch mismatch: {payload.get('arch')!r}")
    precheck(fixed_eval, handoff, errors)
    if errors:
        raise SystemExit("export precheck failed:\n" + "\n".join(errors))

    _model, payload = load_checkpoint(Path(args.checkpoint))
    if payload.get("arch") != ARCH:
        raise SystemExit(f"checkpoint arch mismatch: {payload.get('arch')!r}")
    state = payload.get("model_state_dict")
    if not isinstance(state, dict):
        raise SystemExit("checkpoint missing model_state_dict")
    folded_model, _ = build_folded_model(state)
    plan_map = build_plan_map(conv_fc)

    weight_entries, bias_entries = export_weights_and_biases(folded_model, quant_params, plan_map, output_dir)
    requant_summary = export_requant(quant_params, conv_fc, residual_add, output_dir)

    manifest = {
        "arch": ARCH,
        "schema": "resnet20_r0_5_export_package_v1",
        "source_checkpoint": args.checkpoint,
        "source_folded_layers": args.folded_layers,
        "source_quant_params": args.quant_params,
        "source_fixed_eval": args.fixed_eval,
        "source_handoff_contract": args.handoff_contract,
        "fixed_point_accuracy": float(fixed_eval["fixed_point_accuracy"]),
        "gate_status": fixed_eval.get("fixed_point_accuracy_gate", {}).get("status"),
        "weights": [entry["file"] for entry in weight_entries],
        "bias": [entry["file"] for entry in bias_entries],
        "requant": {
            "summary": "requant/summary.json",
            "conv_fc_requant": "requant/conv_fc_requant.json",
            "residual_add_alignment": "requant/residual_add_alignment.json",
            "gap_requant": "requant/gap_requant.json",
        },
        "task_sequence": None,
        "memory_map": None,
        "rtl_r1_started": False,
        "rtl_memh_generated": True,
        "rtl_memh_scope": "weights_and_bias_only",
        "final_task_sequence_generated": False,
        "one_mb_memory_reuse_map_generated": False,
    }
    deterministic_json_dump(output_dir / "manifest.json", manifest)
    deterministic_json_dump(output_dir / "summary.json", {
        "arch": ARCH,
        "status": "export_package_generated",
        "source_checkpoint": args.checkpoint,
        "fixed_point_accuracy": float(fixed_eval["fixed_point_accuracy"]),
        "gate_status": manifest["gate_status"],
        "handoff_contract_status": handoff.get("handoff_contract_status"),
        "weight_file_count": len(weight_entries),
        "bias_file_count": len(bias_entries),
        "conv_fc_requant_count": requant_summary["conv_fc_requant_count"],
        "residual_add_alignment_count": requant_summary["residual_add_alignment_count"],
        "gap_requant_status": requant_summary["gap_requant_status"],
        "manifest": "manifest.json",
        "task_sequence_generated": False,
        "one_mb_memory_reuse_map_generated": False,
        "rtl_r1_started": False,
        "validation_report": "validation_report.json",
    })

    print(f"Wrote {output_dir / 'summary.json'}")
    print(f"weight_file_count={len(weight_entries)}")
    print(f"bias_file_count={len(bias_entries)}")
    print(f"gap_requant_status={requant_summary['gap_requant_status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
