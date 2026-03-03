#!/bin/bash
#
# T2w GPU phase: TotalSpineSeg + SPINEPS segmentation.
#
# This is the GPU half of the split pipeline. It runs sct_deepseg totalspineseg
# and SPINEPS (if available), producing segmentation outputs for the CPU phase.
#
# Output products (per subject):
#   ${file_t2w}_step2_output.nii.gz           — multi-label segmentation
#   ${file_t2w}_step1_levels.nii.gz           — disc labels
#   derivatives_seg/*_seg-spine*msk.nii.gz    — SPINEPS output (if available)
#
# Usage (via sct_run_batch):
#   sct_run_batch -script process_csa_t2w_gpu.sh \
#       -path-data <PATH-TO-T2W-DATASET> \
#       -path-output <PATH-TO-OUTPUT> \
#       -jobs <N> \
#       -script-args <PATH-TO-THIS-REPO>

# BASH SETTINGS
set -x
set -e -o pipefail
trap "echo Caught Keyboard Interrupt within script. Exiting now.; exit" INT

# Retrieve input params
SUBJECT=$1
SCRIPT_DIR=$2

# Timing
start=$(date +%s)

# Go to processing folder
cd "${PATH_DATA_PROCESSED}"

# Copy source images
rsync -Ravzh "${PATH_DATA}/./${SUBJECT}" .

cd "${SUBJECT}/anat/"

# Dynamically discover the T2w file (naming varies across subjects)
file_t2w_nii=$(ls *_T2w.nii.gz 2>/dev/null | head -1) || true
if [[ -z "${file_t2w_nii}" ]]; then
    echo "WARNING: No T2w file found for ${SUBJECT}. Skipping."
    exit 0
fi
file_t2w="${file_t2w_nii%.nii.gz}"
echo "Found T2w file: ${file_t2w}"

# ======================================================================
# TotalSpineSeg Segmentation (GPU)
# ======================================================================
sct_deepseg totalspineseg -i "${file_t2w}.nii.gz" -qc "${PATH_QC}"

# ======================================================================
# SPINEPS Segmentation (GPU, optional)
# ======================================================================
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
        -i "${file_t2w}.nii.gz" -model_semantic t2w -model_instance instance

    if [[ -n "${CONDA_DEFAULT_ENV}" && "${CONDA_DEFAULT_ENV}" == "spineps" ]]; then
        conda deactivate
    fi
else
    echo "WARNING: spineps not found. Skipping SPINEPS segmentation."
fi
set -e

# ======================================================================
# Done — CPU phase picks up from here
# ======================================================================
end=$(date +%s)
runtime=$((end - start))
echo
echo "~~~"
echo "GPU phase complete for ${SUBJECT}"
echo "Duration: $(($runtime / 3600))hrs $((($runtime / 60) % 60))min $(($runtime % 60))sec"
echo "~~~"
