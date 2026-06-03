#!/usr/bin/env python3
"""Evaluate a spec-matching LeNet checkpoint on MNIST and exported sample subsets."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch

from fine_tune_lenet_fixture import load_checkpoint_to_model
from train_lenet_mnist import accuracy, load_mnist_npz, u8_blob_to_tensor


def load_export_batch(exports_dir: Path, count: int) -> tuple[torch.Tensor, torch.Tensor, list[dict]]:
    manifest = json.loads((exports_dir / "manifest.json").read_text(encoding="ascii"))
    if count > 0:
        manifest = manifest[:count]
    xs = []
    ys = []
    for entry in manifest:
        sample_dir = exports_dir / entry["dir"]
        image = torch.frombuffer(bytearray((sample_dir / "image_i8.bin").read_bytes()), dtype=torch.int8).clone()
        xs.append(image.to(torch.float32).reshape(1, 28, 28))
        ys.append(int(entry["label"]))
    return torch.stack(xs, dim=0), torch.tensor(ys, dtype=torch.long), manifest


@torch.no_grad()
def batched_correct(model: torch.nn.Module, xs: torch.Tensor, ys: torch.Tensor, batch_size: int) -> int:
    model.eval()
    correct = 0
    for start in range(0, xs.shape[0], batch_size):
        xb = xs[start:start + batch_size]
        yb = ys[start:start + batch_size]
        correct += (model(xb, quantize_weights=True).argmax(dim=1) == yb).sum().item()
    return int(correct)


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate LeNet checkpoint on software datasets")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--mnist", default="datasets/mnist/mnist.npz")
    parser.add_argument("--exports-dir", default="datasets/mnist/exports_full")
    parser.add_argument("--exports-count", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--min-full-test-accuracy", type=float, default=0.80)
    parser.add_argument("--output-json", default="")
    args = parser.parse_args()

    model, payload = load_checkpoint_to_model(Path(args.checkpoint))
    model.eval()

    x_train_raw, y_train_raw, x_train_shape, y_train_shape, x_test_raw, y_test_raw, x_test_shape, y_test_shape = load_mnist_npz(Path(args.mnist))
    del x_train_raw, y_train_raw, x_train_shape, y_train_shape
    x_test = u8_blob_to_tensor(x_test_raw, x_test_shape).to(torch.float32) - 128.0
    y_test = u8_blob_to_tensor(y_test_raw, y_test_shape).to(torch.long)
    x_test = x_test.unsqueeze(1)

    xs_export, ys_export, manifest = load_export_batch(Path(args.exports_dir), args.exports_count)

    with torch.no_grad():
        export_pred = model(xs_export, quantize_weights=True).argmax(dim=1)

    full_correct = batched_correct(model, x_test, y_test, args.batch_size)
    full_accuracy = float(accuracy(model, x_test, y_test, args.batch_size))
    export_correct = int((export_pred == ys_export).sum().item())
    quality_gate_pass = full_accuracy >= args.min_full_test_accuracy
    summary = {
        "checkpoint": args.checkpoint,
        "requant_version": payload.get("requant_version"),
        "requant_params": payload.get("requant_params"),
        "metadata_best_test_acc": payload.get("best_test_acc"),
        "metadata_best_test_acc_reloaded": payload.get("best_test_acc_reloaded"),
        "fixture_tuned_best_acc": (payload.get("fixture_tuned") or {}).get("best_acc"),
        "full_test_total": int(y_test.numel()),
        "full_test_correct": full_correct,
        "full_test_accuracy": full_accuracy,
        "export_total": len(manifest),
        "export_correct": export_correct,
        "export_accuracy": float(export_correct / len(manifest)) if manifest else 0.0,
        "export_first10_pred": export_pred[:10].cpu().tolist(),
        "export_first10_label": ys_export[:10].cpu().tolist(),
        "quality_gate_threshold": args.min_full_test_accuracy,
        "quality_gate_pass": quality_gate_pass,
        "quality_gate_status": "PASS" if quality_gate_pass else "FAIL",
    }

    print(json.dumps(summary, indent=2))
    if args.output_json:
        Path(args.output_json).write_text(json.dumps(summary, indent=2) + "\n", encoding="ascii")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
