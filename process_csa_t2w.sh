#!/bin/bash
#
# T2w (sagittal) spinal cord & canal CSA pipeline.
#
# Methods:
#   1 — TotalSpineSeg  (cord + canal from DL segmentation)
#   2 — SPINEPS        (cord + canal from DL segmentation, if installed)
#   3 — Atlas41        (PAM50_atlas_41 = full canal template, warped to native space)
#   4 — PAM50          (PAM50_cord + PAM50_csf warped to native space)
#
# Methods 3 & 4 run an interpolation ablation (nn, linear, spline) comparing
# different warping strategies for probabilistic templates.
#
# Note: T2w filenames vary across subjects (chunk-stitched, chunk-cerv, etc.)
#       so this script discovers the T2w file dynamically in each session.
#
# Dependencies:
#   - SCT >= 7.2.0
#   - SPINEPS (pip install spineps) — optional
#   - Python packages: nibabel, numpy
#
# Usage (via sct_run_batch):
#   sct_run_batch -script process_csa_t2w.sh \
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

# Display SCT info
sct_check_dependencies -short

# PAM50 template directory (within SCT installation)
PAM50_DIR="$(dirname "$(which sct_version)")/../data/PAM50"

# Go to processing folder
cd "${PATH_DATA_PROCESSED}"

# Copy source images
rsync -Ravzh "${PATH_DATA}/./${SUBJECT}" .
file="${SUBJECT//[\/]/_}"

cd "${SUBJECT}/anat/"

# Dynamically discover the T2w file (naming varies across subjects)
file_t2w_nii=$(ls *_T2w.nii.gz 2>/dev/null | head -1)
if [[ -z "${file_t2w_nii}" ]]; then
    echo "WARNING: No T2w file found for ${SUBJECT}. Skipping."
    exit 0
fi
file_t2w="${file_t2w_nii%.nii.gz}"
echo "Found T2w file: ${file_t2w}"

# ======================================================================
# Step 1: TotalSpineSeg Segmentation
# ======================================================================
sct_deepseg spine -i "${file_t2w}.nii.gz" -label-vert 1 -qc "${PATH_QC}"

# Output products (standard SCT naming)
file_totalseg_all="${file_t2w}_totalspineseg_all"
file_totalseg_discs="${file_t2w}_totalspineseg_discs"

# ======================================================================
# Step 2: Parse TotalSpineSeg Labels
# ======================================================================
# Naming: seg-<method>-<structure> for crystal-clear provenance
file_tss_cord="${file_t2w}_seg-totalspineseg-cord"
file_tss_canal="${file_t2w}_seg-totalspineseg-canal"
file_tss_union="${file_t2w}_seg-totalspineseg-cord-canal-union"
file_tss_vert="${file_t2w}_seg-totalspineseg-vertlevels"

python3 "${SCRIPT_DIR}/process_seg.py" \
    -i "${file_totalseg_all}.nii.gz" \
    --cord "${file_tss_cord}.nii.gz" \
    --canal "${file_tss_canal}.nii.gz" \
    --combined "${file_tss_union}.nii.gz"

python3 "${SCRIPT_DIR}/relabel_vertebrae.py" \
    --mask "${file_totalseg_all}.nii.gz" \
    --out "${file_tss_vert}.nii.gz"

# ======================================================================
# Step 3: CSA — Method 1 (TotalSpineSeg)
# ======================================================================
mkdir -p "${PATH_RESULTS}/method-totalspineseg"

# Cord CSA
sct_process_segmentation -i "${file_tss_cord}.nii.gz" \
    -vert 2:4 -vertfile "${file_tss_vert}.nii.gz" \
    -o "${PATH_RESULTS}/method-totalspineseg/${file}_cord.csv" -perlevel 1

# Canal CSA (cord+canal union)
sct_process_segmentation -i "${file_tss_union}.nii.gz" \
    -vert 2:4 -vertfile "${file_tss_vert}.nii.gz" \
    -o "${PATH_RESULTS}/method-totalspineseg/${file}_canal.csv" -perlevel 1

# aSCOR ratio
sct_compute_ascor -i-SC "${file_tss_cord}.nii.gz" -i-canal "${file_tss_canal}.nii.gz" \
    -vert 2:4 -vertfile "${file_tss_vert}.nii.gz" \
    -o "${PATH_RESULTS}/method-totalspineseg/${file}_ratio.csv" -perlevel 1

# ======================================================================
# Step 4: Register to PAM50 Template
# ======================================================================
sct_register_to_template -i "${file_t2w}.nii.gz" \
    -s "${file_tss_cord}.nii.gz" \
    -ldisc "${file_totalseg_discs}.nii.gz" \
    -c t2 -qc "${PATH_QC}"

