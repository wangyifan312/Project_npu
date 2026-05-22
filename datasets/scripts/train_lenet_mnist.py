#!/usr/bin/env python3
"""Train a spec-matching integerized LeNet on local MNIST.

Network topology matches the current RTL/fixture baseline:

    Input(28x28x1)
      -> Conv1(20, 5x5, valid)
      -> Pool1(2x2 max)
      -> clamp INT8
      -> Conv2(50, 5x5, valid)
      -> Pool2(2x2 max)
      -> clamp INT8
      -> FC1(800 -> 500)
      -> ReLU
      -> clamp INT8
      -> FC2(500 -> 10)

Bias is intentionally disabled to match the RTL/spec.
Weights are trained with straight-through fake quantization to INT8.
"""

from __future__ import annotations

import argparse
import ast
import json
import math
import random
import struct
import zipfile
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F


def load_npy_from_bytes(blob: bytes) -> tuple[tuple[int, ...], bytes]:
    if blob[:6] != b"\x93NUMPY":
        raise ValueError("invalid npy magic")

    major = blob[6]
    minor = blob[7]
    if major == 1:
        header_len = struct.unpack("<H", blob[8:10])[0]
        header_start = 10
    elif major == 2:
        header_len = struct.unpack("<I", blob[8:12])[0]
        header_start = 12
    else:
        raise ValueError(f"unsupported npy version {major}.{minor}")

    header_end = header_start + header_len
    header = blob[header_start:header_end].decode("latin1").strip()
    meta = ast.literal_eval(header)

    descr = meta["descr"]
    if descr not in ("|u1", "<u1"):
        raise ValueError(f"unsupported dtype {descr}, expected uint8")
    if meta["fortran_order"]:
        raise ValueError("fortran-order arrays are not supported")

    shape = meta["shape"]
    if not isinstance(shape, tuple):
        raise ValueError("invalid shape in npy header")

    return shape, blob[header_end:]


def load_mnist_npz(path: Path) -> tuple[bytes, bytes, tuple[int, ...], tuple[int, ...], bytes, bytes, tuple[int, ...], tuple[int, ...]]:
    with zipfile.ZipFile(path, "r") as zf:
        x_train_shape, x_train_raw = load_npy_from_bytes(zf.read("x_train.npy"))
        y_train_shape, y_train_raw = load_npy_from_bytes(zf.read("y_train.npy"))
        x_test_shape, x_test_raw = load_npy_from_bytes(zf.read("x_test.npy"))
        y_test_shape, y_test_raw = load_npy_from_bytes(zf.read("y_test.npy"))
    return x_train_raw, y_train_raw, x_train_shape, y_train_shape, x_test_raw, y_test_raw, x_test_shape, y_test_shape


def u8_blob_to_tensor(blob: bytes, shape: tuple[int, ...]) -> torch.Tensor:
    buf = bytearray(blob)
    return torch.frombuffer(buf, dtype=torch.uint8).clone().reshape(shape)


def seed_everything(seed: int) -> None:
    random.seed(seed)
    torch.manual_seed(seed)


def ste_round_clamp_i8(x: torch.Tensor) -> torch.Tensor:
    q = torch.clamp(torch.round(x), -128, 127)
    return x + (q - x).detach()


def clamp_i8(x: torch.Tensor) -> torch.Tensor:
    return torch.clamp(x, -128, 127)


