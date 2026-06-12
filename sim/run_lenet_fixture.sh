#!/bin/bash
# run_lenet_fixture.sh — compile and run LeNet subsystem tests / full-eval batches
set -euo pipefail

cd "$(dirname "$0")/.."

SIMDIR=sim
mkdir -p "$SIMDIR"

FIXTURE_DIR="${FIXTURE_DIR:-datasets/mnist/lenet_fixture}"
MANIFEST_PATH="${MANIFEST_PATH:-$FIXTURE_DIR/manifest.json}"
SAMPLE_ROOT_DIR="${SAMPLE_ROOT_DIR:-$FIXTURE_DIR}"
WEIGHTS_ROOT_DIR="${WEIGHTS_ROOT_DIR:-$FIXTURE_DIR/weights}"
SAMPLE_NAME="${SAMPLE_NAME:-sample_00000_label_7}"
SIMULATOR="${SIMULATOR:-vcs}"
PROGRESS="${PROGRESS:-0}"
INPUT_MEMH_NAME="${INPUT_MEMH_NAME:-input.memh}"
EXPECTED_FILE_NAME="${EXPECTED_FILE_NAME:-argmax.txt}"
EXPECTED_MANIFEST_FIELD="${EXPECTED_MANIFEST_FIELD:-}"
EVAL_MODE="${EVAL_MODE:-0}"
SKIP_PERF_READS="${SKIP_PERF_READS:-0}"
COUNT="${COUNT:-0}"
OFFSET="${OFFSET:-0}"
VERBOSE_LIMIT="${VERBOSE_LIMIT:-16}"
STOP_AFTER_LAYER="${STOP_AFTER_LAYER:-}"
RESULTS_DIR="${RESULTS_DIR:-}"
RUN_LABEL="${RUN_LABEL:-subsystem}"
RQ_CONV2_MULT="${RQ_CONV2_MULT:-}"
RQ_CONV2_SHIFT="${RQ_CONV2_SHIFT:-}"
RQ_FC1_MULT="${RQ_FC1_MULT:-}"
RQ_FC1_SHIFT="${RQ_FC1_SHIFT:-}"
RQ_FC2_MULT="${RQ_FC2_MULT:-}"
RQ_FC2_SHIFT="${RQ_FC2_SHIFT:-}"
IVERILOG="iverilog -DNO_DUMP -g2012 -I rtl/npu -I rtl/soc -I rtl/bus -I tb/integration"
RTL_SOURCES="rtl/npu/*.v rtl/soc/axi4_ram.v tb/integration/tb_lenet_network.v"
VCS_BIN="${VCS_BIN:-vcs}"

resolve_requant_params() {
    python3 - <<'PY' "$FIXTURE_DIR/summary.json" "$WEIGHTS_ROOT_DIR/summary.json" \
        "$RQ_CONV2_MULT" "$RQ_CONV2_SHIFT" "$RQ_FC1_MULT" "$RQ_FC1_SHIFT" "$RQ_FC2_MULT" "$RQ_FC2_SHIFT"
import json, pathlib, sys
summary_paths = [pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])]
values = {
    "conv2_mult": sys.argv[3],
    "conv2_shift": sys.argv[4],
    "fc1_mult": sys.argv[5],
    "fc1_shift": sys.argv[6],
    "fc2_mult": sys.argv[7],
    "fc2_shift": sys.argv[8],
}
params = None
for path in summary_paths:
    if path.exists():
        data = json.loads(path.read_text())
        params = data.get("requant_params")
        if params:
            break
def pick(name, key, subkey, default):
    if values[name] != "":
        return values[name]
    if params and key in params:
        return str(int(params[key].get(subkey, default)))
    return str(default)
print(pick("conv2_mult", "conv2_in", "multiplier", 1))
print(pick("conv2_shift", "conv2_in", "shift", 0))
print(pick("fc1_mult", "fc1_in", "multiplier", 1))
print(pick("fc1_shift", "fc1_in", "shift", 0))
print(pick("fc2_mult", "fc2_in", "multiplier", 1))
print(pick("fc2_shift", "fc2_in", "shift", 0))
PY
}

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