# ======================================================================
# Step 5: Warp Templates to Native Space (explicit interpolation)
# ======================================================================
# PAM50_levels are labels → always use nearest-neighbor
sct_apply_transfo -i "${PAM50_DIR}/template/PAM50_levels.nii.gz" \
    -d "${file_t2w}.nii.gz" \
    -w warp_template2anat.nii.gz \
    -x nn \
    -o PAM50_levels_warped_nn.nii.gz

# Interpolation ablation: warp cord, CSF, and atlas41 with nn/linear/spline
for INTERP in nn linear spline; do
    echo ">>> Warping templates with interpolation: ${INTERP}"

    # PAM50 cord (probabilistic template)
    sct_apply_transfo -i "${PAM50_DIR}/template/PAM50_cord.nii.gz" \
        -d "${file_t2w}.nii.gz" \
        -w warp_template2anat.nii.gz \
        -x "${INTERP}" \
        -o "PAM50_cord_warped_${INTERP}.nii.gz"

    # PAM50 CSF (probabilistic template, does NOT include cord)
    sct_apply_transfo -i "${PAM50_DIR}/template/PAM50_csf.nii.gz" \
        -d "${file_t2w}.nii.gz" \
        -w warp_template2anat.nii.gz \
        -x "${INTERP}" \
        -o "PAM50_csf_warped_${INTERP}.nii.gz"

    # Custom canal atlas (PAM50_atlas_41, INCLUDES cord — full canal)
    sct_apply_transfo -i "${SCRIPT_DIR}/atlas/PAM50_atlas_41.nii.gz" \
        -d "${file_t2w}.nii.gz" \
        -w warp_template2anat.nii.gz \
        -x "${INTERP}" \
        -o "PAM50_atlas41_warped_${INTERP}.nii.gz"

    # ==================================================================
    # Binarize warped templates (threshold 0.5)
    # ==================================================================
    sct_maths -i "PAM50_cord_warped_${INTERP}.nii.gz" -bin 0.5 \
        -o "PAM50_cord_warped_${INTERP}_bin.nii.gz"

    sct_maths -i "PAM50_csf_warped_${INTERP}.nii.gz" -bin 0.5 \
        -o "PAM50_csf_warped_${INTERP}_bin.nii.gz"

    # PAM50 canal = cord + CSF union (since PAM50_csf does NOT include cord)
    sct_maths -i "PAM50_cord_warped_${INTERP}_bin.nii.gz" \
        -add "PAM50_csf_warped_${INTERP}_bin.nii.gz" \
        -o "PAM50_canal_warped_${INTERP}_union.nii.gz"
    sct_maths -i "PAM50_canal_warped_${INTERP}_union.nii.gz" -bin 0.5 \
        -o "PAM50_canal_warped_${INTERP}_bin.nii.gz"

    # Atlas41 full canal (already includes cord)
    sct_maths -i "PAM50_atlas41_warped_${INTERP}.nii.gz" -bin 0.5 \
        -o "PAM50_atlas41_warped_${INTERP}_bin.nii.gz"

    # ==================================================================
    # CSA — Method 3: Atlas41 (custom canal atlas, includes cord)
    # Cord = TotalSpineSeg cord, Canal = warped atlas41
    # Vert reference = warped PAM50_levels (always NN)
    # ==================================================================
    mkdir -p "${PATH_RESULTS}/method-atlas41-warp-${INTERP}"

    # Canal CSA (atlas41 = full canal including cord)
    sct_process_segmentation -i "PAM50_atlas41_warped_${INTERP}_bin.nii.gz" \
        -vert 2:4 -vertfile PAM50_levels_warped_nn.nii.gz \
        -o "${PATH_RESULTS}/method-atlas41-warp-${INTERP}/${file}_canal.csv" -perlevel 1

    # Cord CSA (TotalSpineSeg cord, PAM50 levels as vert reference)
    sct_process_segmentation -i "${file_tss_cord}.nii.gz" \
        -vert 2:4 -vertfile PAM50_levels_warped_nn.nii.gz \
        -o "${PATH_RESULTS}/method-atlas41-warp-${INTERP}/${file}_cord.csv" -perlevel 1

    # ==================================================================
    # CSA — Method 4: PAM50 (cord + CSF, both from warped templates)
    # Cord = warped PAM50_cord, Canal = warped PAM50_cord + PAM50_csf union
    # Vert reference = warped PAM50_levels (always NN)
    # ==================================================================
    mkdir -p "${PATH_RESULTS}/method-pam50-warp-${INTERP}"

    # Canal CSA
    sct_process_segmentation -i "PAM50_canal_warped_${INTERP}_bin.nii.gz" \
        -vert 2:4 -vertfile PAM50_levels_warped_nn.nii.gz \
        -o "${PATH_RESULTS}/method-pam50-warp-${INTERP}/${file}_canal.csv" -perlevel 1

    # Cord CSA
    sct_process_segmentation -i "PAM50_cord_warped_${INTERP}_bin.nii.gz" \
        -vert 2:4 -vertfile PAM50_levels_warped_nn.nii.gz \
        -o "${PATH_RESULTS}/method-pam50-warp-${INTERP}/${file}_cord.csv" -perlevel 1

