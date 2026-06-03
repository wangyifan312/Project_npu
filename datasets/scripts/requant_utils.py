#!/usr/bin/env python3
"""Shared requant helpers for Python training/eval/fixture generation.

This module is the software reference for the RTL `requant_i32_to_i8` block:

    q = clamp(round_half_away_from_zero(acc * multiplier / 2^shift), -128, 127)
"""

from __future__ import annotations

from typing import Mapping

import torch


REQUANT_VERSION = "per_layer_i32_to_i8_v1"
REQUIRED_REQUANT_KEYS = ("conv2_in", "fc1_in", "fc2_in")


def default_requant_params() -> dict[str, dict[str, int]]:
    return {
        "conv2_in": {"multiplier": 1, "shift": 0},
        "fc1_in": {"multiplier": 1, "shift": 0},
        "fc2_in": {"multiplier": 1, "shift": 0},
    }


def normalize_requant_params(raw: Mapping[str, Mapping[str, int]] | None) -> dict[str, dict[str, int]]:
    params = default_requant_params()
    if raw is None:
        return params
    for key in REQUIRED_REQUANT_KEYS:
        if key in raw:
            params[key]["multiplier"] = int(raw[key].get("multiplier", params[key]["multiplier"]))
            params[key]["shift"] = int(raw[key].get("shift", params[key]["shift"]))
    return params


def round_half_away_from_zero(x: torch.Tensor) -> torch.Tensor:
    return torch.sign(x) * torch.floor(torch.abs(x) + 0.5)


def requantize_i32_to_i8(
    x: torch.Tensor,
    multiplier: int,
    shift: int,
    ste: bool = False,
) -> torch.Tensor:
    scaled = x * float(multiplier)
    if shift > 0:
        scaled = scaled / float(1 << shift)
    q = torch.clamp(round_half_away_from_zero(scaled), -128.0, 127.0)
    if ste:
        return x + (q - x).detach()
    return q
