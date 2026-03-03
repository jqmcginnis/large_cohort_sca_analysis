#!/bin/bash
#
# GPU-first / CPU-second orchestrator for spinal cord CSA pipeline.
#
# Phase 1: GPU segmentation (sct_deepseg + SPINEPS) — controlled parallelism
# Phase 2: CPU processing (registration, CSA, aSCOR, QC) — high parallelism
#
# This avoids GPU contention from the monolithic scripts while maximizing
# CPU throughput for the compute-heavy registration + CSA steps.
#
# Usage:
#   ./run_pipeline.sh \
#       -t1w-data <PATH> \
#       -t2w-data <PATH> \
#       -stir-data <PATH> \
#       -output <PATH> \
#       [-jobs-gpu <N>]        # GPU parallelism (default: 4)
#       [-jobs-cpu <N>]        # CPU parallelism (default: nproc/4)
#       [-include-list <FILE>] # file with one subject per line
#
# All three data paths are optional — omit any contrast to skip it.
#
# The monolithic script (process_csa.sh) can be used for single-subject
# standalone debugging via sct_run_batch.

set -e -o pipefail
trap "echo Caught Keyboard Interrupt. Exiting.; exit" INT

# ======================================================================
# Parse arguments
# ======================================================================
T1W_DATA=""
T2W_DATA=""
STIR_DATA=""
OUTPUT=""
JOBS_GPU=4
JOBS_CPU=""
INCLUDE_LIST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t1w-data)     T1W_DATA="$2";     shift 2 ;;
        -t2w-data)     T2W_DATA="$2";     shift 2 ;;
        -stir-data)    STIR_DATA="$2";    shift 2 ;;
        -output)       OUTPUT="$2";        shift 2 ;;
        -jobs-gpu)     JOBS_GPU="$2";      shift 2 ;;
        -jobs-cpu)     JOBS_CPU="$2";      shift 2 ;;
        -include-list) INCLUDE_LIST="$2";  shift 2 ;;
        -h|--help)
            head -25 "$0" | tail -20
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 -output <PATH> [-t1w-data <PATH>] [-t2w-data <PATH>] [-stir-data <PATH>] [-jobs-gpu N] [-jobs-cpu N] [-include-list <FILE>]"
            exit 1
            ;;
    esac
done

# Validate required args
if [[ -z "$OUTPUT" ]]; then
    echo "ERROR: -output is required."
    exit 1
fi
if [[ -z "$T1W_DATA" && -z "$T2W_DATA" && -z "$STIR_DATA" ]]; then
    echo "ERROR: At least one of -t1w-data, -t2w-data, -stir-data is required."
    exit 1
fi

# Default CPU jobs to nproc/4
if [[ -z "$JOBS_CPU" ]]; then
    JOBS_CPU=$(( $(nproc) / 4 ))
    [[ "$JOBS_CPU" -lt 1 ]] && JOBS_CPU=1
fi

# Resolve script directory (where the *_gpu.sh and *_cpu.sh scripts live)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verify atlas file exists
if [[ ! -f "${SCRIPT_DIR}/atlas/PAM50_atlas_41.nii.gz" ]]; then
    echo "ERROR: atlas/PAM50_atlas_41.nii.gz not found."
    echo "Download from: https://github.com/neuroradiologyVH/Spinal-Cord-Canal-Template"
    exit 1
fi

# Build include-list args for sct_run_batch
# -include-list accepts a file (one subject per line) — read into space-separated list
INCLUDE_ARGS=""
if [[ -n "$INCLUDE_LIST" ]]; then
    if [[ ! -f "$INCLUDE_LIST" ]]; then
        echo "ERROR: Include list file not found: $INCLUDE_LIST"
        exit 1
    fi
    INCLUDE_SUBJECTS=$(tr '\n' ' ' < "$INCLUDE_LIST")
    INCLUDE_ARGS="-include-list ${INCLUDE_SUBJECTS}"
fi

echo "================================================================"
echo "Spinal Cord & Canal CSA Pipeline (GPU/CPU Split)"
echo "================================================================"
echo "  T1w data:    ${T1W_DATA:-<skipped>}"
echo "  T2w data:    ${T2W_DATA:-<skipped>}"
echo "  STIR data:   ${STIR_DATA:-<skipped>}"
echo "  Output:      ${OUTPUT}"
echo "  GPU jobs:    ${JOBS_GPU}"
echo "  CPU jobs:    ${JOBS_CPU}"
echo "  Include:     ${INCLUDE_LIST:-<all subjects>}"
echo "  Script dir:  ${SCRIPT_DIR}"
echo "================================================================"
echo

