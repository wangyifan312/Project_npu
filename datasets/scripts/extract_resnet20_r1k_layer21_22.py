#!/usr/bin/env python3
"""Generate R1K fixture: layer2.1 + layer2.2 blocks (all stride=1, 32ch)."""

from __future__ import annotations
import argparse, json, sys
from pathlib import Path
from typing import Any
import torch, torch.nn.functional as F

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
from extract_resnet20_r1f_smoke import conv_cfg_for, memh_values
from search_resnet20_requant_plan import search_multiplier_shift

WEIGHT_LOAD_ADDR = 0x0008_0000
BIAS_LOAD_ADDR = 0x0008_1000

R1K_SLICE = [
    "layer2.1.conv1", "layer2.1.conv2", "layer2.1.add",
    "layer2.2.conv1", "layer2.2.conv2", "layer2.2.add",
]
PRE_TASKS = [f"layer1.{i}.conv1" for i in range(3)] + \
            [f"layer1.{i}.conv2" for i in range(3)] + \
            [f"layer1.{i}.add" for i in range(3)] + \
            ["conv1"]  # conv1 + layer1.0/1/2 = 10 tasks (0-9)
# Actually tasks 0-9 plus 10-13. Let me use all tasks up to 13.
PRE_TASK_NAMES = [
    "conv1",
    "layer1.0.conv1", "layer1.0.conv2", "layer1.0.add",
    "layer1.1.conv1", "layer1.1.conv2", "layer1.1.add",
    "layer1.2.conv1", "layer1.2.conv2", "layer1.2.add",
    "layer2.0.conv1", "layer2.0.conv2", "layer2.0.shortcut.projection", "layer2.0.add",
]

def read_json(path): return json.loads(path.read_text(encoding="ascii"))
def to_s8(v): v &= 0xFF; return v - 256 if v >= 128 else v
def to_s32(v): v &= 0xFFFFFFFF; return v - (1<<32) if v >= (1<<31) else v

def round_shift_half_away(data, shift):
    data = data.to(torch.int64)
    if shift == 0: return data
    r = (torch.abs(data) + (1 << (shift - 1))) >> shift
    return torch.where(data < 0, -r, r)

def requant(data, plan, clamp=True):
    v = round_shift_half_away(data * int(plan["multiplier_int"]), int(plan["shift"]))
    return torch.clamp(v, -128, 127) if clamp else v

def checksum(values):
    return sum((i+1)*(v&0xFF) for i,v in enumerate(values)) & 0xFFFFFFFF

def write_memh(path, values, width):
    path.parent.mkdir(parents=True, exist_ok=True)
    d = width // 4; m = (1<<width)-1
    path.write_text("".join(f"{v&m:0{d}x}\n" for v in values), encoding="ascii")

def tensor_to_hwc_bytes(t):
    return [int(v)&0xFF for v in t[0].permute(1,2,0).contiguous().view(-1).tolist()]

def conv_ref(inp, ih, iw, ic, oc, wvs, bvs, k, stride, pad, rq, relu):
    x = torch.tensor([to_s8(v) for v in inp], dtype=torch.float32)
    x = x.view(1,ih,iw,ic).permute(0,3,1,2).contiguous()
    w = torch.tensor([to_s8(v) for v in wvs], dtype=torch.float32)
    w = w.view(ic,k,k,oc).permute(3,0,1,2).contiguous()
    b = torch.tensor(bvs, dtype=torch.float32)
    acc = torch.round(F.conv2d(x,w,bias=b,stride=stride,padding=pad)).to(torch.int64)
    if relu: acc = torch.clamp(acc, min=0)
    return tensor_to_hwc_bytes(requant(acc, rq))

def find_item(doc, name):
    for item in doc["items"]:
        if item["op"] == name: return item
    raise KeyError(name)

