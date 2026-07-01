# NPU Tile Pipeline — Phase 5-3 Output Tile Descriptor Baseline

## Metadata

- **Commit**: `d5fc5be`
- **Base**: main `070cf26`
- **Date**: 2026-07-02
- **Status**: **OUTPUT TILE DESCRIPTOR FORMALIZED**

## Base

| Phase | Commit | Description |
|-------|--------|-------------|
| Phase 4c-1 | `dfdf2a5` | c_tile double buffer |
| Phase 5-1 | — | M-tiling |
| Phase 5-2 | `c2e915f` | N-tiling |
| Phase 5-3 | `d5fc5be` | Output tile descriptor |

## What Phase 5-3 Implements

- `out_tile_m_base/n_base/M/N/base_addr/row_stride` — live compute descriptor
- `store_desc_*` — locked at STORE start
- STORE pack uses `store_desc_*` (not live tile signals)
- No behavioral change; STORE remains sequential

## Store Descriptor Fields

```
store_desc_m_base/n_base — tile global row/col start
store_desc_M/N           — tile dimensions
store_desc_base_addr     — blk_out_addr
store_desc_row_stride    — align32(gemm_N_val * 4)
store_desc_bank          — c_tile bank to read
```

Locked in `FSM_GEMM_STREAM_DONE` (all K chunks done).

## Address Formulas (unchanged)

STORE: `store_desc_base_addr + (store_desc_m_base + local_row) * store_desc_row_stride + store_desc_n_base * 4`

## Verified

```
RS0-RS19 + MT0-MT5 + NT0-NT6: 37/37 PASS
GEMM_FUNC: 6/6 PASS, 7/7 PASS
UVM_ERROR: 0, UVM_FATAL: 0
```

## Next Step

DMA writer / STORE protocol audit → Phase 4c-2 background STORE engine.
