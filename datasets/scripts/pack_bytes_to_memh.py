#!/usr/bin/env python3
"""Pack a byte stream into 32-bit little-endian MEMH words.

Outputs:
- packed_words.memh : one 32-bit word per line
- preload_map.txt   : "<addr> <word>" per line
"""

from __future__ import annotations

import argparse
from pathlib import Path


def pack_le_words(blob: bytes) -> list[int]:
    words = []
    for i in range(0, len(blob), 4):
        chunk = blob[i:i + 4]
        padded = chunk + b"\x00" * (4 - len(chunk))
        word = padded[0] | (padded[1] << 8) | (padded[2] << 16) | (padded[3] << 24)
        words.append(word)
    return words


def main() -> int:
    parser = argparse.ArgumentParser(description="Pack bytes into 32-bit little-endian MEMH words")
    parser.add_argument("input", help="Input byte file")
    parser.add_argument("--output-dir", required=True, help="Output directory")
    parser.add_argument("--base-addr", default="0x00000100", help="Base address for preload_map.txt")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_dir = Path(args.output_dir)
    base_addr = int(args.base_addr, 0)

    blob = input_path.read_bytes()
    words = pack_le_words(blob)

    output_dir.mkdir(parents=True, exist_ok=True)
    memh_path = output_dir / "packed_words.memh"
    preload_path = output_dir / "preload_map.txt"

    with memh_path.open("w", encoding="ascii") as f:
        for word in words:
            f.write(f"{word:08x}\n")

    with preload_path.open("w", encoding="ascii") as f:
        for idx, word in enumerate(words):
            f.write(f"{base_addr + idx * 4:08x} {word:08x}\n")

    print(f"packed {len(blob)} bytes into {len(words)} words")
    print(memh_path)
    print(preload_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