apply_accuracy_only_defaults() {
    if [[ "${ACCURACY_ONLY:-0}" == "1" ]]; then
        EVAL_MODE="1"
        PROGRESS="0"
        VERBOSE_LIMIT="0"
        if [[ "$RUN_LABEL" == "subsystem" ]]; then
            RUN_LABEL="subsystem_accuracy_only"
        fi
    fi
}

load_requant_defaults() {
    local rq_vals
    mapfile -t rq_vals < <(resolve_requant_params)
    RQ_CONV2_MULT="${rq_vals[0]}"
    RQ_CONV2_SHIFT="${rq_vals[1]}"
    RQ_FC1_MULT="${rq_vals[2]}"
    RQ_FC1_SHIFT="${rq_vals[3]}"
    RQ_FC2_MULT="${rq_vals[4]}"
    RQ_FC2_SHIFT="${rq_vals[5]}"
}

run_one() {
    local sample="$1"
    local ordinal="$2"
    local expected_override="${3:--1}"
    case "$SIMULATOR" in
        iverilog)
            timeout "${TIMEOUT_SECS:-600}s" \
                vvp "$SIMDIR/tb_lenet_network.vvp" \
                +fixture_dir="$FIXTURE_DIR" \
                +sample_name="$sample" \
                +sample_root_dir="$SAMPLE_ROOT_DIR" \
                +weights_root_dir="$WEIGHTS_ROOT_DIR" \
                +input_memh_name="$INPUT_MEMH_NAME" \
                +expected_file_name="$EXPECTED_FILE_NAME" \
                +expected_class_override="$expected_override" \
                +eval_mode="$EVAL_MODE" \
                +skip_perf_reads="$SKIP_PERF_READS" \
                +rq_conv2_mult="$RQ_CONV2_MULT" \
                +rq_conv2_shift="$RQ_CONV2_SHIFT" \
                +rq_fc1_mult="$RQ_FC1_MULT" \
                +rq_fc1_shift="$RQ_FC1_SHIFT" \
                +rq_fc2_mult="$RQ_FC2_MULT" \
                +rq_fc2_shift="$RQ_FC2_SHIFT" \
                +sample_ordinal="$ordinal" \
                +verbose_limit="$VERBOSE_LIMIT" \
                +progress="$PROGRESS" \
                +stop_after_layer="$STOP_AFTER_LAYER"
            ;;
        vcs)
            timeout "${TIMEOUT_SECS:-600}s" \
                "$SIMDIR/simv_lenet" \
                +fixture_dir="$FIXTURE_DIR" \
                +sample_name="$sample" \
                +sample_root_dir="$SAMPLE_ROOT_DIR" \
                +weights_root_dir="$WEIGHTS_ROOT_DIR" \
                +input_memh_name="$INPUT_MEMH_NAME" \
                +expected_file_name="$EXPECTED_FILE_NAME" \
                +expected_class_override="$expected_override" \
                +eval_mode="$EVAL_MODE" \
                +skip_perf_reads="$SKIP_PERF_READS" \
                +rq_conv2_mult="$RQ_CONV2_MULT" \
                +rq_conv2_shift="$RQ_CONV2_SHIFT" \
                +rq_fc1_mult="$RQ_FC1_MULT" \
                +rq_fc1_shift="$RQ_FC1_SHIFT" \
                +rq_fc2_mult="$RQ_FC2_MULT" \
                +rq_fc2_shift="$RQ_FC2_SHIFT" \
                +sample_ordinal="$ordinal" \
                +verbose_limit="$VERBOSE_LIMIT" \
                +progress="$PROGRESS" \
                +stop_after_layer="$STOP_AFTER_LAYER"
            ;;
    esac
}

