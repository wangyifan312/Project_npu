#!/usr/bin/env python3
"""Shared CIFAR-10 ResNet-20 utilities for R0.5 software flow.

This module intentionally stays independent from the existing MNIST/LeNet
scripts.  R0.5 only provides float/smoke plumbing plus explicit TODO metadata
for the later fixed-point golden, weight export, task sequence, and memory map.
"""

from __future__ import annotations

import ast
import io
import json
import pickle
import random
import struct
import tarfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import torch
import torch.nn as nn
import torch.nn.functional as F


ARCH = "cifar10_resnet20_v1"
QUANT_VERSION = "resnet20_r0_5_float_smoke_v0"
BIAS_POLICY = "int32_folded_bias_required_not_exported_in_r0_5_smoke"
SHORTCUT_POLICY = "projection_conv1x1_stride2"
ADD_POLICY = "int32_same_scale_add_required_not_fixed_point_verified"
INPUT_MEMH_NAME = "input.memh"
SMOKE_INPUT_LAYOUT = "HWC"
SMOKE_INPUT_DTYPE = "INT8"
SMOKE_INPUT_QUANTIZATION = "uint8_minus_128_smoke_or_float_placeholder"
CIFAR10_DEFAULT_TAR = "datasets/cifar10/cifar-10-python.tar.gz"


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def seed_everything(seed: int) -> None:
    random.seed(seed)
    torch.manual_seed(seed)


def deterministic_json_dump(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="ascii")


def resnet20_metadata(training_config: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "arch": ARCH,
        "quant_version": QUANT_VERSION,
        "bias_policy": BIAS_POLICY,
        "shortcut_policy": SHORTCUT_POLICY,
        "add_policy": ADD_POLICY,
        "input_shape": [3, 32, 32],
        "num_classes": 10,
        "fixed_point_status": "not_implemented",
        "fixed_point_accuracy_gate": {
            "required_accuracy": 0.80,
            "status": "not_evaluated",
        },
        "training_config": training_config or {},
    }


class BasicBlock(nn.Module):
    expansion = 1

    def __init__(self, in_planes: int, planes: int, stride: int) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(in_planes, planes, kernel_size=3, stride=stride, padding=1, bias=False)
        self.bn1 = nn.BatchNorm2d(planes)
        self.conv2 = nn.Conv2d(planes, planes, kernel_size=3, stride=1, padding=1, bias=False)
        self.bn2 = nn.BatchNorm2d(planes)
        if stride != 1 or in_planes != planes:
            self.shortcut = nn.Sequential(
                nn.Conv2d(in_planes, planes, kernel_size=1, stride=stride, bias=False),
                nn.BatchNorm2d(planes),
            )
        else:
            self.shortcut = nn.Identity()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = F.relu(self.bn1(self.conv1(x)))
        out = self.bn2(self.conv2(out))
        out = out + self.shortcut(x)
        return F.relu(out)


class CifarResNet20(nn.Module):
    """CIFAR ResNet v1 / ResNet-20: 1 initial conv + 3x3x2 conv blocks + FC10."""

    def __init__(self, num_classes: int = 10) -> None:
        super().__init__()
        self.in_planes = 16
        self.conv1 = nn.Conv2d(3, 16, kernel_size=3, stride=1, padding=1, bias=False)
        self.bn1 = nn.BatchNorm2d(16)
        self.layer1 = self._make_layer(16, blocks=3, stride=1)
        self.layer2 = self._make_layer(32, blocks=3, stride=2)
        self.layer3 = self._make_layer(64, blocks=3, stride=2)
        self.fc = nn.Linear(64, num_classes)

    def _make_layer(self, planes: int, blocks: int, stride: int) -> nn.Sequential:
        strides = [stride] + [1] * (blocks - 1)
        layers = []
        for block_stride in strides:
            layers.append(BasicBlock(self.in_planes, planes, block_stride))
            self.in_planes = planes * BasicBlock.expansion
        return nn.Sequential(*layers)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = F.relu(self.bn1(self.conv1(x)))
        out = self.layer1(out)
        out = self.layer2(out)
        out = self.layer3(out)
        out = F.avg_pool2d(out, out.shape[-1])
        out = torch.flatten(out, 1)
        return self.fc(out)


def synthetic_cifar10(count: int, seed: int) -> tuple[torch.Tensor, torch.Tensor]:
    generator = torch.Generator().manual_seed(seed)
    images_u8 = torch.randint(0, 256, (count, 3, 32, 32), dtype=torch.uint8, generator=generator)
    labels = torch.arange(count, dtype=torch.long) % 10
    images = images_u8.to(torch.float32) / 255.0
    images = (images - 0.5) / 0.5
    return images, labels


