#!/usr/bin/env python3
"""Train a spec-matching integerized LeNet on local MNIST.

Network topology matches the current RTL/fixture baseline:

    Input(28x28x1)
      -> Conv1(20, 5x5, valid)
      -> Pool1(2x2 max)
      -> requant INT8
      -> Conv2(50, 5x5, valid)
      -> Pool2(2x2 max)
      -> requant INT8
      -> FC1(800 -> 500)
      -> ReLU
      -> requant INT8
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

from requant_utils import REQUANT_VERSION, normalize_requant_params, requantize_i32_to_i8


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
    def __init__(
        self,
        weight_scale: float = 32.0,
        init_std: float = 0.05,
        requant_params: dict[str, dict[str, int]] | None = None,
    ) -> None:
        super().__init__()
        self.weight_scale = float(weight_scale)
        self.init_std = float(init_std)
        self.requant_params = normalize_requant_params(requant_params)
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
            nn.init.normal_(param, mean=0.0, std=self.init_std)

    def quantized_state(self) -> dict[str, torch.Tensor]:
        return {
            "conv1_weight": torch.clamp(torch.round(self.weight_scale * self.conv1_weight.detach()), -128, 127).to(torch.int8).cpu(),
            "conv2_weight": torch.clamp(torch.round(self.weight_scale * self.conv2_weight.detach()), -128, 127).to(torch.int8).cpu(),
            "fc1_weight": torch.clamp(torch.round(self.weight_scale * self.fc1_weight.detach()), -128, 127).to(torch.int8).cpu(),
            "fc2_weight": torch.clamp(torch.round(self.weight_scale * self.fc2_weight.detach()), -128, 127).to(torch.int8).cpu(),
        }

    def forward_with_intermediates(
        self,
        x: torch.Tensor,
        quantize_weights: bool = True,
        quantize_activations: bool = True,
    ) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
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
        pool1 = x
        if quantize_activations:
            x = requantize_i32_to_i8(
                x,
                self.requant_params["conv2_in"]["multiplier"],
                self.requant_params["conv2_in"]["shift"],
                ste=True,
            )

        x = F.conv2d(x, w2, bias=None, stride=1, padding=0)
        x = F.max_pool2d(x, kernel_size=2, stride=2)
        pool2 = x
        if quantize_activations:
            x = requantize_i32_to_i8(
                x,
                self.requant_params["fc1_in"]["multiplier"],
                self.requant_params["fc1_in"]["shift"],
                ste=True,
            )

        x = x.permute(0, 2, 3, 1).contiguous().view(x.shape[0], -1)
        x = F.linear(x, w3, bias=None)
        x = F.relu(x)
        fc1_relu = x
        if quantize_activations:
            x = requantize_i32_to_i8(
                x,
                self.requant_params["fc2_in"]["multiplier"],
                self.requant_params["fc2_in"]["shift"],
                ste=True,
            )
        x = F.linear(x, w4, bias=None)
        return x, {
            "pool1_pre_quant": pool1,
            "pool2_pre_quant": pool2,
            "fc1_relu_pre_quant": fc1_relu,
        }

    def forward(
        self,
        x: torch.Tensor,
        quantize_weights: bool = True,
        quantize_activations: bool = True,
    ) -> torch.Tensor:
        logits, _ = self.forward_with_intermediates(
            x,
            quantize_weights=quantize_weights,
            quantize_activations=quantize_activations,
        )
        return logits


def model_from_quantized_payload(payload: dict) -> "Int8AwareLeNet":
    qstate = payload["quantized_state"]
    weight_scale = float(payload.get("weight_scale", 32.0))
    model = Int8AwareLeNet(
        weight_scale=weight_scale,
        requant_params=payload.get("requant_params"),
    )
    model.conv1_weight.data.copy_(qstate["conv1_weight"].to(torch.float32) / model.weight_scale)
    model.conv2_weight.data.copy_(qstate["conv2_weight"].to(torch.float32) / model.weight_scale)
    model.fc1_weight.data.copy_(qstate["fc1_weight"].to(torch.float32) / model.weight_scale)
    model.fc2_weight.data.copy_(qstate["fc2_weight"].to(torch.float32) / model.weight_scale)
    return model


@torch.no_grad()
def accuracy(
    model: nn.Module,
    xs: torch.Tensor,
    ys: torch.Tensor,
    batch_size: int,
    quantize_weights: bool = True,
    quantize_activations: bool = True,
) -> float:
    model.eval()
    total = 0
    correct = 0
    for start in range(0, xs.shape[0], batch_size):
        xb = xs[start:start + batch_size]
        yb = ys[start:start + batch_size]
        logits = model(xb, quantize_weights=quantize_weights, quantize_activations=quantize_activations)
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
    parser.add_argument("--weight-scale", type=float, default=32.0)
    parser.add_argument("--init-std", type=float, default=0.05)
    parser.add_argument("--loss-logit-scale", type=float, default=256.0, help="Divide logits by this constant for CE loss only")
    parser.add_argument("--grad-clip", type=float, default=0.0, help="0 disables gradient clipping")
    parser.add_argument("--float-activation-warmup", action="store_true", help="Disable activation quantization during warmup epochs")
    parser.add_argument("--quant-lr", type=float, default=0.0, help="0 keeps base lr; otherwise switch to this lr when quant phase starts")
    parser.add_argument("--epoch-lr-decay", type=float, default=1.0, help="Multiply optimizer lr by this factor after each epoch")
    parser.add_argument("--weight-decay", type=float, default=0.0, help="Adam weight decay")
    parser.add_argument("--activation-overflow-penalty", type=float, default=0.0, help="Penalty multiplier for activations outside INT8 range before requant")
    parser.add_argument("--rq-conv2-mult", type=int, default=1)
    parser.add_argument("--rq-conv2-shift", type=int, default=0)
    parser.add_argument("--rq-fc1-mult", type=int, default=1)
    parser.add_argument("--rq-fc1-shift", type=int, default=0)
    parser.add_argument("--rq-fc2-mult", type=int, default=1)
    parser.add_argument("--rq-fc2-shift", type=int, default=0)
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

    requant_params = {
        "conv2_in": {"multiplier": args.rq_conv2_mult, "shift": args.rq_conv2_shift},
        "fc1_in": {"multiplier": args.rq_fc1_mult, "shift": args.rq_fc1_shift},
        "fc2_in": {"multiplier": args.rq_fc2_mult, "shift": args.rq_fc2_shift},
    }

    model = Int8AwareLeNet(
        weight_scale=args.weight_scale,
        init_std=args.init_std,
        requant_params=requant_params,
    )
    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)

    best_acc = -1.0
    best_quant: dict[str, torch.Tensor] | None = None
    best_reload_acc = -1.0
    history: list[dict[str, float]] = []
    total_epochs = args.warmup_epochs + args.epochs

    for epoch in range(1, total_epochs + 1):
        if epoch == (args.warmup_epochs + 1) and args.quant_lr > 0.0:
            for group in optimizer.param_groups:
                group["lr"] = args.quant_lr
        model.train()
        order = torch.randperm(x_train.shape[0])
        epoch_loss = 0.0
        seen = 0
        quantize_weights = epoch > args.warmup_epochs
        quantize_activations = quantize_weights or (not args.float_activation_warmup)
        current_lr = optimizer.param_groups[0]["lr"]
        epoch_overflow = 0.0
        for start in range(0, x_train.shape[0], args.batch_size):
            idx = order[start:start + args.batch_size]
            xb = x_train[idx]
            yb = y_train[idx]

            optimizer.zero_grad(set_to_none=True)
            logits, intermediates = model.forward_with_intermediates(
                xb,
                quantize_weights=quantize_weights,
                quantize_activations=quantize_activations,
            )
            loss = F.cross_entropy(logits / args.loss_logit_scale, yb)
            overflow_loss = torch.zeros((), dtype=logits.dtype, device=logits.device)
            if args.activation_overflow_penalty > 0.0:
                for tensor in intermediates.values():
                    overflow_loss = overflow_loss + (F.relu(tensor.abs() - 127.0).mean() / 127.0)
                loss = loss + args.activation_overflow_penalty * overflow_loss
            loss.backward()
            if args.grad_clip > 0.0:
                torch.nn.utils.clip_grad_norm_(model.parameters(), args.grad_clip)
            optimizer.step()
            for param in model.parameters():
                param.data.clamp_(-127.0 / model.weight_scale, 127.0 / model.weight_scale)

            batch_n = yb.shape[0]
            epoch_loss += loss.item() * batch_n
            epoch_overflow += float(overflow_loss.item()) * batch_n
            seen += batch_n

        train_acc = accuracy(model, x_train, y_train, args.batch_size)
        test_acc = accuracy(model, x_test, y_test, args.batch_size)
        reload_payload = {
            "weight_scale": model.weight_scale,
            "quantized_state": model.quantized_state(),
            "requant_params": model.requant_params,
        }
        reload_model = model_from_quantized_payload(reload_payload)
        reload_test_acc = accuracy(reload_model, x_test, y_test, args.batch_size)
        avg_loss = epoch_loss / seen if seen else 0.0
        history.append(
            {
                "epoch": float(epoch),
                "loss": avg_loss,
                "overflow_loss": epoch_overflow / seen if seen else 0.0,
                "train_acc": train_acc,
                "test_acc": test_acc,
                "reload_test_acc": reload_test_acc,
                "lr": current_lr,
                "quantized_phase": 1.0 if quantize_weights else 0.0,
            }
        )
        print(
            f"epoch {epoch:02d} ({'quant' if quantize_weights else 'warmup'}): "
            f"loss={avg_loss:.6f} overflow_loss={(epoch_overflow / seen if seen else 0.0):.6f} "
            f"train_acc={train_acc:.4f} test_acc={test_acc:.4f} reload_test_acc={reload_test_acc:.4f} lr={current_lr:.6g}"
        )

        if reload_test_acc > best_reload_acc:
            best_acc = test_acc
            best_reload_acc = reload_test_acc
            best_quant = model.quantized_state()

        if args.epoch_lr_decay != 1.0:
            for group in optimizer.param_groups:
                group["lr"] *= args.epoch_lr_decay

    if best_quant is None:
        raise RuntimeError("training did not produce any checkpoint")

    best_payload = {
        "weight_scale": model.weight_scale,
        "quantized_state": best_quant,
        "requant_params": model.requant_params,
    }
    best_model = model_from_quantized_payload(best_payload)
    best_test_acc_reloaded = accuracy(best_model, x_test, y_test, args.batch_size)
    best_train_acc_reloaded = accuracy(best_model, x_train, y_train, args.batch_size)
    first8_logits = best_model(x_test[:8], quantize_weights=True).argmax(dim=1).cpu().tolist()
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
        "best_test_acc_reloaded": best_test_acc_reloaded,
        "best_train_acc_reloaded": best_train_acc_reloaded,
        "weight_scale": model.weight_scale,
        "requant_version": REQUANT_VERSION,
        "requant_params": model.requant_params,
        "init_std": model.init_std,
        "warmup_epochs": args.warmup_epochs,
        "quant_epochs": args.epochs,
        "batch_size": args.batch_size,
        "lr": args.lr,
        "seed": args.seed,
        "loss_logit_scale": args.loss_logit_scale,
        "grad_clip": args.grad_clip,
        "quant_lr": args.quant_lr,
        "epoch_lr_decay": args.epoch_lr_decay,
        "weight_decay": args.weight_decay,
        "activation_overflow_penalty": args.activation_overflow_penalty,
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
                "best_test_acc_reloaded": best_test_acc_reloaded,
                "best_train_acc_reloaded": best_train_acc_reloaded,
                "weight_scale": model.weight_scale,
                "requant_version": REQUANT_VERSION,
                "requant_params": model.requant_params,
                "init_std": model.init_std,
                "warmup_epochs": args.warmup_epochs,
                "quant_epochs": args.epochs,
                "batch_size": args.batch_size,
                "lr": args.lr,
                "seed": args.seed,
                "loss_logit_scale": args.loss_logit_scale,
                "grad_clip": args.grad_clip,
                "quant_lr": args.quant_lr,
                "epoch_lr_decay": args.epoch_lr_decay,
                "weight_decay": args.weight_decay,
                "activation_overflow_penalty": args.activation_overflow_penalty,
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
