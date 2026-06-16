#!/usr/bin/env bash
# W3 subsystem full-set chunk runner.
#
# This is a driver around sim/run_lenet_fixture.sh. It does not change the
# formal subsystem replay semantics; it only slices the 10000-sample manifest
# into independently resumable chunks.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_ROOT="${OUT_ROOT:-results/w3_subsystem_full_10000_candidate_final_chunked}"
CHUNK_SIZE="${CHUNK_SIZE:-250}"
START_CHUNK="${START_CHUNK:-0}"
NUM_CHUNKS="${NUM_CHUNKS:-1}"
FORCE="${FORCE:-0}"

SIMULATOR="${SIMULATOR:-vcs}"
TIMEOUT_SECS="${TIMEOUT_SECS:-900}"
FIXTURE_DIR="${FIXTURE_DIR:-datasets/mnist/lenet_requant_candidate_final_manifest_10000}"
MANIFEST_PATH="${MANIFEST_PATH:-datasets/mnist/lenet_requant_candidate_final_manifest_10000/manifest.json}"
SAMPLE_ROOT_DIR="${SAMPLE_ROOT_DIR:-datasets/mnist/exports_full_10000}"
WEIGHTS_ROOT_DIR="${WEIGHTS_ROOT_DIR:-datasets/mnist/lenet_requant_candidate_final_manifest_10000/weights}"
INPUT_MEMH_NAME="${INPUT_MEMH_NAME:-packed_words.memh}"
EXPECTED_FILE_NAME="${EXPECTED_FILE_NAME:-label.txt}"

manifest_count() {
    python3 - <<'PY' "$MANIFEST_PATH"
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(len(data))
PY
}

chunk_complete() {
    local summary_json="$1"
    local expected_total="$2"
    [[ -f "$summary_json" ]] || return 1
    python3 - <<'PY' "$summary_json" "$expected_total"
import json, pathlib, sys
summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected_total = int(sys.argv[2])
raise SystemExit(0 if int(summary.get("total", -1)) == expected_total else 1)
PY
}

usage() {
    cat <<'EOF'
Usage:
  scripts/run_w3_subsystem_chunked.sh

Key environment variables:
  OUT_ROOT=<dir>       output root (default: results/w3_subsystem_full_10000_candidate_final_chunked)
  CHUNK_SIZE=<n>       samples per chunk (default: 250)
  START_CHUNK=<n>      first chunk index (default: 0)
  NUM_CHUNKS=<n|all>   number of chunks to run (default: 1)
  FORCE=1             rerun completed chunks

The default W3 full-set path uses candidate-final assets:
  FIXTURE_DIR=datasets/mnist/lenet_requant_candidate_final_manifest_10000
  WEIGHTS_ROOT_DIR=datasets/mnist/lenet_requant_candidate_final_manifest_10000/weights
  MANIFEST_PATH=datasets/mnist/lenet_requant_candidate_final_manifest_10000/manifest.json
  SAMPLE_ROOT_DIR=datasets/mnist/exports_full_10000
  EXPECTED_FILE_NAME=label.txt

Expected class is the real MNIST label for final accuracy. Use
EXPECTED_MANIFEST_FIELD=predicted_class only for RTL/software replay alignment,
not for final full-set accuracy.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if (( CHUNK_SIZE <= 0 )); then
    echo "CHUNK_SIZE must be positive" >&2
    exit 1
fi

total_samples="$(manifest_count)"
total_chunks=$(( (total_samples + CHUNK_SIZE - 1) / CHUNK_SIZE ))

if [[ "$NUM_CHUNKS" == "all" ]]; then
    end_chunk="$total_chunks"
else
    end_chunk=$(( START_CHUNK + NUM_CHUNKS ))
fi
if (( START_CHUNK < 0 || START_CHUNK >= total_chunks )); then
    echo "START_CHUNK=$START_CHUNK out of range 0..$((total_chunks - 1))" >&2
    exit 1
fi
if (( end_chunk > total_chunks )); then
    end_chunk="$total_chunks"
fi

mkdir -p "$OUT_ROOT"

cat > "$OUT_ROOT/chunk_config.json" <<EOF
{
  "level": "subsystem",
  "total_samples": $total_samples,
  "chunk_size": $CHUNK_SIZE,
  "total_chunks": $total_chunks,
  "manifest_path": "$MANIFEST_PATH",
  "sample_root_dir": "$SAMPLE_ROOT_DIR",
  "weights_root_dir": "$WEIGHTS_ROOT_DIR",
  "expected_source": "sample label.txt",
  "checkpoint": "datasets/mnist/models/mnist_lenet_soc6_requant_candidate_final.pt",
  "accuracy_only": 1,
  "skip_perf_reads": 1
}
EOF

echo "W3 subsystem chunked run: total_samples=$total_samples chunk_size=$CHUNK_SIZE total_chunks=$total_chunks range=$START_CHUNK..$((end_chunk - 1))"

for ((chunk_idx = START_CHUNK; chunk_idx < end_chunk; chunk_idx++)); do
    offset=$(( chunk_idx * CHUNK_SIZE ))
    count="$CHUNK_SIZE"
    if (( offset + count > total_samples )); then
        count=$(( total_samples - offset ))
    fi
    last=$(( offset + count - 1 ))
    chunk_dir="$OUT_ROOT/chunk_$(printf '%05d_%05d' "$offset" "$last")"
    summary_json="$chunk_dir/summary.json"

    if [[ "$FORCE" != "1" ]] && chunk_complete "$summary_json" "$count"; then
        echo "SKIP chunk=$chunk_idx offset=$offset count=$count dir=$chunk_dir"
        continue
    fi

    mkdir -p "$chunk_dir"
    echo "RUN chunk=$chunk_idx offset=$offset count=$count dir=$chunk_dir"
    date -Is > "$chunk_dir/started_at.txt"

    SIMULATOR="$SIMULATOR" \
    ACCURACY_ONLY=1 \
    SKIP_PERF_READS=1 \
    TIMEOUT_SECS="$TIMEOUT_SECS" \
    RUN_LABEL="w3_subsystem_full_chunk_${offset}_${last}" \
    RESULTS_DIR="$chunk_dir" \
    COUNT="$count" \
    OFFSET="$offset" \
    FIXTURE_DIR="$FIXTURE_DIR" \
    MANIFEST_PATH="$MANIFEST_PATH" \
    SAMPLE_ROOT_DIR="$SAMPLE_ROOT_DIR" \
    WEIGHTS_ROOT_DIR="$WEIGHTS_ROOT_DIR" \
    INPUT_MEMH_NAME="$INPUT_MEMH_NAME" \
    EXPECTED_FILE_NAME="$EXPECTED_FILE_NAME" \
    bash sim/run_lenet_fixture.sh batch 2>&1 | tee "$chunk_dir/run.log"

    date -Is > "$chunk_dir/finished_at.txt"
done