class _NumpyDtypeStub:
    def __init__(self, name: str, *_args: Any, **_kwargs: Any) -> None:
        self.name = name

    def __setstate__(self, _state: Any) -> None:
        return None


class _NumpyNdarrayStub:
    def __init__(self, *_args: Any, **_kwargs: Any) -> None:
        self.shape: tuple[int, ...] = ()
        self.raw = b""

    def __setstate__(self, state: Any) -> None:
        if not isinstance(state, tuple) or len(state) < 5:
            raise ValueError("unsupported numpy ndarray pickle state")
        _version, shape, _dtype, _is_fortran, raw = state[:5]
        if not isinstance(shape, tuple):
            raise ValueError("unsupported ndarray shape in CIFAR pickle")
        if isinstance(raw, str):
            raw = raw.encode("latin1")
        if not isinstance(raw, (bytes, bytearray)):
            raise ValueError("unsupported ndarray raw payload in CIFAR pickle")
        self.shape = tuple(int(v) for v in shape)
        self.raw = bytes(raw)

    def tobytes(self) -> bytes:
        return self.raw


def _numpy_reconstruct_stub(_subtype: Any, _shape: Any, _dtype: Any) -> _NumpyNdarrayStub:
    return _NumpyNdarrayStub()


class _CifarUnpickler(pickle.Unpickler):
    """Unpickle CIFAR python batches without requiring NumPy to be installed."""

    def find_class(self, module: str, name: str) -> Any:
        if module in ("numpy.core.multiarray", "numpy._core.multiarray") and name == "_reconstruct":
            return _numpy_reconstruct_stub
        if module in ("numpy", "numpy.core.multiarray", "numpy._core.multiarray") and name == "ndarray":
            return _NumpyNdarrayStub
        if module in ("numpy", "numpy.dtype") and name == "dtype":
            return _NumpyDtypeStub
        return super().find_class(module, name)


def _load_cifar_pickle(raw: bytes) -> dict[Any, Any]:
    return _CifarUnpickler(io.BytesIO(raw), encoding="latin1").load()


def _dict_get(batch: dict[Any, Any], key: str) -> Any:
    if key in batch:
        return batch[key]
    bkey = key.encode("ascii")
    if bkey in batch:
        return batch[bkey]
    raise KeyError(key)


