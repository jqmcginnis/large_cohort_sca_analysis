#!/bin/bash
#
# Master orchestration script for spinal cord & canal CSA analysis.
#
# Runs sct_run_batch for each contrast (T1w, T2w, STIR), then aggregates results.
#
# Usage:
#   ./run_pipeline.sh --t1w-data /path/to/t1w --t2w-data /path/to/t2w --output /path/to/output --jobs 8
#
# All flags are optional — only contrasts with provided --*-data paths will be processed.

set -e -o pipefail

# Defaults
JOBS=4
OUTPUT_DIR=""
T1W_DATA=""
T2W_DATA=""
STIR_DATA=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --t1w-data  PATH    Path to T1w (MPRAGE) dataset
  --t2w-data  PATH    Path to T2w (sagittal) dataset
  --stir-data PATH    Path to STIR (sagittal) dataset (defaults to --t2w-data if not set)
  --output    PATH    Base output directory (required)
  --jobs      N       Number of parallel jobs (default: 4)
  -h, --help          Show this help message
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --t1w-data)  T1W_DATA="$2";  shift 2 ;;
        --t2w-data)  T2W_DATA="$2";  shift 2 ;;
        --stir-data) STIR_DATA="$2"; shift 2 ;;
        --output)    OUTPUT_DIR="$2"; shift 2 ;;
        --jobs)      JOBS="$2";       shift 2 ;;
        -h|--help)   usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "${OUTPUT_DIR}" ]]; then
    echo "ERROR: --output is required."
    usage
fi

# If STIR data path not set, default to T2w data path (same directory, different filenames)
if [[ -n "${T2W_DATA}" && -z "${STIR_DATA}" ]]; then
    STIR_DATA="${T2W_DATA}"
fi

# Verify atlas file exists
if [[ ! -f "${SCRIPT_DIR}/atlas/PAM50_atlas_41.nii.gz" ]]; then
    echo "ERROR: atlas/PAM50_atlas_41.nii.gz not found."
    echo "Download from: https://github.com/neuroradiologyVH/Spinal-Cord-Canal-Template"
    exit 1
fi

echo "============================================================"
echo "Spinal Cord & Canal CSA Analysis Pipeline"
echo "============================================================"
echo "Script dir:  ${SCRIPT_DIR}"
echo "Output dir:  ${OUTPUT_DIR}"
echo "Jobs:        ${JOBS}"
echo "T1w data:    ${T1W_DATA:-<not set>}"
echo "T2w data:    ${T2W_DATA:-<not set>}"
echo "STIR data:   ${STIR_DATA:-<not set>}"
echo "============================================================"

# ======================================================================
# T1w Pipeline
# ======================================================================
if [[ -n "${T1W_DATA}" ]]; then
    echo ""
    echo ">>> Running T1w pipeline..."
    sct_run_batch \
        -script "${SCRIPT_DIR}/process_csa_t1w.sh" \
        -path-data "${T1W_DATA}" \
        -path-output "${OUTPUT_DIR}/t1w_out" \
        -jobs "${JOBS}" \
        -script-args "${SCRIPT_DIR}"

    echo ">>> Aggregating T1w results..."
    python3 "${SCRIPT_DIR}/parse_results.py" \
        --directory "${OUTPUT_DIR}/t1w_out/results" \
        --info "MEAN(area)"
fi

# ======================================================================
# T2w Pipeline
# ======================================================================
if [[ -n "${T2W_DATA}" ]]; then
    echo ""
    echo ">>> Running T2w pipeline..."
    sct_run_batch \
        -script "${SCRIPT_DIR}/process_csa_t2w.sh" \
        -path-data "${T2W_DATA}" \
        -path-output "${OUTPUT_DIR}/t2w_out" \
        -jobs "${JOBS}" \
        -script-args "${SCRIPT_DIR}"

    echo ">>> Aggregating T2w results..."
    python3 "${SCRIPT_DIR}/parse_results.py" \
        --directory "${OUTPUT_DIR}/t2w_out/results" \
        --info "MEAN(area)"
fi

# ======================================================================
# STIR Pipeline
# ======================================================================
if [[ -n "${STIR_DATA}" ]]; then
    echo ""
    echo ">>> Running STIR pipeline..."
    sct_run_batch \
        -script "${SCRIPT_DIR}/process_csa_stir.sh" \
        -path-data "${STIR_DATA}" \
        -path-output "${OUTPUT_DIR}/stir_out" \
        -jobs "${JOBS}" \
        -script-args "${SCRIPT_DIR}"

    echo ">>> Aggregating STIR results..."
    python3 "${SCRIPT_DIR}/parse_results.py" \
        --directory "${OUTPUT_DIR}/stir_out/results" \
        --info "MEAN(area)"
fi

echo ""
echo "============================================================"
echo "Pipeline complete."
echo "Results in: ${OUTPUT_DIR}"
echo "============================================================"
