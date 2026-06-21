#!/usr/bin/env python3
"""Generate a package-faithful ResNet-20 R1h conv1 compare fixture.

R1h deliberately moves beyond the compact alias/remap compare.  This fixture
uses the formal task_sequence/memory_map addresses and tensor byte sizes for
the first package task:

    input.image -> conv1 -> conv1.relu

Weights, folded bias, and requant parameters come from the validated export
package.  The generated testbench include is still a small fixture, not full
ResNet-20 execution.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from extract_resnet20_r1f_smoke import conv_cfg_for, load_json, memh_values


WEIGHT_LOAD_ADDR = 0x0008_0000
BIAS_LOAD_ADDR = 0x0008_1000


def to_s8(value: int) -> int:
    value &= 0xFF
    return value - 256 if value >= 128 else value


def to_u8(value: int) -> int:
    return value & 0xFF


def to_s32(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value >= (1 << 31) else value


def round_shift_half_away(value: int, shift: int) -> int:
    if shift < 0:
        raise ValueError(f"negative shift {shift}")
    if shift == 0:
        return value
    sign = -1 if value < 0 else 1
    rounded = (abs(value) + (1 << (shift - 1))) >> shift
    return sign * rounded


def requantize_i8(value: int, multiplier: int, shift: int) -> int:
    q = round_shift_half_away(value * int(multiplier), int(shift))
    return max(-128, min(127, q))


def checksum_bytes(values: list[int]) -> int:
    acc = 0
    for idx, value in enumerate(values):
        acc = (acc + ((value & 0xFF) * (idx + 1))) & 0xFFFFFFFF
    return acc


def seeded_input_bytes(byte_size: int) -> list[int]:
    # Deterministic signed-INT8 image-like pattern.  It is not CIFAR evidence.
    return [((idx * 37 + (idx // 3) * 11 + 19) & 0xFF) for idx in range(byte_size)]


def load_u8_memh(path: Path) -> list[int]:
    return [value & 0xFF for value in memh_values(path)]


def load_s8_memh(path: Path) -> list[int]:
    return [to_s8(value) for value in memh_values(path)]


def load_s32_memh(path: Path) -> list[int]:
    return [to_s32(value) for value in memh_values(path)]


def conv1_reference_hwc(
    input_bytes: list[int],
    weights_i8: list[int],
    bias_i32: list[int],
    multiplier: int,
    shift: int,
) -> tuple[list[int], dict[str, Any]]:
    in_h = 32
    in_w = 32
    in_c = 3
    out_c = 16
    kernel = 3
    expected = [0 for _ in range(in_h * in_w * out_c)]
    first_trace: dict[str, Any] = {}

    for oh in range(in_h):
        for ow in range(in_w):
            for oc in range(out_c):
                mac = 0
                taps: list[dict[str, int]] = []
                for kh in range(kernel):
                    ih = oh + kh - 1
                    for kw in range(kernel):
                        iw = ow + kw - 1
                        for ic in range(in_c):
                            if 0 <= ih < in_h and 0 <= iw < in_w:
                                input_idx = ((ih * in_w) + iw) * in_c + ic
                                input_i8 = to_s8(input_bytes[input_idx])
                            else:
                                input_idx = -1
                                input_i8 = 0
                            weight_idx = (((ic * kernel) + kh) * kernel + kw) * out_c + oc
                            weight_i8 = weights_i8[weight_idx]
                            product = input_i8 * weight_i8
                            mac += product
                            if oh == 0 and ow == 0 and oc == 0:
                                taps.append({
                                    "kh": kh,
                                    "kw": kw,
                                    "ic": ic,
                                    "input_idx": input_idx,
                                    "input_i8": input_i8,
                                    "weight_idx": weight_idx,
                                    "weight_i8": weight_i8,
                                    "product": product,
                                })
                acc_after_bias = mac + bias_i32[oc]
                relu = max(0, acc_after_bias)
                q = requantize_i8(relu, multiplier, shift)
                out_idx = ((oh * in_w) + ow) * out_c + oc
                expected[out_idx] = to_u8(q)
                if oh == 0 and ow == 0 and oc == 0:
                    first_trace = {
                        "position": {"oh": oh, "ow": ow, "oc": oc},
                        "layout": "dense_hwc",
                        "mac_before_bias": mac,
                        "bias_i32": bias_i32[oc],
                        "acc_after_bias": acc_after_bias,
                        "acc_after_relu": relu,
                        "requant_multiplier": multiplier,
                        "requant_shift": shift,
                        "output_i8": q,
                        "output_byte": to_u8(q),
                        "taps": taps,
                    }
    return expected, first_trace


def q(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def sv_i32(value: int) -> str:
    value = int(value)
    if value < 0:
        return f"-32'sd{abs(value)}"
    return f"32'sd{value}"


def emit_byte_array(lines: list[str], array_name: str, values: list[int]) -> None:
    for idx, value in enumerate(values):
        lines.append(f"    {array_name}[{idx}] = 8'h{value & 0xFF:02x};")


def emit_include(
    path: Path,
    *,
    task: dict[str, Any],
    input_tensor: dict[str, Any],
    output_tensor: dict[str, Any],
    input_bytes: list[int],
    weight_bytes: list[int],
    bias_bytes: list[int],
    expected_bytes: list[int],
    multiplier: int,
    shift: int,
    first_trace: dict[str, Any],
) -> None:
    lines: list[str] = []
    lines.append("// Generated by datasets/scripts/extract_resnet20_r1h_package_fixture.py")
    lines.append("// R1h package-faithful small fixture: input.image -> conv1 only.")
    lines.append(f"localparam integer R1H_INPUT_BYTES = {len(input_bytes)};")
    lines.append(f"localparam integer R1H_WEIGHT_BYTES = {len(weight_bytes)};")
    lines.append(f"localparam integer R1H_BIAS_BYTES = {len(bias_bytes)};")
    lines.append(f"localparam integer R1H_COMPARE_BYTES = {len(expected_bytes)};")
    lines.append(f"localparam [31:0] R1H_INPUT_ADDR = 32'd{int(input_tensor['base_addr'])};")
    lines.append(f"localparam [31:0] R1H_WEIGHT_ADDR = 32'd{WEIGHT_LOAD_ADDR};")
    lines.append(f"localparam [31:0] R1H_BIAS_ADDR = 32'd{BIAS_LOAD_ADDR};")
    lines.append(f"localparam [31:0] R1H_OUTPUT_ADDR = 32'd{int(output_tensor['base_addr'])};")
    lines.append(f"localparam [31:0] R1H_REQUANT_MULT = 32'd{multiplier};")
    lines.append(f"localparam [31:0] R1H_REQUANT_SHIFT = 32'd{shift};")
    lines.append(f"localparam [31:0] R1H_CONV_CFG = 32'd{conv_cfg_for(task)};")
    lines.append(f"localparam [31:0] R1H_EXPECTED_CHECKSUM = 32'h{checksum_bytes(expected_bytes):08x};")
    lines.append(f"localparam [31:0] R1H_INPUT_CHECKSUM = 32'h{checksum_bytes(input_bytes):08x};")
    lines.append(f"localparam signed [31:0] R1H_REF_MAC_BEFORE_BIAS = {sv_i32(first_trace['mac_before_bias'])};")
    lines.append(f"localparam signed [31:0] R1H_REF_BIAS_I32 = {sv_i32(first_trace['bias_i32'])};")
    lines.append(f"localparam signed [31:0] R1H_REF_ACC_AFTER_BIAS = {sv_i32(first_trace['acc_after_bias'])};")
    lines.append(f"localparam signed [31:0] R1H_REF_ACC_AFTER_RELU = {sv_i32(first_trace['acc_after_relu'])};")
    lines.append(f"localparam signed [31:0] R1H_REF_OUTPUT_I8 = {sv_i32(first_trace['output_i8'])};")
    lines.append(f"localparam [7:0] R1H_REF_OUTPUT_BYTE = 8'h{int(first_trace['output_byte']) & 0xFF:02x};")
    lines.append("")
    lines.append("task init_r1h_fixture;")
    lines.append("begin")
    emit_byte_array(lines, "r1h_input_byte", input_bytes)
    emit_byte_array(lines, "r1h_weight_byte", weight_bytes)
    emit_byte_array(lines, "r1h_bias_byte", bias_bytes)
    emit_byte_array(lines, "r1h_expected_byte", expected_bytes)
    for idx, tap in enumerate(first_trace["taps"]):
        lines.append(f"    r1h_ref_input_idx[{idx}] = {int(tap['input_idx'])};")
        lines.append(f"    r1h_ref_weight_idx[{idx}] = {int(tap['weight_idx'])};")
        lines.append(f"    r1h_ref_input_i8[{idx}] = {sv_i32(tap['input_i8'])};")
        lines.append(f"    r1h_ref_weight_i8[{idx}] = {sv_i32(tap['weight_i8'])};")
        lines.append(f"    r1h_ref_product[{idx}] = {sv_i32(tap['product'])};")
    lines.append("end")
    lines.append("endtask")
    lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="ascii")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate R1h package-faithful conv1 compare fixture")
    parser.add_argument("--package-dir", default="datasets/cifar10/resnet20_export_package")
    parser.add_argument("--output", default="tb/generated/resnet20_r1h_package_compare.vh")
    parser.add_argument("--summary", default="tb/generated/resnet20_r1h_package_compare_summary.json")
    parser.add_argument("--trace", default="tb/generated/resnet20_r1h_conv1_reference_trace.json")
    args = parser.parse_args()

    package_dir = Path(args.package_dir)
    task_sequence = load_json(package_dir / "task_sequence.json")
    memory_map = load_json(package_dir / "memory_map.json")
    conv_fc = load_json(package_dir / "requant/conv_fc_requant.json")["items"]

    task = task_sequence["tasks"][0]
    if task["name"] != "conv1" or task["op_type"] != "CONV3x3":
        raise SystemExit(f"unexpected task0: {task.get('name')} {task.get('op_type')}")
    tensors = {item["name"]: item for item in memory_map["tensors"]}
    input_tensor = tensors["input.image"]
    output_tensor = tensors["conv1.relu"]
    if int(input_tensor["base_addr"]) == 0:
        raise SystemExit("input.image base_addr is 0; regenerate memory_map with null-address reservation first")

    requant_item = next(item for item in conv_fc if item["op"] == "conv1")
    multiplier = int(requant_item["requant"]["multiplier_int"])
    shift = int(requant_item["requant"]["shift"])

    input_bytes = seeded_input_bytes(int(input_tensor["byte_size"]))
    weight_path = package_dir / task["weight_file"]
    bias_path = package_dir / task["bias_file"]
    weight_bytes = load_u8_memh(weight_path)
    weights_i8 = load_s8_memh(weight_path)
    bias_u32 = memh_values(bias_path)
    bias_bytes: list[int] = []
    for value in bias_u32:
        for lane in range(4):
            bias_bytes.append((value >> (8 * lane)) & 0xFF)
    bias_i32 = load_s32_memh(bias_path)
    expected_bytes, first_trace = conv1_reference_hwc(
        input_bytes,
        weights_i8,
        bias_i32,
        multiplier,
        shift,
    )
    if len(expected_bytes) != int(output_tensor["byte_size"]):
        raise ValueError("expected output byte count mismatch")

    emit_include(
        Path(args.output),
        task=task,
        input_tensor=input_tensor,
        output_tensor=output_tensor,
        input_bytes=input_bytes,
        weight_bytes=weight_bytes,
        bias_bytes=bias_bytes,
        expected_bytes=expected_bytes,
        multiplier=multiplier,
        shift=shift,
        first_trace=first_trace,
    )

    summary = {
        "scope": "R1h package-faithful input.image_to_conv1 compare fixture",
        "package_dir": str(package_dir),
        "task": task["name"],
        "input_tensor": {
            "name": "input.image",
            "base_addr": int(input_tensor["base_addr"]),
            "byte_size": int(input_tensor["byte_size"]),
            "layout": "dense_hwc_int8",
        },
        "output_tensor": {
            "name": "conv1.relu",
            "base_addr": int(output_tensor["base_addr"]),
            "byte_size": int(output_tensor["byte_size"]),
            "layout": "dense_hwc_int8_reference",
        },
        "weight_load_addr": WEIGHT_LOAD_ADDR,
        "bias_load_addr": BIAS_LOAD_ADDR,
        "weight_bytes": len(weight_bytes),
        "bias_bytes": len(bias_bytes),
        "compare_bytes": len(expected_bytes),
        "expected_checksum": f"0x{checksum_bytes(expected_bytes):08x}",
        "input_checksum": f"0x{checksum_bytes(input_bytes):08x}",
        "requant_multiplier": multiplier,
        "requant_shift": shift,
        "conv_cfg": conv_cfg_for(task),
        "address_contract": "package memory_map reserves address 0; input.image uses nonzero formal address",
        "not_full_resnet20": True,
    }
    Path(args.summary).parent.mkdir(parents=True, exist_ok=True)
    Path(args.summary).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="ascii")
    Path(args.trace).parent.mkdir(parents=True, exist_ok=True)
    Path(args.trace).write_text(json.dumps(first_trace, indent=2, sort_keys=True) + "\n", encoding="ascii")
    print(f"Wrote {args.output}")
    print(f"Wrote {args.summary}")
    print(f"input_addr={input_tensor['base_addr']} output_addr={output_tensor['base_addr']} compare_bytes={len(expected_bytes)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
