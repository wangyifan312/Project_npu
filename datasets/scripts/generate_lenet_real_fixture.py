#!/usr/bin/env python3
"""Generate real-weight LeNet fixtures from a trained spec-matching checkpoint."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import torch
import torch.nn.functional as F
from requant_utils import REQUANT_VERSION, normalize_requant_params, requantize_i32_to_i8

from generate_lenet_fixture import (
    CONV1_WGT_BASE,
    CONV2_IN_BASE,
    CONV2_WGT_BASE,
    FC1_WGT_BASE,
    FC2_WGT_BASE,
    argmax,
    int32_to_i8_blob,
    pack_le_words,
    write_i32_memh,
    write_memh_and_preload,
)


EXPECTED_TOPOLOGY = {
    "conv1": [20, 1, 5, 5],
    "conv2": [50, 20, 5, 5],
    "fc1": [500, 800],
    "fc2": [10, 500],
}


def validate_checkpoint(payload: dict) -> dict[str, torch.Tensor]:
    if payload.get("arch") != "soc6_lenet_int8_v1":
        raise ValueError(f"unsupported arch {payload.get('arch')!r}")
    if payload.get("requant_version") != REQUANT_VERSION:
        raise ValueError(
            f"checkpoint requant_version mismatch: {payload.get('requant_version')!r} != {REQUANT_VERSION!r}"
        )
    topo = payload.get("topology", {})
    for key, shape in EXPECTED_TOPOLOGY.items():
        if list(topo.get(key, [])) != shape:
            raise ValueError(f"checkpoint topology mismatch for {key}: {topo.get(key)} != {shape}")
    if topo.get("bias", False):
        raise ValueError("checkpoint enables bias, which is incompatible with the RTL/spec")

    qstate = payload.get("quantized_state")
    if not isinstance(qstate, dict):
        raise ValueError("checkpoint missing quantized_state")

    for key, shape in (
        ("conv1_weight", EXPECTED_TOPOLOGY["conv1"]),
        ("conv2_weight", EXPECTED_TOPOLOGY["conv2"]),
        ("fc1_weight", EXPECTED_TOPOLOGY["fc1"]),
        ("fc2_weight", EXPECTED_TOPOLOGY["fc2"]),
    ):
        tensor = qstate.get(key)
        if not isinstance(tensor, torch.Tensor):
            raise ValueError(f"checkpoint missing tensor {key}")
        if list(tensor.shape) != shape:
            raise ValueError(f"tensor shape mismatch for {key}: {list(tensor.shape)} != {shape}")
    return qstate


def to_u8_byte(val: int) -> int:
    return val & 0xFF


def conv_weight_bytes(weight: torch.Tensor) -> bytes:
    out_c, in_c, k_h, k_w = weight.shape
    blob = bytearray()
    for ic in range(in_c):
        chunk = bytearray()
        for kh in range(k_h):
            for kw in range(k_w):
                for oc in range(out_c):
                    chunk.append(to_u8_byte(int(weight[oc, ic, kh, kw].item())))
        while len(chunk) % 4:
            chunk.append(0)
        blob.extend(chunk)
    return bytes(blob)


def fc_weight_bytes(weight: torch.Tensor) -> bytes:
    out_features, in_features = weight.shape
    blob = bytearray()
    for out_idx in range(out_features):
        for in_idx in range(in_features):
            blob.append(to_u8_byte(int(weight[out_idx, in_idx].item())))
    return bytes(blob)


def signed_i8_tensor_from_file(path: Path, shape: tuple[int, ...]) -> torch.Tensor:
    buf = bytearray(path.read_bytes())
    return torch.frombuffer(buf, dtype=torch.int8).clone().reshape(shape)


def hw_conv_pool_fc(
    image: torch.Tensor,
    conv1_w: torch.Tensor,
    conv2_w: torch.Tensor,
    fc1_w: torch.Tensor,
    fc2_w: torch.Tensor,
    requant_params: dict[str, dict[str, int]],
) -> tuple[list[int], list[int], bytes, list[int], list[int], list[int], list[int]]:
    x = image.to(torch.float32).unsqueeze(0).unsqueeze(0)

    conv1 = F.conv2d(x, conv1_w.to(torch.float32), bias=None, stride=1, padding=0)
    pool1 = F.max_pool2d(conv1, kernel_size=2, stride=2)
    conv2_in = requantize_i32_to_i8(
        pool1,
        requant_params["conv2_in"]["multiplier"],
        requant_params["conv2_in"]["shift"],
    )

    conv2 = F.conv2d(conv2_in, conv2_w.to(torch.float32), bias=None, stride=1, padding=0)
    pool2 = F.max_pool2d(conv2, kernel_size=2, stride=2)
    fc1_in = requantize_i32_to_i8(
        pool2,
        requant_params["fc1_in"]["multiplier"],
        requant_params["fc1_in"]["shift"],
    )

    fc1 = F.linear(fc1_in.permute(0, 2, 3, 1).contiguous().view(1, -1), fc1_w.to(torch.float32), bias=None)
    fc1_relu = torch.relu(fc1)
    fc2_in = requantize_i32_to_i8(
        fc1_relu,
        requant_params["fc2_in"]["multiplier"],
        requant_params["fc2_in"]["shift"],
    )
    fc2 = F.linear(fc2_in, fc2_w.to(torch.float32), bias=None)

    return (
        nchw_to_hwc_i32_list(conv1.squeeze(0)),
        nchw_to_hwc_i32_list(pool1.squeeze(0)),
        nchw_i8_to_hwc_blob(conv2_in.squeeze(0)),
        nchw_to_hwc_i32_list(conv2.squeeze(0)),
        nchw_to_hwc_i32_list(pool2.squeeze(0)),
        tensor1d_to_i32_list(fc1_relu.squeeze(0)),
        tensor1d_to_i32_list(fc2.squeeze(0)),
    )


def predict_class_only(
    image: torch.Tensor,
    conv1_w: torch.Tensor,
    conv2_w: torch.Tensor,
    fc1_w: torch.Tensor,
    fc2_w: torch.Tensor,
    requant_params: dict[str, dict[str, int]],
) -> int:
    x = image.to(torch.float32).unsqueeze(0).unsqueeze(0)

    conv1 = F.conv2d(x, conv1_w.to(torch.float32), bias=None, stride=1, padding=0)
    pool1 = F.max_pool2d(conv1, kernel_size=2, stride=2)
    conv2_in = requantize_i32_to_i8(
        pool1,
        requant_params["conv2_in"]["multiplier"],
        requant_params["conv2_in"]["shift"],
    )

    conv2 = F.conv2d(conv2_in, conv2_w.to(torch.float32), bias=None, stride=1, padding=0)
    pool2 = F.max_pool2d(conv2, kernel_size=2, stride=2)
    fc1_in = requantize_i32_to_i8(
        pool2,
        requant_params["fc1_in"]["multiplier"],
        requant_params["fc1_in"]["shift"],
    )

    fc1 = F.linear(fc1_in.permute(0, 2, 3, 1).contiguous().view(1, -1), fc1_w.to(torch.float32), bias=None)
    fc1_relu = torch.relu(fc1)
    fc2_in = requantize_i32_to_i8(
        fc1_relu,
        requant_params["fc2_in"]["multiplier"],
        requant_params["fc2_in"]["shift"],
    )
    fc2 = F.linear(fc2_in, fc2_w.to(torch.float32), bias=None)
    return argmax(tensor1d_to_i32_list(fc2.squeeze(0)))


def nchw_to_hwc_i32_list(tensor: torch.Tensor) -> list[int]:
    c, h, w = tensor.shape
    out: list[int] = []
    for oh in range(h):
        for ow in range(w):
            for oc in range(c):
                out.append(int(tensor[oc, oh, ow].item()))
    return out


def nchw_i8_to_hwc_blob(tensor: torch.Tensor) -> bytes:
    c, h, w = tensor.shape
    out = bytearray()
    for oh in range(h):
        for ow in range(w):
            for oc in range(c):
                out.append(to_u8_byte(int(tensor[oc, oh, ow].item())))
    return bytes(out)


def tensor1d_to_i32_list(tensor: torch.Tensor) -> list[int]:
    return [int(v.item()) for v in tensor]


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate real-weight LeNet fixture")
    parser.add_argument("--checkpoint", default="datasets/mnist/models/mnist_lenet_soc6_fixture8.pt")
    parser.add_argument("--exports-dir", default="datasets/mnist/exports")
    parser.add_argument("--output-dir", default="datasets/mnist/lenet_real_fixture")
    parser.add_argument("--count", type=int, default=8, help="0 = all remaining samples from offset")
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--manifest-only", action="store_true", help="Write manifest + weights only")
    parser.add_argument("--full-fixture", action="store_true", help="Force full per-sample fixture generation")
    args = parser.parse_args()

    ckpt_path = Path(args.checkpoint)
    exports_dir = Path(args.exports_dir)
    out_dir = Path(args.output_dir)

    payload = torch.load(ckpt_path, map_location="cpu")
    qstate = validate_checkpoint(payload)
    requant_params = normalize_requant_params(payload.get("requant_params"))

    conv1_w = qstate["conv1_weight"].to(torch.int8)
    conv2_w = qstate["conv2_weight"].to(torch.int8)
    fc1_w = qstate["fc1_weight"].to(torch.int8)
    fc2_w = qstate["fc2_weight"].to(torch.int8)

    weights_dir = out_dir / "weights"
    weights_dir.mkdir(parents=True, exist_ok=True)

    write_memh_and_preload(
        conv_weight_bytes(conv1_w),
        weights_dir / "conv1_weights.memh",
        weights_dir / "conv1_weights.preload_map.txt",
        CONV1_WGT_BASE,
    )
    write_memh_and_preload(
        conv_weight_bytes(conv2_w),
        weights_dir / "conv2_weights.memh",
        weights_dir / "conv2_weights.preload_map.txt",
        CONV2_WGT_BASE,
    )
    write_memh_and_preload(
        fc_weight_bytes(fc1_w),
        weights_dir / "fc1_weights.memh",
        weights_dir / "fc1_weights.preload_map.txt",
        FC1_WGT_BASE,
    )
    write_memh_and_preload(
        fc_weight_bytes(fc2_w),
        weights_dir / "fc2_weights.memh",
        weights_dir / "fc2_weights.preload_map.txt",
        FC2_WGT_BASE,
    )

    manifest = json.loads((exports_dir / "manifest.json").read_text(encoding="ascii"))
    manifest = manifest[args.offset:]
    if args.count > 0:
        manifest = manifest[: args.count]
    full_fixture_mode = args.full_fixture or not args.manifest_only

    fixture_manifest = []
    for entry in manifest:
        sample_dir = exports_dir / entry["dir"]
        image = signed_i8_tensor_from_file(sample_dir / "image_i8.bin", (28, 28))
        if full_fixture_mode:
            conv1, pool1, conv2_input_blob, conv2, pool2, fc1, fc2 = hw_conv_pool_fc(
                image=image,
                conv1_w=conv1_w,
                conv2_w=conv2_w,
                fc1_w=fc1_w,
                fc2_w=fc2_w,
                requant_params=requant_params,
            )
            pred = argmax(fc2)
        else:
            pred = predict_class_only(
                image=image,
                conv1_w=conv1_w,
                conv2_w=conv2_w,
                fc1_w=fc1_w,
                fc2_w=fc2_w,
                requant_params=requant_params,
            )
        record = {
            "dir": entry["dir"],
            "index": entry["index"],
            "label": entry["label"],
            "predicted_class": pred,
            "source_dir": str(sample_dir),
            "input_memh": str(sample_dir / "packed_words.memh"),
            "label_path": str(sample_dir / "label.txt"),
            "meta_path": str(sample_dir / "meta.json"),
        }

        if full_fixture_mode:
            fixture_dir = out_dir / entry["dir"]
            fixture_dir.mkdir(parents=True, exist_ok=True)

            shutil.copyfile(sample_dir / "packed_words.memh", fixture_dir / "input.memh")
            shutil.copyfile(sample_dir / "label.txt", fixture_dir / "label.txt")
            shutil.copyfile(sample_dir / "meta.json", fixture_dir / "meta.json")

            write_i32_memh(conv1, fixture_dir / "conv1_out.memh")
            write_i32_memh(pool1, fixture_dir / "pool1_out.memh")
            write_memh_and_preload(
                conv2_input_blob,
                fixture_dir / "conv2_input.memh",
                fixture_dir / "conv2_input.preload_map.txt",
                CONV2_IN_BASE,
            )
            write_i32_memh(conv2, fixture_dir / "conv2_out.memh")
            write_i32_memh(pool2, fixture_dir / "pool2_out.memh")
            write_i32_memh(fc1, fixture_dir / "fc1_out.memh")
            write_i32_memh(fc2, fixture_dir / "fc2_logits.memh")
            (fixture_dir / "argmax.txt").write_text(f"{pred}\n", encoding="ascii")

            summary = {
                "sample_index": entry["index"],
                "label": entry["label"],
                "predicted_class": pred,
                "checkpoint": str(ckpt_path),
                "checkpoint_test_acc": payload.get("best_test_acc"),
                "requant_version": payload.get("requant_version"),
                "requant_params": requant_params,
                "conv1_shape": [24, 24, 20],
                "pool1_shape": [12, 12, 20],
                "conv2_shape": [8, 8, 50],
                "pool2_shape": [4, 4, 50],
                "fc1_shape": [500],
                "fc2_shape": [10],
                "fc2_logits": fc2,
            }
            (fixture_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="ascii")
        fixture_manifest.append(record)

    (out_dir / "manifest.json").write_text(json.dumps(fixture_manifest, indent=2) + "\n", encoding="ascii")
    fixture_summary = {
        "checkpoint": str(ckpt_path),
        "exports_dir": str(exports_dir),
        "output_dir": str(out_dir),
        "offset": args.offset,
        "count": len(fixture_manifest),
        "mode": "full_fixture" if full_fixture_mode else "manifest_only",
        "best_test_acc": payload.get("best_test_acc"),
        "requant_version": payload.get("requant_version"),
        "requant_params": requant_params,
    }
    (out_dir / "summary.json").write_text(json.dumps(fixture_summary, indent=2) + "\n", encoding="ascii")

    weights_summary = {
        "checkpoint": str(ckpt_path),
        "best_test_acc": payload.get("best_test_acc"),
        "mode": "full_fixture" if full_fixture_mode else "manifest_only",
        "offset": args.offset,
        "count": len(fixture_manifest),
        "requant_version": payload.get("requant_version"),
        "requant_params": requant_params,
        "conv1_words": len(pack_le_words(conv_weight_bytes(conv1_w))),
        "conv2_words": len(pack_le_words(conv_weight_bytes(conv2_w))),
        "fc1_words": len(pack_le_words(fc_weight_bytes(fc1_w))),
        "fc2_words": len(pack_le_words(fc_weight_bytes(fc2_w))),
    }
    (weights_dir / "summary.json").write_text(json.dumps(weights_summary, indent=2) + "\n", encoding="ascii")

    print(f"generated real-weight LeNet {'full fixture' if full_fixture_mode else 'manifest'} for {len(fixture_manifest)} samples at {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
