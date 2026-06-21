#!/usr/bin/env python3
"""Generate a compact package-derived fixed-point compare fixture for R1g.

The fixture intentionally uses the same compact alias/remap policy as the R1f
`npu_top` smoke.  It does not claim full ResNet-20 execution; it creates a
small value-aware reference for:

    layer1.0.conv1 -> layer1.0.conv2 -> layer1.0.add

All weights, bias, requant, and residual alignment parameters come from the
validated export package.  The compact input tensor is deterministic and
recorded in the generated JSON so RTL and reference use the same data.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

from extract_resnet20_r1f_smoke import (
    RESIDUAL_ALIAS_ADDR,
    RESIDUAL_ALIAS_BYTES,
    RESIDUAL_NPU_TOP_SLICE,
    load_json,
    memh_values,
)


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
    abs_value = abs(value)
    rounded = (abs_value + (1 << (shift - 1))) >> shift
    return sign * rounded


def requantize(value: int, plan: dict[str, Any], *, clamp_int8: bool) -> int:
    if plan.get("status") != "searched":
        raise ValueError(f"invalid requant plan status: {plan}")
    multiplier = int(plan["multiplier_int"])
    shift = int(plan["shift"])
    rounded = round_shift_half_away(value * multiplier, shift)
    if clamp_int8:
        rounded = max(-128, min(127, rounded))
    return rounded


def search_multiplier_shift(real_multiplier: float) -> dict[str, Any]:
    if not math.isfinite(real_multiplier) or real_multiplier <= 0.0:
        raise ValueError(f"invalid multiplier {real_multiplier!r}")
    best: dict[str, Any] | None = None
    for shift in range(32):
        multiplier = int(math.floor(real_multiplier * (1 << shift) + 0.5))
        if multiplier <= 0 or multiplier > 0x7FFFFFFF:
            continue
        approx = multiplier / float(1 << shift)
        rel = abs(approx - real_multiplier) / real_multiplier
        cand = {
            "status": "searched",
            "real_multiplier": real_multiplier,
            "multiplier_int": multiplier,
            "shift": shift,
            "relative_error": rel,
        }
        if best is None or rel < float(best["relative_error"]):
            best = cand
    if best is None:
        raise ValueError(f"no multiplier/shift found for {real_multiplier!r}")
    return best


def ratio_requant(src_scale: float, dst_scale: float) -> dict[str, Any]:
    return search_multiplier_shift(float(src_scale) / float(dst_scale))


def seeded_bytes(name: str, base_addr: int, byte_size: int) -> list[int]:
    seed = (
        (base_addr * 2654435761)
        ^ (byte_size * 2246822519)
        ^ sum(ord(c) for c in name)
    ) & 0xFFFFFFFF
    return [((seed >> ((i % 4) * 8)) + i) & 0xFF for i in range(byte_size)]


def load_s8_memh(path: Path) -> list[int]:
    return [to_s8(v) for v in memh_values(path)]


def load_s32_memh(path: Path) -> list[int]:
    return [to_s32(v) for v in memh_values(path)]


def store_i8_as_words(values: list[int], total_bytes: int) -> list[int]:
    out = [0 for _ in range(total_bytes)]
    for idx, value in enumerate(values):
        base = idx * 4
        if base >= total_bytes:
            break
        out[base] = to_u8(value)
    return out


def dense_i8_bytes(data: list[int], count: int) -> list[int]:
    if len(data) < count:
        raise ValueError(f"dense byte stream needs {count} bytes, got {len(data)}")
    return [to_s8(v) for v in data[:count]]


def rtl_frontend_window_3x3(
    input_mem: list[int],
    *,
    oh: int,
    ow: int,
) -> list[int]:
    """Model the current R1b conv_frontend-visible dense HWC window.

    R1g uses a compact 3x3x1 tensor. The RTL frontend consumes dense bytes
    from memory, not lane0 bytes from 32-bit words. This helper intentionally
    follows the current frontend's compact 3-row preload behavior so the
    compare tests the same stream the RTL datapath actually sees.
    """

    del oh  # Current compact frontend skeleton does not vertically slide here.
    dense = dense_i8_bytes(input_mem, 9)
    rows = [dense[0:3], dense[3:6], dense[6:9]]
    lb = [[0, 0, 0] for _ in range(5)]
    for row_idx, row in enumerate(rows):
        lb[2 + row_idx] = row[:]

    window: list[int] = []
    for kh in range(3):
        for kw in range(3):
            src_col = ow + kw - 1
            if 0 <= src_col < 3:
                window.append(lb[kh][src_col])
            else:
                window.append(0)
    return window


def conv3x3_rtl_frontend_i8(
    input_mem: list[int],
    *,
    weights_i8: list[int],
    bias_i32: int,
    requant: dict[str, Any],
    relu_before_requant: bool,
) -> list[int]:
    if len(input_mem) < 9:
        raise ValueError("compact Conv reference expects at least 9 dense input bytes")
    if len(weights_i8) < 9:
        raise ValueError("compact Conv reference expects at least 9 weights")
    output: list[int] = []
    for oh in range(3):
        for ow in range(3):
            mac = 0
            window = rtl_frontend_window_3x3(input_mem, oh=oh, ow=ow)
            for idx, value in enumerate(window):
                mac += value * weights_i8[idx]
            acc = mac + int(bias_i32)
            if relu_before_requant and acc < 0:
                acc = 0
            output.append(requantize(acc, requant, clamp_int8=True))
    return output


def conv3x3_first_output_trace(
    input_mem: list[int],
    *,
    weights_i8: list[int],
    bias_i32: int,
    requant: dict[str, Any],
    relu_before_requant: bool,
) -> dict[str, Any]:
    mac_before_bias = 0
    taps: list[dict[str, int]] = []
    oh = 0
    ow = 0
    window = rtl_frontend_window_3x3(input_mem, oh=oh, ow=ow)
    for kh in range(3):
        for kw in range(3):
            weight_idx = kh * 3 + kw
            input_i8 = window[weight_idx]
            product = input_i8 * weights_i8[weight_idx]
            mac_before_bias += product
            taps.append(
                {
                    "kh": kh,
                    "kw": kw,
                    "window_idx": weight_idx,
                    "weight_idx": weight_idx,
                    "input_i8": input_i8,
                    "weight_i8": weights_i8[weight_idx],
                    "product": product,
                }
            )
    acc_before_relu = mac_before_bias + int(bias_i32)
    acc_after_relu = max(0, acc_before_relu) if relu_before_requant else acc_before_relu
    product_before_shift = acc_after_relu * int(requant["multiplier_int"])
    output_i8 = requantize(acc_after_relu, requant, clamp_int8=True)
    return {
        "output_position": {"oh": oh, "ow": ow},
        "bias_i32": bias_i32,
        "taps": taps,
        "mac_before_bias": mac_before_bias,
        "acc_before_relu": acc_before_relu,
        "acc_after_bias": acc_before_relu,
        "acc_after_relu": acc_after_relu,
        "requant": requant,
        "product_before_shift": product_before_shift,
        "reference_output_i8": output_i8,
        "reference_output_byte": to_u8(output_i8),
    }


def clamp_i8(value: int) -> int:
    return max(-128, min(127, value))


def residual_add_bytes(
    main_mem: list[int],
    shortcut_mem: list[int],
    plan: dict[str, Any],
    *,
    post_requant_en: bool,
) -> list[int]:
    post_requant = ratio_requant(float(plan["target_add_scale"]), float(plan["post_relu_scale"]))
    output: list[int] = []
    count = min(len(main_mem), len(shortcut_mem))
    for idx in range(count):
        main = requantize(to_s8(main_mem[idx]), plan["main_to_target"], clamp_int8=True)
        shortcut = requantize(to_s8(shortcut_mem[idx]), plan["shortcut_to_target"], clamp_int8=True)
        add_relu = max(0, main + shortcut)
        if post_requant_en:
            output.append(requantize(add_relu, post_requant, clamp_int8=True))
        else:
            output.append(clamp_i8(add_relu))
    return output


def checksum_bytes(values: list[int]) -> int:
    acc = 0
    for idx, value in enumerate(values, start=1):
        acc = (acc + ((value & 0xFF) * idx)) & 0xFFFFFFFF
    return acc


def q(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def s32_literal(value: int) -> str:
    if value < 0:
        return f"-32'sd{abs(value)}"
    return f"32'sd{value}"


def u8_bytes_from_s32(value: int) -> list[int]:
    value &= 0xFFFFFFFF
    return [(value >> (8 * i)) & 0xFF for i in range(4)]


def emit_verilog_include(
    path: Path,
    expected_by_task: list[dict[str, Any]],
    conv1_trace: dict[str, Any],
) -> None:
    max_bytes = max(len(item["expected_bytes"]) for item in expected_by_task)
    lines: list[str] = []
    lines.append("// Generated by datasets/scripts/extract_resnet20_r1g_compare_fixture.py")
    lines.append("// R1g compact value-aware compare fixture, not full ResNet-20 closure.")
    lines.append(f"localparam integer R1G_COMPARE_TASK_COUNT = {len(expected_by_task)};")
    lines.append(f"localparam integer R1G_MAX_COMPARE_BYTES = {max_bytes};")
    lines.append(f"localparam signed [31:0] R1G_CONV1_REF_MAC_BEFORE_BIAS = {s32_literal(int(conv1_trace['mac_before_bias']))};")
    lines.append(f"localparam signed [31:0] R1G_CONV1_REF_BIAS = {s32_literal(int(conv1_trace['bias_i32']))};")
    lines.append(f"localparam signed [31:0] R1G_CONV1_REF_ACC_AFTER_BIAS = {s32_literal(int(conv1_trace['acc_after_bias']))};")
    lines.append(f"localparam signed [7:0] R1G_CONV1_REF_OUTPUT_I8 = 8'sd{int(conv1_trace['reference_output_i8'])};")
    lines.append("")
    lines.append("task init_r1g_compare_expected;")
    lines.append("integer i;")
    lines.append("begin")
    lines.append("    for (i = 0; i < 8; i = i + 1) begin")
    lines.append("        r1g_compare_bytes[i] = 0;")
    lines.append("        r1g_expected_checksum[i] = 32'd0;")
    lines.append("        r1g_reference_name[i] = \"\";")
    lines.append("        r1g_weight_payload_bytes[i] = 0;")
    lines.append("        r1g_bias_payload_bytes[i] = 0;")
    lines.append("    end")
    lines.append("    for (i = 0; i < 256; i = i + 1) begin")
    lines.append("        r1g_expected_byte[0][i] = 8'd0;")
    lines.append("        r1g_expected_byte[1][i] = 8'd0;")
    lines.append("        r1g_expected_byte[2][i] = 8'd0;")
    lines.append("        r1g_weight_payload_byte[0][i] = 8'd0;")
    lines.append("        r1g_weight_payload_byte[1][i] = 8'd0;")
    lines.append("        r1g_weight_payload_byte[2][i] = 8'd0;")
    lines.append("        r1g_bias_payload_byte[0][i] = 8'd0;")
    lines.append("        r1g_bias_payload_byte[1][i] = 8'd0;")
    lines.append("        r1g_bias_payload_byte[2][i] = 8'd0;")
    lines.append("    end")
    for task_idx, item in enumerate(expected_by_task):
        lines.append(f"    r1g_reference_name[{task_idx}] = {q(item['name'])};")
        lines.append(f"    r1g_compare_bytes[{task_idx}] = {len(item['expected_bytes'])};")
        lines.append(f"    r1g_expected_checksum[{task_idx}] = 32'h{item['checksum']:08x};")
        for byte_idx, value in enumerate(item["expected_bytes"]):
            lines.append(f"    r1g_expected_byte[{task_idx}][{byte_idx}] = 8'h{value:02x};")
        lines.append(f"    r1g_weight_payload_bytes[{task_idx}] = {len(item['weight_payload_bytes'])};")
        for byte_idx, value in enumerate(item["weight_payload_bytes"]):
            lines.append(f"    r1g_weight_payload_byte[{task_idx}][{byte_idx}] = 8'h{value:02x};")
        lines.append(f"    r1g_bias_payload_bytes[{task_idx}] = {len(item['bias_payload_bytes'])};")
        for byte_idx, value in enumerate(item["bias_payload_bytes"]):
            lines.append(f"    r1g_bias_payload_byte[{task_idx}][{byte_idx}] = 8'h{value:02x};")
    lines.append("end")
    lines.append("endtask")
    lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package-dir", default="datasets/cifar10/resnet20_export_package")
    ap.add_argument("--r1f-summary", default="tb/generated/resnet20_r1f_npu_top_residual_summary.json")
    ap.add_argument("--output", default="tb/generated/resnet20_r1g_compare_expected.vh")
    ap.add_argument("--summary", default="tb/generated/resnet20_r1g_compare_summary.json")
    ap.add_argument("--debug-summary", default="tb/generated/resnet20_r1g_compare_debug_summary.json")
    args = ap.parse_args()

    package_dir = Path(args.package_dir)
    r1f_summary = load_json(Path(args.r1f_summary))
    conv_fc_items = load_json(package_dir / "requant/conv_fc_requant.json")["items"]
    add_items = load_json(package_dir / "requant/residual_add_alignment.json")["items"]
    conv_fc = {item["op"]: item for item in conv_fc_items}
    add_plans = {item["op"]: item for item in add_items}

    tensors = {item["name"]: item for item in r1f_summary["tensors"]}
    input_name = "conv1.relu"
    input_bytes = seeded_bytes(
        input_name,
        int(tensors[input_name]["base_addr"]),
        int(tensors[input_name]["byte_size"]),
    )
    input_i8 = dense_i8_bytes(input_bytes, 9)

    expected_by_task: list[dict[str, Any]] = []
    intermediate: dict[str, list[int]] = {input_name: input_bytes}
    debug_traces: dict[str, Any] = {
        "input_seed": {
            "tensor": input_name,
            "bytes": input_bytes,
            "dense_hwc_i8_values_first9": input_i8,
            "packing": (
                "compact TB Conv inputs are dense HWC bytes; current Conv store "
                "emits INT8 outputs as byte lane 0 of 32-bit words"
            ),
        }
    }

    for task in r1f_summary["tasks"]:
        name = task["name"]
        weights: list[int] = []
        weight_payload_bytes: list[int] = []
        bias_payload_bytes: list[int] = []
        if task["op_type"] == "CONV3x3":
            weights_raw = memh_values(package_dir / task["weight_file"])
            weights = [to_s8(v) for v in weights_raw]
            bias = load_s32_memh(package_dir / task["bias_file"])[0]
            weight_payload_bytes = [to_u8(v) for v in weights[: int(task["weight_bytes"])]]
            bias_payload_bytes = u8_bytes_from_s32(bias)[: int(task["bias_bytes"])]
            in_tensor = task["input_tensors"][0]
            if name == "layer1.0.conv1":
                debug_traces["conv1_first_output"] = conv3x3_first_output_trace(
                    intermediate[in_tensor],
                    weights_i8=weights,
                    bias_i32=bias,
                    requant=conv_fc[name]["requant"],
                    relu_before_requant=task["output_tensor"].endswith(".relu"),
                )
            out_i8 = conv3x3_rtl_frontend_i8(
                intermediate[in_tensor],
                weights_i8=weights,
                bias_i32=bias,
                requant=conv_fc[name]["requant"],
                relu_before_requant=task["output_tensor"].endswith(".relu"),
            )
        elif task["op_type"] == "RESIDUAL_ADD":
            main_tensor, shortcut_tensor = task["input_tensors"]
            add_values = residual_add_bytes(
                intermediate[main_tensor],
                intermediate[shortcut_tensor],
                add_plans[name],
                post_requant_en=bool(int(task.get("add_cfg", 0)) & 0x8),
            )
            out_bytes = [to_u8(v) for v in add_values[: int(task["output_bytes"])]]
            out_i8 = [to_s8(v) for v in out_bytes]
        else:
            raise ValueError(f"unsupported R1g op {task['op_type']}")

        if task["op_type"] == "CONV3x3":
            out_bytes = store_i8_as_words(out_i8, int(task["output_bytes"]))
        intermediate[task["output_tensor"]] = out_bytes
        expected_by_task.append(
            {
                "name": name,
                "output_tensor": task["output_tensor"],
                "expected_values_i8": out_i8,
                "expected_bytes": out_bytes,
                "checksum": checksum_bytes(out_bytes),
                "weight_payload_bytes": weight_payload_bytes,
                "bias_payload_bytes": bias_payload_bytes,
            }
        )

    emit_verilog_include(Path(args.output), expected_by_task, debug_traces["conv1_first_output"])

    summary = {
        "status": "generated",
        "scope": "R1g compact fixed-point compare fixture, not full ResNet-20 closure",
        "package_dir": str(package_dir),
        "source_r1f_summary": args.r1f_summary,
        "slice": RESIDUAL_NPU_TOP_SLICE,
        "uses_compact_alias": True,
        "compact_alias_addresses": RESIDUAL_ALIAS_ADDR,
        "compact_alias_bytes": RESIDUAL_ALIAS_BYTES,
        "reference_source": "export_package_weights_bias_requant_and_residual_alignment",
        "rounding": "software_reference_round_half_away_from_zero_not_rtl_locked",
        "input_image_base_addr_zero_handling": (
            "task0 skipped; conv1.relu is used as compact seed tensor with nonzero TB-only alias"
        ),
        "compact_layout_contract": {
            "conv_input": "dense HWC INT8 byte stream at task input address",
            "conv_output": "current RTL physical store: one INT8 output in byte lane 0 of each 32-bit word",
            "add_input": "physical byte stream exactly as stored in memory",
            "add_output": "dense INT8 byte stream packed four values per 32-bit word by ADD datapath",
        },
        "debug_traces": debug_traces,
        "known_compare_boundary": (
            "Reference and RTL now share the same compact physical memory layout. "
            "This is still a compact alias/remap fixture, not full-shape ResNet execution."
        ),
        "expected": expected_by_task,
    }
    Path(args.summary).parent.mkdir(parents=True, exist_ok=True)
    Path(args.summary).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    debug_summary = {
        "status": "reference_trace_generated",
        "scope": summary["scope"],
        "slice": summary["slice"],
        "uses_compact_alias": True,
        "compact_layout_contract": summary["compact_layout_contract"],
        "reference_source": summary["reference_source"],
        "conv1_first_output_reference_trace": debug_traces["conv1_first_output"],
        "current_debug_boundary": (
            "Reference uses dense HWC Conv input bytes and current RTL physical Conv output bytes. "
            "RTL conv1 byte0 first-divergence details are emitted by "
            "tb/generated/resnet20_r1g_conv1_trace.json after simulation."
        ),
        "expected_stage_checksums": [
            {
                "name": item["name"],
                "output_tensor": item["output_tensor"],
                "checksum": f"0x{item['checksum']:08x}",
                "expected_byte0": f"0x{item['expected_bytes'][0]:02x}" if item["expected_bytes"] else None,
            }
            for item in expected_by_task
        ],
        "note": (
            "RTL stage-wise mismatch/unknown counts are produced by "
            "tb/generated/resnet20_r1g_compare_rtl_result.json after simulation."
        ),
    }
    Path(args.debug_summary).parent.mkdir(parents=True, exist_ok=True)
    Path(args.debug_summary).write_text(
        json.dumps(debug_summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
