#!/bin/bash
#
# GPU-first / CPU-second orchestrator for spinal cord CSA pipeline.
#
# Phase 1: GPU segmentation (sct_deepseg + SPINEPS) — controlled parallelism
# Phase 2: CPU processing (registration, CSA, aSCOR, QC) — high parallelism
#
# Usage:
#   ./run_pipeline.sh \
#       -path-data <PATH> \
#       -contrast <t1w|t2w|stir> \
#       -output <PATH> \
#       [-jobs-gpu <N>]        # GPU parallelism (default: 4)
#       [-jobs-cpu <N>]        # CPU parallelism (default: nproc/4)
#       [-include-list <FILE>] # file with one subject per line
#
# Run once per contrast. For multiple contrasts, call the script multiple times.

set -e -o pipefail
trap "echo Caught Keyboard Interrupt. Exiting.; exit" INT

# ======================================================================
# Parse arguments
# ======================================================================
PATH_DATA=""
CONTRAST=""
OUTPUT=""
JOBS_GPU=4
JOBS_CPU=""
INCLUDE_LIST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -path-data)    PATH_DATA="$2";    shift 2 ;;
        -contrast)     CONTRAST="$2";     shift 2 ;;
        -output)       OUTPUT="$2";       shift 2 ;;
        -jobs-gpu)     JOBS_GPU="$2";     shift 2 ;;
        -jobs-cpu)     JOBS_CPU="$2";     shift 2 ;;
        -include-list) INCLUDE_LIST="$2"; shift 2 ;;
        -h|--help)
            head -17 "$0" | tail -14
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 -path-data <PATH> -contrast <t1w|t2w|stir> -output <PATH> [-jobs-gpu N] [-jobs-cpu N] [-include-list <FILE>]"
            exit 1
            ;;
    esac
done

# Validate required args
if [[ -z "$PATH_DATA" ]]; then
    echo "ERROR: -path-data is required."
    exit 1
fi
if [[ -z "$CONTRAST" ]]; then
    echo "ERROR: -contrast is required (t1w, t2w, or stir)."
    exit 1
fi
if [[ "$CONTRAST" != "t1w" && "$CONTRAST" != "t2w" && "$CONTRAST" != "stir" ]]; then
    echo "ERROR: -contrast must be one of: t1w, t2w, stir (got: ${CONTRAST})"
    exit 1
fi
if [[ -z "$OUTPUT" ]]; then
    echo "ERROR: -output is required."
    exit 1
fi

# Default CPU jobs to nproc/4
if [[ -z "$JOBS_CPU" ]]; then
    JOBS_CPU=$(( $(nproc) / 4 ))
    [[ "$JOBS_CPU" -lt 1 ]] && JOBS_CPU=1
fi

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verify atlas file exists
if [[ ! -f "${SCRIPT_DIR}/atlas/PAM50_atlas_41.nii.gz" ]]; then
    echo "ERROR: atlas/PAM50_atlas_41.nii.gz not found."
    echo "Download from: https://github.com/neuroradiologyVH/Spinal-Cord-Canal-Template"
    exit 1
fi

# Build include-list args for sct_run_batch
INCLUDE_ARGS=""
if [[ -n "$INCLUDE_LIST" ]]; then
    if [[ ! -f "$INCLUDE_LIST" ]]; then
        echo "ERROR: Include list file not found: $INCLUDE_LIST"
        exit 1
    fi
    INCLUDE_SUBJECTS=$(tr '\n' ' ' < "$INCLUDE_LIST")
    INCLUDE_ARGS="-include-list ${INCLUDE_SUBJECTS}"
fi

CONTRAST_UPPER=$(echo "$CONTRAST" | tr '[:lower:]' '[:upper:]')

echo "================================================================"
echo "Spinal Cord & Canal CSA Pipeline (GPU/CPU Split)"
echo "================================================================"
echo "  Contrast:    ${CONTRAST_UPPER}"
echo "  Data:        ${PATH_DATA}"
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
echo "=== Phase 1: GPU Segmentation — ${CONTRAST_UPPER} (jobs=${JOBS_GPU}) ==="
echo "================================================================"
phase1_start=$(date +%s)

# sct_run_batch exits non-zero if ANY subject fails, even though it continues
# processing. We tolerate partial failures — the CPU phase skips subjects
# whose GPU outputs are missing.
sct_run_batch -script "${SCRIPT_DIR}/process_csa_gpu.sh" \
    -path-data "$PATH_DATA" \
    -path-output "$OUTPUT" \
    -jobs "$JOBS_GPU" \
    ${INCLUDE_ARGS} \
    -script-args "$CONTRAST $SCRIPT_DIR" \
|| echo "WARNING: Some ${CONTRAST_UPPER} subjects failed GPU segmentation (see logs). Continuing."

phase1_end=$(date +%s)
phase1_runtime=$((phase1_end - phase1_start))
echo
echo "Phase 1 complete: $(($phase1_runtime / 3600))hrs $((($phase1_runtime / 60) % 60))min $(($phase1_runtime % 60))sec"
echo

# ======================================================================
# Phase 2: CPU Processing
# ======================================================================
echo "================================================================"
echo "=== Phase 2: CPU Processing — ${CONTRAST_UPPER} (jobs=${JOBS_CPU}) ==="
echo "================================================================"
phase2_start=$(date +%s)

sct_run_batch -script "${SCRIPT_DIR}/process_csa_cpu.sh" \
    -path-data "$OUTPUT/data_processed" \
    -path-output "$OUTPUT" \
    -jobs "$JOBS_CPU" \
    ${INCLUDE_ARGS} \
    -script-args "$CONTRAST $SCRIPT_DIR" \
|| echo "WARNING: Some ${CONTRAST_UPPER} subjects failed CPU processing (see logs). Continuing."

echo ">>> Aggregating ${CONTRAST_UPPER} results..."
python3 "${SCRIPT_DIR}/parse_results.py" \
    --directory "$OUTPUT/results" \
    --info "MEAN(area)" || true

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
echo "Pipeline complete! (${CONTRAST_UPPER})"
echo "  Phase 1 (GPU): $(($phase1_runtime / 3600))hrs $((($phase1_runtime / 60) % 60))min $(($phase1_runtime % 60))sec"
echo "  Phase 2 (CPU): $(($phase2_runtime / 3600))hrs $((($phase2_runtime / 60) % 60))min $(($phase2_runtime % 60))sec"
echo "  Total:         $(($total_runtime / 3600))hrs $((($total_runtime / 60) % 60))min $(($total_runtime % 60))sec"
echo "  Output:        ${OUTPUT}"
echo "================================================================"