class Int8AwareLeNet(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.weight_scale = 32.0
        self.conv1_weight = nn.Parameter(torch.empty(20, 1, 5, 5))
        self.conv2_weight = nn.Parameter(torch.empty(50, 20, 5, 5))
        self.fc1_weight = nn.Parameter(torch.empty(500, 800))
        self.fc2_weight = nn.Parameter(torch.empty(10, 500))
        self.reset_parameters()

    def reset_parameters(self) -> None:
        for param in (
            self.conv1_weight,
            self.conv2_weight,
            self.fc1_weight,
            self.fc2_weight,
        ):
            nn.init.kaiming_uniform_(param, a=math.sqrt(5))

    def quantized_state(self) -> dict[str, torch.Tensor]:
        return {
            "conv1_weight": torch.clamp(torch.round(self.weight_scale * self.conv1_weight.detach()), -128, 127).to(torch.int8).cpu(),
            "conv2_weight": torch.clamp(torch.round(self.weight_scale * self.conv2_weight.detach()), -128, 127).to(torch.int8).cpu(),
            "fc1_weight": torch.clamp(torch.round(self.weight_scale * self.fc1_weight.detach()), -128, 127).to(torch.int8).cpu(),
            "fc2_weight": torch.clamp(torch.round(self.weight_scale * self.fc2_weight.detach()), -128, 127).to(torch.int8).cpu(),
        }

    def forward(self, x: torch.Tensor, quantize_weights: bool = True) -> torch.Tensor:
        if quantize_weights:
            w1 = ste_round_clamp_i8(self.weight_scale * self.conv1_weight)
            w2 = ste_round_clamp_i8(self.weight_scale * self.conv2_weight)
            w3 = ste_round_clamp_i8(self.weight_scale * self.fc1_weight)
            w4 = ste_round_clamp_i8(self.weight_scale * self.fc2_weight)
        else:
            w1 = clamp_i8(self.weight_scale * self.conv1_weight)
            w2 = clamp_i8(self.weight_scale * self.conv2_weight)
            w3 = clamp_i8(self.weight_scale * self.fc1_weight)
            w4 = clamp_i8(self.weight_scale * self.fc2_weight)

        x = F.conv2d(x, w1, bias=None, stride=1, padding=0)
        x = F.max_pool2d(x, kernel_size=2, stride=2)
        x = ste_round_clamp_i8(x)

        x = F.conv2d(x, w2, bias=None, stride=1, padding=0)
        x = F.max_pool2d(x, kernel_size=2, stride=2)
        x = ste_round_clamp_i8(x)

        x = x.permute(0, 2, 3, 1).contiguous().view(x.shape[0], -1)
        x = F.linear(x, w3, bias=None)
        x = F.relu(x)
        x = ste_round_clamp_i8(x)
        x = F.linear(x, w4, bias=None)
        return x


@torch.no_grad()
def accuracy(model: nn.Module, xs: torch.Tensor, ys: torch.Tensor, batch_size: int) -> float:
    model.eval()
    total = 0
    correct = 0
    for start in range(0, xs.shape[0], batch_size):
        xb = xs[start:start + batch_size]
        yb = ys[start:start + batch_size]
        logits = model(xb, quantize_weights=True)
        pred = logits.argmax(dim=1)
        total += yb.numel()
        correct += (pred == yb).sum().item()
    return correct / total if total else 0.0


def main() -> int:
    parser = argparse.ArgumentParser(description="Train spec-matching integerized LeNet on MNIST")
    parser.add_argument("--input", default="datasets/mnist/mnist.npz")
    parser.add_argument("--output", default="datasets/mnist/models/mnist_lenet_soc6.pt")
    parser.add_argument("--epochs", type=int, default=4, help="Quantized fine-tune epochs")
    parser.add_argument("--warmup-epochs", type=int, default=4, help="Float warmup epochs before INT8 fine-tune")
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--seed", type=int, default=1234)
    parser.add_argument("--train-limit", type=int, default=0, help="0 = full training set")
    parser.add_argument("--test-limit", type=int, default=0, help="0 = full test set")
    args = parser.parse_args()

    seed_everything(args.seed)

    path = Path(args.input)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    x_train_raw, y_train_raw, x_train_shape, y_train_shape, x_test_raw, y_test_raw, x_test_shape, y_test_shape = load_mnist_npz(path)

    x_train = u8_blob_to_tensor(x_train_raw, x_train_shape).to(torch.float32) - 128.0
    y_train = u8_blob_to_tensor(y_train_raw, y_train_shape).to(torch.long)
    x_test = u8_blob_to_tensor(x_test_raw, x_test_shape).to(torch.float32) - 128.0
    y_test = u8_blob_to_tensor(y_test_raw, y_test_shape).to(torch.long)

    if args.train_limit > 0:
        x_train = x_train[:args.train_limit]
        y_train = y_train[:args.train_limit]
    if args.test_limit > 0:
        x_test = x_test[:args.test_limit]
        y_test = y_test[:args.test_limit]

    x_train = x_train.unsqueeze(1)
    x_test = x_test.unsqueeze(1)

    model = Int8AwareLeNet()
    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr)

    best_acc = -1.0
    best_quant: dict[str, torch.Tensor] | None = None
    history: list[dict[str, float]] = []
    total_epochs = args.warmup_epochs + args.epochs

    for epoch in range(1, total_epochs + 1):
        model.train()
        order = torch.randperm(x_train.shape[0])
        epoch_loss = 0.0
        seen = 0
        quantize_weights = epoch > args.warmup_epochs
        for start in range(0, x_train.shape[0], args.batch_size):
            idx = order[start:start + args.batch_size]
            xb = x_train[idx]
            yb = y_train[idx]

            optimizer.zero_grad(set_to_none=True)
            logits = model(xb, quantize_weights=quantize_weights)
            loss = F.cross_entropy(logits, yb)
            loss.backward()
            optimizer.step()
            for param in model.parameters():
                param.data.clamp_(-127.0 / model.weight_scale, 127.0 / model.weight_scale)

            batch_n = yb.shape[0]
            epoch_loss += loss.item() * batch_n
            seen += batch_n

        train_acc = accuracy(model, x_train, y_train, args.batch_size)
        test_acc = accuracy(model, x_test, y_test, args.batch_size)
        avg_loss = epoch_loss / seen if seen else 0.0
        history.append(
            {
                "epoch": float(epoch),
                "loss": avg_loss,
                "train_acc": train_acc,
                "test_acc": test_acc,
                "quantized_phase": 1.0 if quantize_weights else 0.0,
            }
        )
        print(
            f"epoch {epoch:02d} ({'quant' if quantize_weights else 'warmup'}): "
            f"loss={avg_loss:.6f} train_acc={train_acc:.4f} test_acc={test_acc:.4f}"
        )

        if test_acc > best_acc:
            best_acc = test_acc
            best_quant = model.quantized_state()

    if best_quant is None:
        raise RuntimeError("training did not produce any checkpoint")

    first8_logits = model(x_test[:8], quantize_weights=True).argmax(dim=1).cpu().tolist()
    first8_labels = y_test[:8].cpu().tolist()

    payload = {
        "arch": "soc6_lenet_int8_v1",
        "topology": {
            "conv1": [20, 1, 5, 5],
            "conv2": [50, 20, 5, 5],
            "fc1": [500, 800],
            "fc2": [10, 500],
            "bias": False,
        },
        "best_test_acc": best_acc,
        "weight_scale": model.weight_scale,
        "warmup_epochs": args.warmup_epochs,
        "quant_epochs": args.epochs,
        "batch_size": args.batch_size,
        "lr": args.lr,
        "seed": args.seed,
        "history": history,
        "first8_pred": first8_logits,
        "first8_label": first8_labels,
        "quantized_state": best_quant,
    }
    torch.save(payload, out_path)

    metrics_path = out_path.with_suffix(out_path.suffix + ".json")
    metrics_path.write_text(
        json.dumps(
            {
                "arch": payload["arch"],
                "best_test_acc": best_acc,
                "warmup_epochs": args.warmup_epochs,
                "quant_epochs": args.epochs,
                "batch_size": args.batch_size,
                "lr": args.lr,
                "seed": args.seed,
                "first8_pred": first8_logits,
                "first8_label": first8_labels,
                "history": history,
            },
            indent=2,
        )
        + "\n",
        encoding="ascii",
    )
    print(f"saved checkpoint: {out_path}")
    print(f"saved metrics: {metrics_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
