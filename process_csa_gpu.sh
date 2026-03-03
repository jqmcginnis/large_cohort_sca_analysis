#!/bin/bash
#
# Unified GPU phase: TotalSpineSeg (+ SPINEPS for T2w) segmentation.
#
# Parameterized by contrast — handles T1w, T2w, and STIR in a single script.
#
# Output products (per subject):
#   ${file}_step2_output.nii.gz           — multi-label segmentation
#   ${file}_step1_levels.nii.gz           — disc labels
#   derivatives_seg/*_seg-spine*msk.nii.gz — SPINEPS output (T2w only)
#
# Usage (via sct_run_batch):
#   sct_run_batch -script process_csa_gpu.sh \
#       -path-data <PATH-TO-DATASET> \
#       -path-output <PATH-TO-OUTPUT> \
#       -jobs <N> \
#       -script-args "<CONTRAST> <PATH-TO-THIS-REPO>"
#
#   CONTRAST: t1w, t2w, or stir

# BASH SETTINGS
set -x
set -e -o pipefail
trap "echo Caught Keyboard Interrupt within script. Exiting now.; exit" INT

# Retrieve input params
SUBJECT=$1
CONTRAST=$2
SCRIPT_DIR=$3

# Timing
start=$(date +%s)

# Go to processing folder
cd "${PATH_DATA_PROCESSED}"

# Copy source images
rsync -Ravzh "${PATH_DATA}/./${SUBJECT}" .

cd "${SUBJECT}/anat/"

# ======================================================================
# File discovery (contrast-dependent)
# ======================================================================
file_nii=""
case "$CONTRAST" in
    t1w)
        file_nii=$(ls *_T1w.nii.gz 2>/dev/null | head -1) || true
        if [[ -z "$file_nii" ]]; then
            file_nii=$(ls *_T1w-CE.nii.gz 2>/dev/null | head -1) || true
        fi
        ;;
    t2w)
        file_nii=$(ls *_T2w.nii.gz 2>/dev/null | head -1) || true
        ;;
    stir)
        file_nii=$(ls *_STIR.nii.gz 2>/dev/null | head -1) || true
        ;;
    *)
        echo "ERROR: Unknown contrast '${CONTRAST}'. Expected: t1w, t2w, or stir."
        exit 1
        ;;
esac

if [[ -z "$file_nii" ]]; then
    echo "WARNING: No ${CONTRAST} file found for ${SUBJECT}. Skipping."
    exit 0
fi
file="${file_nii%.nii.gz}"
echo "Found ${CONTRAST} file: ${file}"

# ======================================================================
# TotalSpineSeg Segmentation (GPU)
# ======================================================================
sct_deepseg totalspineseg -i "${file}.nii.gz" -qc "${PATH_QC}"

# ======================================================================
# SPINEPS Segmentation (GPU, T2w only)
# ======================================================================
if [[ "$CONTRAST" == "t2w" ]]; then
    set +e
    SPINEPS_AVAILABLE=false
    if [[ -d "${HOME}/anaconda3/envs/spineps" ]]; then
        SPINEPS_AVAILABLE=true
    elif command -v spineps &>/dev/null; then
        SPINEPS_AVAILABLE=true
    fi

    if [[ "${SPINEPS_AVAILABLE}" == "true" ]]; then
        if ! command -v spineps &>/dev/null; then
            source "${HOME}/anaconda3/etc/profile.d/conda.sh"
            conda activate spineps
        fi

        spineps sample -ignore_bids_filter -ignore_inference_compatibility \
            -i "${file}.nii.gz" -model_semantic t2w -model_instance instance

        if [[ -n "${CONDA_DEFAULT_ENV}" && "${CONDA_DEFAULT_ENV}" == "spineps" ]]; then
            conda deactivate
        fi
    else
        echo "WARNING: spineps not found. Skipping SPINEPS segmentation."
    fi
    set -e
fi

# ======================================================================
# Done — CPU phase picks up from here
# ======================================================================
end=$(date +%s)
runtime=$((end - start))
echo
echo "~~~"
echo "GPU phase complete for ${SUBJECT} (${CONTRAST})"
echo "Duration: $(($runtime / 3600))hrs $((($runtime / 60) % 60))min $(($runtime % 60))sec"
echo "~~~"
