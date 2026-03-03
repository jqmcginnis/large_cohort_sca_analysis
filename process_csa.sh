#!/bin/bash
#
# Unified monolithic spinal cord & canal CSA pipeline (GPU + CPU combined).
#
# Parameterized by contrast — handles T1w, T2w, and STIR in a single script.
#
# Methods:
#   1 — TotalSpineSeg  (cord + canal from DL segmentation)
#   2 — SPINEPS        (cord + canal from DL segmentation, T2w only)
#   3 — Atlas41        (PAM50_atlas_41 warped to native space)
#   4 — PAM50          (PAM50_cord+csf union warped to native)
#
# Methods 3 & 4 run an interpolation ablation (nn, linear, spline) comparing
# different warping strategies for probabilistic templates.
#
# Parallelization strategy:
#   Phase 1: GPU segmentation (sct_deepseg + optional SPINEPS — serial)
#   Phase 2: Label parsing (process_seg + relabel_vertebrae — parallel)
#   Phase 3: Parallel branches:
#     A — Method 1 (TotalSpineSeg) CSA
#     B — Registration + Methods 3 & 4 (3 interpolation variants in parallel)
#     C — SPINEPS CSA (T2w only, if GPU output exists)
#   ITK threads are capped to prevent oversubscription with sct_run_batch -jobs N.
#   Override with: export ITK_THREADS=2 (before sct_run_batch).
#
# Dependencies:
#   - SCT >= 7.1
#   - SPINEPS (pip install spineps) — optional, T2w only
#   - Python packages: nibabel, numpy
#
# Usage (via sct_run_batch):
#   sct_run_batch -script process_csa.sh \
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

# ITK thread control — prevent oversubscription when sct_run_batch uses -jobs N
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${ITK_THREADS:-4}"

# Retrieve input params
SUBJECT=$1
CONTRAST=$2
SCRIPT_DIR=$3

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
file_base="${file_nii%.nii.gz}"
echo "Found ${CONTRAST} file: ${file_base}"

# Registration contrast flag
case "$CONTRAST" in
    t1w) REG_CONTRAST="t1" ;;
    *)   REG_CONTRAST="t2" ;;
esac

# QC title
CONTRAST_UPPER=$(echo "$CONTRAST" | tr '[:lower:]' '[:upper:]')

# ======================================================================
# Phase 1: TotalSpineSeg Segmentation (GPU — serial)
# ======================================================================
sct_deepseg totalspineseg -i "${file_base}.nii.gz" -qc "${PATH_QC}"

# Output products (SCT 7.1 naming: step1_* and step2_*)
file_totalseg_all="${file_base}_step2_output"
file_totalseg_discs="${file_base}_step1_levels"

# ======================================================================
# Phase 1b: SPINEPS Segmentation (GPU, T2w only)
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
            -i "${file_base}.nii.gz" -model_semantic t2w -model_instance instance

        if [[ -n "${CONDA_DEFAULT_ENV}" && "${CONDA_DEFAULT_ENV}" == "spineps" ]]; then
            conda deactivate
        fi
    else
        echo "WARNING: spineps not found. Skipping Method 2 (SPINEPS)."
    fi
    set -e
fi

