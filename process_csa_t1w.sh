#!/bin/bash
#
# T1w (MPRAGE) spinal cord & canal CSA pipeline.
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
# Parallelization strategy:
#   Phase 1: GPU segmentation (sct_deepseg — serial)
#   Phase 2: Label parsing (process_seg + relabel_vertebrae — parallel)
#   Phase 3: Three parallel branches:
#     A — Method 1 (TotalSpineSeg) CSA
#     B — Registration + Methods 3 & 4 (3 interpolation variants in parallel)
#     C — SPINEPS segmentation (GPU) + Method 2 CSA
#   ITK threads are capped to prevent oversubscription with sct_run_batch -jobs N.
#   Override with: export ITK_THREADS=2 (before sct_run_batch).
#
# Note: T1w filenames vary (T1w vs T1w-CE) so this script discovers the file
#       dynamically. Prefers non-CE T1w; falls back to T1w-CE if unavailable.
#
# Dependencies:
#   - SCT >= 7.2.0
#   - SPINEPS (pip install spineps) — optional
#   - Python packages: nibabel, numpy
#
# Usage (via sct_run_batch):
#   sct_run_batch -script process_csa_t1w.sh \
#       -path-data <PATH-TO-T1W-DATASET> \
#       -path-output <PATH-TO-OUTPUT> \
#       -jobs <N> \
#       -script-args <PATH-TO-THIS-REPO>

# BASH SETTINGS
set -x
set -e -o pipefail
trap "echo Caught Keyboard Interrupt within script. Exiting now.; exit" INT

# ITK thread control — prevent oversubscription when sct_run_batch uses -jobs N
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${ITK_THREADS:-4}"

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

# Dynamically discover the T1w file (prefer non-CE; fall back to T1w-CE)
file_t1w_nii=$(ls *_T1w.nii.gz 2>/dev/null | head -1)
if [[ -z "${file_t1w_nii}" ]]; then
    file_t1w_nii=$(ls *_T1w-CE.nii.gz 2>/dev/null | head -1)
fi
if [[ -z "${file_t1w_nii}" ]]; then
    echo "WARNING: No T1w file found for ${SUBJECT}. Skipping."
    exit 0
fi
file_t1w="${file_t1w_nii%.nii.gz}"
echo "Found T1w file: ${file_t1w}"

# ======================================================================
# Phase 1: TotalSpineSeg Segmentation (GPU — serial)
# ======================================================================
sct_deepseg spine -i "${file_t1w}.nii.gz" -label-vert 1 -qc "${PATH_QC}"

# Output products (standard SCT naming)
file_totalseg_all="${file_t1w}_totalspineseg_all"
file_totalseg_discs="${file_t1w}_totalspineseg_discs"

# ======================================================================
# Phase 2: Parse TotalSpineSeg Labels (parallel)
# ======================================================================
# Naming: seg-<method>-<structure> for crystal-clear provenance
file_tss_cord="${file_t1w}_seg-totalspineseg-cord"
file_tss_canal="${file_t1w}_seg-totalspineseg-canal"
file_tss_union="${file_t1w}_seg-totalspineseg-cord-canal-union"
file_tss_vert="${file_t1w}_seg-totalspineseg-vertlevels"

python3 "${SCRIPT_DIR}/process_seg.py" \
    -i "${file_totalseg_all}.nii.gz" \
    --cord "${file_tss_cord}.nii.gz" \
    --canal "${file_tss_canal}.nii.gz" \
    --combined "${file_tss_union}.nii.gz" &
pid_seg=$!

python3 "${SCRIPT_DIR}/relabel_vertebrae.py" \
    --mask "${file_totalseg_all}.nii.gz" \
    --out "${file_tss_vert}.nii.gz" &
pid_vert=$!

wait $pid_seg
wait $pid_vert

# ======================================================================
# Phase 3: Parallel CPU branches
# ======================================================================