def get_task(tasks_doc, name):
    for t in tasks_doc["tasks"]:
        if t["name"] == name: return t
    raise KeyError(name)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--package-dir", default="datasets/cifar10/resnet20_export_package")
    p.add_argument("--output-dir", default="tb/generated/resnet20_r1k_package_slice")
    p.add_argument("--summary", default="tb/generated/resnet20_r1k_package_slice_compare_summary.json")
    p.add_argument("--sv-include", default="tb/generated/resnet20_r1k_package_slice.vh")
    p.add_argument("--task-include", default="tb/generated/resnet20_r1k_package_tasks.vh")
    p.add_argument("--expected-include", default="tb/generated/resnet20_r1k_package_expected.vh")
    args = p.parse_args()

    pkg = Path(args.package_dir); out = Path(args.output_dir)
    tasks_doc = read_json(pkg/"task_sequence.json")
    mem_doc = read_json(pkg/"memory_map.json")
    conv_rq = read_json(pkg/"requant/conv_fc_requant.json")
    add_doc = read_json(pkg/"requant/residual_add_alignment.json")
    tensors = {it["name"]: it for it in mem_doc["tensors"]}

    # Phase 1: compute tasks 0-13 to get layer2.0.add.relu
    input_vals = [((i*37+(i//3)*11+19)&0xFF) for i in range(3072)]
    write_memh(out/"input_image.memh", input_vals, 8)
    cur = input_vals
    l12_add_relu = None  # saved after task 9 for task 12's input

    for tname in PRE_TASK_NAMES:
        task = get_task(tasks_doc, tname)
        op = task["op_type"]
        ic = int(task["input_shape"][0]); oc = int(task["output_shape"][0])
        relu = task["output_tensor"].endswith(".relu")
        ih = int(task["input_shape"][1]); iw = int(task["input_shape"][2])

        if op in ("CONV3x3", "CONV1x1_PROJECTION"):
            wvs = [v&0xFF for v in memh_values(pkg/task["weight_file"])]
            bvs = [to_s32(v) for v in memh_values(pkg/task["bias_file"])]
            rq = find_item(conv_rq, tname)["requant"]
            k = int(task["kernel"][0]); stride = int(task.get("stride") or 1)
            pad = k//2 if (conv_cfg_for(task)>>3)&1 else 0
            # Task 12 (projection) uses layer1.2.add.relu, not previous output
            conv_input = l12_add_relu if tname == "layer2.0.shortcut.projection" else cur
            result = conv_ref(conv_input, ih, iw, ic, oc, wvs, bvs, k, stride, pad, rq, relu)
            if tname == "layer2.0.shortcut.projection":
                proj_output = result  # save for add task
            cur = result
        elif op == "RESIDUAL_ADD":
            ap = find_item(add_doc, tname)
            sc_name = task["input_tensors"][1]
            if sc_name == "conv1.relu":
                sc = [int(l.strip(),16) for l in (out/"conv1_expected.memh").read_text().splitlines()]
            elif sc_name == "layer1.0.add.relu":
                sc = [int(l.strip(),16) for l in (out/"layer1_0_add_expected.memh").read_text().splitlines()]
            elif sc_name == "layer1.1.add.relu":
                sc = [int(l.strip(),16) for l in (out/"layer1_1_add_expected.memh").read_text().splitlines()]
            elif sc_name == "layer1.2.add.relu":
                sc = [int(l.strip(),16) for l in (out/"layer1_2_add_expected.memh").read_text().splitlines()]
            elif sc_name == "layer2.0.shortcut.pre_add":
                sc = proj_output  # use saved projection output
            else:
                sc = [int(l.strip(),16) for l in (out/f"{sc_name.replace('.','_')}_expected.memh").read_text().splitlines()]

            m = torch.tensor([to_s8(v) for v in cur], dtype=torch.int64)
            s = torch.tensor([to_s8(v) for v in sc], dtype=torch.int64)
            ma = requant(m, ap["main_to_target"], clamp=True)
            sa = requant(s, ap["shortcut_to_target"], clamp=True)
            ar = torch.clamp(ma+sa, min=0)
            pp = search_multiplier_shift(float(ap["target_add_scale"])/float(ap["post_relu_scale"]))
            cur = [int(v)&0xFF for v in requant(ar, pp, clamp=True).tolist()]

        stem = tname.replace(".","_")
        write_memh(out/f"{stem}_expected.memh", cur, 8)
        # Save layer1.2.add.relu for task 12's input
        if tname == "layer1.2.add":
            l12_add_relu = cur

    l2a = cur  # layer2.0.add.relu
    write_memh(out/"input_layer2_0_add_relu.memh", l2a, 8)

    # Phase 2: tasks 14-19 (layer2.1, layer2.2)
    stages = []
    cur = l2a
    for sidx, tname in enumerate(R1K_SLICE):
        task = get_task(tasks_doc, tname)
        op = task["op_type"]
        ic = int(task["input_shape"][0]); oc = int(task["output_shape"][0])
        relu = task["output_tensor"].endswith(".relu")
        ih = int(task["input_shape"][1]); iw = int(task["input_shape"][2])

        if op == "CONV3x3":
            wvs = [v&0xFF for v in memh_values(pkg/task["weight_file"])]
            bvs = [to_s32(v) for v in memh_values(pkg/task["bias_file"])]
            rq = find_item(conv_rq, tname)["requant"]
            k = int(task["kernel"][0]); stride = int(task.get("stride") or 1)
            pad = k // 2
            cur = conv_ref(cur, ih, iw, ic, oc, wvs, bvs, k, stride, pad, rq, relu)
            stem = tname.replace(".","_")
            write_memh(out/f"{stem}_weights.memh", wvs, 8)
            write_memh(out/f"{stem}_bias.memh", bvs, 32)
            bbf = [((v&0xFFFFFFFF)>>(8*l))&0xFF for v in bvs for l in range(4)]
            write_memh(out/f"{stem}_bias_bytes.memh", bbf, 8)
            write_memh(out/f"{stem}_expected.memh", cur, 8)
            ot = tensors[task["output_tensor"]]
            stages.append({
                "stage_index": sidx, "task_id": task["task_id"], "name": tname,
                "task_type": 0, "input_addr": task["memory"]["inputs"][task["input_tensors"][0]],
                "output_addr": task["memory"]["output"],
                "input_bytes": tensors[task["input_tensors"][0]]["byte_size"],
                "output_bytes": ot["byte_size"], "input_c": ic, "output_c": oc,
                "input_h": ih, "input_w": iw, "conv_cfg": conv_cfg_for(task), "relu": relu,
                "multiplier_int": rq["multiplier_int"], "shift": rq["shift"],
                "weight_bytes": len(wvs), "bias_bytes": len(bvs)*4,
                "expected_checksum": f"0x{checksum(cur):08x}",
            })
        elif op == "RESIDUAL_ADD":
            ap = find_item(add_doc, tname)
            sc_name = task["input_tensors"][1]
            # Shortcut is always the previous block's add.relu
            if sc_name == "layer2.0.add.relu":
                sc = [int(l.strip(),16) for l in (out/"layer2_0_add_expected.memh").read_text().splitlines()]
            elif sc_name == "layer2.1.add.relu":
                sc = [int(l.strip(),16) for l in (out/"layer2_1_add_expected.memh").read_text().splitlines()]
            else:
                sc = None
            if sc is None:
                sc = cur  # fallback

            m = torch.tensor([to_s8(v) for v in cur], dtype=torch.int64)
            s = torch.tensor([to_s8(v) for v in sc], dtype=torch.int64)
            ma = requant(m, ap["main_to_target"], clamp=True)
            sa = requant(s, ap["shortcut_to_target"], clamp=True)
            ar = torch.clamp(ma+sa, min=0)
            pp = search_multiplier_shift(float(ap["target_add_scale"])/float(ap["post_relu_scale"]))
            cur = [int(v)&0xFF for v in requant(ar, pp, clamp=True).tolist()]
            stem = tname.replace(".","_")
            write_memh(out/f"{stem}_expected.memh", cur, 8)
            ot = tensors[task["output_tensor"]]
            src0_addr = task["memory"]["inputs"][task["input_tensors"][0]]
            src1_addr = task["memory"]["inputs"][task["input_tensors"][1]]
            stages.append({
                "stage_index": sidx, "task_id": task["task_id"], "name": tname,
                "task_type": 4, "input_addr": src0_addr, "src1_addr": src1_addr,
                "output_addr": task["memory"]["output"],
                "input_bytes": tensors[task["input_tensors"][0]]["byte_size"],
                "src1_bytes": tensors[task["input_tensors"][1]]["byte_size"],
                "output_bytes": ot["byte_size"], "input_c": ic, "output_c": oc,
                "add_cfg": 0xC,
                "src0_multiplier": ap["main_to_target"]["multiplier_int"],
                "src0_shift": ap["main_to_target"]["shift"],
                "src1_multiplier": ap["shortcut_to_target"]["multiplier_int"],
                "src1_shift": ap["shortcut_to_target"]["shift"],
                "out_multiplier": pp["multiplier_int"], "out_shift": pp["shift"],
                "expected_checksum": f"0x{checksum(cur):08x}",
            })

    # Summary
    summary = {"arch":"cifar10_resnet20_v1","scope":R1K_SLICE,"package_faithful":True,
               "task_sequence":str(pkg/"task_sequence.json"),"memory_map":str(pkg/"memory_map.json"),
               "input_file":str(out/"input_layer2_0_add_relu.memh"),
               "input_addr":tensors["layer2.0.add.relu"]["base_addr"],
               "weight_load_addr":WEIGHT_LOAD_ADDR,"bias_load_addr":BIAS_LOAD_ADDR,
               "stages":stages,"full_resnet20":False}
    Path(args.summary).write_text(json.dumps(summary,indent=2,sort_keys=True)+"\n",encoding="ascii")

    # SV include
    lines = ["// Generated by extract_resnet20_r1k_layer21_22.py",
             f"localparam [31:0] R1K_INPUT_ADDR = 32'd{summary['input_addr']};",
             f"localparam [31:0] R1K_WEIGHT_ADDR = 32'd{WEIGHT_LOAD_ADDR};",
             f"localparam [31:0] R1K_BIAS_ADDR = 32'd{BIAS_LOAD_ADDR};"]
    for it in stages:
        pfx = f"R1K_S{it['stage_index']}"
        for k in ["input_addr","output_addr","input_bytes","output_bytes","input_c","output_c"]:
            lines.append(f"localparam [31:0] {pfx}_{k.upper()} = 32'd{it[k]};")
        lines.append(f"localparam [31:0] {pfx}_EXPECTED_CHECKSUM = 32'h{it['expected_checksum'][2:]};")
        if it["task_type"]==0:
            for k in ["weight_bytes","bias_bytes","conv_cfg","multiplier_int","shift"]:
                lines.append(f"localparam [31:0] {pfx}_{k.upper()} = 32'd{it[k]};")
            lines.append(f"localparam [31:0] {pfx}_RELU = 32'd{1 if it['relu'] else 0};")
        else:
            for k in ["src1_addr","src1_bytes","add_cfg","src0_multiplier","src0_shift",
                      "src1_multiplier","src1_shift","out_multiplier","out_shift"]:
                lines.append(f"localparam [31:0] {pfx}_{k.upper()} = 32'd{it[k]};")
    Path(args.sv_include).write_text("\n".join(lines)+"\n",encoding="ascii")

    # Task include
    tlines = ["// Generated R1K task configuration.",
              "localparam integer R1F_TASK_COUNT = 6;",
              "localparam integer R1F_TENSOR_COUNT = 7;",
              f"localparam [31:0] R1F_EXPECTED_FINAL_CHECKSUM = 32'h{stages[-1]['expected_checksum'][2:]};",
              "task init_r1f_smoke_tasks;","integer i;","begin",
              "  for (i=0;i<8;i=i+1) begin",
              "    r1f_weight_addr[i]=0; r1f_weight_bytes[i]=0; r1f_bias_addr[i]=0; r1f_bias_bytes[i]=0;",
              "    r1f_src1_addr[i]=0; r1f_src1_bytes[i]=0; r1f_conv_cfg[i]=0; r1f_add_cfg[i]=0;",
              "    r1f_gap_cfg[i]=0; r1f_postproc_cfg[i]=0; r1f_requant_multiplier[i]=1; r1f_requant_shift[i]=0;",
              "    r1f_add_src0_multiplier[i]=1; r1f_add_src0_shift[i]=0; r1f_add_src1_multiplier[i]=1; r1f_add_src1_shift[i]=0;",
              "    r1f_add_out_multiplier[i]=1; r1f_add_out_shift[i]=0; r1i_relu_en[i]=0;",
              "  end"]
    tn = ["layer2.0.add.relu","layer2.1.conv1.relu","layer2.1.conv2.pre_add_main",
          "layer2.1.add.relu","layer2.2.conv1.relu","layer2.2.conv2.pre_add_main","layer2.2.add.relu"]
    for idx, name in enumerate(tn):
        t = tensors[name]
        tlines += [f"  r1f_tensor_name[{idx}] = \"{name}\";",
                   f"  r1f_tensor_addr[{idx}] = 32'd{t['base_addr']};",
                   f"  r1f_tensor_bytes[{idx}] = 32'd{t['byte_size']};",
                   f"  r1f_tensor_checksum[{idx}] = 32'd0;"]
    for it in stages:
        idx = it["stage_index"]
        op = "CONV3x3" if it["task_type"]==0 else "RESIDUAL_ADD"
        tlines += [f"  r1f_task_name[{idx}] = \"{it['name']}\";",
                   f"  r1f_op_name[{idx}] = \"{op}\";",
                   f"  r1f_task_type[{idx}] = 32'd{it['task_type']};",
                   f"  r1f_input_addr[{idx}] = 32'd{it['input_addr']};",
                   f"  r1f_output_addr[{idx}] = 32'd{it['output_addr']};",
                   f"  r1f_input_bytes[{idx}] = 32'd{it['input_bytes']};",
                   f"  r1f_output_bytes[{idx}] = 32'd{it['output_bytes']};",
                   f"  r1f_input_h[{idx}] = 32'd16; r1f_input_w[{idx}] = 32'd16;",
                   f"  r1f_input_c[{idx}] = 32'd{it['input_c']}; r1f_output_c[{idx}] = 32'd{it['output_c']};"]
        if it["task_type"]==0:
            tlines += [f"  r1f_weight_addr[{idx}] = 32'd{WEIGHT_LOAD_ADDR}; r1f_weight_bytes[{idx}] = 32'd{it['weight_bytes']};",
                       f"  r1f_bias_addr[{idx}] = 32'd{BIAS_LOAD_ADDR}; r1f_bias_bytes[{idx}] = 32'd{it['bias_bytes']};",
                       f"  r1f_conv_cfg[{idx}] = 32'd{it['conv_cfg']};",
                       f"  r1f_requant_multiplier[{idx}] = 32'd{it['multiplier_int']}; r1f_requant_shift[{idx}] = 32'd{it['shift']};",
                       f"  r1i_relu_en[{idx}] = 32'd{1 if it['relu'] else 0};"]
        else:
            tlines += [f"  r1f_src1_addr[{idx}] = 32'd{it['src1_addr']}; r1f_src1_bytes[{idx}] = 32'd{it['src1_bytes']};",
                       f"  r1f_add_cfg[{idx}] = 32'd{it['add_cfg']};",
                       f"  r1f_add_src0_multiplier[{idx}] = 32'd{it['src0_multiplier']}; r1f_add_src0_shift[{idx}] = 32'd{it['src0_shift']};",
                       f"  r1f_add_src1_multiplier[{idx}] = 32'd{it['src1_multiplier']}; r1f_add_src1_shift[{idx}] = 32'd{it['src1_shift']};",
                       f"  r1f_add_out_multiplier[{idx}] = 32'd{it['out_multiplier']}; r1f_add_out_shift[{idx}] = 32'd{it['out_shift']};"]
        tlines += [f"  r1f_src0_tensor_idx[{idx}] = {idx}; r1f_src1_tensor_idx[{idx}] = -1; r1f_dst_tensor_idx[{idx}] = {idx+1};",
                   f"  r1f_weight_checksum[{idx}] = 0; r1f_bias_checksum[{idx}] = 0; r1f_expected_output_checksum[{idx}] = 32'h{it['expected_checksum'][2:]};"]
    tlines += ["end","endtask"]
    Path(args.task_include).write_text("\n".join(tlines)+"\n",encoding="ascii")

    # Expected include
    elines = ["// Generated R1K expected values and payloads.",
              "localparam integer R1G_COMPARE_TASK_COUNT = 6;",
              "localparam integer R1G_MAX_COMPARE_BYTES = 16384;",
              "localparam signed [31:0] R1G_CONV1_REF_MAC_BEFORE_BIAS = 0;",
              "localparam signed [31:0] R1G_CONV1_REF_BIAS = 0;",
              "localparam signed [31:0] R1G_CONV1_REF_ACC_AFTER_BIAS = 0;",
              "localparam signed [7:0] R1G_CONV1_REF_OUTPUT_I8 = 0;",
              "task init_r1g_compare_expected;","integer i;","begin",
              "  for (i=0;i<8;i=i+1) begin r1g_compare_bytes[i]=0; r1g_expected_checksum[i]=0; r1g_weight_payload_bytes[i]=0; r1g_bias_payload_bytes[i]=0; end",
              f"  $readmemh(\"{out}/input_layer2_0_add_relu.memh\", r1i_load_byte);",
              f"  for (i=0;i<{len(l2a)};i=i+1) r1i_input_payload[i] = r1i_load_byte[i];",
              f"  r1i_input_payload_bytes = {len(l2a)};"]
    for it in stages:
        idx = it["stage_index"]
        stem = it["name"].replace(".","_")
        elines += [f"  r1g_reference_name[{idx}] = \"{it['name']}\";",
                   f"  r1g_compare_bytes[{idx}] = {it['output_bytes']};",
                   f"  r1g_expected_checksum[{idx}] = 32'h{it['expected_checksum'][2:]};",
                   f"  $readmemh(\"{out}/{stem}_expected.memh\", r1i_load_byte);",
                   f"  for (i=0;i<{it['output_bytes']};i=i+1) r1g_expected_byte[{idx}][i] = r1i_load_byte[i];"]
        if it["task_type"]==0:
            elines += [f"  r1g_weight_payload_bytes[{idx}] = {it['weight_bytes']};",
                       f"  r1g_bias_payload_bytes[{idx}] = {it['bias_bytes']};",
                       f"  $readmemh(\"{out}/{stem}_weights.memh\", r1i_load_byte);",
                       f"  for (i=0;i<{it['weight_bytes']};i=i+1) r1g_weight_payload_byte[{idx}][i] = r1i_load_byte[i];",
                       f"  $readmemh(\"{out}/{stem}_bias_bytes.memh\", r1i_load_byte);",
                       f"  for (i=0;i<{it['bias_bytes']};i=i+1) r1g_bias_payload_byte[{idx}][i] = r1i_load_byte[i];"]
    elines += ["end","endtask"]
    Path(args.expected_include).write_text("\n".join(elines)+"\n",encoding="ascii")

    print(f"Wrote {args.summary}")
    print(f"scope={','.join(R1K_SLICE)}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
