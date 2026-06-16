#!/usr/bin/env bash
# Formal W3 candidate-final subsystem full-set entry.
#
# User-facing goal: one command starts/resumes the complete 10000-sample run.
# Implementation goal: keep the resumable chunk workflow underneath.
set -euo pipefail

cd "$(dirname "$0")/.."

ACTION="${1:-run}"

OUT_ROOT="${OUT_ROOT:-results/w3_subsystem_full_10000_candidate_final_chunked}"
CHUNK_SIZE="${CHUNK_SIZE:-250}"
START_CHUNK="${START_CHUNK:-0}"
NUM_CHUNKS="${NUM_CHUNKS:-all}"
FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"

SIMULATOR="${SIMULATOR:-vcs}"
TIMEOUT_SECS="${TIMEOUT_SECS:-900}"
FIXTURE_DIR="${FIXTURE_DIR:-datasets/mnist/lenet_requant_candidate_final_manifest_10000}"
MANIFEST_PATH="${MANIFEST_PATH:-datasets/mnist/lenet_requant_candidate_final_manifest_10000/manifest.json}"
SAMPLE_ROOT_DIR="${SAMPLE_ROOT_DIR:-datasets/mnist/exports_full_10000}"
WEIGHTS_ROOT_DIR="${WEIGHTS_ROOT_DIR:-datasets/mnist/lenet_requant_candidate_final_manifest_10000/weights}"
INPUT_MEMH_NAME="${INPUT_MEMH_NAME:-packed_words.memh}"
EXPECTED_FILE_NAME="${EXPECTED_FILE_NAME:-label.txt}"

usage() {
    cat <<'EOF'
Usage:
  scripts/run_w3_subsystem_full.sh [run|status|merge|help]

Default command:
  run       Start or resume the full 10000-sample subsystem full-set.

Other commands:
  status    Merge existing completed chunks and print current progress.
  merge     Run the merge step only.
  help      Show this message.

Key environment variables:
  OUT_ROOT=<dir>       output root
  CHUNK_SIZE=<n>       samples per chunk (default: 250)
  START_CHUNK=<n>      first chunk index (default: 0)
  NUM_CHUNKS=<n|all>   number of chunks to consider (default: all)
  FORCE=1             rerun completed chunks; default skips them
  DRY_RUN=1           print run/skip decisions without launching simulation

Default W3 candidate-final assets:
  MANIFEST_PATH=datasets/mnist/lenet_requant_candidate_final_manifest_10000/manifest.json
  SAMPLE_ROOT_DIR=datasets/mnist/exports_full_10000
  WEIGHTS_ROOT_DIR=datasets/mnist/lenet_requant_candidate_final_manifest_10000/weights
  INPUT_MEMH_NAME=packed_words.memh
  EXPECTED_FILE_NAME=label.txt
EOF
}

manifest_count() {
    python3 - <<'PY' "$MANIFEST_PATH"
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(len(data["samples"]) if isinstance(data, dict) and "samples" in data else len(data))
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

merge_chunks() {
    python3 scripts/merge_w3_subsystem_chunks.py \
        --root "$OUT_ROOT" \
        --manifest "$MANIFEST_PATH" \
        --chunk-size "$CHUNK_SIZE" \
        --allow-partial
}

print_status() {
    merge_chunks >/dev/null
    python3 - <<'PY' "$OUT_ROOT/merged/summary.json"
import json, pathlib, sys
summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(json.dumps({
    "root": str(pathlib.Path(sys.argv[1]).parent.parent),
    "total": summary["total"],
    "correct": summary["correct"],
    "accuracy": summary["accuracy"],
    "is_complete": summary["is_complete"],
    "completed_chunks": summary["completed_chunks"],
    "observed_chunks": summary["observed_chunks"],
    "missing_samples": summary["missing_samples"],
    "first_missing_sample": summary["first_missing_sample"],
    "first_failing_sample": summary["first_failing_sample"],
    "first_failing_expected": summary["first_failing_expected"],
    "first_failing_predicted": summary["first_failing_predicted"],
}, indent=2))
PY
}

case "$ACTION" in
    -h|--help|help)
        usage
        exit 0
        ;;
    merge)
        merge_chunks
        exit 0
        ;;
    status)
        print_status
        exit 0
        ;;
    run)
        ;;
    *)
        echo "Unknown action: $ACTION" >&2
        usage >&2
        exit 1
        ;;
esac

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

echo "W3 candidate-final subsystem full-set: total_samples=$total_samples chunk_size=$CHUNK_SIZE total_chunks=$total_chunks range=$START_CHUNK..$((end_chunk - 1))"
echo "OUT_ROOT=$OUT_ROOT"
echo "FORCE=$FORCE DRY_RUN=$DRY_RUN"

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

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "WOULD RUN chunk=$chunk_idx offset=$offset count=$count dir=$chunk_dir"
        continue
    fi

    OUT_ROOT="$OUT_ROOT" \
    CHUNK_SIZE="$CHUNK_SIZE" \
    START_CHUNK="$chunk_idx" \
    NUM_CHUNKS=1 \
    FORCE="$FORCE" \
    SIMULATOR="$SIMULATOR" \
    TIMEOUT_SECS="$TIMEOUT_SECS" \
    FIXTURE_DIR="$FIXTURE_DIR" \
    MANIFEST_PATH="$MANIFEST_PATH" \
    SAMPLE_ROOT_DIR="$SAMPLE_ROOT_DIR" \
    WEIGHTS_ROOT_DIR="$WEIGHTS_ROOT_DIR" \
    INPUT_MEMH_NAME="$INPUT_MEMH_NAME" \
    EXPECTED_FILE_NAME="$EXPECTED_FILE_NAME" \
    bash scripts/run_w3_subsystem_chunked.sh

    merge_chunks >/dev/null
    print_status
done

if [[ "$DRY_RUN" != "1" ]]; then
    print_status
fi