# --- Branch A: Method 1 (TotalSpineSeg) CSA ---
(
    mkdir -p "${PATH_RESULTS}/method-totalspineseg"

    sct_process_segmentation -i "${file_tss_cord}.nii.gz" \
        -vertfile "${file_tss_vert}.nii.gz" \
        -o "${PATH_RESULTS}/method-totalspineseg/${file}_cord.csv" -perlevel 1 &
    pid1=$!

    sct_process_segmentation -i "${file_tss_union}.nii.gz" \
        -vertfile "${file_tss_vert}.nii.gz" \
        -o "${PATH_RESULTS}/method-totalspineseg/${file}_canal.csv" -perlevel 1 &
    pid2=$!

    sct_compute_ascor -i-SC "${file_tss_cord}.nii.gz" -i-canal "${file_tss_canal}.nii.gz" \
        -vertfile "${file_tss_vert}.nii.gz" \
        -o "${PATH_RESULTS}/method-totalspineseg/${file}_ratio.csv" -perlevel 1 &
    pid3=$!

    wait $pid1
    wait $pid2
    wait $pid3
) &
pid_branch_a=$!

# --- Branch B: Registration + Methods 3 & 4 ---
(
    # Filter disc labels to PAM50-compatible range (1-21, 60)
    file_discs_filtered="${file_totalseg_discs}_filtered"
    python3 "${SCRIPT_DIR}/filter_disc_labels.py" \
        -i "${file_totalseg_discs}.nii.gz" \
        -o "${file_discs_filtered}.nii.gz"

    sct_register_to_template -i "${file_t1w}.nii.gz" \
        -s "${file_tss_cord}.nii.gz" \
        -ldisc "${file_discs_filtered}.nii.gz" \
        -c t1 -qc "${PATH_QC}"

    # PAM50_levels are labels → always use nearest-neighbor
    sct_apply_transfo -i "${PAM50_DIR}/template/PAM50_levels.nii.gz" \
        -d "${file_t1w}.nii.gz" \
        -w warp_template2anat.nii.gz \
        -x nn \
        -o PAM50_levels_warped_nn.nii.gz

    # --- 3 interpolation variants in parallel ---
    interp_pids=()
    for INTERP in nn linear spline; do
        (
            echo ">>> Warping templates with interpolation: ${INTERP}"

            # Warp 3 templates in parallel
            sct_apply_transfo -i "${PAM50_DIR}/template/PAM50_cord.nii.gz" \
                -d "${file_t1w}.nii.gz" \
                -w warp_template2anat.nii.gz \
                -x "${INTERP}" \
                -o "PAM50_cord_warped_${INTERP}.nii.gz" &
            pid_w1=$!

            sct_apply_transfo -i "${PAM50_DIR}/template/PAM50_csf.nii.gz" \
                -d "${file_t1w}.nii.gz" \
                -w warp_template2anat.nii.gz \
                -x "${INTERP}" \
                -o "PAM50_csf_warped_${INTERP}.nii.gz" &
            pid_w2=$!

            sct_apply_transfo -i "${SCRIPT_DIR}/atlas/PAM50_atlas_41.nii.gz" \
                -d "${file_t1w}.nii.gz" \
                -w warp_template2anat.nii.gz \
                -x "${INTERP}" \
                -o "PAM50_atlas41_warped_${INTERP}.nii.gz" &
            pid_w3=$!

            wait $pid_w1
            wait $pid_w2
            wait $pid_w3

            # Binarize warped templates in parallel
            sct_maths -i "PAM50_cord_warped_${INTERP}.nii.gz" -bin 0.5 \
                -o "PAM50_cord_warped_${INTERP}_bin.nii.gz" &
            pid_b1=$!

            sct_maths -i "PAM50_csf_warped_${INTERP}.nii.gz" -bin 0.5 \
                -o "PAM50_csf_warped_${INTERP}_bin.nii.gz" &
            pid_b2=$!

            sct_maths -i "PAM50_atlas41_warped_${INTERP}.nii.gz" -bin 0.5 \
                -o "PAM50_atlas41_warped_${INTERP}_bin.nii.gz" &
            pid_b3=$!

            wait $pid_b1
            wait $pid_b2
            wait $pid_b3

            # PAM50 canal = cord + CSF union (sequential — needs cord_bin + csf_bin)
            sct_maths -i "PAM50_cord_warped_${INTERP}_bin.nii.gz" \
                -add "PAM50_csf_warped_${INTERP}_bin.nii.gz" \
                -o "PAM50_canal_warped_${INTERP}_union.nii.gz"
            sct_maths -i "PAM50_canal_warped_${INTERP}_union.nii.gz" -bin 0.5 \
                -o "PAM50_canal_warped_${INTERP}_bin.nii.gz"

            # Create result directories
            mkdir -p "${PATH_RESULTS}/method-atlas41-warp-${INTERP}"
            mkdir -p "${PATH_RESULTS}/method-pam50-warp-${INTERP}"

            # Method 3 (Atlas41) and Method 4 (PAM50) in parallel
            (
                # Method 3: Atlas41 — CSA + aSCOR
                sct_process_segmentation -i "PAM50_atlas41_warped_${INTERP}_bin.nii.gz" \
                    -vertfile PAM50_levels_warped_nn.nii.gz \
                    -o "${PATH_RESULTS}/method-atlas41-warp-${INTERP}/${file}_canal.csv" -perlevel 1 &
                pid_c1=$!

                sct_process_segmentation -i "${file_tss_cord}.nii.gz" \
                    -vertfile PAM50_levels_warped_nn.nii.gz \
                    -o "${PATH_RESULTS}/method-atlas41-warp-${INTERP}/${file}_cord.csv" -perlevel 1 &
                pid_c2=$!

                {
                    sct_maths -i "PAM50_atlas41_warped_${INTERP}_bin.nii.gz" \
                        -sub "${file_tss_cord}.nii.gz" \
                        -o "PAM50_atlas41_canal_only_${INTERP}.nii.gz"
                    sct_maths -i "PAM50_atlas41_canal_only_${INTERP}.nii.gz" -bin 0.5 \
                        -o "PAM50_atlas41_canal_only_${INTERP}_bin.nii.gz"
                    sct_compute_ascor -i-SC "${file_tss_cord}.nii.gz" \
                        -i-canal "PAM50_atlas41_canal_only_${INTERP}_bin.nii.gz" \
                        -vertfile PAM50_levels_warped_nn.nii.gz \
                        -o "${PATH_RESULTS}/method-atlas41-warp-${INTERP}/${file}_ratio.csv" -perlevel 1
                } &
                pid_c3=$!

                wait $pid_c1
                wait $pid_c2
                wait $pid_c3
            ) &
            pid_m3=$!

            (
                # Method 4: PAM50 — CSA + aSCOR
                sct_process_segmentation -i "PAM50_canal_warped_${INTERP}_bin.nii.gz" \
                    -vertfile PAM50_levels_warped_nn.nii.gz \
                    -o "${PATH_RESULTS}/method-pam50-warp-${INTERP}/${file}_canal.csv" -perlevel 1 &
                pid_c1=$!

                sct_process_segmentation -i "PAM50_cord_warped_${INTERP}_bin.nii.gz" \
                    -vertfile PAM50_levels_warped_nn.nii.gz \
                    -o "${PATH_RESULTS}/method-pam50-warp-${INTERP}/${file}_cord.csv" -perlevel 1 &
                pid_c2=$!

                {
                    sct_maths -i "PAM50_canal_warped_${INTERP}_bin.nii.gz" \
                        -sub "${file_tss_cord}.nii.gz" \
                        -o "PAM50_canal_only_warped_${INTERP}.nii.gz"
                    sct_maths -i "PAM50_canal_only_warped_${INTERP}.nii.gz" -bin 0.5 \
                        -o "PAM50_canal_only_warped_${INTERP}_bin.nii.gz"
                    sct_compute_ascor -i-SC "${file_tss_cord}.nii.gz" \
                        -i-canal "PAM50_canal_only_warped_${INTERP}_bin.nii.gz" \
                        -vertfile PAM50_levels_warped_nn.nii.gz \
                        -o "${PATH_RESULTS}/method-pam50-warp-${INTERP}/${file}_ratio.csv" -perlevel 1
                } &
                pid_c3=$!

                wait $pid_c1
                wait $pid_c2
                wait $pid_c3
            ) &
            pid_m4=$!

            wait $pid_m3
            wait $pid_m4
        ) &
        interp_pids+=($!)
    done
    for pid in "${interp_pids[@]}"; do
        wait "$pid"
    done
) &
pid_branch_b=$!

