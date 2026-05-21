#!/usr/bin/env python3
"""Generate deterministic LeNet(MNIST) weights and golden outputs.

Outputs a self-contained fixture tree for network-level RTL testing:

- common weights in MEMH/preload_map form
- per-sample golden layer outputs
- final logits / argmax

No third-party Python dependencies are required.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path


INPUT_BASE = 0x0000_0100
CONV1_WGT_BASE = 0x0000_1000
CONV1_OUT_BASE = 0x0000_4000
POOL1_OUT_BASE = 0x0001_8000
CONV2_IN_BASE = 0x0001_C000
CONV2_WGT_BASE = 0x0002_0000
CONV2_OUT_BASE = 0x0006_0000
POOL2_OUT_BASE = 0x0008_0000
FC1_WGT_BASE = 0x0009_0000
FC1_OUT_BASE = 0x000F_2000
FC2_WGT_BASE = 0x000F_3000
FC2_OUT_BASE = 0x000F_5000


def sat_i8(val: int) -> int:
    if val > 127:
        return 127
    if val < -128:
        return -128
    return val


def to_u8(val: int) -> int:
    return val & 0xFF


def pack_le_words(blob: bytes) -> list[int]:
    words: list[int] = []
    for i in range(0, len(blob), 4):
        chunk = blob[i:i + 4]
        padded = chunk + b"\x00" * (4 - len(chunk))
        words.append(padded[0] | (padded[1] << 8) | (padded[2] << 16) | (padded[3] << 24))
    return words


def write_memh_and_preload(blob: bytes, memh_path: Path, preload_path: Path, base_addr: int) -> None:
    words = pack_le_words(blob)
    memh_path.parent.mkdir(parents=True, exist_ok=True)
    with memh_path.open("w", encoding="ascii") as f:
        for word in words:
            f.write(f"{word:08x}\n")
    with preload_path.open("w", encoding="ascii") as f:
        for idx, word in enumerate(words):
            f.write(f"{base_addr + idx * 4:08x} {word:08x}\n")


def write_i32_memh(values: list[int], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii") as f:
        for value in values:
            f.write(f"{value & 0xFFFF_FFFF:08x}\n")


def idx_hwc(h: int, w: int, c: int, width: int, channels: int) -> int:
    return (h * width + w) * channels + c


def conv_weight_val(ic: int, kh: int, kw: int, oc: int, layer: int) -> int:
    if layer == 1:
        return -((((oc * 3 + kh * 2 + kw + 1) % 2) + 1))
    return ((ic * 7 + oc * 3 + kh * 2 + kw + 1) % 3)


def fc_weight_val(out_idx: int, in_idx: int, layer: int) -> int:
    if layer == 1:
        return ((out_idx * 5 + in_idx * 3 + 1) % 2) + 1
    return (out_idx % 10) + 1


def gen_conv_weight_bytes(input_c: int, output_c: int, layer: int) -> bytes:
    out = bytearray()
    for ic in range(input_c):
        chunk = bytearray()
        for kh in range(5):
            for kw in range(5):
                for oc in range(output_c):
                    chunk.append(to_u8(conv_weight_val(ic, kh, kw, oc, layer)))
        while len(chunk) % 4:
            chunk.append(0)
        out.extend(chunk)
    return bytes(out)


def gen_fc_weight_bytes(input_size: int, output_size: int, layer: int) -> bytes:
    out = bytearray()
    for out_idx in range(output_size):
        for in_idx in range(input_size):
            out.append(to_u8(fc_weight_val(out_idx, in_idx, layer)))
    return bytes(out)


def conv5x5_valid_hwc(inp: list[int], in_h: int, in_w: int, in_c: int, out_c: int, layer: int) -> list[int]:
    out_h = in_h - 4
    out_w = in_w - 4
    out = [0] * (out_h * out_w * out_c)
    for oh in range(out_h):
        for ow in range(out_w):
            for oc in range(out_c):
                acc = 0
                for ic in range(in_c):
                    for kh in range(5):
                        for kw in range(5):
                            a = inp[idx_hwc(oh + kh, ow + kw, ic, in_w, in_c)]
                            w = conv_weight_val(ic, kh, kw, oc, layer)
                            acc += a * w
                out[idx_hwc(oh, ow, oc, out_w, out_c)] = acc
    return out


def pool2x2_hwc(inp: list[int], in_h: int, in_w: int, channels: int) -> list[int]:
    out_h = in_h // 2
    out_w = in_w // 2
    out = [0] * (out_h * out_w * channels)
    for oh in range(out_h):
        for ow in range(out_w):
            for c in range(channels):
                vals = [
                    inp[idx_hwc(oh * 2 + 0, ow * 2 + 0, c, in_w, channels)],
                    inp[idx_hwc(oh * 2 + 0, ow * 2 + 1, c, in_w, channels)],
                    inp[idx_hwc(oh * 2 + 1, ow * 2 + 0, c, in_w, channels)],
                    inp[idx_hwc(oh * 2 + 1, ow * 2 + 1, c, in_w, channels)],
                ]
                out[idx_hwc(oh, ow, c, out_w, channels)] = max(vals)
    return out


def fc_int32_to_int32(inp: list[int], output_size: int, layer: int, relu: bool) -> list[int]:
    out = [0] * output_size
    qinp = [sat_i8(v) for v in inp]
    for out_idx in range(output_size):
        acc = 0
        for in_idx, aval in enumerate(qinp):
            acc += aval * fc_weight_val(out_idx, in_idx, layer)
        if relu and acc < 0:
            acc = 0
        out[out_idx] = acc
    return out


def int32_list_to_le_bytes(values: list[int]) -> bytes:
    out = bytearray()
    for val in values:
        word = val & 0xFFFF_FFFF
        out.extend(bytes((word & 0xFF, (word >> 8) & 0xFF, (word >> 16) & 0xFF, (word >> 24) & 0xFF)))
    return bytes(out)


def int32_to_i8_blob(values: list[int]) -> bytes:
    return bytes(to_u8(sat_i8(v)) for v in values)


def argmax(values: list[int]) -> int:
    best_i = 0
    best_v = values[0]
    for i, v in enumerate(values[1:], start=1):
        if v > best_v:
            best_i = i
            best_v = v
    return best_i


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate deterministic LeNet fixture")
    parser.add_argument("--exports-dir", default="datasets/mnist/exports")
    parser.add_argument("--output-dir", default="datasets/mnist/lenet_fixture")
    parser.add_argument("--count", type=int, default=8)
    args = parser.parse_args()

    exports_dir = Path(args.exports_dir)
    out_dir = Path(args.output_dir)
    manifest = json.loads((exports_dir / "manifest.json").read_text(encoding="ascii"))
    manifest = manifest[: args.count]

    weights_dir = out_dir / "weights"
    weights_dir.mkdir(parents=True, exist_ok=True)

    conv1_blob = gen_conv_weight_bytes(1, 20, layer=1)
    conv2_blob = gen_conv_weight_bytes(20, 50, layer=2)
    fc1_blob = gen_fc_weight_bytes(800, 500, layer=1)
    fc2_blob = gen_fc_weight_bytes(500, 10, layer=2)

    write_memh_and_preload(conv1_blob, weights_dir / "conv1_weights.memh", weights_dir / "conv1_weights.preload_map.txt", CONV1_WGT_BASE)
    write_memh_and_preload(conv2_blob, weights_dir / "conv2_weights.memh", weights_dir / "conv2_weights.preload_map.txt", CONV2_WGT_BASE)
    write_memh_and_preload(fc1_blob, weights_dir / "fc1_weights.memh", weights_dir / "fc1_weights.preload_map.txt", FC1_WGT_BASE)
    write_memh_and_preload(fc2_blob, weights_dir / "fc2_weights.memh", weights_dir / "fc2_weights.preload_map.txt", FC2_WGT_BASE)

    fixture_manifest = []
    for entry in manifest:
        sample_dir = exports_dir / entry["dir"]
        fixture_dir = out_dir / entry["dir"]
        fixture_dir.mkdir(parents=True, exist_ok=True)

        image_i8 = sample_dir.joinpath("image_i8.bin").read_bytes()
        image = [b - 256 if b >= 128 else b for b in image_i8]

        conv1 = conv5x5_valid_hwc(image, 28, 28, 1, 20, layer=1)
        pool1 = pool2x2_hwc(conv1, 24, 24, 20)
        conv2_in = [sat_i8(v) for v in pool1]
        conv2 = conv5x5_valid_hwc(conv2_in, 12, 12, 20, 50, layer=2)
        pool2 = pool2x2_hwc(conv2, 8, 8, 50)
        fc1 = fc_int32_to_int32(pool2, 500, layer=1, relu=True)
        fc2 = fc_int32_to_int32(fc1, 10, layer=2, relu=False)
        pred = argmax(fc2)

        shutil.copyfile(sample_dir / "packed_words.memh", fixture_dir / "input.memh")
        shutil.copyfile(sample_dir / "label.txt", fixture_dir / "label.txt")
        shutil.copyfile(sample_dir / "meta.json", fixture_dir / "meta.json")

        write_i32_memh(conv1, fixture_dir / "conv1_out.memh")
        write_i32_memh(pool1, fixture_dir / "pool1_out.memh")
        write_memh_and_preload(int32_to_i8_blob(pool1), fixture_dir / "conv2_input.memh", fixture_dir / "conv2_input.preload_map.txt", CONV2_IN_BASE)
        write_i32_memh(conv2, fixture_dir / "conv2_out.memh")
        write_i32_memh(pool2, fixture_dir / "pool2_out.memh")
        write_i32_memh(fc1, fixture_dir / "fc1_out.memh")
        write_i32_memh(fc2, fixture_dir / "fc2_logits.memh")
        (fixture_dir / "argmax.txt").write_text(f"{pred}\n", encoding="ascii")

        summary = {
            "sample_index": entry["index"],
            "label": entry["label"],
            "predicted_class": pred,
            "conv1_shape": [24, 24, 20],
            "pool1_shape": [12, 12, 20],
            "conv2_shape": [8, 8, 50],
            "pool2_shape": [4, 4, 50],
            "fc1_shape": [500],
            "fc2_shape": [10],
            "fc2_logits": fc2,
        }
        (fixture_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="ascii")
        fixture_manifest.append({"dir": entry["dir"], "label": entry["label"], "predicted_class": pred})

    (out_dir / "manifest.json").write_text(json.dumps(fixture_manifest, indent=2) + "\n", encoding="ascii")
    print(f"generated LeNet fixture for {len(fixture_manifest)} samples at {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
