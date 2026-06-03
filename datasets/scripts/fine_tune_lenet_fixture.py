#!/usr/bin/env python3
"""Fine-tune a spec-matching LeNet checkpoint on exported MNIST fixture samples."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
import torch.nn.functional as F

from train_lenet_mnist import Int8AwareLeNet


def load_checkpoint_to_model(path: Path) -> tuple[Int8AwareLeNet, dict]:
    payload = torch.load(path, map_location="cpu")
    if payload.get("arch") != "soc6_lenet_int8_v1":
        raise ValueError(f"unsupported checkpoint arch {payload.get('arch')!r}")

    qstate = payload.get("quantized_state", {})
    model = Int8AwareLeNet(
        weight_scale=float(payload.get("weight_scale", 32.0)),
        requant_params=payload.get("requant_params"),
    )
    model.conv1_weight.data.copy_(qstate["conv1_weight"].to(torch.float32) / model.weight_scale)
    model.conv2_weight.data.copy_(qstate["conv2_weight"].to(torch.float32) / model.weight_scale)
    model.fc1_weight.data.copy_(qstate["fc1_weight"].to(torch.float32) / model.weight_scale)
    model.fc2_weight.data.copy_(qstate["fc2_weight"].to(torch.float32) / model.weight_scale)
    return model, payload


def load_fixture_batch(exports_dir: Path, count: int) -> tuple[torch.Tensor, torch.Tensor, list[dict]]:
    manifest = json.loads((exports_dir / "manifest.json").read_text(encoding="ascii"))[:count]
    xs = []
    ys = []
    for entry in manifest:
        sample_dir = exports_dir / entry["dir"]
        image = torch.frombuffer(bytearray((sample_dir / "image_i8.bin").read_bytes()), dtype=torch.int8).clone()
        xs.append(image.to(torch.float32).reshape(1, 28, 28))
        ys.append(int(entry["label"]))
    x = torch.stack(xs, dim=0)
    y = torch.tensor(ys, dtype=torch.long)
    return x, y, manifest


@torch.no_grad()
def evaluate(model: Int8AwareLeNet, xs: torch.Tensor, ys: torch.Tensor) -> tuple[list[int], float]:
    model.eval()
    logits = model(xs, quantize_weights=True)
    pred = logits.argmax(dim=1)
    acc = (pred == ys).to(torch.float32).mean().item()
    return pred.cpu().tolist(), acc


def main() -> int:
    parser = argparse.ArgumentParser(description="Fine-tune spec-matching LeNet on exported fixture samples")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--exports-dir", default="datasets/mnist/exports")
    parser.add_argument("--output", required=True)
    parser.add_argument("--count", type=int, default=8)
    parser.add_argument("--epochs", type=int, default=200)
    parser.add_argument("--lr", type=float, default=1e-3)
    args = parser.parse_args()

    ckpt_path = Path(args.checkpoint)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    model, payload = load_checkpoint_to_model(ckpt_path)
    xs, ys, manifest = load_fixture_batch(Path(args.exports_dir), args.count)

    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr)
    best_acc = -1.0
    best_state = model.quantized_state()
    best_pred: list[int] = []

    for epoch in range(1, args.epochs + 1):
        model.train()
        optimizer.zero_grad(set_to_none=True)
        logits = model(xs, quantize_weights=True)
        loss = F.cross_entropy(logits, ys)
        loss.backward()
        optimizer.step()
        for param in model.parameters():
            param.data.clamp_(-127.0 / model.weight_scale, 127.0 / model.weight_scale)

        pred, acc = evaluate(model, xs, ys)
        if acc > best_acc:
            best_acc = acc
            best_state = model.quantized_state()
            best_pred = pred
        print(f"epoch {epoch:03d}: loss={loss.item():.6f} acc={acc:.4f} pred={pred}")
        if acc == 1.0:
            break

    payload["quantized_state"] = best_state
    payload["fixture_tuned"] = {
        "exports_dir": str(args.exports_dir),
        "count": args.count,
        "best_acc": best_acc,
        "best_pred": best_pred,
        "labels": ys.cpu().tolist(),
        "samples": [entry["dir"] for entry in manifest],
    }
    torch.save(payload, out_path)
    out_path.with_suffix(out_path.suffix + ".json").write_text(
        json.dumps(payload["fixture_tuned"], indent=2) + "\n",
        encoding="ascii",
    )
    print(f"saved checkpoint: {out_path}")
    print(f"saved tuning summary: {out_path}.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