# --- Branch C: SPINEPS (GPU + CPU) ---
(
    SPINEPS_AVAILABLE=false
    if [[ -d "${HOME}/anaconda3/envs/spineps" ]]; then
        SPINEPS_AVAILABLE=true
    elif command -v spineps &>/dev/null; then
        SPINEPS_AVAILABLE=true
    fi

    if [[ "${SPINEPS_AVAILABLE}" == "true" ]]; then
        # Activate spineps conda env if needed
        if ! command -v spineps &>/dev/null; then
            source "${HOME}/anaconda3/etc/profile.d/conda.sh"
            conda activate spineps
        fi

        spineps sample -i "${file_t1w}.nii.gz" -model_semantic t2w -model_instance instance

        # Deactivate back to base environment for SCT compatibility
        if [[ -n "${CONDA_DEFAULT_ENV}" && "${CONDA_DEFAULT_ENV}" == "spineps" ]]; then
            conda deactivate
        fi

        # SPINEPS outputs to derivatives_seg/ with _mod-{suffix} naming
        spineps_base="$(basename "${file_t1w}")"
        file_spineps_spine="$(dirname "${file_t1w}")/derivatives_seg/${spineps_base%_T1w}_mod-T1w_seg-spine_msk"
        file_spi_cord="${file_t1w}_seg-spineps-cord"
        file_spi_canal="${file_t1w}_seg-spineps-canal"
        file_spi_union="${file_t1w}_seg-spineps-cord-canal-union"

        python3 "${SCRIPT_DIR}/process_spineps_seg.py" \
            -i "${file_spineps_spine}.nii.gz" \
            --cord "${file_spi_cord}.nii.gz" \
            --canal "${file_spi_canal}.nii.gz" \
            --combined "${file_spi_union}.nii.gz"

        mkdir -p "${PATH_RESULTS}/method-spineps"

        sct_process_segmentation -i "${file_spi_cord}.nii.gz" \
            -vertfile "${file_tss_vert}.nii.gz" \
            -o "${PATH_RESULTS}/method-spineps/${file}_cord.csv" -perlevel 1 &
        pid_s1=$!

        sct_process_segmentation -i "${file_spi_union}.nii.gz" \
            -vertfile "${file_tss_vert}.nii.gz" \
            -o "${PATH_RESULTS}/method-spineps/${file}_canal.csv" -perlevel 1 &
        pid_s2=$!

        sct_compute_ascor -i-SC "${file_spi_cord}.nii.gz" -i-canal "${file_spi_canal}.nii.gz" \
            -vertfile "${file_tss_vert}.nii.gz" \
            -o "${PATH_RESULTS}/method-spineps/${file}_ratio.csv" -perlevel 1 &
        pid_s3=$!

        wait $pid_s1
        wait $pid_s2
        wait $pid_s3
    else
        echo "WARNING: spineps not found. Skipping Method 2 (SPINEPS)."
    fi
) &
pid_branch_c=$!

