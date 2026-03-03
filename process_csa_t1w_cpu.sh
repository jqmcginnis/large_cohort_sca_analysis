#!/bin/bash
#
# T1w CPU phase: label parsing, registration, CSA, aSCOR, QC.
#
# This is the CPU half of the split pipeline. It expects GPU outputs to already
# exist in the subject directory (from process_csa_t1w_gpu.sh).
#
# Expected GPU outputs:
#   ${file_t1w}_step2_output.nii.gz  — multi-label segmentation
#   ${file_t1w}_step1_levels.nii.gz  — disc labels
#
# Methods:
#   1 — TotalSpineSeg  (cord + canal from DL segmentation)
#   3 — Atlas41        (PAM50_atlas_41 warped to native space)
#   4 — PAM50          (PAM50_cord+csf union warped to native)
#
# Usage (via sct_run_batch, called from run_pipeline.sh):
#   sct_run_batch -script process_csa_t1w_cpu.sh \
#       -path-data <PATH-TO-GPU-OUTPUT/data_processed> \
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

# Go to processing folder — data already in place from GPU phase
cd "${PATH_DATA_PROCESSED}"
file="${SUBJECT//[\/]/_}"

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

# Verify GPU outputs exist
file_totalseg_all="${file_t1w}_step2_output"
file_totalseg_discs="${file_t1w}_step1_levels"

if [[ ! -f "${file_totalseg_all}.nii.gz" ]]; then
    echo "ERROR: GPU output ${file_totalseg_all}.nii.gz not found for ${SUBJECT}. Run GPU phase first."
    exit 1
fi
if [[ ! -f "${file_totalseg_discs}.nii.gz" ]]; then
    echo "ERROR: GPU output ${file_totalseg_discs}.nii.gz not found for ${SUBJECT}. Run GPU phase first."
    exit 1
fi

# ======================================================================
# Phase 2: Parse TotalSpineSeg Labels (parallel)
# ======================================================================
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
                -d "${file_t1w}.nii.gz" \
                -w warp_template2anat.nii.gz \
                -x "${INTERP}" \
                -o "PAM50_canal_warped_${INTERP}.nii.gz" &
            pid_w1=$!

            sct_apply_transfo -i "${SCRIPT_DIR}/atlas/PAM50_atlas_41.nii.gz" \
                -d "${file_t1w}.nii.gz" \
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

# Wait for all parallel branches to complete
wait $pid_branch_a
wait $pid_branch_b

# ======================================================================
# QC: Custom overlay comparing all methods (uses spline = best quality)
# ======================================================================
mkdir -p "${PATH_QC}/custom_overlays"

python3 "${SCRIPT_DIR}/generate_qc.py" \
    -i "${file_t1w}.nii.gz" \
    --vertfile "${file_tss_vert}.nii.gz" \
    --totalspineseg-cord "${file_tss_cord}.nii.gz" \
    --totalspineseg-canal "${file_tss_union}.nii.gz" \
    --custom-atlas-cord "${file_tss_cord}.nii.gz" \
    --custom-atlas-canal "PAM50_atlas41_warped_spline_bin.nii.gz" \
    --pam50-cord "${file_tss_cord}.nii.gz" \
    --pam50-canal "PAM50_canal_warped_spline_bin.nii.gz" \
    -o "${PATH_QC}/custom_overlays/${file}_qc.png" \
    --title "${file} — T1w"

# ======================================================================
# Done
# ======================================================================
end=$(date +%s)
runtime=$((end - start))
echo
echo "~~~"
echo "CPU phase complete for ${SUBJECT}"
echo "SCT version: $(sct_version)"
echo "Ran on:      $(uname -nsr)"
echo "Duration:    $(($runtime / 3600))hrs $((($runtime / 60) % 60))min $(($runtime % 60))sec"
echo "~~~"