# ======================================================================
# Phase 1: GPU Segmentation
# ======================================================================
echo "================================================================"
echo "=== Phase 1: GPU Segmentation (jobs=${JOBS_GPU}) ==="
echo "================================================================"
phase1_start=$(date +%s)

# sct_run_batch exits non-zero if ANY subject fails, even though it continues
# processing. We tolerate partial failures — the CPU phase skips subjects
# whose GPU outputs are missing.
for CONTRAST_INFO in "t1w:$T1W_DATA" "t2w:$T2W_DATA" "stir:$STIR_DATA"; do
    CONTRAST="${CONTRAST_INFO%%:*}"
    DATA_PATH="${CONTRAST_INFO#*:}"
    [[ -z "$DATA_PATH" ]] && continue

    CONTRAST_UPPER=$(echo "$CONTRAST" | tr '[:lower:]' '[:upper:]')
    echo "--- ${CONTRAST_UPPER} GPU segmentation ---"
    sct_run_batch -script "${SCRIPT_DIR}/process_csa_gpu.sh" \
        -path-data "$DATA_PATH" \
        -path-output "$OUTPUT/$CONTRAST" \
        -jobs "$JOBS_GPU" \
        ${INCLUDE_ARGS} \
        -script-args "$CONTRAST $SCRIPT_DIR" \
    || echo "WARNING: Some ${CONTRAST_UPPER} subjects failed GPU segmentation (see logs). Continuing."
done

phase1_end=$(date +%s)
phase1_runtime=$((phase1_end - phase1_start))
echo
echo "Phase 1 complete: $(($phase1_runtime / 3600))hrs $((($phase1_runtime / 60) % 60))min $(($phase1_runtime % 60))sec"
echo

# ======================================================================
# Phase 2: CPU Processing
# ======================================================================
echo "================================================================"
echo "=== Phase 2: CPU Processing (jobs=${JOBS_CPU}) ==="
echo "================================================================"
phase2_start=$(date +%s)

for CONTRAST_INFO in "t1w:$T1W_DATA" "t2w:$T2W_DATA" "stir:$STIR_DATA"; do
    CONTRAST="${CONTRAST_INFO%%:*}"
    DATA_PATH="${CONTRAST_INFO#*:}"
    [[ -z "$DATA_PATH" ]] && continue

    CONTRAST_UPPER=$(echo "$CONTRAST" | tr '[:lower:]' '[:upper:]')
    echo "--- ${CONTRAST_UPPER} CPU processing ---"
    sct_run_batch -script "${SCRIPT_DIR}/process_csa_cpu.sh" \
        -path-data "$OUTPUT/$CONTRAST/data_processed" \
        -path-output "$OUTPUT/$CONTRAST" \
        -jobs "$JOBS_CPU" \
        ${INCLUDE_ARGS} \
        -script-args "$CONTRAST $SCRIPT_DIR" \
    || echo "WARNING: Some ${CONTRAST_UPPER} subjects failed CPU processing (see logs). Continuing."

    echo ">>> Aggregating ${CONTRAST_UPPER} results..."
    python3 "${SCRIPT_DIR}/parse_results.py" \
        --directory "$OUTPUT/$CONTRAST/results" \
        --info "MEAN(area)" || true
done

phase2_end=$(date +%s)
phase2_runtime=$((phase2_end - phase2_start))
echo
echo "Phase 2 complete: $(($phase2_runtime / 3600))hrs $((($phase2_runtime / 60) % 60))min $(($phase2_runtime % 60))sec"
echo

# ======================================================================
# Summary
# ======================================================================
total_runtime=$((phase2_end - phase1_start))
echo "================================================================"
echo "Pipeline complete!"
echo "  Phase 1 (GPU): $(($phase1_runtime / 3600))hrs $((($phase1_runtime / 60) % 60))min $(($phase1_runtime % 60))sec"
echo "  Phase 2 (CPU): $(($phase2_runtime / 3600))hrs $((($phase2_runtime / 60) % 60))min $(($phase2_runtime % 60))sec"
echo "  Total:         $(($total_runtime / 3600))hrs $((($total_runtime / 60) % 60))min $(($total_runtime % 60))sec"
echo "  Output:        ${OUTPUT}"
echo "================================================================"
