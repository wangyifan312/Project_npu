#!/usr/bin/env python3
"""Run staged CIFAR-10 ResNet-20 float training for R0.5.

This is an orchestration wrapper around the existing train/eval scripts.  It
does not implement fixed-point golden generation and must not be treated as an
RTL enablement gate.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from resnet20_cifar10_common import ARCH, CIFAR10_DEFAULT_TAR, deterministic_json_dump, utc_now_iso


R0_5_UNFINISHED = [
    "fixed_point_golden",
    "accuracy_gate_80_percent",
    "real_cifar10_full_fixed_point_eval",
    "weights_bias_memh",
    "task_sequence",
    "one_mb_memory_reuse_map",
]


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="ascii"))


def run_command(cmd: list[str]) -> None:
    print(" ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run staged ResNet-20 float candidate training")
    parser.add_argument("--cifar10-tar", default=CIFAR10_DEFAULT_TAR)
    parser.add_argument("--out-dir", default="results/resnet20_float_staged")
    parser.add_argument("--stages", type=int, default=2)
    parser.add_argument("--epochs-per-stage", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--lr", type=float, default=0.1)
    parser.add_argument("--momentum", type=float, default=0.9)
    parser.add_argument("--weight-decay", type=float, default=0.0001)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--train-count", type=int, default=5000)
    parser.add_argument("--eval-count", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--augment", action="store_true")
    parser.add_argument("--stop-accuracy", type=float, default=0.0)
    args = parser.parse_args()

    if args.stages <= 0:
        raise SystemExit("--stages must be > 0")
    if args.epochs_per_stage <= 0:
        raise SystemExit("--epochs-per-stage must be > 0")

    repo_root = Path(__file__).resolve().parents[2]
    train_script = repo_root / "datasets" / "scripts" / "train_resnet20_cifar10.py"
    eval_script = repo_root / "datasets" / "scripts" / "eval_resnet20_checkpoint.py"
    out_dir = Path(args.out_dir)
    checkpoints_dir = out_dir / "checkpoints"
    metrics_dir = out_dir / "metrics"
    checkpoints_dir.mkdir(parents=True, exist_ok=True)
    metrics_dir.mkdir(parents=True, exist_ok=True)

    stage_results: list[dict[str, Any]] = []
    best_checkpoint: str | None = None
    best_eval_accuracy = -1.0
    previous_checkpoint: Path | None = None

    for stage in range(1, args.stages + 1):
        checkpoint = checkpoints_dir / f"stage_{stage:03d}.pt"
        train_metrics = metrics_dir / f"stage_{stage:03d}_train.json"
        eval_metrics = metrics_dir / f"stage_{stage:03d}_eval.json"

        train_cmd = [
            sys.executable,
            str(train_script),
            "--output",
            str(checkpoint),
            "--cifar10-tar",
            args.cifar10_tar,
            "--count",
            str(args.train_count),
            "--eval-count",
            str(args.eval_count),
            "--epochs",
            str(args.epochs_per_stage),
            "--batch-size",
            str(args.batch_size),
            "--lr",
            str(args.lr),
            "--momentum",
            str(args.momentum),
            "--weight-decay",
            str(args.weight_decay),
            "--metrics-output",
            str(train_metrics),
            "--device",
            args.device,
            "--seed",
            str(args.seed),
            "--save-best",
        ]
        if args.augment:
            train_cmd.append("--augment")
        if previous_checkpoint is not None:
            train_cmd.extend(["--resume", str(previous_checkpoint)])
        run_command(train_cmd)

        eval_cmd = [
            sys.executable,
            str(eval_script),
            "--checkpoint",
            str(checkpoint),
            "--cifar10-tar",
            args.cifar10_tar,
            "--split",
            "test",
            "--count",
            str(args.eval_count),
            "--batch-size",
            str(args.batch_size),
            "--output",
            str(eval_metrics),
            "--device",
            args.device,
            "--seed",
            str(args.seed),
        ]
        run_command(eval_cmd)

        train_summary = read_json(train_metrics)
        eval_summary = read_json(eval_metrics)
        eval_accuracy = float(eval_summary["accuracy"])
        if eval_accuracy > best_eval_accuracy:
            best_eval_accuracy = eval_accuracy
            best_checkpoint = str(checkpoint)

        stage_result = {
            "stage": stage,
            "checkpoint": str(checkpoint),
            "resume_source": str(previous_checkpoint) if previous_checkpoint is not None else None,
            "train_metrics": str(train_metrics),
            "eval_metrics": str(eval_metrics),
            "train_accuracy": float(train_summary["accuracy"]),
            "train_eval_accuracy": train_summary.get("eval_accuracy"),
            "eval_accuracy": eval_accuracy,
            "eval_correct": int(eval_summary["correct"]),
            "eval_total": int(eval_summary["total"]),
        }
        stage_results.append(stage_result)
        previous_checkpoint = checkpoint

        if args.stop_accuracy > 0.0 and eval_accuracy >= args.stop_accuracy:
            break

    summary = {
        "status": "float_staged_training_summary",
        "arch": ARCH,
        "created_at": utc_now_iso(),
        "stages_requested": int(args.stages),
        "stages_completed": len(stage_results),
        "epochs_per_stage": int(args.epochs_per_stage),
        "train_count": int(args.train_count),
        "eval_count": int(args.eval_count),
        "batch_size": int(args.batch_size),
        "lr": float(args.lr),
        "momentum": float(args.momentum),
        "weight_decay": float(args.weight_decay),
        "device": args.device,
        "augment": bool(args.augment),
        "cifar10_tar": args.cifar10_tar,
        "best_checkpoint": best_checkpoint,
        "best_eval_accuracy": float(best_eval_accuracy) if best_eval_accuracy >= 0.0 else None,
        "stage_results": stage_results,
        "all_stage_metrics_paths": [
            {"train": item["train_metrics"], "eval": item["eval_metrics"]}
            for item in stage_results
        ],
        "fixed_point_status": "not_implemented",
        "fixed_point_accuracy_gate": {
            "required_accuracy": 0.80,
            "status": "not_evaluated",
            "reason": "staged runner only trains/evaluates float checkpoints",
        },
        "rtl_status": "not_started",
        "r0_5_unfinished": R0_5_UNFINISHED,
    }
    summary_path = out_dir / "summary.json"
    deterministic_json_dump(summary_path, summary)
    print(summary_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
