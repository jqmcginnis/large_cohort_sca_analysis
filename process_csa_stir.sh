#!/bin/bash
#
# STIR (sagittal) spinal cord & canal CSA pipeline.
#
# Methods:
#   1 — TotalSpineSeg  (cord + canal from DL segmentation)
#   2 — SPINEPS        (cord + canal from DL segmentation, if installed)
#   3 — Atlas41        (PAM50_atlas_41 = full canal template, warped to native space)
#   4 — PAM50          (PAM50_cord+csf union warped to native; cord from TotalSpineSeg)
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
# Note: STIR filenames vary across subjects (chunk-stitched, chunk-cerv, etc.)
#       so this script discovers the STIR file dynamically in each session.
#
# Dependencies:
#   - SCT >= 7.1
#   - SPINEPS (pip install spineps) — optional
#   - Python packages: nibabel, numpy
#
# Usage (via sct_run_batch):
#   sct_run_batch -script process_csa_stir.sh \
#       -path-data <PATH-TO-STIR-DATASET> \
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
PAM50_DIR="${SCT_DIR}/data/PAM50"

# Go to processing folder
cd "${PATH_DATA_PROCESSED}"

# Copy source images
rsync -Ravzh "${PATH_DATA}/./${SUBJECT}" .
file="${SUBJECT//[\/]/_}"

cd "${SUBJECT}/anat/"

# Dynamically discover the STIR file (naming varies across subjects)
file_stir_nii=$(ls *_STIR.nii.gz 2>/dev/null | head -1) || true
if [[ -z "${file_stir_nii}" ]]; then
    echo "WARNING: No STIR file found for ${SUBJECT}. Skipping."
    exit 0
fi
file_stir="${file_stir_nii%.nii.gz}"
echo "Found STIR file: ${file_stir}"

# ======================================================================
# Phase 1: TotalSpineSeg Segmentation (GPU — serial)
# ======================================================================
sct_deepseg totalspineseg -i "${file_stir}.nii.gz" -qc "${PATH_QC}"

# Output products (SCT 7.1 naming: step1_* and step2_*)
file_totalseg_all="${file_stir}_step2_output"
file_totalseg_discs="${file_stir}_step1_levels"

# ======================================================================
# Phase 2: Parse TotalSpineSeg Labels (parallel)
# ======================================================================
# Naming: seg-<method>-<structure> for crystal-clear provenance
file_tss_cord="${file_stir}_seg-totalspineseg-cord"
file_tss_canal="${file_stir}_seg-totalspineseg-canal"
file_tss_union="${file_stir}_seg-totalspineseg-cord-canal-union"
file_tss_vert="${file_stir}_seg-totalspineseg-vertlevels"

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
        -o "${PATH_RESULTS}/method-totalspineseg/${file}_cord.csv" -vert 1:25 -perlevel 1 &
    pid1=$!

    sct_process_segmentation -i "${file_tss_union}.nii.gz" \
        -vertfile "${file_tss_vert}.nii.gz" \
        -o "${PATH_RESULTS}/method-totalspineseg/${file}_canal.csv" -vert 1:25 -perlevel 1 &
    pid2=$!

    sct_process_segmentation -i "${file_tss_canal}.nii.gz" \
        -vertfile "${file_tss_vert}.nii.gz" \
        -o "${file_tss_canal}_csa.csv" -vert 1:25 -perlevel 1 &
    pid3=$!

    wait $pid1
    wait $pid2
    wait $pid3

    python3 "${SCRIPT_DIR}/compute_ascor.py" \
        --cord-csa "${PATH_RESULTS}/method-totalspineseg/${file}_cord.csv" \
        --canal-csa "${file_tss_canal}_csa.csv" \
        -o "${PATH_RESULTS}/method-totalspineseg/${file}_ratio.csv"
) &
pid_branch_a=$!

