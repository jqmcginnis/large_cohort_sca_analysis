#!/bin/bash
#
# T1w GPU phase: TotalSpineSeg segmentation only.
#
# This is the GPU half of the split pipeline. It runs sct_deepseg totalspineseg
# and produces the segmentation outputs that the CPU phase picks up.
#
# Output products (per subject):
#   ${file_t1w}_step2_output.nii.gz  — multi-label segmentation
#   ${file_t1w}_step1_levels.nii.gz  — disc labels
#
# Usage (via sct_run_batch):
#   sct_run_batch -script process_csa_t1w_gpu.sh \
#       -path-data <PATH-TO-T1W-DATASET> \
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

# Dynamically discover the T1w file (prefer non-CE; fall back to T1w-CE)
file_t1w_nii=$(ls *_T1w.nii.gz 2>/dev/null | head -1) || true
if [[ -z "${file_t1w_nii}" ]]; then
    file_t1w_nii=$(ls *_T1w-CE.nii.gz 2>/dev/null | head -1) || true
fi
if [[ -z "${file_t1w_nii}" ]]; then
    echo "WARNING: No T1w file found for ${SUBJECT}. Skipping."
    exit 0
fi
file_t1w="${file_t1w_nii%.nii.gz}"
echo "Found T1w file: ${file_t1w}"

# ======================================================================
# TotalSpineSeg Segmentation (GPU)
# ======================================================================
sct_deepseg totalspineseg -i "${file_t1w}.nii.gz" -qc "${PATH_QC}"

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
