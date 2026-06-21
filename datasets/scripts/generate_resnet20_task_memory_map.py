#!/usr/bin/env python3
"""Generate ResNet-20 logical task sequence and 1 MB memory map skeleton.

F6d/F6e produces handoff inputs for later RTL R1 review.  It does not modify RTL
and does not implement the tasks in hardware.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from resnet20_cifar10_common import ARCH, deterministic_json_dump


MEMORY_BYTES = 1 << 20
ALIGN_BYTES = 64
RESERVED_NULL_BYTES = ALIGN_BYTES


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="ascii"))


def align_up(value: int, alignment: int = ALIGN_BYTES) -> int:
    return (int(value) + alignment - 1) // alignment * alignment


def element_count(shape: list[int]) -> int:
    count = 1
    for dim in shape:
        count *= int(dim)
    return count


def tensor_bytes(shape: list[int], dtype: str) -> int:
    if dtype != "INT8":
        raise ValueError(f"unsupported tensor dtype {dtype}")
    return element_count(shape)


def safe_ref(path: str, op: str) -> str:
    return f"{path}#{op}"


class TaskBuilder:
    def __init__(self, package_dir: Path) -> None:
        self.package_dir = package_dir
        self.tasks: list[dict[str, Any]] = []
        self.tensors: dict[str, dict[str, Any]] = {}
        self.consumers: dict[str, list[int]] = {}

    def ensure_tensor(self, name: str, shape: list[int], producer_task: int | None) -> None:
        if name not in self.tensors:
            self.tensors[name] = {
                "name": name,
                "shape": shape,
                "dtype": "INT8",
                "producer_task": producer_task,
            }
        elif self.tensors[name]["shape"] != shape:
            raise ValueError(f"tensor {name} shape mismatch: {self.tensors[name]['shape']} vs {shape}")

    def add_task(
        self,
        *,
        name: str,
        op_type: str,
        input_tensors: list[str],
        output_tensor: str,
        input_shape: list[int],
        output_shape: list[int],
        stride: int | None = None,
        kernel: list[int] | None = None,
        weight_file: str | None = None,
        bias_file: str | None = None,
        requant_ref: str | None = None,
        residual_add_ref: str | None = None,
    ) -> str:
        task_id = len(self.tasks)
        for tensor in input_tensors:
            if tensor not in self.tensors:
                raise KeyError(f"input tensor {tensor} was not declared before task {name}")
            self.consumers.setdefault(tensor, []).append(task_id)
        self.ensure_tensor(output_tensor, output_shape, task_id)
        task = {
            "task_id": task_id,
            "name": name,
            "op_type": op_type,
            "input_tensors": input_tensors,
            "output_tensor": output_tensor,
            "input_shape": input_shape,
            "output_shape": output_shape,
            "stride": stride,
            "kernel": kernel,
            "weight_file": weight_file,
            "bias_file": bias_file,
            "requant_ref": requant_ref,
            "residual_add_ref": residual_add_ref,
            "memory": {
                "inputs": {},
                "output": None,
            },
            "contract_status": "handoff_skeleton",
        }
        self.tasks.append(task)
        return output_tensor

    def build_network(self) -> None:
        self.ensure_tensor("input.image", [3, 32, 32], None)
        current = self.add_task(
            name="conv1",
            op_type="CONV3x3",
            input_tensors=["input.image"],
            output_tensor="conv1.relu",
            input_shape=[3, 32, 32],
            output_shape=[16, 32, 32],
            stride=1,
            kernel=[3, 3],
            weight_file="weights/conv1.memh",
            bias_file="bias/conv1.memh",
            requant_ref=safe_ref("requant/conv_fc_requant.json", "conv1"),
        )

        layer_specs = [
            ("layer1", 16, 32, 1),
            ("layer2", 32, 16, 2),
            ("layer3", 64, 8, 2),
        ]
        in_channels = 16
        in_spatial = 32
        for layer_name, channels, spatial, first_stride in layer_specs:
            for block_idx in range(3):
                prefix = f"{layer_name}.{block_idx}"
                stride = first_stride if block_idx == 0 else 1
                block_in = current
                block_in_shape = [in_channels, in_spatial, in_spatial]
                conv1_out = self.add_task(
                    name=f"{prefix}.conv1",
                    op_type="CONV3x3",
                    input_tensors=[block_in],
                    output_tensor=f"{prefix}.conv1.relu",
                    input_shape=block_in_shape,
                    output_shape=[channels, spatial, spatial],
                    stride=stride,
                    kernel=[3, 3],
                    weight_file=f"weights/{prefix.replace('.', '_')}_conv1.memh",
                    bias_file=f"bias/{prefix.replace('.', '_')}_conv1.memh",
                    requant_ref=safe_ref("requant/conv_fc_requant.json", f"{prefix}.conv1"),
                )
                conv2_out = self.add_task(
                    name=f"{prefix}.conv2",
                    op_type="CONV3x3",
                    input_tensors=[conv1_out],
                    output_tensor=f"{prefix}.conv2.pre_add_main",
                    input_shape=[channels, spatial, spatial],
                    output_shape=[channels, spatial, spatial],
                    stride=1,
                    kernel=[3, 3],
                    weight_file=f"weights/{prefix.replace('.', '_')}_conv2.memh",
                    bias_file=f"bias/{prefix.replace('.', '_')}_conv2.memh",
                    requant_ref=safe_ref("requant/conv_fc_requant.json", f"{prefix}.conv2"),
                )
                if stride != 1 or in_channels != channels:
                    shortcut = self.add_task(
                        name=f"{prefix}.shortcut.projection",
                        op_type="CONV1x1_PROJECTION",
                        input_tensors=[block_in],
                        output_tensor=f"{prefix}.shortcut.pre_add",
                        input_shape=block_in_shape,
                        output_shape=[channels, spatial, spatial],
                        stride=stride,
                        kernel=[1, 1],
                        weight_file=f"weights/{prefix.replace('.', '_')}_shortcut_projection.memh",
                        bias_file=f"bias/{prefix.replace('.', '_')}_shortcut_projection.memh",
                        requant_ref=safe_ref("requant/conv_fc_requant.json", f"{prefix}.shortcut.projection"),
                    )
                else:
                    shortcut = block_in
                current = self.add_task(
                    name=f"{prefix}.add",
                    op_type="RESIDUAL_ADD",
                    input_tensors=[conv2_out, shortcut],
                    output_tensor=f"{prefix}.add.relu",
                    input_shape=[channels, spatial, spatial],
                    output_shape=[channels, spatial, spatial],
                    residual_add_ref=safe_ref("requant/residual_add_alignment.json", f"{prefix}.add"),
                )
                in_channels = channels
                in_spatial = spatial

        gap = self.add_task(
            name="gap",
            op_type="GAP8x8",
            input_tensors=[current],
            output_tensor="gap.output",
            input_shape=[64, 8, 8],
            output_shape=[64],
            kernel=[8, 8],
            requant_ref=safe_ref("requant/gap_requant.json", "gap.output"),
        )
        self.add_task(
            name="fc",
            op_type="FC10",
            input_tensors=[gap],
            output_tensor="fc.logits",
            input_shape=[64],
            output_shape=[10],
            weight_file="weights/fc.memh",
            bias_file="bias/fc.memh",
            requant_ref=safe_ref("requant/conv_fc_requant.json", "fc"),
        )

    def build_memory_map(self) -> dict[str, Any]:
        # Address 0 is reserved because the current task_checker treats zero
        # task addresses as null/invalid. Keep the package contract aligned
        # with RTL instead of relying on testbench-only aliases.
        cursor = RESERVED_NULL_BYTES
        tensor_entries = []
        for name, tensor in self.tensors.items():
            byte_size = tensor_bytes(tensor["shape"], tensor["dtype"])
            aligned = align_up(byte_size)
            base = align_up(cursor)
            end = base + aligned
            if end > MEMORY_BYTES:
                raise ValueError(f"memory map overflow at tensor {name}: 0x{end:x}")
            consumers = self.consumers.get(name, [])
            producer = tensor["producer_task"]
            lifetime_start = 0 if producer is None else int(producer)
            lifetime_end = max(consumers) if consumers else lifetime_start
            entry = {
                "name": name,
                "shape": tensor["shape"],
                "dtype": tensor["dtype"],
                "element_count": element_count(tensor["shape"]),
                "byte_size": byte_size,
                "aligned_byte_size": aligned,
                "base_addr": base,
                "end_addr": end,
                "producer_task": producer,
                "consumer_tasks": consumers,
                "lifetime": {
                    "start_task": lifetime_start,
                    "end_task": lifetime_end,
                },
            }
            tensor_entries.append(entry)
            cursor = end

        addr_by_tensor = {entry["name"]: entry["base_addr"] for entry in tensor_entries}
        for task in self.tasks:
            task["memory"]["inputs"] = {tensor: addr_by_tensor[tensor] for tensor in task["input_tensors"]}
            task["memory"]["output"] = addr_by_tensor[task["output_tensor"]]

        peak_live = 0
        for task_id in range(len(self.tasks)):
            live = sum(
                entry["aligned_byte_size"]
                for entry in tensor_entries
                if entry["lifetime"]["start_task"] <= task_id <= entry["lifetime"]["end_task"]
            )
            peak_live = max(peak_live, live)

        return {
            "arch": ARCH,
            "status": "memory_map_generated",
            "policy": {
                "memory_bytes": MEMORY_BYTES,
                "physical_organization": "32768 x 256-bit beat",
                "addressing": "byte_addressed",
                "alignment_bytes": ALIGN_BYTES,
                "reserved_null_bytes": RESERVED_NULL_BYTES,
                "null_address_policy": "address_0_reserved_to_preserve_task_checker_null_address_reject",
                "activation_dtype": "INT8",
                "allocation_strategy": "conservative_unique_tensor_allocation_no_reuse",
            },
            "tensor_count": len(tensor_entries),
            "memory_total_bytes": MEMORY_BYTES,
            "memory_peak_live_bytes": peak_live,
            "memory_allocated_bytes": cursor,
            "memory_max_end_address": max((entry["end_addr"] for entry in tensor_entries), default=0),
            "tensors": tensor_entries,
        }


def precheck(package_dir: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    manifest = read_json(package_dir / "manifest.json")
    validation = read_json(package_dir / "validation_report.json")
    errors = []
    if validation.get("validation_status") != "pass":
        errors.append("export package validation_status is not pass")
    for key, expected in (
        ("weight_file_count", 22),
        ("bias_file_count", 22),
        ("conv_fc_requant_count", 22),
        ("residual_add_alignment_count", 9),
    ):
        if int(validation.get(key, -1)) != expected:
            errors.append(f"{key} is {validation.get(key)!r}, expected {expected}")
    if errors:
        raise SystemExit("precheck failed:\n" + "\n".join(errors))
    return manifest, validation


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate ResNet-20 task sequence and memory map")
    parser.add_argument("--package-dir", required=True)
    parser.add_argument("--output-task", required=True)
    parser.add_argument("--output-memory", required=True)
    args = parser.parse_args()

    package_dir = Path(args.package_dir)
    output_task = Path(args.output_task)
    output_memory = Path(args.output_memory)
    manifest, _validation = precheck(package_dir)

    builder = TaskBuilder(package_dir)
    builder.build_network()
    memory_map = builder.build_memory_map()

    op_counts: dict[str, int] = {}
    for task in builder.tasks:
        op_counts[task["op_type"]] = op_counts.get(task["op_type"], 0) + 1
    task_sequence = {
        "arch": ARCH,
        "status": "task_sequence_generated",
        "contract_status": "handoff_skeleton",
        "task_count": len(builder.tasks),
        "op_counts": op_counts,
        "tasks": builder.tasks,
    }
    deterministic_json_dump(output_task, task_sequence)
    deterministic_json_dump(output_memory, memory_map)

    manifest["task_sequence"] = output_task.name
    manifest["memory_map"] = output_memory.name
    manifest["final_task_sequence_generated"] = True
    manifest["one_mb_memory_reuse_map_generated"] = True
    manifest["rtl_r1_started"] = False
    deterministic_json_dump(package_dir / "manifest.json", manifest)

    summary_path = package_dir / "summary.json"
    summary = read_json(summary_path)
    summary["status"] = "export_package_with_task_memory_map"
    summary["task_sequence_generated"] = True
    summary["one_mb_memory_reuse_map_generated"] = True
    summary["task_memory_validation"] = "task_memory_validation.json"
    summary["task_count"] = len(builder.tasks)
    summary["memory_total_bytes"] = memory_map["memory_total_bytes"]
    summary["memory_peak_live_bytes"] = memory_map["memory_peak_live_bytes"]
    summary["memory_max_end_address"] = memory_map["memory_max_end_address"]
    summary["rtl_r1_started"] = False
    deterministic_json_dump(summary_path, summary)

    print(f"Wrote {output_task}")
    print(f"Wrote {output_memory}")
    print(f"task_count={len(builder.tasks)}")
    print(f"memory_max_end_address={memory_map['memory_max_end_address']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
