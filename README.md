# Spinal Cord & Canal CSA Analysis Pipeline

Pipeline for computing spinal cord and canal cross-sectional area (CSA) and aSCOR across all vertebral levels, comparing four segmentation/template methods across three MRI contrasts.

## Quick Start

```bash
pip install -r requirements.txt

# Download PAM50_atlas_41.nii.gz from:
# https://github.com/neuroradiologyVH/Spinal-Cord-Canal-Template
mkdir -p atlas/  # place PAM50_atlas_41.nii.gz here

# Run once per contrast:
./run_pipeline.sh -path-data ~/data/mms_T1w-MPRAGE_selected -contrast t1w -output ~/output/t1w
./run_pipeline.sh -path-data ~/data/mms_acq-sag_T2w-STIR -contrast t2w  -output ~/output/t2w
./run_pipeline.sh -path-data ~/data/mms_acq-sag_T2w-STIR -contrast stir -output ~/output/stir
```

T2w and STIR can point to the **same BIDS directory** -- scripts discover files by suffix (`*_T2w.nii.gz` / `*_STIR.nii.gz`) and skip sessions that lack the expected contrast.

```
<dataset>/sub-XXX/ses-YYY/anat/sub-XXX_ses-YYY_T1w.nii.gz       # matched by *_T1w.nii.gz (or *_T1w-CE.nii.gz)
<dataset>/sub-XXX/ses-YYY/anat/sub-XXX_ses-YYY_*_T2w.nii.gz     # matched by *_T2w.nii.gz
<dataset>/sub-XXX/ses-YYY/anat/sub-XXX_ses-YYY_*_STIR.nii.gz    # matched by *_STIR.nii.gz
```

## Methods

| # | Method | Source | Contrasts |
|---|--------|--------|-----------|
| 1 | **TotalSpineSeg** | `sct_deepseg totalspineseg` (SCT) | T1w, T2w, STIR |
| 2 | **SPINEPS** | [spineps](https://github.com/Hendrik-code/spineps) | T2w only |
| 3 | **Atlas41** | [`PAM50_atlas_41`](https://github.com/neuroradiologyVH/Spinal-Cord-Canal-Template) warped to native | T1w, T2w, STIR |
| 4 | **PAM50** | SCT `PAM50_cord` + `PAM50_csf` warped to native | T1w, T2w, STIR |

Methods 3 & 4 run an **interpolation ablation** (nn, linear, spline) when warping templates to native space. All methods produce per-level cord CSA, canal CSA, and aSCOR (cord / canal-only ratio).

## Dependencies

- [Spinal Cord Toolbox (SCT)](https://spinalcordtoolbox.com/) >= 7.1
- [SPINEPS](https://github.com/Hendrik-code/spineps) (optional -- skipped gracefully if not installed)
- Python: `pip install -r requirements.txt`
- GPU recommended (CUDA) for sct_deepseg and SPINEPS

## Usage

### `run_pipeline.sh` (recommended)

| Flag | Description | Default |
|------|-------------|---------|
| `-path-data` | Path to BIDS dataset | **required** |
| `-contrast` | Contrast to process (`t1w`, `t2w`, or `stir`) | **required** |
| `-output` | Output directory | **required** |
| `-jobs-gpu` | Parallel GPU segmentation jobs | 4 |
| `-jobs-cpu` | Parallel CPU processing jobs | nproc/4 |
| `-include-list` | File with one subject ID per line | *(all)* |

Run once per contrast. Override ITK threads with `export ITK_THREADS=2` before launching.

### Standalone (single subject debugging)

```bash
sct_run_batch -script process_csa.sh \
    -path-data /path/to/data -path-output /path/to/output \
    -jobs 4 -script-args "t2w /path/to/this/repo"
```

First arg to `-script-args` is the contrast (`t1w`, `t2w`, or `stir`).

### Aggregate results

```bash
python3 parse_results.py --directory /path/to/output/results --info "MEAN(area)"
```

## Architecture

```
run_pipeline.sh -contrast <t1w|t2w|stir> (orchestrator, one contrast per run)
|
+-- Phase 1: GPU segmentation (-jobs-gpu N)
|     process_csa_gpu.sh <contrast>  -> rsync + sct_deepseg (+ SPINEPS for t2w)
|
+-- Phase 2: CPU processing (-jobs-cpu N)
      process_csa_cpu.sh <contrast>  -> labels, registration, CSA, aSCOR, QC
```

Within each subject (CPU phase), three branches run in parallel:
- **Branch A**: Method 1 (TotalSpineSeg) CSA
- **Branch B**: Registration + 3 interpolation variants x Methods 3 & 4
- **Branch C**: SPINEPS CSA (T2w only)

## QC

Each subject produces a multi-panel QC PNG in `qc/custom_overlays/` comparing all methods side-by-side. Layout: one row per method (+ native reference), columns for sagittal, coronal, and axial C1--C4 slices. Cord is shown as a colored overlay, canal as a yellow contour. The title includes contrast and interpolation method (e.g., `"sub-001_ses-01 -- T2W (interp: spline)"`).

SCT also generates its own HTML QC reports in `qc/` for `sct_deepseg` and `sct_register_to_template`.

## Output

```
<output>/
+-- results/
|   +-- method-totalspineseg/          # *_cord.csv, *_canal.csv, *_ratio.csv
|   +-- method-spineps/                # T2w only
|   +-- method-atlas41-warp-{nn,linear,spline}/
|   +-- method-pam50-warp-{nn,linear,spline}/
+-- data_processed/                    # Intermediate NIfTIs per subject
+-- log/                               # Per-subject logs
+-- qc/custom_overlays/                # QC PNGs
```

## Repository Structure

```
run_pipeline.sh              # Orchestrator
process_csa_gpu.sh           # GPU phase (parameterized by contrast)
process_csa_cpu.sh           # CPU phase (parameterized by contrast)
process_csa.sh               # Monolithic GPU+CPU (standalone use)
process_seg.py               # TotalSpineSeg multi-label -> binary masks
process_spineps_seg.py       # SPINEPS multi-label -> binary masks
relabel_vertebrae.py         # Remap vert labels to SCT convention
compute_ascor.py             # aSCOR from cord + canal CSA CSVs
filter_disc_labels.py        # Filter disc labels to PAM50-compatible range
fill_canal_holes.py          # Fill 2D holes in canal masks (post-warp)
generate_qc.py               # Multi-panel QC overlay PNG
parse_results.py             # Aggregate per-subject CSVs
atlas/PAM50_atlas_41.nii.gz  # Custom canal atlas (download separately)
```
