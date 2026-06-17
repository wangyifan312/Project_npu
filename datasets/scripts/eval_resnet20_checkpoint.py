#!/usr/bin/env python3
"""Evaluate a ResNet-20 checkpoint for R0.5 smoke or local CIFAR-10 npz."""

from __future__ import annotations

import argparse
from pathlib import Path

from resnet20_cifar10_common import (
    deterministic_json_dump,
    evaluate_model_detailed,
    get_dataset,
    load_checkpoint,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate CIFAR-10 ResNet-20 checkpoint")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--cifar10-tar", default="datasets/cifar10/cifar-10-python.tar.gz")
    parser.add_argument("--dataset-npz", default="", help="Optional local CIFAR-10 npz")
    parser.add_argument("--split", choices=["train", "test"], default="test")
    parser.add_argument("--count", type=int, default=0, help="Non-smoke sample count, 0 means all")
    parser.add_argument("--smoke", action="store_true", help="Use deterministic synthetic data")
    parser.add_argument("--synthetic-count", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--mode", choices=["float", "fixed_point"], default="float")
    args = parser.parse_args()

    if args.mode == "fixed_point":
        raise SystemExit("fixed_point mode is reserved for later R0.5 work and is not implemented")

    model, payload = load_checkpoint(Path(args.checkpoint))
    images, labels, dataset_source = get_dataset(args, default_split=args.split)
    stats = evaluate_model_detailed(model, images, labels, args.batch_size, device=args.device)
    summary = {
        "checkpoint": args.checkpoint,
        "arch": payload.get("arch"),
        "mode": args.mode,
        "split": args.split if not args.smoke else "synthetic",
        "status": "float_smoke" if args.smoke else "float_eval",
        "fixed_point_status": "not_implemented",
        "fixed_point_accuracy_gate": {
            "required_accuracy": 0.80,
            "status": "not_evaluated",
            "reason": "R0.5 skeleton has not implemented fixed-point quantized inference",
        },
        "dataset_source": dataset_source,
        "total": int(stats["total"]),
        "correct": int(stats["correct"]),
        "accuracy": float(stats["accuracy"]),
        "predicted_class": stats["predicted_class"],
        "label": stats["label"],
        "per_class_correct": stats["per_class_correct"],
        "per_class_total": stats["per_class_total"],
        "per_class_accuracy": stats["per_class_accuracy"],
        "r0_5_unfinished": [
            "fixed_point_golden",
            "accuracy_gate_80_percent",
            "real_cifar10_full_fixed_point_eval",
            "weights_bias_memh",
            "task_sequence",
            "one_mb_memory_reuse_map",
        ],
    }
    deterministic_json_dump(Path(args.output), summary)
    print(Path(args.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
