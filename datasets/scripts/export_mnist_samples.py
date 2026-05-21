#!/usr/bin/env python3
"""Export MNIST test samples without external Python dependencies.

Reads Keras/TensorFlow `mnist.npz` using only the standard library and exports:
- raw 28x28 uint8 bytes
- centered int8 bytes (pixel - 128)
- packed 32-bit little-endian memh
- label text
- metadata json
"""

from __future__ import annotations

import argparse
import ast
import json
import subprocess
import struct
import zipfile
from pathlib import Path


def load_npy_from_bytes(blob: bytes) -> tuple[tuple[int, ...], bytes]:
    if blob[:6] != b"\x93NUMPY":
        raise ValueError("invalid npy magic")

    major = blob[6]
    minor = blob[7]
    if major == 1:
        header_len = struct.unpack("<H", blob[8:10])[0]
        header_start = 10
    elif major == 2:
        header_len = struct.unpack("<I", blob[8:12])[0]
        header_start = 12
    else:
        raise ValueError(f"unsupported npy version {major}.{minor}")

    header_end = header_start + header_len
    header = blob[header_start:header_end].decode("latin1").strip()
    meta = ast.literal_eval(header)

    descr = meta["descr"]
    if descr not in ("|u1", "<u1"):
        raise ValueError(f"unsupported dtype {descr}, expected uint8")
    if meta["fortran_order"]:
        raise ValueError("fortran-order arrays are not supported")

    shape = meta["shape"]
    if not isinstance(shape, tuple):
        raise ValueError("invalid shape in npy header")

    return shape, blob[header_end:]


def load_mnist_npz(path: Path) -> tuple[bytes, bytes, tuple[int, ...], tuple[int, ...]]:
    with zipfile.ZipFile(path, "r") as zf:
        x_test_shape, x_test_raw = load_npy_from_bytes(zf.read("x_test.npy"))
        y_test_shape, y_test_raw = load_npy_from_bytes(zf.read("y_test.npy"))
    return x_test_raw, y_test_raw, x_test_shape, y_test_shape


def export_sample(out_dir: Path, index: int, image: bytes, label: int, shape: tuple[int, ...]) -> None:
    sample_dir = out_dir / f"sample_{index:05d}_label_{label}"
    sample_dir.mkdir(parents=True, exist_ok=True)

    centered = bytes(((b - 128) & 0xFF) for b in image)

    (sample_dir / "image_u8.bin").write_bytes(image)
    (sample_dir / "image_i8.bin").write_bytes(centered)
    (sample_dir / "label.txt").write_text(f"{label}\n", encoding="ascii")

    pack_script = Path(__file__).with_name("pack_bytes_to_memh.py")
    subprocess.run(
        [
            "python3",
            str(pack_script),
            str(sample_dir / "image_i8.bin"),
            "--output-dir",
            str(sample_dir),
            "--base-addr",
            "0x00000100",
        ],
        check=True,
    )

    meta = {
        "index": index,
        "label": label,
        "shape": list(shape),
        "u8_min": min(image),
        "u8_max": max(image),
        "i8_min": min((b - 256) if b >= 128 else b for b in centered),
        "i8_max": max((b - 256) if b >= 128 else b for b in centered),
    }
    (sample_dir / "meta.json").write_text(
        json.dumps(meta, indent=2, sort_keys=True) + "\n",
        encoding="ascii",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Export MNIST test samples")
    parser.add_argument("--input", default="datasets/mnist/mnist.npz", help="Path to mnist.npz")
    parser.add_argument("--output-dir", default="datasets/mnist/exports", help="Output directory")
    parser.add_argument("--count", type=int, default=16, help="Number of test samples to export")
    parser.add_argument("--offset", type=int, default=0, help="Starting test-set index")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_dir = Path(args.output_dir)
    if not input_path.exists():
        raise FileNotFoundError(f"MNIST file not found: {input_path}")

    x_test_raw, y_test_raw, x_test_shape, y_test_shape = load_mnist_npz(input_path)
    if len(x_test_shape) != 3:
        raise ValueError(f"unexpected x_test shape: {x_test_shape}")
    if len(y_test_shape) != 1:
        raise ValueError(f"unexpected y_test shape: {y_test_shape}")

    sample_count, height, width = x_test_shape
    sample_size = height * width
    label_count = y_test_shape[0]
    if label_count != sample_count:
        raise ValueError("image/label count mismatch")

    output_dir.mkdir(parents=True, exist_ok=True)
    end = min(args.offset + args.count, sample_count)

    manifest = []
    for idx in range(args.offset, end):
        start = idx * sample_size
        stop = start + sample_size
        image = x_test_raw[start:stop]
        label = y_test_raw[idx]
        export_sample(output_dir, idx, image, label, (height, width))
        manifest.append(
            {
                "index": idx,
                "label": int(label),
                "dir": f"sample_{idx:05d}_label_{int(label)}",
            }
        )

    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="ascii",
    )
    print(f"exported {len(manifest)} MNIST test samples to {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