done

# ======================================================================
# SPINEPS — Method 2 (skip if spineps not installed)
# ======================================================================
if command -v spineps &>/dev/null; then
    spineps sample -i "${file_t2w}.nii.gz" -model_semantic t2w -model_instance instance

    file_spineps_spine="${file_t2w}_seg-spine"
    file_spi_cord="${file_t2w}_seg-spineps-cord"
    file_spi_canal="${file_t2w}_seg-spineps-canal"
    file_spi_union="${file_t2w}_seg-spineps-cord-canal-union"

    python3 "${SCRIPT_DIR}/process_spineps_seg.py" \
        -i "${file_spineps_spine}.nii.gz" \
        --cord "${file_spi_cord}.nii.gz" \
        --canal "${file_spi_canal}.nii.gz" \
        --combined "${file_spi_union}.nii.gz"

    mkdir -p "${PATH_RESULTS}/method-spineps"

    # Cord CSA (SPINEPS cord, TotalSpineSeg vert levels for consistency)
    sct_process_segmentation -i "${file_spi_cord}.nii.gz" \
        -vert 2:4 -vertfile "${file_tss_vert}.nii.gz" \
        -o "${PATH_RESULTS}/method-spineps/${file}_cord.csv" -perlevel 1

    # Canal CSA (SPINEPS cord+canal union)
    sct_process_segmentation -i "${file_spi_union}.nii.gz" \
        -vert 2:4 -vertfile "${file_tss_vert}.nii.gz" \
        -o "${PATH_RESULTS}/method-spineps/${file}_canal.csv" -perlevel 1

    # aSCOR ratio
    sct_compute_ascor -i-SC "${file_spi_cord}.nii.gz" -i-canal "${file_spi_canal}.nii.gz" \
        -vert 2:4 -vertfile "${file_tss_vert}.nii.gz" \
        -o "${PATH_RESULTS}/method-spineps/${file}_ratio.csv" -perlevel 1
else
    echo "WARNING: spineps not found. Skipping Method 2 (SPINEPS)."
fi

# ======================================================================
# QC: Custom overlay comparing all methods (uses spline = best quality)
# ======================================================================
mkdir -p "${PATH_QC}/custom_overlays"

# Build SPINEPS args if available
SPINEPS_QC_ARGS=""
if [[ -f "${file_t2w}_seg-spineps-cord.nii.gz" ]]; then
    SPINEPS_QC_ARGS="--spineps-cord ${file_t2w}_seg-spineps-cord.nii.gz --spineps-canal ${file_t2w}_seg-spineps-cord-canal-union.nii.gz"
fi

python3 "${SCRIPT_DIR}/generate_qc.py" \
    -i "${file_t2w}.nii.gz" \
    --vertfile "${file_tss_vert}.nii.gz" \
    --totalspineseg-cord "${file_tss_cord}.nii.gz" \
    --totalspineseg-canal "${file_tss_union}.nii.gz" \
    --custom-atlas-cord "${file_tss_cord}.nii.gz" \
    --custom-atlas-canal "PAM50_atlas41_warped_spline_bin.nii.gz" \
    --pam50-cord "PAM50_cord_warped_spline_bin.nii.gz" \
    --pam50-canal "PAM50_canal_warped_spline_bin.nii.gz" \
    ${SPINEPS_QC_ARGS} \
    -o "${PATH_QC}/custom_overlays/${file}_qc.png" \
    --title "${file} — T2w"

# ======================================================================
# Done
# ======================================================================
end=$(date +%s)
runtime=$((end - start))
echo
echo "~~~"
echo "SCT version: $(sct_version)"
echo "Ran on:      $(uname -nsr)"
echo "Duration:    $(($runtime / 3600))hrs $((($runtime / 60) % 60))min $(($runtime % 60))sec"
echo "~~~"