manifest_expected() {
    local sample="$1"
    if [[ -z "$EXPECTED_MANIFEST_FIELD" ]]; then
        echo "-1"
        return
    fi
    python3 - <<'PY' "$MANIFEST_PATH" "$sample" "$EXPECTED_MANIFEST_FIELD"
import json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
sample = sys.argv[2]
field = sys.argv[3]
for entry in manifest:
    if entry.get("dir") == sample:
        if field not in entry:
            raise SystemExit(f"manifest entry for {sample} lacks {field}")
        print(int(entry[field]))
        break
else:
    raise SystemExit(f"sample {sample} not found in manifest")
PY
}

manifest_samples() {
    python3 - <<'PY' "$MANIFEST_PATH" "$COUNT" "$OFFSET"
import json, sys, pathlib
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
count = int(sys.argv[2])
offset = int(sys.argv[3])
manifest = manifest[offset:]
if count > 0:
    manifest = manifest[:count]
for entry in manifest:
    print(entry["dir"])
PY
}

manifest_count() {
    python3 - <<'PY' "$MANIFEST_PATH" "$COUNT" "$OFFSET"
import json, sys, pathlib
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
count = int(sys.argv[2])
offset = int(sys.argv[3])
manifest = manifest[offset:]
if count > 0:
    manifest = manifest[:count]
print(len(manifest))
PY
}

append_csv_row() {
    local line="$1"
    local csv_path="$2"
    python3 - <<'PY' "$line" "$csv_path"
import csv, os, re, sys
line = sys.argv[1]
csv_path = sys.argv[2]
fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
fieldnames = [
    "sample_name", "expected", "predicted", "status", "pass_fail",
    "total_cycles", "total_mac", "total_read_beats", "total_write_beats",
    "total_read_active", "total_write_active",
    "total_array_active", "total_array_stall", "total_cluster_active", "total_cluster_stall",
]
exists = os.path.exists(csv_path)
with open(csv_path, "a", newline="", encoding="ascii") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    if not exists:
        writer.writeheader()
    writer.writerow({
        "sample_name": fields.get("sample", ""),
        "expected": fields.get("expected", ""),
        "predicted": fields.get("predicted", ""),
        "status": fields.get("status", "FAIL"),
        "pass_fail": "1" if fields.get("status") == "PASS" else "0",
        "total_cycles": fields.get("total_cycles", "0"),
        "total_mac": fields.get("total_mac", "0"),
        "total_read_beats": fields.get("total_read_beats", "0"),
        "total_write_beats": fields.get("total_write_beats", "0"),
        "total_read_active": fields.get("total_read_active", "0"),
        "total_write_active": fields.get("total_write_active", "0"),
        "total_array_active": fields.get("total_array_active", "0"),
        "total_array_stall": fields.get("total_array_stall", "0"),
        "total_cluster_active": fields.get("total_cluster_active", "0"),
        "total_cluster_stall": fields.get("total_cluster_stall", "0"),
    })
PY
}

