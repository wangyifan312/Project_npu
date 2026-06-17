#!/usr/bin/env python3
"""Generate a ResNet-20 R0.5 smoke fixture skeleton.

The fixture intentionally records TODO status for weights/bias memh, task
sequence, and 1 MB memory reuse map.  It must not be mistaken for a completed
fixed-point RTL fixture.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import torch

from resnet20_cifar10_common import (
    INPUT_MEMH_NAME,
    SMOKE_INPUT_DTYPE,
    SMOKE_INPUT_LAYOUT,
    SMOKE_INPUT_QUANTIZATION,
    deterministic_json_dump,
    evaluate_model,
    get_dataset,
    load_checkpoint,
    tensor_to_input_memh_words,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate ResNet-20 fixture skeleton")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--cifar10-tar", default="datasets/cifar10/cifar-10-python.tar.gz")
    parser.add_argument("--dataset-npz", default="", help="Optional local CIFAR-10 npz")
    parser.add_argument("--split", choices=["train", "test"], default="test")
    parser.add_argument("--count", type=int, default=0, help="Non-smoke sample count, 0 means all")
    parser.add_argument("--smoke", action="store_true", help="Use deterministic synthetic data")
    parser.add_argument("--synthetic-count", type=int, default=4)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args()

    model, payload = load_checkpoint(Path(args.checkpoint))
    images, labels, dataset_source = get_dataset(args, default_split=args.split)
    correct, predicted = evaluate_model(model, images, labels, args.batch_size, device=args.device)

    out_dir = Path(args.output_dir)
    weights_dir = out_dir / "weights"
    weights_dir.mkdir(parents=True, exist_ok=True)

    deterministic_json_dump(weights_dir / "summary.json", {
        "status": "todo",
        "checkpoint": args.checkpoint,
        "arch": payload.get("arch"),
        "weights_bias_memh": "not_generated_in_r0_5_smoke",
        "int32_folded_bias": "required_later",
        "preload_map": "not_generated_in_r0_5_smoke",
        "todo": [
            "export int8 weights",
            "export int32 folded bias",
            "freeze layer weight layout",
            "generate preload maps",
        ],
    })

    manifest = []
    for idx in range(int(labels.numel())):
        label = int(labels[idx].item())
        sample_name = f"sample_{idx:05d}_label_{label}"
        sample_dir = out_dir / sample_name
        sample_dir.mkdir(parents=True, exist_ok=True)

        (sample_dir / INPUT_MEMH_NAME).write_text(
            "\n".join(tensor_to_input_memh_words(images[idx])) + "\n",
            encoding="ascii",
        )
        (sample_dir / "label.txt").write_text(f"{label}\n", encoding="ascii")
        meta = {
            "sample": sample_name,
            "index": idx,
            "label": label,
            "predicted_class": int(predicted[idx]),
            "input_memh": INPUT_MEMH_NAME,
            "input_layout": SMOKE_INPUT_LAYOUT,
            "input_dtype": SMOKE_INPUT_DTYPE,
            "input_quantization": SMOKE_INPUT_QUANTIZATION,
            "source": dataset_source,
            "split": args.split if not args.smoke else "synthetic",
            "status": "smoke_fixture",
            "fixed_point_status": "not_implemented",
        }
        deterministic_json_dump(sample_dir / "meta.json", meta)
        manifest.append({
            "sample": sample_name,
            "label": label,
            "predicted_class": int(predicted[idx]),
            "input_memh": f"{sample_name}/{INPUT_MEMH_NAME}",
            "label_path": f"{sample_name}/label.txt",
            "meta_path": f"{sample_name}/meta.json",
            "task_sequence_status": "todo",
            "memory_reuse_map_status": "todo",
        })

    summary = {
        "status": "r0_5_smoke_fixture_skeleton",
        "checkpoint": args.checkpoint,
        "arch": payload.get("arch"),
        "dataset_source": dataset_source,
        "split": args.split if not args.smoke else "synthetic",
        "total": int(labels.numel()),
        "correct": correct,
        "accuracy": float(correct / labels.numel()) if labels.numel() else 0.0,
        "manifest": "manifest.json",
        "manifest_schema": "top_level_list_v1",
        "weights_summary": "weights/summary.json",
        "fixed_point_status": "not_implemented",
        "input_layout": SMOKE_INPUT_LAYOUT,
        "input_dtype": SMOKE_INPUT_DTYPE,
        "input_quantization": SMOKE_INPUT_QUANTIZATION,
        "input_contract_status": "smoke_placeholder_not_final_fixed_point_contract",
        "expected_fields": ["label", "predicted_class"],
        "todo_status": {
            "weights_bias_memh": "not_generated",
            "task_sequence": "not_generated",
            "one_mb_memory_reuse_map": "not_generated",
            "fixed_point_golden": "not_implemented",
            "accuracy_gate_80_percent": "not_evaluated",
        },
        "contract_notes": {
            "shared_memory": "1 MB = 32768 x 256-bit beat",
            "alignment": "64B base address alignment remains required",
            "rtl_status": "not_started",
        },
    }
    deterministic_json_dump(out_dir / "manifest.json", manifest)
    deterministic_json_dump(out_dir / "summary.json", summary)

    print(out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
