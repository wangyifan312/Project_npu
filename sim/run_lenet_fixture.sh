#!/bin/bash
# run_lenet_fixture.sh — compile and run LeNet fixture-based network tests
set -euo pipefail

cd "$(dirname "$0")/.."

SIMDIR=sim
mkdir -p "$SIMDIR"

FIXTURE_DIR="${FIXTURE_DIR:-datasets/mnist/lenet_fixture}"
SAMPLE_NAME="${SAMPLE_NAME:-sample_00000_label_7}"
SIMULATOR="${SIMULATOR:-vcs}"
PROGRESS="${PROGRESS:-0}"

IVERILOG="iverilog -DNO_DUMP -g2012 -I rtl/npu -I rtl/soc -I rtl/bus -I tb/integration"
RTL_SOURCES="rtl/npu/*.v rtl/soc/axi4_ram.v tb/integration/tb_lenet_network.v"
VCS_BIN="${VCS_BIN:-vcs}"

compile_iverilog() {
    $IVERILOG -o "$SIMDIR/tb_lenet_network.vvp" $RTL_SOURCES
}

compile_vcs() {
    $VCS_BIN -full64 -sverilog -timescale=1ns/1ps \
        -o "$SIMDIR/simv_lenet" \
        +incdir+rtl/npu +incdir+rtl/soc +incdir+rtl/bus +incdir+tb/integration \
        $RTL_SOURCES
}

compile() {
    case "$SIMULATOR" in
        iverilog) compile_iverilog ;;
        vcs)      compile_vcs ;;
        *) echo "Unsupported SIMULATOR=$SIMULATOR"; exit 1 ;;
    esac
}

run_one() {
    local sample="$1"
    case "$SIMULATOR" in
        iverilog)
            timeout "${TIMEOUT_SECS:-600}s" \
                vvp "$SIMDIR/tb_lenet_network.vvp" \
                +fixture_dir="$FIXTURE_DIR" \
                +sample_name="$sample" \
                +progress="$PROGRESS"
            ;;
        vcs)
            timeout "${TIMEOUT_SECS:-600}s" \
                "$SIMDIR/simv_lenet" \
                +fixture_dir="$FIXTURE_DIR" \
                +sample_name="$sample" \
                +progress="$PROGRESS"
            ;;
    esac
}

run_all() {
    python3 - <<'PY' "$FIXTURE_DIR/manifest.json" > "$SIMDIR/.lenet_samples.txt"
import json, sys, pathlib
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
for entry in manifest:
    print(entry["dir"])
PY
    while IFS= read -r sample; do
        echo "=== $sample ==="
        run_one "$sample"
    done < "$SIMDIR/.lenet_samples.txt"
}

case "${1:-}" in
    compile)
        compile
        ;;
    sample)
        compile
        run_one "$SAMPLE_NAME"
        ;;
    all)
        compile
        run_all
        ;;
    *)
        echo "Usage: $0 {compile|sample|all}"
        echo "  FIXTURE_DIR=<dir>   fixture root (default: datasets/mnist/lenet_fixture)"
        echo "  SAMPLE_NAME=<dir>   sample dir for 'sample' mode"
        echo "  SIMULATOR=<vcs|iverilog>   simulator backend (default: vcs)"
        echo "  PROGRESS=<0|1>      enable layer progress prints (default: 0)"
        echo "  TIMEOUT_SECS=<n>    per-sample timeout (default: 600)"
        exit 1
        ;;
esac