# Wait for all parallel branches to complete
wait $pid_branch_a
wait $pid_branch_b
wait $pid_branch_c

# ======================================================================
# QC: Custom overlay comparing all methods (uses spline = best quality)
# ======================================================================
mkdir -p "${PATH_QC}/custom_overlays"

# Build SPINEPS args if available
SPINEPS_QC_ARGS=""
if [[ -f "${file_t1w}_seg-spineps-cord.nii.gz" ]]; then
    SPINEPS_QC_ARGS="--spineps-cord ${file_t1w}_seg-spineps-cord.nii.gz --spineps-canal ${file_t1w}_seg-spineps-cord-canal-union.nii.gz"
fi

python3 "${SCRIPT_DIR}/generate_qc.py" \
    -i "${file_t1w}.nii.gz" \
    --vertfile "${file_tss_vert}.nii.gz" \
    --totalspineseg-cord "${file_tss_cord}.nii.gz" \
    --totalspineseg-canal "${file_tss_union}.nii.gz" \
    --custom-atlas-cord "${file_tss_cord}.nii.gz" \
    --custom-atlas-canal "PAM50_atlas41_warped_spline_bin.nii.gz" \
    --pam50-cord "PAM50_cord_warped_spline_bin.nii.gz" \
    --pam50-canal "PAM50_canal_warped_spline_bin.nii.gz" \
    ${SPINEPS_QC_ARGS} \
    -o "${PATH_QC}/custom_overlays/${file}_qc.png" \
    --title "${file} — T1w"

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