write_summary() {
    local csv_path="$1"
    local summary_json="$2"
    local summary_md="$3"
    local total_target="$4"
    local manifest_path="$5"
    python3 - <<'PY' "$csv_path" "$summary_json" "$summary_md" "$total_target" "$manifest_path" "$RUN_LABEL" "$SIMULATOR" "$EVAL_MODE"
import csv, json, pathlib, sys
csv_path = pathlib.Path(sys.argv[1])
summary_json = pathlib.Path(sys.argv[2])
summary_md = pathlib.Path(sys.argv[3])
total_target = int(sys.argv[4])
manifest_path = sys.argv[5]
run_label = sys.argv[6]
simulator = sys.argv[7]
eval_mode = int(sys.argv[8])

rows = list(csv.DictReader(csv_path.open()))
total = len(rows)
correct = sum(1 for r in rows if r["status"] == "PASS")
sum_cycles = sum(int(r["total_cycles"] or 0) for r in rows)
sum_mac = sum(int(r["total_mac"] or 0) for r in rows)
sum_read_beats = sum(int(r["total_read_beats"] or 0) for r in rows)
sum_write_beats = sum(int(r["total_write_beats"] or 0) for r in rows)
sum_read_active = sum(int(r.get("total_read_active", "0") or 0) for r in rows)
sum_write_active = sum(int(r.get("total_write_active", "0") or 0) for r in rows)
sum_array_active = sum(int(r["total_array_active"] or 0) for r in rows)
sum_array_stall = sum(int(r["total_array_stall"] or 0) for r in rows)
sum_cluster_active = sum(int(r["total_cluster_active"] or 0) for r in rows)
sum_cluster_stall = sum(int(r["total_cluster_stall"] or 0) for r in rows)

summary = {
    "level": "subsystem",
    "run_label": run_label,
    "simulator": simulator,
    "eval_mode": eval_mode,
    "manifest_path": manifest_path,
    "target_total": total_target,
    "total": total,
    "correct": correct,
    "accuracy": (correct / total) if total else 0.0,
    "total_cycles": sum_cycles,
    "avg_cycles": (sum_cycles / total) if total else 0.0,
    "total_mac": sum_mac,
    "avg_mac": (sum_mac / total) if total else 0.0,
    "total_read_beats": sum_read_beats,
    "avg_read_beats": (sum_read_beats / total) if total else 0.0,
    "total_write_beats": sum_write_beats,
    "avg_write_beats": (sum_write_beats / total) if total else 0.0,
    "beat_bytes": 32,
    "total_read_bytes": sum_read_beats * 32,
    "total_write_bytes": sum_write_beats * 32,
    "total_read_active": sum_read_active,
    "total_write_active": sum_write_active,
    "avg_read_bw_util": (sum_read_beats / sum_read_active) if sum_read_active else 0.0,
    "avg_write_bw_util": (sum_write_beats / sum_write_active) if sum_write_active else 0.0,
    "total_array_active": sum_array_active,
    "total_array_stall": sum_array_stall,
    "total_cluster_active": sum_cluster_active,
    "total_cluster_stall": sum_cluster_stall,
    "avg_array_util": (sum_array_active / sum_cycles) if sum_cycles else 0.0,
    "avg_cluster_util": (sum_cluster_active / sum_cycles) if sum_cycles else 0.0,
}
summary_json.write_text(json.dumps(summary, indent=2) + "\n", encoding="ascii")
summary_md.write_text(
    "\n".join([
        "# MNIST Full Eval Summary",
        "",
        f"- level: `subsystem`",
        f"- run_label: `{run_label}`",
        f"- simulator: `{simulator}`",
        f"- eval_mode: `{eval_mode}`",
        f"- manifest: `{manifest_path}`",
        "",
        "| Metric | Value |",
        "| --- | ---: |",
        f"| target_total | {total_target} |",
        f"| total | {total} |",
        f"| correct | {correct} |",
        f"| accuracy | {summary['accuracy']:.6f} |",
        f"| total_cycles | {sum_cycles} |",
        f"| avg_cycles | {summary['avg_cycles']:.2f} |",
        f"| total_mac | {sum_mac} |",
        f"| avg_mac | {summary['avg_mac']:.2f} |",
        f"| total_read_beats | {sum_read_beats} |",
        f"| total_write_beats | {sum_write_beats} |",
        f"| beat_bytes | 32 |",
        f"| total_read_bytes | {sum_read_beats * 32} |",
        f"| total_write_bytes | {sum_write_beats * 32} |",
        f"| total_read_active | {sum_read_active} |",
        f"| total_write_active | {sum_write_active} |",
        f"| avg_read_bw_util | {summary['avg_read_bw_util']:.6f} |",
        f"| avg_write_bw_util | {summary['avg_write_bw_util']:.6f} |",
        f"| avg_array_util | {summary['avg_array_util']:.6f} |",
        f"| avg_cluster_util | {summary['avg_cluster_util']:.6f} |",
        "",
    ]) + "\n",
    encoding="ascii",
)
print(json.dumps(summary))
PY
}

