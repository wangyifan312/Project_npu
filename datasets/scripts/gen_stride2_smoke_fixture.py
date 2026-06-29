#!/usr/bin/env python3
"""Generate a minimal 3x3 stride2 same-padding smoke fixture.

Isolates the conv_frontend stride2 path:
  - 16 input channels × 32×32
  - 16 output channels × 16×16 (fits PE_COLS=16, MODE_SINGLE)
  - deterministic weights/bias, no package dependency
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F


def to_s8(value: int) -> int:
    value &= 0xFF
    return value - 256 if value >= 128 else value


def round_shift_half_away(data: torch.Tensor, shift: int) -> torch.Tensor:
    data = data.to(torch.int64)
    if shift == 0:
        return data
    rounded = (torch.abs(data) + (1 << (shift - 1))) >> shift
    return torch.where(data < 0, -rounded, rounded)


def requant(data: torch.Tensor, mult: int, sft: int, clamp: bool = True) -> torch.Tensor:
    value = round_shift_half_away(data * mult, sft)
    return torch.clamp(value, -128, 127) if clamp else value


def seeded_input(byte_size: int) -> list[int]:
    return [((idx * 37 + (idx // 3) * 11 + 19) & 0xFF) for idx in range(byte_size)]


def checksum(values: list[int]) -> int:
    return sum((idx + 1) * (value & 0xFF) for idx, value in enumerate(values)) & 0xFFFFFFFF


def write_memh(path: Path, values: list[int], width: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    digits = width // 4
    mask = (1 << width) - 1
    path.write_text("".join(f"{value & mask:0{digits}x}\n" for value in values), encoding="ascii")


def tensor_to_hwc_bytes(tensor: torch.Tensor) -> list[int]:
    flat = tensor[0].permute(1, 2, 0).contiguous().view(-1).tolist()
    return [int(value) & 0xFF for value in flat]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", default="tb/generated/stride2_smoke")
    parser.add_argument("--summary", default="tb/generated/stride2_smoke/summary.json")
    parser.add_argument("--output-c", type=int, default=16, help="output channels (16 or 32)")
    args = parser.parse_args()

    output = Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)

    IN_C = 16
    OUT_C = args.output_c
    H = 32
    W = 32
    KERNEL = 3
    STRIDE = 2
    PADDING = 1  # same
    MULTIPLIER_INT = 1234567
    SHIFT = 27
    INPUT_ADDR = 64
    WEIGHT_ADDR = 0x0008_0000  # 524288
    BIAS_ADDR = 0x0008_1000   # 528384
    OUTPUT_ADDR = 3136
    CONV_CFG = 0x1E  # 3x3(2) | stride2(4) | same(8) | bias(16) = 30

    # -------- input --------
    input_bytes = IN_C * H * W  # 16384
    input_values = seeded_input(input_bytes)
    write_memh(output / "input.memh", input_values, 8)

    # -------- weights (3×3×16×16 = 2304 bytes, IHWO layout) --------
    weight_values: list[int] = []
    for ic in range(IN_C):
        for kh in range(KERNEL):
            for kw in range(KERNEL):
                for oc in range(OUT_C):
                    w = oc * 16 + ic * 3 + kh * 3 + kw
                    w_s8 = w % 256
                    if w_s8 >= 128:
                        w_s8 -= 256
                    weight_values.append(w_s8 & 0xFF)

    write_memh(output / "weights.memh", weight_values, 8)

    # -------- bias (16 × INT32) --------
    bias_i32: list[int] = []
    for oc in range(OUT_C):
        b = oc * 100 - 800  # -800, -700, ..., 700
        bias_i32.append(b & 0xFFFFFFFF)

    write_memh(output / "bias.memh", bias_i32, 32)

    # bias as little-endian byte stream
    bias_bytes: list[int] = []
    for b32 in bias_i32:
        for lane in range(4):
            bias_bytes.append((b32 >> (8 * lane)) & 0xFF)

    write_memh(output / "bias_bytes.memh", bias_bytes, 8)

    # -------- software reference --------
    x = torch.tensor([to_s8(v) for v in input_values], dtype=torch.float32)
    x = x.view(1, H, W, IN_C).permute(0, 3, 1, 2).contiguous()

    w = torch.tensor([to_s8(v) for v in weight_values], dtype=torch.float32)
    w = w.view(IN_C, KERNEL, KERNEL, OUT_C).permute(3, 0, 1, 2).contiguous()

    b = torch.tensor([v if v < (1 << 31) else v - (1 << 32) for v in bias_i32], dtype=torch.float32)

    acc = torch.round(F.conv2d(x, w, bias=b, stride=STRIDE, padding=PADDING)).to(torch.int64)
    acc_relu = torch.clamp(acc, min=0)
    expected = requant(acc_relu, MULTIPLIER_INT, SHIFT, clamp=True)
    expected_hwc = tensor_to_hwc_bytes(expected)

    out_h = 16
    out_w = 16
    assert len(expected_hwc) == OUT_C * out_h * out_w, f"expected {OUT_C*out_h*out_w} bytes, got {len(expected_hwc)}"

    write_memh(output / "expected.memh", expected_hwc, 8)

    # -------- first mismatch debug info --------
    # Store per-channel debug: bias, expected first few pixels per channel
    per_channel_debug = []
    for oc in range(OUT_C):
        first_expected = expected_hwc[oc]  # h=0,w=0, this oc
        first_actual_ref = int(expected_hwc[oc])
        bias_val = bias_i32[oc]
        if bias_val >= (1 << 31):
            bias_val -= (1 << 32)
        per_channel_debug.append({
            "oc": oc,
            "bias_i32": bias_val,
            "first_pixel_expected": first_actual_ref,
        })

    summary = {
        "arch": "stride2_3x3_smoke",
        "kernel": [3, 3],
        "stride": 2,
        "padding": "same",
        "input_shape": [IN_C, H, W],
        "output_shape": [OUT_C, out_h, out_w],
        "input_addr": INPUT_ADDR,
        "weight_addr": WEIGHT_ADDR,
        "bias_addr": BIAS_ADDR,
        "output_addr": OUTPUT_ADDR,
        "input_bytes": input_bytes,
        "weight_bytes": len(weight_values),
        "bias_bytes": len(bias_i32) * 4,
        "output_bytes": len(expected_hwc),
        "multiplier_int": MULTIPLIER_INT,
        "shift": SHIFT,
        "conv_cfg": f"0x{CONV_CFG:02X}",
        "expected_checksum": f"0x{checksum(expected_hwc):08x}",
        "expected_file": str(output / "expected.memh"),
        "per_channel_debug": per_channel_debug,
    }
    Path(args.summary).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="ascii")

    print(f"Wrote {args.summary}")
    print(f"  input={input_bytes} bytes, weight={len(weight_values)} bytes, bias={len(bias_i32)*4} bytes")
    print(f"  output={len(expected_hwc)} bytes, expected_checksum={summary['expected_checksum']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