def _cifar_data_raw_and_shape(data_obj: Any) -> tuple[bytes, tuple[int, int]]:
    shape = getattr(data_obj, "shape", None)
    if hasattr(data_obj, "tobytes"):
        raw = data_obj.tobytes()
    elif isinstance(data_obj, (bytes, bytearray)):
        raw = bytes(data_obj)
    else:
        raise ValueError(f"unsupported CIFAR data payload {type(data_obj).__name__}")
    if shape is None:
        if len(raw) % 3072:
            raise ValueError("CIFAR raw data is not divisible by 3072")
        shape = (len(raw) // 3072, 3072)
    shape_tuple = tuple(int(v) for v in shape)
    if len(shape_tuple) != 2 or shape_tuple[1] != 3072:
        raise ValueError(f"unsupported CIFAR data shape {shape_tuple}")
    return raw, (shape_tuple[0], shape_tuple[1])


def load_cifar10_tar(path: Path, count: int, split: str = "test") -> tuple[torch.Tensor, torch.Tensor]:
    if split not in ("train", "test"):
        raise ValueError("--split must be train or test")
    if not path.exists():
        raise FileNotFoundError(
            f"CIFAR-10 python tarball not found: {path}; provide --cifar10-tar or use --smoke"
        )

    batch_names = [f"cifar-10-batches-py/data_batch_{idx}" for idx in range(1, 6)] if split == "train" else [
        "cifar-10-batches-py/test_batch"
    ]
    chunks: list[torch.Tensor] = []
    label_chunks: list[torch.Tensor] = []
    remaining = count if count > 0 else None

    with tarfile.open(path, "r:gz") as tf:
        for batch_name in batch_names:
            member = tf.extractfile(batch_name)
            if member is None:
                raise FileNotFoundError(f"missing CIFAR batch in tarball: {batch_name}")
            batch = _load_cifar_pickle(member.read())
            raw, shape = _cifar_data_raw_and_shape(_dict_get(batch, "data"))
            labels_obj = _dict_get(batch, "labels")
            labels_list = [int(v) for v in labels_obj]
            batch_count = shape[0]
            use_count = batch_count if remaining is None else min(batch_count, remaining)
            image_tensor = torch.frombuffer(bytearray(raw), dtype=torch.uint8).clone().reshape(batch_count, 3, 32, 32)
            label_tensor = torch.tensor(labels_list, dtype=torch.long)
            chunks.append(image_tensor[:use_count])
            label_chunks.append(label_tensor[:use_count])
            if remaining is not None:
                remaining -= use_count
                if remaining <= 0:
                    break

    if not chunks:
        raise ValueError("no CIFAR samples loaded")

    images_u8 = torch.cat(chunks, dim=0)
    labels = torch.cat(label_chunks, dim=0)
    images = images_u8.to(torch.float32) / 255.0
    images = (images - 0.5) / 0.5
    return images, labels


def load_npy_from_bytes(blob: bytes) -> tuple[tuple[int, ...], str, bytes]:
    if blob[:6] != b"\x93NUMPY":
        raise ValueError("invalid npy magic")
    major = blob[6]
    if major == 1:
        header_len = struct.unpack("<H", blob[8:10])[0]
        header_start = 10
    elif major == 2:
        header_len = struct.unpack("<I", blob[8:12])[0]
        header_start = 12
    else:
        raise ValueError(f"unsupported npy version {major}")
    header_end = header_start + header_len
    meta = ast.literal_eval(blob[header_start:header_end].decode("latin1").strip())
    if meta["fortran_order"]:
        raise ValueError("fortran-order arrays are not supported")
    shape = meta["shape"]
    if not isinstance(shape, tuple):
        raise ValueError("invalid npy shape")
    return shape, meta["descr"], blob[header_end:]


def load_cifar10_npz(path: Path, count: int, split: str = "test") -> tuple[torch.Tensor, torch.Tensor]:
    """Load a local CIFAR-10 npz without adding a numpy dependency.

    Accepted keys are either x_test/y_test or images/labels for simple custom
    exports.  Image shape may be NHWC or NCHW uint8.
    """

    with zipfile.ZipFile(path, "r") as zf:
        names = set(zf.namelist())
        if f"x_{split}.npy" in names and f"y_{split}.npy" in names:
            x_name = f"x_{split}.npy"
            y_name = f"y_{split}.npy"
        elif "images.npy" in names and "labels.npy" in names:
            x_name = "images.npy"
            y_name = "labels.npy"
        else:
            raise ValueError("npz must contain x_test/y_test or images/labels arrays")
        x_shape, x_descr, x_raw = load_npy_from_bytes(zf.read(x_name))
        y_shape, y_descr, y_raw = load_npy_from_bytes(zf.read(y_name))

    if x_descr not in ("|u1", "<u1"):
        raise ValueError(f"unsupported CIFAR image dtype {x_descr}, expected uint8")
    if y_descr not in ("|u1", "<u1", "<i8", "<i4"):
        raise ValueError(f"unsupported CIFAR label dtype {y_descr}")

    total = x_shape[0]
    use_count = total if count <= 0 else min(count, total)
    image_tensor = torch.frombuffer(bytearray(x_raw), dtype=torch.uint8).clone().reshape(x_shape)[:use_count]
    if list(image_tensor.shape[1:]) == [32, 32, 3]:
        image_tensor = image_tensor.permute(0, 3, 1, 2).contiguous()
    elif list(image_tensor.shape[1:]) != [3, 32, 32]:
        raise ValueError(f"unsupported CIFAR image shape {list(image_tensor.shape)}")

    label_dtype = torch.uint8 if y_descr in ("|u1", "<u1") else (torch.int32 if y_descr == "<i4" else torch.int64)
    labels = torch.frombuffer(bytearray(y_raw), dtype=label_dtype).clone().reshape(y_shape)[:use_count].to(torch.long)
    images = image_tensor.to(torch.float32) / 255.0
    images = (images - 0.5) / 0.5
    return images, labels


def get_dataset(args: Any, *, default_split: str = "test") -> tuple[torch.Tensor, torch.Tensor, str]:
    if getattr(args, "smoke", False):
        count = int(getattr(args, "synthetic_count", 0) or 0)
    else:
        count = int(getattr(args, "count", 0) or 0)
    seed = int(getattr(args, "seed", 1))
    if getattr(args, "smoke", False):
        if count <= 0:
            raise ValueError("--smoke requires --synthetic-count > 0")
        return (*synthetic_cifar10(count, seed), "synthetic_smoke")

    split = getattr(args, "split", default_split)
    dataset_npz = getattr(args, "dataset_npz", "")
    if not dataset_npz:
        cifar10_tar = getattr(args, "cifar10_tar", CIFAR10_DEFAULT_TAR)
        images, labels = load_cifar10_tar(Path(cifar10_tar), count=count, split=split)
        return images, labels, f"cifar10_tar:{cifar10_tar}:{split}"
    images, labels = load_cifar10_npz(Path(dataset_npz), count=count, split=split)
    return images, labels, f"npz:{dataset_npz}:{split}"


def save_checkpoint(path: Path, model: nn.Module, metadata: dict[str, Any], extra: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        **metadata,
        **extra,
        "model_state_dict": model.state_dict(),
        "created_at": utc_now_iso(),
    }
    torch.save(payload, path)


def load_checkpoint(path: Path) -> tuple[CifarResNet20, dict[str, Any]]:
    payload = torch.load(path, map_location="cpu")
    if payload.get("arch") != ARCH:
        raise ValueError(f"unsupported checkpoint arch {payload.get('arch')!r}")
    model = CifarResNet20(num_classes=int(payload.get("num_classes", 10)))
    state = payload.get("model_state_dict")
    if not isinstance(state, dict):
        raise ValueError("checkpoint missing model_state_dict")
    model.load_state_dict(state)
    model.eval()
    return model, payload


def augment_cifar_batch(batch: torch.Tensor, generator: torch.Generator) -> torch.Tensor:
    """Apply deterministic CIFAR-style crop/flip augmentation to an NCHW batch."""

    padded = F.pad(batch, (4, 4, 4, 4), mode="constant", value=-1.0)
    augmented = torch.empty_like(batch)
    for idx in range(batch.shape[0]):
        top = int(torch.randint(0, 9, (1,), generator=generator).item())
        left = int(torch.randint(0, 9, (1,), generator=generator).item())
        cropped = padded[idx, :, top:top + 32, left:left + 32]
        if bool(torch.randint(0, 2, (1,), generator=generator).item()):
            cropped = torch.flip(cropped, dims=[2])
        augmented[idx] = cropped
    return augmented


@torch.no_grad()
def evaluate_model_detailed(
    model: nn.Module,
    images: torch.Tensor,
    labels: torch.Tensor,
    batch_size: int,
    device: str | torch.device = "cpu",
) -> dict[str, Any]:
    device_obj = torch.device(device)
    model.eval()
    model.to(device_obj)
    predicted: list[int] = []
    correct = 0
    per_class_correct = [0 for _ in range(10)]
    per_class_total = [0 for _ in range(10)]
    for start in range(0, images.shape[0], batch_size):
        xb = images[start:start + batch_size].to(device_obj)
        yb = labels[start:start + batch_size].to(device_obj)
        pred = model(xb).argmax(dim=1).cpu()
        y_cpu = yb.cpu()
        predicted.extend(int(v) for v in pred.tolist())
        correct += int((pred == y_cpu).sum().item())
        for label, pred_label in zip(y_cpu.tolist(), pred.tolist()):
            label_i = int(label)
            per_class_total[label_i] += 1
            if int(pred_label) == label_i:
                per_class_correct[label_i] += 1

    per_class_accuracy = [
        float(c / t) if t else 0.0
        for c, t in zip(per_class_correct, per_class_total)
    ]
    total = int(labels.numel())
    return {
        "total": total,
        "correct": correct,
        "accuracy": float(correct / total) if total else 0.0,
        "predicted_class": predicted,
        "label": [int(v) for v in labels.cpu().tolist()],
        "per_class_correct": per_class_correct,
        "per_class_total": per_class_total,
        "per_class_accuracy": per_class_accuracy,
    }


@torch.no_grad()
def evaluate_model(
    model: nn.Module,
    images: torch.Tensor,
    labels: torch.Tensor,
    batch_size: int,
    device: str | torch.device = "cpu",
) -> tuple[int, list[int]]:
    result = evaluate_model_detailed(model, images, labels, batch_size, device=device)
    return int(result["correct"]), list(result["predicted_class"])


def tensor_to_input_memh_words(image: torch.Tensor) -> list[str]:
    """Pack normalized CHW image into HWC little-endian 32-bit words.

    The smoke fixture uses int8 pixels derived from the normalized tensor.  This
    is a placeholder input packing contract for software smoke only; later R0.5
    work must freeze the real fixed-point CIFAR input contract.
    """

    dequant = torch.clamp(torch.round((image * 0.5 + 0.5) * 255.0), 0, 255).to(torch.int16)
    signed = torch.clamp(dequant - 128, -128, 127).to(torch.int16)
    hwc = signed.permute(1, 2, 0).contiguous()
    blob = bytearray((int(v.item()) & 0xFF) for v in hwc.flatten())
    while len(blob) % 4:
        blob.append(0)
    words = []
    for idx in range(0, len(blob), 4):
        word = blob[idx] | (blob[idx + 1] << 8) | (blob[idx + 2] << 16) | (blob[idx + 3] << 24)
        words.append(f"{word:08x}")
    return words