run_batch() {
    local target_total
    local csv_path=""
    local summary_json=""
    local summary_md=""
    local tmp_log
    local result_line
    local ordinal=0
    local run_rc=0

    target_total="$(manifest_count)"

    if [[ -n "$RESULTS_DIR" ]]; then
        mkdir -p "$RESULTS_DIR"
        csv_path="$RESULTS_DIR/per_sample.csv"
        summary_json="$RESULTS_DIR/summary.json"
        summary_md="$RESULTS_DIR/perf_summary.md"
        rm -f "$csv_path" "$summary_json" "$summary_md"
    fi

    while IFS= read -r sample; do
        echo "=== $sample ==="
        tmp_log="$(mktemp)"
        run_rc=0
        if run_one "$sample" "$ordinal" "$(manifest_expected "$sample")" | tee "$tmp_log"; then
            run_rc=0
        else
            run_rc=$?
        fi
        result_line="$(grep '^SUBSYS_RESULT ' "$tmp_log" | tail -n1 || true)"
        if [[ -z "$result_line" ]]; then
            rm -f "$tmp_log"
            echo "ERROR: subsystem simulation aborted before producing SUBSYS_RESULT for $sample" >&2
            return "${run_rc:-1}"
        fi
        if [[ -n "$csv_path" ]]; then
            append_csv_row "$result_line" "$csv_path"
        fi
        rm -f "$tmp_log"
        ordinal=$((ordinal + 1))
    done < <(manifest_samples)

    if [[ -n "$csv_path" ]]; then
        write_summary "$csv_path" "$summary_json" "$summary_md" "$target_total" "$MANIFEST_PATH"
    fi
}

case "${1:-}" in
    compile)
        apply_accuracy_only_defaults
        load_requant_defaults
        compile
        ;;
    sample)
        apply_accuracy_only_defaults
        load_requant_defaults
        compile
        run_one "$SAMPLE_NAME" 0 "$(manifest_expected "$SAMPLE_NAME")"
        ;;
    batch)
        apply_accuracy_only_defaults
        load_requant_defaults
        compile
        run_batch
        ;;
    all)
        apply_accuracy_only_defaults
        load_requant_defaults
        compile
        COUNT=0
        OFFSET=0
        run_batch
        ;;
    *)
        echo "Usage: $0 {compile|sample|batch|all}"
        echo "  FIXTURE_DIR=<dir>       fixture root"
        echo "  MANIFEST_PATH=<path>    manifest json (default: \$FIXTURE_DIR/manifest.json)"
        echo "  SAMPLE_ROOT_DIR=<dir>   sample data root (default: \$FIXTURE_DIR)"
        echo "  WEIGHTS_ROOT_DIR=<dir>  weight memh root (default: \$FIXTURE_DIR/weights)"
        echo "  INPUT_MEMH_NAME=<name>  sample input memh file (default: input.memh)"
        echo "  EXPECTED_FILE_NAME=<name> expected label/prediction file (default: argmax.txt)"
        echo "  EXPECTED_MANIFEST_FIELD=<field> use manifest field as expected class"
        echo "  EVAL_MODE=<0|1>         0=strict golden compare, 1=classification/perf eval only"
        echo "  SKIP_PERF_READS=<0|1>   skip layer-end perf register reads inside testbench"
        echo "  STOP_AFTER_LAYER=<name> stop after conv1/pool1/conv2/pool2/fc1/fc2 and print cumulative perf"
        echo "  RQ_* overrides          requant params; default from fixture summary.json"
        echo "  ACCURACY_ONLY=<0|1>     force eval-mode defaults; perf reads stay enabled unless SKIP_PERF_READS=1"
        echo "  COUNT=<n> OFFSET=<n>    slicing for batch mode"
        echo "  RESULTS_DIR=<dir>       emit per_sample.csv / summary.json / perf_summary.md"
        echo "  SIMULATOR=<vcs|iverilog> PROGRESS=<0|1> VERBOSE_LIMIT=<n>"
        exit 1
        ;;
esac