# ======================================================================
# Phase 2: Parse TotalSpineSeg Labels (parallel)
# ======================================================================
file_tss_cord="${file_base}_seg-totalspineseg-cord"
file_tss_canal="${file_base}_seg-totalspineseg-canal"
file_tss_union="${file_base}_seg-totalspineseg-cord-canal-union"
file_tss_vert="${file_base}_seg-totalspineseg-vertlevels"

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
    # Filter disc labels to PAM50-compatible range (1-21, 60)
    file_discs_filtered="${file_totalseg_discs}_filtered"
    python3 "${SCRIPT_DIR}/filter_disc_labels.py" \
        -i "${file_totalseg_discs}.nii.gz" \
        -o "${file_discs_filtered}.nii.gz"

    sct_register_to_template -i "${file_base}.nii.gz" \
        -s "${file_tss_cord}.nii.gz" \
        -ldisc "${file_discs_filtered}.nii.gz" \
        -c "$REG_CONTRAST" -qc "${PATH_QC}"

    # PAM50_levels are labels → always use nearest-neighbor
    sct_apply_transfo -i "${PAM50_DIR}/template/PAM50_levels.nii.gz" \
        -d "${file_base}.nii.gz" \
        -w warp_template2anat.nii.gz \
        -x nn \
        -o PAM50_levels_warped_nn.nii.gz

    # Pre-combine cord+CSF in template space (binary union)
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

            sct_apply_transfo -i PAM50_cord_csf_union_template.nii.gz \
                -d "${file_base}.nii.gz" \
                -w warp_template2anat.nii.gz \
                -x "${INTERP}" \
                -o "PAM50_canal_warped_${INTERP}.nii.gz" &
            pid_w1=$!

            sct_apply_transfo -i "${SCRIPT_DIR}/atlas/PAM50_atlas_41.nii.gz" \
                -d "${file_base}.nii.gz" \
                -w warp_template2anat.nii.gz \
                -x "${INTERP}" \
                -o "PAM50_atlas41_warped_${INTERP}.nii.gz" &
            pid_w2=$!

            wait $pid_w1
            wait $pid_w2

            sct_maths -i "PAM50_canal_warped_${INTERP}.nii.gz" -bin 0.5 \
                -o "PAM50_canal_warped_${INTERP}_bin.nii.gz" &
            pid_b1=$!

            sct_maths -i "PAM50_atlas41_warped_${INTERP}.nii.gz" -bin 0.5 \
                -o "PAM50_atlas41_warped_${INTERP}_bin.nii.gz" &
            pid_b2=$!

            wait $pid_b1
            wait $pid_b2

            # Post-process canal mask: union with cord + fill holes
            sct_maths -i "PAM50_canal_warped_${INTERP}_bin.nii.gz" \
                -add "${file_tss_cord}.nii.gz" \
                -o "PAM50_canal_warped_${INTERP}_bin.nii.gz"
            sct_maths -i "PAM50_canal_warped_${INTERP}_bin.nii.gz" -bin 0.5 \
                -o "PAM50_canal_warped_${INTERP}_bin.nii.gz"
            python3 "${SCRIPT_DIR}/fill_canal_holes.py" \
                -i "PAM50_canal_warped_${INTERP}_bin.nii.gz" \
                -o "PAM50_canal_warped_${INTERP}_bin.nii.gz"

            # Create result directories
            mkdir -p "${PATH_RESULTS}/method-atlas41-warp-${INTERP}"
            mkdir -p "${PATH_RESULTS}/method-pam50-warp-${INTERP}"

            # Method 3 (Atlas41) and Method 4 (PAM50) in parallel
            (
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

# --- Branch C: SPINEPS CSA (T2w only) ---
if [[ "$CONTRAST" == "t2w" ]]; then
    (
        set +e
        # SPINEPS outputs to derivatives_seg/ — check if GPU phase produced them
        file_spineps_spine=$(ls "$(dirname "${file_base}")"/derivatives_seg/*_seg-spine*msk.nii.gz 2>/dev/null | head -1)

        if [[ -n "${file_spineps_spine}" ]]; then
            file_spineps_spine="${file_spineps_spine%.nii.gz}"
            file_spi_cord="${file_base}_seg-spineps-cord"
            file_spi_canal="${file_base}_seg-spineps-canal"
            file_spi_union="${file_base}_seg-spineps-cord-canal-union"

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
            echo "INFO: No SPINEPS GPU output found. Skipping Method 2 (SPINEPS)."
        fi
    ) &
    pid_branch_c=$!
fi

# Wait for all parallel branches to complete
wait $pid_branch_a
wait $pid_branch_b
if [[ "$CONTRAST" == "t2w" ]]; then
    wait $pid_branch_c || echo "WARNING: SPINEPS branch failed (non-critical). Continuing."
fi

# ======================================================================
# QC: Custom overlay comparing all methods (uses spline = best quality)
# ======================================================================
mkdir -p "${PATH_QC}/custom_overlays"

# Build SPINEPS args if available (T2w only)
SPINEPS_QC_ARGS=""
if [[ "$CONTRAST" == "t2w" && -f "${file_base}_seg-spineps-cord.nii.gz" ]]; then
    SPINEPS_QC_ARGS="--spineps-cord ${file_base}_seg-spineps-cord.nii.gz --spineps-canal ${file_base}_seg-spineps-cord-canal-union.nii.gz"
fi

python3 "${SCRIPT_DIR}/generate_qc.py" \
    -i "${file_base}.nii.gz" \
    --vertfile "${file_tss_vert}.nii.gz" \
    --totalspineseg-cord "${file_tss_cord}.nii.gz" \
    --totalspineseg-canal "${file_tss_union}.nii.gz" \
    --custom-atlas-cord "${file_tss_cord}.nii.gz" \
    --custom-atlas-canal "PAM50_atlas41_warped_spline_bin.nii.gz" \
    --pam50-cord "${file_tss_cord}.nii.gz" \
    --pam50-canal "PAM50_canal_warped_spline_bin.nii.gz" \
    ${SPINEPS_QC_ARGS} \
    -o "${PATH_QC}/custom_overlays/${file}_qc.png" \
    --title "${file} — ${CONTRAST_UPPER}" \
    --interp spline

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
