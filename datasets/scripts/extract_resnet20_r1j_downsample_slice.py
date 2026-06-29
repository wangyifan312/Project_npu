#!/usr/bin/env python3
"""Generate a package-faithful layer2.0 downsample block fixture for R1j."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from extract_resnet20_r1f_smoke import conv_cfg_for, memh_values
from search_resnet20_requant_plan import search_multiplier_shift


# Tasks 10-13 inclusive (the layer2.0 downsample block)
R1J_SLICE_NAMES = [
    "layer2.0.conv1",
    "layer2.0.conv2",
    "layer2.0.shortcut.projection",
    "layer2.0.add",
]

# Pre-compute tasks (0-9) needed to produce layer1.2.add.relu
PRE_TASK_NAMES = [
    "conv1",
    "layer1.0.conv1", "layer1.0.conv2", "layer1.0.add",
    "layer1.1.conv1", "layer1.1.conv2", "layer1.1.add",
    "layer1.2.conv1", "layer1.2.conv2", "layer1.2.add",
]

WEIGHT_LOAD_ADDR = 0x0008_0000
BIAS_LOAD_ADDR = 0x0008_1000
SEED_BYTE_SIZE = 3072


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="ascii"))


def to_s8(value: int) -> int:
    value &= 0xFF
    return value - 256 if value >= 128 else value


def to_s32(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value >= (1 << 31) else value


def round_shift_half_away(data: torch.Tensor, shift: int) -> torch.Tensor:
    data = data.to(torch.int64)
    if shift == 0:
        return data
    rounded = (torch.abs(data) + (1 << (shift - 1))) >> shift
    return torch.where(data < 0, -rounded, rounded)


def requant(data: torch.Tensor, plan: dict[str, Any], *, clamp: bool = True) -> torch.Tensor:
    value = round_shift_half_away(data * int(plan["multiplier_int"]), int(plan["shift"]))
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


def conv_reference(
    input_hwc: list[int],
    input_h: int,
    input_w: int,
    input_c: int,
    output_c: int,
    weight_values: list[int],
    bias_values: list[int],
    kernel: int,
    stride: int,
    padding: int,
    rq: dict[str, Any],
    relu: bool,
) -> list[int]:
    x = torch.tensor([to_s8(v) for v in input_hwc], dtype=torch.float32)
    x = x.view(1, input_h, input_w, input_c).permute(0, 3, 1, 2).contiguous()

    weight = torch.tensor([to_s8(v) for v in weight_values], dtype=torch.float32)
    weight = weight.view(input_c, kernel, kernel, output_c).permute(3, 0, 1, 2).contiguous()

    bias = torch.tensor(bias_values, dtype=torch.float32)
    acc = torch.round(F.conv2d(x, weight, bias=bias, stride=stride, padding=padding)).to(torch.int64)
    if relu:
        acc = torch.clamp(acc, min=0)
    return tensor_to_hwc_bytes(requant(acc, rq, clamp=True))


def find_item(document: dict[str, Any], name: str) -> dict[str, Any]:
    for item in document["items"]:
        if item["op"] == name:
            return item
    raise KeyError(name)


def get_task_by_name(tasks_doc: dict[str, Any], name: str) -> dict[str, Any]:
    for task in tasks_doc["tasks"]:
        if task["name"] == name:
            return task
    raise KeyError(name)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-dir", default="datasets/cifar10/resnet20_export_package")
    parser.add_argument("--output-dir", default="tb/generated/resnet20_r1j_package_slice")
    parser.add_argument("--summary", default="tb/generated/resnet20_r1j_package_slice_compare_summary.json")
    parser.add_argument("--sv-include", default="tb/generated/resnet20_r1j_package_slice.vh")
    parser.add_argument("--task-include", default="tb/generated/resnet20_r1j_package_tasks.vh")
    parser.add_argument("--expected-include", default="tb/generated/resnet20_r1j_package_expected.vh")
    args = parser.parse_args()

    package = Path(args.package_dir)
    output = Path(args.output_dir)
    tasks_doc = read_json(package / "task_sequence.json")
    memory_doc = read_json(package / "memory_map.json")
    conv_rq_doc = read_json(package / "requant/conv_fc_requant.json")
    add_doc = read_json(package / "requant/residual_add_alignment.json")
    tensors = {item["name"]: item for item in memory_doc["tensors"]}

    # ============================================================
    # Phase 1: Run software reference for tasks 0-9 to get layer1.2.add.relu
    # ============================================================
    input_values = seeded_input(SEED_BYTE_SIZE)
    write_memh(output / "input_image.memh", input_values, 8)
    current = input_values

    pre_stages = []
    for task_name in PRE_TASK_NAMES:
        task = get_task_by_name(tasks_doc, task_name)
        op_type = task["op_type"]
        input_c = int(task["input_shape"][0])
        output_c = int(task["output_shape"][0])
        relu = task["output_tensor"].endswith(".relu")

        if op_type in ("CONV3x3", "CONV1x1_PROJECTION"):
            weight_values = [value & 0xFF for value in memh_values(package / task["weight_file"])]
            bias_values = [to_s32(value) for value in memh_values(package / task["bias_file"])]
            rq_item = find_item(conv_rq_doc, task_name)
            rq = rq_item["requant"]

            kernel = int(task["kernel"][0])
            stride = int(task.get("stride") or 1)
            padding = kernel // 2 if (conv_cfg_for(task) >> 3) & 1 else 0

            # Determine input spatial dims from shape
            in_h = int(task["input_shape"][1])
            in_w = int(task["input_shape"][2])

            current = conv_reference(
                current, in_h, in_w, input_c, output_c,
                weight_values, bias_values,
                kernel, stride, padding,
                rq, relu,
            )
        elif op_type == "RESIDUAL_ADD":
            add_plan = find_item(add_doc, task_name)
            # Get the shortcut tensor from memory (the previous block's add.relu)
            shortcut_tensor_name = task["input_tensors"][1]
            if task_name == "layer1.0.add":
                shortcut = [int(line.strip(), 16) for line in
                           (output / "conv1_expected.memh").read_text(encoding="ascii").splitlines()]
            elif task_name == "layer1.1.add":
                shortcut = [int(line.strip(), 16) for line in
                           (output / "layer1_0_add_expected.memh").read_text(encoding="ascii").splitlines()]
            elif task_name == "layer1.2.add":
                shortcut = [int(line.strip(), 16) for line in
                           (output / "layer1_1_add_expected.memh").read_text(encoding="ascii").splitlines()]
            else:
                raise KeyError(f"unknown add shortcut source for {task_name}")

            main_tensor = torch.tensor([to_s8(v) for v in current], dtype=torch.int64)
            short_tensor = torch.tensor([to_s8(v) for v in shortcut], dtype=torch.int64)

            main_aligned = requant(main_tensor, add_plan["main_to_target"], clamp=True)
            shortcut_aligned = requant(short_tensor, add_plan["shortcut_to_target"], clamp=True)

            add_relu = torch.clamp(main_aligned + shortcut_aligned, min=0)

            post_plan = search_multiplier_shift(
                float(add_plan["target_add_scale"]) / float(add_plan["post_relu_scale"])
            )
            current = [int(value) & 0xFF for value in requant(add_relu, post_plan, clamp=True).tolist()]

            stem = task_name.replace(".", "_")
            write_memh(output / f"{stem}_expected.memh", current, 8)
        else:
            raise ValueError(f"unsupported op_type: {op_type}")

        stem = task_name.replace(".", "_")
        if op_type in ("CONV3x3", "CONV1x1_PROJECTION"):
            write_memh(output / f"{stem}_expected.memh", current, 8)

    # layer1.2.add.relu is now in `current`
    layer1_2_add_relu_values = current
    write_memh(output / "input_layer1_2_add_relu.memh", layer1_2_add_relu_values, 8)

    # ============================================================
    # Phase 2: Run tasks 10-13 (layer2.0 downsample block)
    # ============================================================
    r1j_tasks = [get_task_by_name(tasks_doc, name) for name in R1J_SLICE_NAMES]
    current = layer1_2_add_relu_values  # start from layer1.2.add.relu
    stages: list[dict[str, Any]] = []

    # Task 10: layer2.0.conv1 (3x3 same stride2, 16→32, 32×32→16×16)
    task = r1j_tasks[0]
    name = task["name"]
    weight_values = [value & 0xFF for value in memh_values(package / task["weight_file"])]
    bias_values = [to_s32(value) for value in memh_values(package / task["bias_file"])]
    rq_item = find_item(conv_rq_doc, name)
    input_c = int(task["input_shape"][0])
    output_c = int(task["output_shape"][0])
    in_h = int(task["input_shape"][1])
    in_w = int(task["input_shape"][2])
    relu = task["output_tensor"].endswith(".relu")
    kernel = int(task["kernel"][0])
    stride = int(task.get("stride") or 1)
    padding = kernel // 2  # same padding

    current = conv_reference(
        current, in_h, in_w, input_c, output_c,
        weight_values, bias_values,
        kernel, stride, padding,
        rq_item["requant"], relu,
    )
    stem = name.replace(".", "_")
    write_memh(output / f"{stem}_weights.memh", weight_values, 8)
    write_memh(output / f"{stem}_bias.memh", bias_values, 32)
    bias_bytes_flat = [((value & 0xFFFFFFFF) >> (8 * lane)) & 0xFF
                       for value in bias_values for lane in range(4)]
    write_memh(output / f"{stem}_bias_bytes.memh", bias_bytes_flat, 8)
    write_memh(output / f"{stem}_expected.memh", current, 8)
    output_tensor = tensors[task["output_tensor"]]
    stages.append({
        "stage_index": 0,
        "task_id": task["task_id"],
        "name": name,
        "task_type": 0,
        "input_addr": task["memory"]["inputs"][task["input_tensors"][0]],
        "output_addr": task["memory"]["output"],
        "input_bytes": tensors[task["input_tensors"][0]]["byte_size"],
        "output_bytes": output_tensor["byte_size"],
        "input_c": input_c,
        "output_c": output_c,
        "input_h": in_h,
        "input_w": in_w,
        "conv_cfg": conv_cfg_for(task),
        "relu": relu,
        "multiplier_int": rq_item["requant"]["multiplier_int"],
        "shift": rq_item["requant"]["shift"],
        "weight_file": str(output / f"{stem}_weights.memh"),
        "weight_bytes": len(weight_values),
        "bias_file": str(output / f"{stem}_bias.memh"),
        "bias_byte_file": str(output / f"{stem}_bias_bytes.memh"),
        "bias_bytes": len(bias_values) * 4,
        "expected_file": str(output / f"{stem}_expected.memh"),
        "expected_checksum": f"0x{checksum(current):08x}",
    })
    conv1_output = current

    # Task 11: layer2.0.conv2 (3x3 same stride1, 32→32, 16×16→16×16)
    task = r1j_tasks[1]
    name = task["name"]
    weight_values = [value & 0xFF for value in memh_values(package / task["weight_file"])]
    bias_values = [to_s32(value) for value in memh_values(package / task["bias_file"])]
    rq_item = find_item(conv_rq_doc, name)
    input_c = int(task["input_shape"][0])
    output_c = int(task["output_shape"][0])
    in_h = int(task["input_shape"][1])
    in_w = int(task["input_shape"][2])
    relu = task["output_tensor"].endswith(".relu")
    kernel = int(task["kernel"][0])
    stride = int(task.get("stride") or 1)
    padding = kernel // 2  # same padding

    current = conv_reference(
        current, in_h, in_w, input_c, output_c,
        weight_values, bias_values,
        kernel, stride, padding,
        rq_item["requant"], relu,
    )
    stem = name.replace(".", "_")
    write_memh(output / f"{stem}_weights.memh", weight_values, 8)
    write_memh(output / f"{stem}_bias.memh", bias_values, 32)
    bias_bytes_flat = [((value & 0xFFFFFFFF) >> (8 * lane)) & 0xFF
                       for value in bias_values for lane in range(4)]
    write_memh(output / f"{stem}_bias_bytes.memh", bias_bytes_flat, 8)
    write_memh(output / f"{stem}_expected.memh", current, 8)
    output_tensor = tensors[task["output_tensor"]]
    stages.append({
        "stage_index": 1,
        "task_id": task["task_id"],
        "name": name,
        "task_type": 0,
        "input_addr": task["memory"]["inputs"][task["input_tensors"][0]],
        "output_addr": task["memory"]["output"],
        "input_bytes": tensors[task["input_tensors"][0]]["byte_size"],
        "output_bytes": output_tensor["byte_size"],
        "input_c": input_c,
        "output_c": output_c,
        "input_h": in_h,
        "input_w": in_w,
        "conv_cfg": conv_cfg_for(task),
        "relu": relu,
        "multiplier_int": rq_item["requant"]["multiplier_int"],
        "shift": rq_item["requant"]["shift"],
        "weight_file": str(output / f"{stem}_weights.memh"),
        "weight_bytes": len(weight_values),
        "bias_file": str(output / f"{stem}_bias.memh"),
        "bias_byte_file": str(output / f"{stem}_bias_bytes.memh"),
        "bias_bytes": len(bias_values) * 4,
        "expected_file": str(output / f"{stem}_expected.memh"),
        "expected_checksum": f"0x{checksum(current):08x}",
    })
    conv2_output = current

    # Task 12: layer2.0.shortcut.projection (1x1 valid stride2, 16→32, 32×32→16×16)
    # Note: input is layer1.2.add.relu (same as task 10), not the output of task 11
    task = r1j_tasks[2]
    name = task["name"]
    weight_values = [value & 0xFF for value in memh_values(package / task["weight_file"])]
    bias_values = [to_s32(value) for value in memh_values(package / task["bias_file"])]
    rq_item = find_item(conv_rq_doc, name)
    input_c = int(task["input_shape"][0])
    output_c = int(task["output_shape"][0])
    in_h = int(task["input_shape"][1])
    in_w = int(task["input_shape"][2])
    relu = task["output_tensor"].endswith(".relu")  # False for pre_add
    kernel = int(task["kernel"][0])
    stride = int(task.get("stride") or 1)
    padding = 0  # valid padding for 1x1

    proj_input = layer1_2_add_relu_values  # same input as task 10
    proj_output = conv_reference(
        proj_input, in_h, in_w, input_c, output_c,
        weight_values, bias_values,
        kernel, stride, padding,
        rq_item["requant"], relu,
    )
    stem = name.replace(".", "_")
    write_memh(output / f"{stem}_weights.memh", weight_values, 8)
    write_memh(output / f"{stem}_bias.memh", bias_values, 32)
    bias_bytes_flat = [((value & 0xFFFFFFFF) >> (8 * lane)) & 0xFF
                       for value in bias_values for lane in range(4)]
    write_memh(output / f"{stem}_bias_bytes.memh", bias_bytes_flat, 8)
    write_memh(output / f"{stem}_expected.memh", proj_output, 8)
    output_tensor = tensors[task["output_tensor"]]
    stages.append({
        "stage_index": 2,
        "task_id": task["task_id"],
        "name": name,
        "task_type": 0,
        "input_addr": task["memory"]["inputs"][task["input_tensors"][0]],
        "output_addr": task["memory"]["output"],
        "input_bytes": tensors[task["input_tensors"][0]]["byte_size"],
        "output_bytes": output_tensor["byte_size"],
        "input_c": input_c,
        "output_c": output_c,
        "input_h": in_h,
        "input_w": in_w,
        "conv_cfg": conv_cfg_for(task),
        "relu": relu,
        "multiplier_int": rq_item["requant"]["multiplier_int"],
        "shift": rq_item["requant"]["shift"],
        "weight_file": str(output / f"{stem}_weights.memh"),
        "weight_bytes": len(weight_values),
        "bias_file": str(output / f"{stem}_bias.memh"),
        "bias_byte_file": str(output / f"{stem}_bias_bytes.memh"),
        "bias_bytes": len(bias_values) * 4,
        "expected_file": str(output / f"{stem}_expected.memh"),
        "expected_checksum": f"0x{checksum(proj_output):08x}",
    })

    # Task 13: layer2.0.add
    task = r1j_tasks[3]
    add_plan = find_item(add_doc, task["name"])
    # main = conv2_output (layer2.0.conv2.pre_add_main)
    # shortcut = proj_output (layer2.0.shortcut.pre_add)
    main_tensor = torch.tensor([to_s8(v) for v in conv2_output], dtype=torch.int64)
    short_tensor = torch.tensor([to_s8(v) for v in proj_output], dtype=torch.int64)

    main_aligned = requant(main_tensor, add_plan["main_to_target"], clamp=True)
    shortcut_aligned = requant(short_tensor, add_plan["shortcut_to_target"], clamp=True)

    add_relu = torch.clamp(main_aligned + shortcut_aligned, min=0)

    # post_relu_scale == target_add_scale, so ratio = 1.0
    post_plan = search_multiplier_shift(
        float(add_plan["target_add_scale"]) / float(add_plan["post_relu_scale"])
    )
    add_output = [int(value) & 0xFF for value in requant(add_relu, post_plan, clamp=True).tolist()]
    stem = "layer2_0_add"
    write_memh(output / f"{stem}_expected.memh", add_output, 8)
    output_tensor = tensors[task["output_tensor"]]

    # src0 is main (conv2.pre_add_main), src1 is shortcut (shortcut.pre_add)
    src0_addr = task["memory"]["inputs"]["layer2.0.conv2.pre_add_main"]
    src1_addr = task["memory"]["inputs"]["layer2.0.shortcut.pre_add"]

    stages.append({
        "stage_index": 3,
        "task_id": task["task_id"],
        "name": task["name"],
        "task_type": 4,
        "input_addr": src0_addr,
        "src1_addr": src1_addr,
        "output_addr": task["memory"]["output"],
        "input_bytes": tensors["layer2.0.conv2.pre_add_main"]["byte_size"],
        "src1_bytes": tensors["layer2.0.shortcut.pre_add"]["byte_size"],
        "output_bytes": output_tensor["byte_size"],
        "input_c": int(task["input_shape"][0]),
        "output_c": int(task["output_shape"][0]),
        "add_cfg": 0xC,  # ReLU + post-requant, INT32+INT32
        "src0_multiplier": add_plan["main_to_target"]["multiplier_int"],
        "src0_shift": add_plan["main_to_target"]["shift"],
        "src1_multiplier": add_plan["shortcut_to_target"]["multiplier_int"],
        "src1_shift": add_plan["shortcut_to_target"]["shift"],
        "out_multiplier": post_plan["multiplier_int"],
        "out_shift": post_plan["shift"],
        "expected_file": str(output / f"{stem}_expected.memh"),
        "expected_checksum": f"0x{checksum(add_output):08x}",
    })

    # ============================================================
    # Write summary JSON
    # ============================================================
    summary = {
        "arch": "cifar10_resnet20_v1",
        "scope": R1J_SLICE_NAMES,
        "package_faithful": True,
        "task_sequence": str(package / "task_sequence.json"),
        "memory_map": str(package / "memory_map.json"),
        "input_file": str(output / "input_image.memh"),
        "layer1_2_add_relu_file": str(output / "input_layer1_2_add_relu.memh"),
        "layer1_2_add_relu_addr": tensors["layer1.2.add.relu"]["base_addr"],
        "weight_load_addr": WEIGHT_LOAD_ADDR,
        "bias_load_addr": BIAS_LOAD_ADDR,
        "stages": stages,
        "full_resnet20": False,
    }
    Path(args.summary).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="ascii")

    # ============================================================
    # Write SV include file
    # ============================================================
    lines = ["// Generated by extract_resnet20_r1j_downsample_slice.py"]
    lines += [
        f"localparam [31:0] R1J_INPUT_ADDR = 32'd{summary['layer1_2_add_relu_addr']};",
        f"localparam [31:0] R1J_WEIGHT_ADDR = 32'd{WEIGHT_LOAD_ADDR};",
        f"localparam [31:0] R1J_BIAS_ADDR = 32'd{BIAS_LOAD_ADDR};",
    ]
    for item in stages:
        prefix = f"R1J_S{item['stage_index']}"
        for key in ["input_addr", "output_addr", "input_bytes", "output_bytes", "input_c", "output_c"]:
            lines.append(f"localparam [31:0] {prefix}_{key.upper()} = 32'd{item[key]};")
        if "input_h" in item:
            lines.append(f"localparam [31:0] {prefix}_INPUT_H = 32'd{item['input_h']};")
            lines.append(f"localparam [31:0] {prefix}_INPUT_W = 32'd{item['input_w']};")
        lines.append(f"localparam [31:0] {prefix}_EXPECTED_CHECKSUM = 32'h{item['expected_checksum'][2:]};")
        if item["task_type"] == 0:
            for key in ["weight_bytes", "bias_bytes", "conv_cfg", "multiplier_int", "shift"]:
                lines.append(f"localparam [31:0] {prefix}_{key.upper()} = 32'd{item[key]};")
            lines.append(f"localparam [31:0] {prefix}_RELU = 32'd{1 if item['relu'] else 0};")
        else:
            for key in ["src1_addr", "src1_bytes", "add_cfg",
                         "src0_multiplier", "src0_shift",
                         "src1_multiplier", "src1_shift",
                         "out_multiplier", "out_shift"]:
                lines.append(f"localparam [31:0] {prefix}_{key.upper()} = 32'd{item[key]};")
    Path(args.sv_include).write_text("\n".join(lines) + "\n", encoding="ascii")

    # ============================================================
    # Write task include file
    # ============================================================
    task_lines = [
        "// Generated package-faithful R1j task configuration.",
        "localparam integer R1F_TASK_COUNT = 4;",
        "localparam integer R1F_TENSOR_COUNT = 5;",
        "localparam [31:0] R1F_EXPECTED_FINAL_CHECKSUM = "
        f"32'h{stages[-1]['expected_checksum'][2:]};",
        "task init_r1f_smoke_tasks;",
        "integer i;",
        "begin",
        "  for (i = 0; i < 8; i = i + 1) begin",
        "    r1f_weight_addr[i]=0; r1f_weight_bytes[i]=0; r1f_bias_addr[i]=0; r1f_bias_bytes[i]=0;",
        "    r1f_src1_addr[i]=0; r1f_src1_bytes[i]=0; r1f_conv_cfg[i]=0; r1f_add_cfg[i]=0;",
        "    r1f_gap_cfg[i]=0; r1f_postproc_cfg[i]=0; r1f_requant_multiplier[i]=1; r1f_requant_shift[i]=0;",
        "    r1f_add_src0_multiplier[i]=1; r1f_add_src0_shift[i]=0; r1f_add_src1_multiplier[i]=1; r1f_add_src1_shift[i]=0;",
        "    r1f_add_out_multiplier[i]=1; r1f_add_out_shift[i]=0; r1i_relu_en[i]=0;",
        "  end",
    ]
    tensor_names = [
        "layer1.2.add.relu",
        "layer2.0.conv1.relu",
        "layer2.0.conv2.pre_add_main",
        "layer2.0.shortcut.pre_add",
        "layer2.0.add.relu",
    ]
    for idx, name in enumerate(tensor_names):
        tensor = tensors[name]
        task_lines += [
            f"  r1f_tensor_name[{idx}] = \"{name}\";",
            f"  r1f_tensor_addr[{idx}] = 32'd{tensor['base_addr']};",
            f"  r1f_tensor_bytes[{idx}] = 32'd{tensor['byte_size']};",
            f"  r1f_tensor_checksum[{idx}] = 32'd0;",
        ]
    for item in stages:
        idx = item["stage_index"]
        if item["task_type"] == 0:
            if "projection" in item["name"]:
                op = "CONV1x1_PROJECTION"
            else:
                op = "CONV3x3"
        else:
            op = "RESIDUAL_ADD"
        task_lines += [
            f"  r1f_task_name[{idx}] = \"{item['name']}\";",
            f"  r1f_op_name[{idx}] = \"{op}\";",
            f"  r1f_task_type[{idx}] = 32'd{item['task_type']};",
            f"  r1f_input_addr[{idx}] = 32'd{item['input_addr']};",
            f"  r1f_output_addr[{idx}] = 32'd{item['output_addr']};",
            f"  r1f_input_bytes[{idx}] = 32'd{item['input_bytes']};",
            f"  r1f_output_bytes[{idx}] = 32'd{item['output_bytes']};",
        ]
        if "input_h" in item:
            task_lines += [
                f"  r1f_input_h[{idx}] = 32'd{item['input_h']}; r1f_input_w[{idx}] = 32'd{item['input_w']};",
            ]
        else:
            # For ADD, compute from shape
            in_h = 16
            in_w = 16
            task_lines += [
                f"  r1f_input_h[{idx}] = 32'd{in_h}; r1f_input_w[{idx}] = 32'd{in_w};",
            ]
        task_lines += [
            f"  r1f_input_c[{idx}] = 32'd{item['input_c']}; r1f_output_c[{idx}] = 32'd{item['output_c']};",
        ]
        if item["task_type"] == 0:
            task_lines += [
                f"  r1f_weight_addr[{idx}] = 32'd{WEIGHT_LOAD_ADDR}; r1f_weight_bytes[{idx}] = 32'd{item['weight_bytes']};",
                f"  r1f_bias_addr[{idx}] = 32'd{BIAS_LOAD_ADDR}; r1f_bias_bytes[{idx}] = 32'd{item['bias_bytes']};",
                f"  r1f_conv_cfg[{idx}] = 32'd{item['conv_cfg']};",
                f"  r1f_requant_multiplier[{idx}] = 32'd{item['multiplier_int']}; r1f_requant_shift[{idx}] = 32'd{item['shift']};",
                f"  r1i_relu_en[{idx}] = 32'd{1 if item['relu'] else 0};",
            ]
        else:
            task_lines += [
                f"  r1f_src1_addr[{idx}] = 32'd{item['src1_addr']}; r1f_src1_bytes[{idx}] = 32'd{item['src1_bytes']};",
                f"  r1f_add_cfg[{idx}] = 32'd{item['add_cfg']};",
                f"  r1f_add_src0_multiplier[{idx}] = 32'd{item['src0_multiplier']}; r1f_add_src0_shift[{idx}] = 32'd{item['src0_shift']};",
                f"  r1f_add_src1_multiplier[{idx}] = 32'd{item['src1_multiplier']}; r1f_add_src1_shift[{idx}] = 32'd{item['src1_shift']};",
                f"  r1f_add_out_multiplier[{idx}] = 32'd{item['out_multiplier']}; r1f_add_out_shift[{idx}] = 32'd{item['out_shift']};",
            ]
        task_lines += [
            f"  r1f_src0_tensor_idx[{idx}] = {idx}; r1f_src1_tensor_idx[{idx}] = -1; r1f_dst_tensor_idx[{idx}] = {idx + 1};",
            f"  r1f_weight_checksum[{idx}] = 0; r1f_bias_checksum[{idx}] = 0; r1f_expected_output_checksum[{idx}] = 32'h{item['expected_checksum'][2:]};",
        ]
    task_lines += ["end", "endtask"]
    Path(args.task_include).write_text("\n".join(task_lines) + "\n", encoding="ascii")

    # ============================================================
    # Write expected include file
    # ============================================================
    expected_lines = [
        "// Generated package-faithful R1j expected values and payloads.",
        "localparam integer R1G_COMPARE_TASK_COUNT = 4;",
        "localparam integer R1G_MAX_COMPARE_BYTES = 16384;",
        "localparam signed [31:0] R1G_CONV1_REF_MAC_BEFORE_BIAS = 0;",
        "localparam signed [31:0] R1G_CONV1_REF_BIAS = 0;",
        "localparam signed [31:0] R1G_CONV1_REF_ACC_AFTER_BIAS = 0;",
        "localparam signed [7:0] R1G_CONV1_REF_OUTPUT_I8 = 0;",
        "task init_r1g_compare_expected;",
        "integer i;",
        "begin",
        "  for (i=0;i<8;i=i+1) begin r1g_compare_bytes[i]=0; r1g_expected_checksum[i]=0; r1g_weight_payload_bytes[i]=0; r1g_bias_payload_bytes[i]=0; end",
        f"  $readmemh(\"{output / 'input_layer1_2_add_relu.memh'}\", r1i_load_byte);",
        f"  for (i=0;i<{len(layer1_2_add_relu_values)};i=i+1) r1i_input_payload[i] = r1i_load_byte[i];",
        f"  r1i_input_payload_bytes = {len(layer1_2_add_relu_values)};",
    ]
    for item in stages:
        idx = item["stage_index"]
        expected_lines += [
            f"  r1g_reference_name[{idx}] = \"{item['name']}\";",
            f"  r1g_compare_bytes[{idx}] = {item['output_bytes']};",
            f"  r1g_expected_checksum[{idx}] = 32'h{item['expected_checksum'][2:]};",
            f"  $readmemh(\"{item['expected_file']}\", r1i_load_byte);",
            f"  for (i=0;i<{item['output_bytes']};i=i+1) r1g_expected_byte[{idx}][i] = r1i_load_byte[i];",
        ]
        if item["task_type"] == 0:
            expected_lines += [
                f"  r1g_weight_payload_bytes[{idx}] = {item['weight_bytes']};",
                f"  r1g_bias_payload_bytes[{idx}] = {item['bias_bytes']};",
                f"  $readmemh(\"{item['weight_file']}\", r1i_load_byte);",
                f"  for (i=0;i<{item['weight_bytes']};i=i+1) r1g_weight_payload_byte[{idx}][i] = r1i_load_byte[i];",
                f"  $readmemh(\"{item['bias_byte_file']}\", r1i_load_byte);",
                f"  for (i=0;i<{item['bias_bytes']};i=i+1) r1g_bias_payload_byte[{idx}][i] = r1i_load_byte[i];",
            ]
    expected_lines += ["end", "endtask"]
    Path(args.expected_include).write_text("\n".join(expected_lines) + "\n", encoding="ascii")

    print(f"Wrote {args.summary}")
    print(f"scope={','.join(R1J_SLICE_NAMES)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