# --- Branch B: Registration + Methods 3 & 4 ---
(
    # Filter disc labels to PAM50-compatible range (1-21, 60) — sagittal spine
    # images may cover discs beyond PAM50 template coverage
    file_discs_filtered="${file_totalseg_discs}_filtered"
    python3 "${SCRIPT_DIR}/filter_disc_labels.py" \
        -i "${file_totalseg_discs}.nii.gz" \
        -o "${file_discs_filtered}.nii.gz"

    sct_register_to_template -i "${file_stir}.nii.gz" \
        -s "${file_tss_cord}.nii.gz" \
        -ldisc "${file_discs_filtered}.nii.gz" \
        -c t2 -qc "${PATH_QC}"

    # PAM50_levels are labels → always use nearest-neighbor
    sct_apply_transfo -i "${PAM50_DIR}/template/PAM50_levels.nii.gz" \
        -d "${file_stir}.nii.gz" \
        -w warp_template2anat.nii.gz \
        -x nn \
        -o PAM50_levels_warped_nn.nii.gz

    # Pre-combine cord+CSF in template space (binary union) so that a single
    # warp preserves boundary voxels. Warping separately and combining in
    # native space loses voxels where cord=0.4 + csf=0.4 = 0.8 canal
    # probability — both get zeroed by independent 0.5 thresholds.
    sct_maths -i "${PAM50_DIR}/template/PAM50_cord.nii.gz" \
        -add "${PAM50_DIR}/template/PAM50_csf.nii.gz" \
        -o PAM50_cord_csf_union_template.nii.gz
    sct_maths -i PAM50_cord_csf_union_template.nii.gz -bin 0.5 \
        -o PAM50_cord_csf_union_template.nii.gz

    # --- 3 interpolation variants in parallel ---
    interp_pids=()
    for INTERP in nn linear spline; do
        (
            echo ">>> Warping templates with interpolation: ${INTERP}"

            # Warp 2 templates in parallel: cord+csf union, atlas41
            # No need to warp PAM50_cord — we use TotalSpineSeg cord (native space)
            sct_apply_transfo -i PAM50_cord_csf_union_template.nii.gz \
                -d "${file_stir}.nii.gz" \
                -w warp_template2anat.nii.gz \
                -x "${INTERP}" \
                -o "PAM50_canal_warped_${INTERP}.nii.gz" &
            pid_w1=$!

            sct_apply_transfo -i "${SCRIPT_DIR}/atlas/PAM50_atlas_41.nii.gz" \
                -d "${file_stir}.nii.gz" \
                -w warp_template2anat.nii.gz \
                -x "${INTERP}" \
                -o "PAM50_atlas41_warped_${INTERP}.nii.gz" &
            pid_w2=$!

            wait $pid_w1
            wait $pid_w2

            # Binarize warped templates in parallel
            sct_maths -i "PAM50_canal_warped_${INTERP}.nii.gz" -bin 0.5 \
                -o "PAM50_canal_warped_${INTERP}_bin.nii.gz" &
            pid_b1=$!

            sct_maths -i "PAM50_atlas41_warped_${INTERP}.nii.gz" -bin 0.5 \
                -o "PAM50_atlas41_warped_${INTERP}_bin.nii.gz" &
            pid_b2=$!

            wait $pid_b1
            wait $pid_b2

            # Post-process canal mask:
            # 1. Ensure canal ⊇ cord (warping can lose boundary voxels)
            # 2. Fill holes (spline interpolation creates gaps in the CSF ring)
            # Both are needed for clean QC contours and correct aSCOR.
            sct_maths -i "PAM50_canal_warped_${INTERP}_bin.nii.gz" \
                -add "${file_tss_cord}.nii.gz" \
                -o "PAM50_canal_warped_${INTERP}_bin.nii.gz"
            sct_maths -i "PAM50_canal_warped_${INTERP}_bin.nii.gz" -bin 0.5 \
                -o "PAM50_canal_warped_${INTERP}_bin.nii.gz"
            python3 -c "
import nibabel as nib, numpy as np
from scipy.ndimage import binary_fill_holes
img = nib.load('PAM50_canal_warped_${INTERP}_bin.nii.gz')
d = img.get_fdata()
for z in range(d.shape[2]):
    d[:,:,z] = binary_fill_holes(d[:,:,z])
nib.save(nib.Nifti1Image(d.astype(np.float32), img.affine, img.header), 'PAM50_canal_warped_${INTERP}_bin.nii.gz')
"

            # Create result directories
            mkdir -p "${PATH_RESULTS}/method-atlas41-warp-${INTERP}"
            mkdir -p "${PATH_RESULTS}/method-pam50-warp-${INTERP}"

            # Method 3 (Atlas41) and Method 4 (PAM50) in parallel
            (
                # Method 3: Atlas41 — CSA + aSCOR
                sct_process_segmentation -i "PAM50_atlas41_warped_${INTERP}_bin.nii.gz" \
                    -vertfile PAM50_levels_warped_nn.nii.gz \
                    -o "${PATH_RESULTS}/method-atlas41-warp-${INTERP}/${file}_canal.csv" -vert 1:25 -perlevel 1 &
                pid_c1=$!

                sct_process_segmentation -i "${file_tss_cord}.nii.gz" \
                    -vertfile PAM50_levels_warped_nn.nii.gz \
                    -o "${PATH_RESULTS}/method-atlas41-warp-${INTERP}/${file}_cord.csv" -vert 1:25 -perlevel 1 &
                pid_c2=$!

                {
                    sct_maths -i "PAM50_atlas41_warped_${INTERP}_bin.nii.gz" \
                        -sub "${file_tss_cord}.nii.gz" \
                        -o "PAM50_atlas41_canal_only_${INTERP}.nii.gz"
                    sct_maths -i "PAM50_atlas41_canal_only_${INTERP}.nii.gz" -bin 0.5 \
                        -o "PAM50_atlas41_canal_only_${INTERP}_bin.nii.gz"
                    sct_process_segmentation -i "PAM50_atlas41_canal_only_${INTERP}_bin.nii.gz" \
                        -vertfile PAM50_levels_warped_nn.nii.gz \
                        -o "atlas41_canal_only_${INTERP}_csa.csv" -vert 1:25 -perlevel 1
                } &
                pid_c3=$!

                wait $pid_c1
                wait $pid_c2
                wait $pid_c3

                python3 "${SCRIPT_DIR}/compute_ascor.py" \
                    --cord-csa "${PATH_RESULTS}/method-atlas41-warp-${INTERP}/${file}_cord.csv" \
                    --canal-csa "atlas41_canal_only_${INTERP}_csa.csv" \
                    -o "${PATH_RESULTS}/method-atlas41-warp-${INTERP}/${file}_ratio.csv"
            ) &
            pid_m3=$!

            (
                # Method 4: PAM50 — CSA + aSCOR
                # Cord CSA uses TotalSpineSeg cord (native) — no need for warped PAM50 cord
                sct_process_segmentation -i "PAM50_canal_warped_${INTERP}_bin.nii.gz" \
                    -vertfile PAM50_levels_warped_nn.nii.gz \
                    -o "${PATH_RESULTS}/method-pam50-warp-${INTERP}/${file}_canal.csv" -vert 1:25 -perlevel 1 &
                pid_c1=$!

                sct_process_segmentation -i "${file_tss_cord}.nii.gz" \
                    -vertfile PAM50_levels_warped_nn.nii.gz \
                    -o "${PATH_RESULTS}/method-pam50-warp-${INTERP}/${file}_cord.csv" -vert 1:25 -perlevel 1 &
                pid_c2=$!

                {
                    sct_maths -i "PAM50_canal_warped_${INTERP}_bin.nii.gz" \
                        -sub "${file_tss_cord}.nii.gz" \
                        -o "PAM50_canal_only_warped_${INTERP}.nii.gz"
                    sct_maths -i "PAM50_canal_only_warped_${INTERP}.nii.gz" -bin 0.5 \
                        -o "PAM50_canal_only_warped_${INTERP}_bin.nii.gz"
                    sct_process_segmentation -i "PAM50_canal_only_warped_${INTERP}_bin.nii.gz" \
                        -vertfile PAM50_levels_warped_nn.nii.gz \
                        -o "pam50_canal_only_${INTERP}_csa.csv" -vert 1:25 -perlevel 1
                } &
                pid_c3=$!

                wait $pid_c1
                wait $pid_c2
                wait $pid_c3

                python3 "${SCRIPT_DIR}/compute_ascor.py" \
                    --cord-csa "${PATH_RESULTS}/method-pam50-warp-${INTERP}/${file}_cord.csv" \
                    --canal-csa "pam50_canal_only_${INTERP}_csa.csv" \
                    -o "${PATH_RESULTS}/method-pam50-warp-${INTERP}/${file}_ratio.csv"
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
# SPINEPS is optional — failures must not kill the main pipeline
(
    set +e
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

        # SPINEPS rejects filenames containing "STIR" — create a T2-named symlink
        file_stir_spineps_input="${file_stir/_STIR/_T2}"
        ln -sf "${file_stir}.nii.gz" "${file_stir_spineps_input}.nii.gz"
        spineps sample -ignore_bids_filter -ignore_inference_compatibility -i "${file_stir_spineps_input}.nii.gz" -model_semantic t2w -model_instance instance

        # Deactivate back to base environment for SCT compatibility
        if [[ -n "${CONDA_DEFAULT_ENV}" && "${CONDA_DEFAULT_ENV}" == "spineps" ]]; then
            conda deactivate
        fi

        # SPINEPS outputs to derivatives_seg/ — entity order varies, so glob for it
        file_spineps_spine=$(ls "$(dirname "${file_stir_spineps_input}")"/derivatives_seg/*_seg-spine*msk.nii.gz 2>/dev/null | head -1)
        file_spineps_spine="${file_spineps_spine%.nii.gz}"
        file_spi_cord="${file_stir}_seg-spineps-cord"
        file_spi_canal="${file_stir}_seg-spineps-canal"
        file_spi_union="${file_stir}_seg-spineps-cord-canal-union"

        python3 "${SCRIPT_DIR}/process_spineps_seg.py" \
            -i "${file_spineps_spine}.nii.gz" \
            --cord "${file_spi_cord}.nii.gz" \
            --canal "${file_spi_canal}.nii.gz" \
            --combined "${file_spi_union}.nii.gz"

        mkdir -p "${PATH_RESULTS}/method-spineps"

        sct_process_segmentation -i "${file_spi_cord}.nii.gz" \
            -vertfile "${file_tss_vert}.nii.gz" \
            -o "${PATH_RESULTS}/method-spineps/${file}_cord.csv" -vert 1:25 -perlevel 1 &
        pid_s1=$!

        sct_process_segmentation -i "${file_spi_union}.nii.gz" \
            -vertfile "${file_tss_vert}.nii.gz" \
            -o "${PATH_RESULTS}/method-spineps/${file}_canal.csv" -vert 1:25 -perlevel 1 &
        pid_s2=$!

        sct_process_segmentation -i "${file_spi_canal}.nii.gz" \
            -vertfile "${file_tss_vert}.nii.gz" \
            -o "${file_spi_canal}_csa.csv" -vert 1:25 -perlevel 1 &
        pid_s3=$!

        wait $pid_s1
        wait $pid_s2
        wait $pid_s3

        python3 "${SCRIPT_DIR}/compute_ascor.py" \
            --cord-csa "${PATH_RESULTS}/method-spineps/${file}_cord.csv" \
            --canal-csa "${file_spi_canal}_csa.csv" \
            -o "${PATH_RESULTS}/method-spineps/${file}_ratio.csv"
    else
        echo "WARNING: spineps not found. Skipping Method 2 (SPINEPS)."
    fi
) &
pid_branch_c=$!

# Wait for all parallel branches to complete
wait $pid_branch_a
wait $pid_branch_b
wait $pid_branch_c || echo "WARNING: SPINEPS branch failed (non-critical). Continuing."

# ======================================================================
# QC: Custom overlay comparing all methods (uses spline = best quality)
# ======================================================================
mkdir -p "${PATH_QC}/custom_overlays"

# Build SPINEPS args if available (SPINEPS output uses _seg-spineps-* naming)
SPINEPS_QC_ARGS=""
for spi_cord_candidate in "${file_stir}_seg-spineps-cord.nii.gz" "${file_stir/_STIR/_T2}_seg-spineps-cord.nii.gz"; do
    if [[ -f "${spi_cord_candidate}" ]]; then
        spi_union_candidate="${spi_cord_candidate/-cord/-cord-canal-union}"
        SPINEPS_QC_ARGS="--spineps-cord ${spi_cord_candidate} --spineps-canal ${spi_union_candidate}"
        break
    fi
done

python3 "${SCRIPT_DIR}/generate_qc.py" \
    -i "${file_stir}.nii.gz" \
    --vertfile "${file_tss_vert}.nii.gz" \
    --totalspineseg-cord "${file_tss_cord}.nii.gz" \
    --totalspineseg-canal "${file_tss_union}.nii.gz" \
    --custom-atlas-cord "${file_tss_cord}.nii.gz" \
    --custom-atlas-canal "PAM50_atlas41_warped_spline_bin.nii.gz" \
    --pam50-cord "${file_tss_cord}.nii.gz" \
    --pam50-canal "PAM50_canal_warped_spline_bin.nii.gz" \
    ${SPINEPS_QC_ARGS} \
    -o "${PATH_QC}/custom_overlays/${file}_qc.png" \
    --title "${file} — STIR"

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
