#!/usr/bin/env python3
"""Train CIFAR-10 ResNet-20 or run a deterministic R0.5 smoke training pass."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
import torch.nn.functional as F

from resnet20_cifar10_common import (
    ADD_POLICY,
    ARCH,
    BIAS_POLICY,
    QUANT_VERSION,
    SHORTCUT_POLICY,
    CifarResNet20,
    augment_cifar_batch,
    deterministic_json_dump,
    evaluate_model_detailed,
    get_dataset,
    load_checkpoint,
    resnet20_metadata,
    save_checkpoint,
    seed_everything,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Train CIFAR-10 ResNet-20 checkpoint")
    parser.add_argument("--output", required=True)
    parser.add_argument("--cifar10-tar", default="datasets/cifar10/cifar-10-python.tar.gz")
    parser.add_argument("--dataset-npz", default="", help="Optional local CIFAR-10 npz for non-smoke training")
    parser.add_argument("--count", type=int, default=0, help="Non-smoke sample count, 0 means all")
    parser.add_argument("--max-train-samples", type=int, default=None, help="Alias for --count")
    parser.add_argument("--eval-count", "--max-test-samples", dest="eval_count", type=int, default=0)
    parser.add_argument("--smoke", action="store_true", help="Run synthetic deterministic smoke only")
    parser.add_argument("--synthetic-count", type=int, default=8)
    parser.add_argument("--epochs", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--lr", type=float, default=0.01)
    parser.add_argument("--weight-decay", type=float, default=0.0001)
    parser.add_argument("--momentum", type=float, default=0.9)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--augment", action="store_true", help="Enable deterministic random crop/flip augmentation")
    parser.add_argument("--resume", default="", help="Optional checkpoint to resume model weights from")
    parser.add_argument("--save-best", action="store_true", help="Record whether this run improves best eval accuracy")
    parser.add_argument("--metrics-output", default="", help="Optional JSON metrics output path")
    parser.add_argument("--quant-version", default=QUANT_VERSION)
    args = parser.parse_args()
    if args.max_train_samples is not None:
        args.count = int(args.max_train_samples)

    seed_everything(args.seed)
    images, labels, dataset_source = get_dataset(args, default_split="train")
    device = torch.device(args.device)
    if args.resume:
        model, resume_payload = load_checkpoint(Path(args.resume))
    else:
        model = CifarResNet20(num_classes=10)
        resume_payload = {}
    model.to(device)
    optimizer = torch.optim.SGD(
        model.parameters(),
        lr=args.lr,
        momentum=args.momentum,
        weight_decay=args.weight_decay,
    )
    train_generator = torch.Generator().manual_seed(args.seed)

    epoch_metrics: list[dict[str, float | int]] = []
    losses: list[float] = []
    for epoch in range(args.epochs):
        model.train()
        permutation = torch.randperm(images.shape[0], generator=train_generator)
        epoch_losses: list[float] = []
        for start in range(0, images.shape[0], args.batch_size):
            batch_indices = permutation[start:start + args.batch_size]
            xb_cpu = images[batch_indices]
            if args.augment:
                xb_cpu = augment_cifar_batch(xb_cpu, train_generator)
            xb = xb_cpu.to(device)
            yb = labels[batch_indices].to(device)
            optimizer.zero_grad(set_to_none=True)
            loss = F.cross_entropy(model(xb), yb)
            loss.backward()
            optimizer.step()
            loss_value = float(loss.item())
            losses.append(loss_value)
            epoch_losses.append(loss_value)
        epoch_metrics.append({
            "epoch": epoch + 1,
            "loss_avg": float(sum(epoch_losses) / len(epoch_losses)) if epoch_losses else 0.0,
            "loss_last": float(epoch_losses[-1]) if epoch_losses else 0.0,
        })

    train_stats = evaluate_model_detailed(model, images, labels, args.batch_size, device=device)
    eval_stats = None
    eval_dataset_source = None
    if args.eval_count > 0:
        eval_args = argparse.Namespace(
            smoke=bool(args.smoke),
            synthetic_count=int(args.eval_count),
            count=int(args.eval_count),
            seed=int(args.seed),
            split="test",
            dataset_npz=args.dataset_npz,
            cifar10_tar=args.cifar10_tar,
        )
        eval_images, eval_labels, eval_dataset_source = get_dataset(eval_args, default_split="test")
        eval_stats = evaluate_model_detailed(model, eval_images, eval_labels, args.batch_size, device=device)

    training_config = {
        "dataset_source": dataset_source,
        "split": "train",
        "smoke": bool(args.smoke),
        "synthetic_count": int(args.synthetic_count),
        "count": int(args.count),
        "eval_count": int(args.eval_count),
        "epochs": int(args.epochs),
        "batch_size": int(args.batch_size),
        "lr": float(args.lr),
        "weight_decay": float(args.weight_decay),
        "momentum": float(args.momentum),
        "seed": int(args.seed),
        "device": str(args.device),
        "augment": bool(args.augment),
        "resume": args.resume,
        "save_best": bool(args.save_best),
    }
    metadata = resnet20_metadata(training_config)
    metadata["quant_version"] = args.quant_version
    previous_best = resume_payload.get("best_accuracy")
    previous_epoch_metrics = resume_payload.get("cumulative_epoch_metrics")
    if not isinstance(previous_epoch_metrics, list):
        previous_epoch_metrics = resume_payload.get("epoch_metrics", [])
    if not isinstance(previous_epoch_metrics, list):
        previous_epoch_metrics = []
    previous_stage_history = resume_payload.get("stage_history", [])
    if not isinstance(previous_stage_history, list):
        previous_stage_history = []
    stage_index = len(previous_stage_history) + 1
    current_select_accuracy = (
        float(eval_stats["accuracy"]) if eval_stats is not None else float(train_stats["accuracy"])
    )
    best_accuracy = max(float(previous_best), current_select_accuracy) if previous_best is not None else current_select_accuracy
    best_is_current = current_select_accuracy >= best_accuracy
    cumulative_epoch_metrics = list(previous_epoch_metrics)
    for metric in epoch_metrics:
        cumulative_metric = dict(metric)
        cumulative_metric["stage"] = stage_index
        cumulative_metric["cumulative_epoch"] = len(cumulative_epoch_metrics) + 1
        cumulative_epoch_metrics.append(cumulative_metric)
    stage_history = list(previous_stage_history)
    stage_history.append({
        "stage": stage_index,
        "resume_source": args.resume or None,
        "epochs": int(args.epochs),
        "train_total": int(train_stats["total"]),
        "train_accuracy": float(train_stats["accuracy"]),
        "eval_total": int(eval_stats["total"]) if eval_stats is not None else None,
        "eval_accuracy": float(eval_stats["accuracy"]) if eval_stats is not None else None,
        "selected_accuracy": float(current_select_accuracy),
    })

    extra = {
        "status": "smoke_checkpoint" if args.smoke else "training_checkpoint",
        "arch": ARCH,
        "dataset_source": dataset_source,
        "split": "train",
        "eval_dataset_source": eval_dataset_source,
        "bias_policy": BIAS_POLICY,
        "shortcut_policy": SHORTCUT_POLICY,
        "add_policy": ADD_POLICY,
        "fixed_point_status": "not_implemented",
        "fixed_point_accuracy_gate": {
            "required_accuracy": 0.80,
            "status": "not_evaluated",
            "reason": "float baseline training does not implement fixed-point evaluation",
        },
        "accuracy_gate_80_percent": "not_evaluated",
        "train_total": int(train_stats["total"]),
        "train_correct": int(train_stats["correct"]),
        "train_accuracy": float(train_stats["accuracy"]),
        "eval_total": int(eval_stats["total"]) if eval_stats is not None else None,
        "eval_correct": int(eval_stats["correct"]) if eval_stats is not None else None,
        "eval_accuracy": float(eval_stats["accuracy"]) if eval_stats is not None else None,
        "resume_source": args.resume or None,
        "previous_best_accuracy": float(previous_best) if previous_best is not None else None,
        "current_stage_epochs": int(args.epochs),
        "stage_index": int(stage_index),
        "optimizer_state_resume": False,
        "best_accuracy": float(best_accuracy),
        "best_is_current": bool(best_is_current),
        "best_metric": "eval_accuracy" if eval_stats is not None else "train_accuracy",
        "loss_first": losses[0] if losses else None,
        "loss_last": losses[-1] if losses else None,
        "epoch_metrics": epoch_metrics,
        "cumulative_epoch_metrics": cumulative_epoch_metrics,
        "stage_history": stage_history,
        "r0_5_unfinished": [
            "fixed_point_golden",
            "accuracy_gate_80_percent",
            "real_cifar10_full_fixed_point_eval",
            "weights_bias_memh",
            "task_sequence",
            "one_mb_memory_reuse_map",
        ],
    }
    save_checkpoint(Path(args.output), model, metadata, extra)

    metrics_summary = {
        "checkpoint": args.output,
        "arch": ARCH,
        "status": extra["status"],
        "total": extra["train_total"],
        "correct": extra["train_correct"],
        "accuracy": extra["train_accuracy"],
        "eval_total": extra["eval_total"],
        "eval_correct": extra["eval_correct"],
        "eval_accuracy": extra["eval_accuracy"],
        "resume_source": extra["resume_source"],
        "previous_best_accuracy": extra["previous_best_accuracy"],
        "current_stage_epochs": extra["current_stage_epochs"],
        "stage_index": extra["stage_index"],
        "optimizer_state_resume": extra["optimizer_state_resume"],
        "best_accuracy": extra["best_accuracy"],
        "best_is_current": extra["best_is_current"],
        "epoch_metrics": epoch_metrics,
        "cumulative_epoch_metrics": cumulative_epoch_metrics,
        "stage_history": stage_history,
        "fixed_point_status": "not_implemented",
        "accuracy_gate_80_percent": "not_evaluated",
    }
    if args.metrics_output:
        deterministic_json_dump(Path(args.metrics_output), {
            **metrics_summary,
            "dataset_source": dataset_source,
            "eval_dataset_source": eval_dataset_source,
            "training_config": training_config,
            "fixed_point_accuracy_gate": extra["fixed_point_accuracy_gate"],
            "r0_5_unfinished": extra["r0_5_unfinished"],
        })
    print(json.dumps(metrics_summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
