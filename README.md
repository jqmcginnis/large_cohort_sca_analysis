# Spinal Cord & Canal CSA Analysis Pipeline

Publication-ready pipeline for computing spinal cord and canal cross-sectional area (CSA) and aSCOR (age-adjusted spinal cord occupation ratio) across all vertebral levels, comparing four segmentation/template methods across three MRI contrasts.

## Quick Start

```bash
# 1. Install dependencies
pip install -r requirements.txt

# 2. Download the custom canal atlas
mkdir -p atlas/
# Get PAM50_atlas_41.nii.gz from:
# https://github.com/neuroradiologyVH/Spinal-Cord-Canal-Template

# 3. Run the pipeline (any combination of contrasts)
./run_pipeline.sh \
    -t1w-data /path/to/t1w/dataset \
    -t2w-data /path/to/t2w/dataset \
    -stir-data /path/to/stir/dataset \
    -output /path/to/output \
    -jobs-gpu 4 \
    -jobs-cpu 16

# Example with real paths (T2w and STIR share the same BIDS directory):
./run_pipeline.sh \
    -t1w-data  ~/data/mms_T1w-MPRAGE_selected \
    -t2w-data  ~/data/mms_acq-sag_T2w-STIR_desc-sc_qced_filtered \
    -stir-data ~/data/mms_acq-sag_T2w-STIR_desc-sc_qced_filtered \
    -output ~/output/csa_results \
    -jobs-gpu 4 -jobs-cpu 16
```

Expected BIDS layout per contrast:

```
mms_T1w-MPRAGE_selected/                              # -t1w-data
  sub-XXX/ses-YYY/anat/sub-XXX_ses-YYY_T1w.nii.gz     # (or *_T1w-CE.nii.gz)

mms_acq-sag_T2w-STIR_desc-sc_qced_filtered/           # -t2w-data AND -stir-data
  sub-XXX/ses-YYY/anat/sub-XXX_ses-YYY_*_T2w.nii.gz   # matched by *_T2w.nii.gz
  sub-XXX/ses-YYY/anat/sub-XXX_ses-YYY_*_STIR.nii.gz  # matched by *_STIR.nii.gz
```

T2w and STIR can point to the **same directory** -- the scripts discover files by suffix and gracefully skip sessions that lack the expected contrast.

## Methods

| # | Method | Source | Cord | Canal | aSCOR | Contrasts |
|---|--------|--------|------|-------|-------|-----------|
| 1 | **TotalSpineSeg** | `sct_deepseg totalspineseg` (SCT) | DL segmentation (label 1) | DL segmentation cord+canal union (labels 1+2) | cord / canal-only (label 2) | T1w, T2w, STIR |
| 2 | **SPINEPS** | [spineps](https://github.com/Hendrik-code/spineps) | DL segmentation (label 60) | DL segmentation cord+canal union (labels 60+61) | cord / canal-only (label 61) | T2w |
| 3 | **Atlas41** | [`PAM50_atlas_41.nii.gz`](https://github.com/neuroradiologyVH/Spinal-Cord-Canal-Template) warped to native | TotalSpineSeg cord | Warped atlas (includes cord) | cord / (atlas41 - cord) | T1w, T2w, STIR |
| 4 | **PAM50** | SCT built-in `PAM50_cord` + `PAM50_csf` warped to native | TotalSpineSeg cord | Warped PAM50_cord + PAM50_csf union | cord / (union - cord) | T1w, T2w, STIR |

> **Note:** SPINEPS (Method 2) runs only on T2w -- its instance segmentation is unreliable on T1w and not supported for STIR.

### Contrast-dependent behavior

All processing logic lives in a single parameterized script per phase. The contrast (`t1w`, `t2w`, `stir`) controls:

| Feature | t1w | t2w | stir |
|---------|-----|-----|------|
| File glob | `*_T1w.nii.gz` (+ `*_T1w-CE.nii.gz` fallback) | `*_T2w.nii.gz` | `*_STIR.nii.gz` |
| Registration | `-c t1` | `-c t2` | `-c t2` |
| SPINEPS | -- | Yes | -- |
| QC title | "T1W" | "T2W" | "STIR" |

### Segmentation label reference

**TotalSpineSeg** (`sct_deepseg totalspineseg`, via SCT) -- `_step2_output.nii.gz`:

| Label | Structure |
|-------|-----------|
| 1 | Spinal cord |
| 2 | Spinal canal (CSF only, does NOT include cord) |
| 11--17 | Vertebral levels C1--C7 |
| 21--32 | Vertebral levels T1--T12 |
| 41--45 | Vertebral levels L1--L5 |
| 50 | Sacrum (S1) |

**SPINEPS** ([spineps](https://github.com/Hendrik-code/spineps)) -- `_seg-spine_msk.nii.gz`:

| Label | Structure |
|-------|-----------|
| 60 | Spinal cord |
| 61 | Spinal canal (CSF only, does NOT include cord) |

Both tools output cord and canal as separate labels. The pipeline parses these into individual binary masks using `process_seg.py` (TotalSpineSeg) and `process_spineps_seg.py` (SPINEPS), with Z-range intersection to ensure cord and canal occupy the same slices.

### Key differences between canal definitions

- **Atlas41** (`PAM50_atlas_41`): A single template that represents the **full spinal canal** (cord + CSF). When warped and binarized, it directly gives the canal mask.
- **PAM50**: Uses two separate SCT templates -- `PAM50_cord` (cord only) and `PAM50_csf` (CSF only, does NOT include cord). These are pre-combined in template space, then warped as a single volume and binarized.

### aSCOR computation

All four methods produce aSCOR (`_ratio.csv`) via `compute_ascor.py` (custom replacement for `sct_compute_ascor`, compatible with SCT 7.1+). This requires a **canal-only** mask (CSF without cord):

- **Methods 1 & 2**: The DL segmentation directly provides separate cord and canal labels.
- **Methods 3 & 4**: Canal-only is derived by subtracting the TotalSpineSeg cord mask from the warped union (atlas41 or PAM50 cord+CSF), followed by binarization at threshold 0.5.

### Interpolation ablation

Methods 3 and 4 involve warping probabilistic templates from PAM50 space to native space. Each pipeline runs an ablation over three interpolation modes:

| Interpolation | Flag | Behavior |
|---------------|------|----------|
| **Nearest-neighbor** | `-x nn` | Binary output, may produce holes/artifacts |
| **Linear** | `-x linear` | Smooth output, moderate quality |
| **Spline** | `-x spline` | Smoothest output, best quality (default for QC) |

PAM50_levels (vertebral labels) always use NN since they are discrete labels.

### Canal post-processing

After warping, the canal mask undergoes two post-processing steps (via `fill_canal_holes.py`):

1. **Union with cord**: Ensures the canal mask is a superset of the cord (`canal >= cord`), since warping can lose boundary voxels.
2. **2D hole filling**: Fills gaps in the CSF ring slice-by-slice using `scipy.ndimage.binary_fill_holes`. Spline interpolation in particular can create donut-shaped artifacts that need filling.

### Vertebral levels

Analysis covers **all vertebral levels** present in the segmentation (C1--C7, T1--T12, L1--L5, S1). The `relabel_vertebrae.py` script maps TotalSpineSeg labels to SCT convention:

| Region | TotalSpineSeg labels | SCT labels |
|--------|---------------------|------------|
| Cervical (C1--C7) | 11--17 | 1--7 |
| Thoracic (T1--T12) | 21--32 | 8--19 |
| Lumbar (L1--L5) | 41--45 | 20--24 |
| Sacrum (S1) | 50 | 25 |

## Dependencies

- [Spinal Cord Toolbox (SCT)](https://spinalcordtoolbox.com/) >= 7.1
- [SPINEPS](https://github.com/Hendrik-code/spineps) (optional -- skipped gracefully if not installed)
- Python packages: `pip install -r requirements.txt`
- GPU recommended (CUDA-compatible) -- used by sct_deepseg and SPINEPS inference

## Setup

1. Clone this repository
2. Install Python dependencies:
   ```bash
   pip install -r requirements.txt
   ```
3. Download the custom canal atlas:
   ```bash
   mkdir -p atlas/
   # Download PAM50_atlas_41.nii.gz from:
   # https://github.com/neuroradiologyVH/Spinal-Cord-Canal-Template
   # Place it in atlas/PAM50_atlas_41.nii.gz
   ```

## Usage

### GPU/CPU split pipeline (recommended)

The recommended way to run the pipeline is via `run_pipeline.sh`, which splits processing into two phases:

1. **Phase 1 (GPU)**: DL segmentation (sct_deepseg + SPINEPS) with moderate parallelism
2. **Phase 2 (CPU)**: Registration, CSA computation, aSCOR, and QC with high parallelism

This separation avoids GPU contention while maximizing CPU throughput.

```bash
./run_pipeline.sh \
    -t1w-data  ~/data/mms_T1w-MPRAGE_selected \
    -t2w-data  ~/data/mms_acq-sag_T2w-STIR_desc-sc_qced_filtered \
    -stir-data ~/data/mms_acq-sag_T2w-STIR_desc-sc_qced_filtered \
    -output ~/output/csa_results \
    -jobs-gpu 4 \
    -jobs-cpu 16
```

| Flag | Description | Default |
|------|-------------|---------|
| `-t1w-data` | Path to T1w (MPRAGE) BIDS dataset | *(optional)* |
| `-t2w-data` | Path to T2w (sagittal) BIDS dataset | *(optional)* |
| `-stir-data` | Path to STIR (sagittal) BIDS dataset | *(optional)* |
| `-output` | Base output directory | **required** |
| `-jobs-gpu` | Number of parallel GPU segmentation jobs | 4 |
| `-jobs-cpu` | Number of parallel CPU processing jobs | nproc/4 |
| `-include-list` | File with one subject ID per line (subset) | *(all subjects)* |

At least one of `-t1w-data`, `-t2w-data`, `-stir-data` must be provided.

> **Note:** T2w and STIR data can live in the same BIDS directory -- the scripts discover files by suffix (`*_T2w.nii.gz` vs `*_STIR.nii.gz`). Sessions without the expected contrast are gracefully skipped.

### Subset of subjects

```bash
# include_list.txt — one subject per line
sub-001
sub-002
sub-003
```

```bash
./run_pipeline.sh \
    -t2w-data /path/to/t2w/dataset \
    -output /path/to/output \
    -include-list include_list.txt
```

### Monolithic standalone script

The monolithic `process_csa.sh` combines GPU + CPU in one script, parameterized by contrast. Useful for debugging a single subject:

```bash
sct_run_batch \
    -script process_csa.sh \
    -path-data /path/to/data \
    -path-output /path/to/output \
    -jobs 4 \
    -script-args "t2w /path/to/this/repo"
```

The first argument to `-script-args` is the contrast (`t1w`, `t2w`, or `stir`).

### ITK thread control

When running with high parallelism, each subject spawns additional parallel within-subject tasks. To prevent CPU oversubscription, ITK threads are capped at 4 by default. Override before launching:

```bash
export ITK_THREADS=2  # tighter control for many parallel jobs
```

### Aggregate results

```bash
python3 parse_results.py --directory /path/to/output/t2w/results --info "MEAN(area)"
```

## Architecture

### GPU/CPU split pipeline

```
run_pipeline.sh (orchestrator)
|
+-- Phase 1: GPU segmentation (-jobs-gpu N, default 4)
|   for each contrast in {t1w, t2w, stir}:
|     process_csa_gpu.sh <contrast>  -> rsync + sct_deepseg (+ SPINEPS for t2w)
|
+-- Phase 2: CPU processing (-jobs-cpu N, default nproc/4)
    for each contrast in {t1w, t2w, stir}:
      process_csa_cpu.sh <contrast>  -> label parsing, registration, CSA, aSCOR, QC
```

Both scripts are parameterized by contrast (`t1w`, `t2w`, `stir`) via `-script-args`.
The GPU script copies subject data and runs DL inference. The CPU script picks up
from `data_processed/`, verifies GPU outputs exist, and runs everything else. Both
phases use `sct_run_batch` for subject-level parallelism.

### Within-subject parallelism (CPU phase)

```
Label parsing: process_seg.py || relabel_vertebrae.py
              |
              v
Three parallel branches:
  Branch A: Method 1 CSA (cord, canal, ratio)
  Branch B: Registration -> 3 interpolation variants in parallel
            -> Method 3 || Method 4 within each variant
  Branch C: SPINEPS CSA (T2w only, if GPU output exists)
              |
              v
QC overlay (after all branches complete)
```

### Error handling

- **GPU phase**: `sct_run_batch` continues past individual subject failures. The orchestrator tolerates non-zero exit codes and proceeds to the next contrast.
- **CPU phase**: Scripts verify GPU outputs exist before processing. Subjects with missing GPU outputs are skipped with an error message (logged by `sct_run_batch`).
- **SPINEPS**: Optional -- failures do not affect the main pipeline. If SPINEPS is not installed or fails, Method 2 is simply omitted.
- **File discovery**: Scripts gracefully handle sessions that lack the expected contrast file (e.g., a session with T2w but no STIR).

## Quality Control (QC)

### Automatic QC overlays

After all CSA branches complete, each subject gets a multi-panel QC image (`generate_qc.py`) saved to `qc/custom_overlays/`. The figure title includes the subject ID, contrast, and interpolation method used for the atlas/PAM50 overlays (e.g., `"sub-001_ses-01 -- T2W (interp: spline)"`).

**Layout** -- rows x columns:

| | Sagittal | Coronal | Axial C1 | Axial C2 | Axial C3 | Axial C4 |
|---|---------|---------|----------|----------|----------|----------|
| **native** | raw image | raw image | raw image | raw image | raw image | raw image |
| **totalspineseg** | cord + canal overlay | ... | ... | ... | ... | ... |
| **spineps** *(T2w only)* | cord + canal overlay | ... | ... | ... | ... | ... |
| **custom-atlas** | cord + canal overlay | ... | ... | ... | ... | ... |
| **pam50** | cord + canal overlay | ... | ... | ... | ... | ... |

- **Cord** is shown as a filled semi-transparent overlay (method-specific color).
- **Canal** is shown as a bold yellow contour line.
- Slice positions are centered on the spinal cord using the vertebral level mask (centroid of non-zero voxels).
- Axial slices are taken at the midpoints of vertebral levels C1--C4.
- Aspect ratios are computed from voxel spacing for correct geometry.
- The QC overlays use **spline**-interpolated atlas/PAM50 files (best quality), and the `--interp spline` flag ensures this is visible in the title.

**Method colors:**

| Method | Cord color | Canal color |
|--------|-----------|-------------|
| TotalSpineSeg | Red | Yellow contour |
| SPINEPS | Blue | Yellow contour |
| Atlas41 | Green | Yellow contour |
| PAM50 | Purple | Yellow contour |

### SCT built-in QC

`sct_deepseg` and `sct_register_to_template` also produce their own QC reports in `qc/` (SCT's HTML-based QC viewer).

## Output Structure

```
<output>/<contrast>/
+-- data_processed/sub-XXX/ses-XXX/anat/  # Intermediate files
+-- results/
|   +-- method-totalspineseg/             # Cord, canal, ratio CSVs
|   +-- method-spineps/                   # Cord, canal, ratio CSVs (T2w only)
|   +-- method-atlas41-warp-nn/           # NN interpolation
|   +-- method-atlas41-warp-linear/       # Linear interpolation
|   +-- method-atlas41-warp-spline/       # Spline interpolation
|   +-- method-pam50-warp-nn/
|   +-- method-pam50-warp-linear/
|   +-- method-pam50-warp-spline/
+-- log/                                  # Per-subject logs (err.* prefix = failed)
+-- qc/
    +-- custom_overlays/                  # Multi-panel QC PNGs per subject
    +-- (SCT QC reports)                  # sct_deepseg / sct_register_to_template
```

Each `results/method-*/` directory contains per-subject CSVs:
- `*_cord.csv` -- cord CSA per vertebral level
- `*_canal.csv` -- canal CSA per vertebral level
- `*_ratio.csv` -- aSCOR (cord / canal-only) per vertebral level

### Intermediate file naming convention

Files in `data_processed/` use the pattern `<original>_seg-<method>-<structure>` for clear provenance:

| File | Description |
|------|-------------|
| `*_step2_output.nii.gz` | Raw TotalSpineSeg multi-label output (GPU phase) |
| `*_step1_levels.nii.gz` | Raw TotalSpineSeg disc labels (GPU phase) |
| `*_seg-totalspineseg-cord.nii.gz` | Binary cord mask from TotalSpineSeg (label 1) |
| `*_seg-totalspineseg-canal.nii.gz` | Binary canal mask from TotalSpineSeg (label 2) |
| `*_seg-totalspineseg-cord-canal-union.nii.gz` | Cord+canal union from TotalSpineSeg |
| `*_seg-totalspineseg-vertlevels.nii.gz` | Vertebral levels (remapped to SCT convention) |
| `*_seg-spineps-cord.nii.gz` | Binary cord mask from SPINEPS (label 60) |
| `*_seg-spineps-canal.nii.gz` | Binary canal mask from SPINEPS (label 61) |
| `*_seg-spineps-cord-canal-union.nii.gz` | Cord+canal union from SPINEPS |
| `PAM50_canal_warped_<interp>_bin.nii.gz` | Binarized PAM50 cord+CSF canal union |
| `PAM50_atlas41_warped_<interp>_bin.nii.gz` | Binarized custom canal atlas |
| `PAM50_levels_warped_nn.nii.gz` | PAM50 vertebral levels (always NN) |

## Repository Structure

```
run_pipeline.sh                # Orchestrator: GPU phase -> CPU phase
|
+-- Parameterized bash scripts (contrast passed via -script-args):
|   process_csa_gpu.sh         # GPU: rsync + sct_deepseg (+ SPINEPS for t2w)
|   process_csa_cpu.sh         # CPU: label parsing, registration, CSA, aSCOR, QC
|   process_csa.sh             # Monolithic: GPU + CPU combined (standalone use)
|
+-- Python utilities:
|   process_seg.py             # Parse TotalSpineSeg multi-label -> binary masks
|   process_spineps_seg.py     # Parse SPINEPS multi-label -> binary masks
|   relabel_vertebrae.py       # Remap TotalSpineSeg vert labels to SCT convention
|   compute_ascor.py           # aSCOR from cord + canal CSA CSVs
|   filter_disc_labels.py      # Filter disc labels to PAM50-compatible range
|   fill_canal_holes.py        # Fill 2D holes slice-by-slice in canal masks
|   generate_qc.py             # Multi-panel QC overlay PNG (--interp in title)
|   parse_results.py           # Aggregate per-subject CSVs into summary stats
|
+-- Data:
|   atlas/PAM50_atlas_41.nii.gz  # Custom canal atlas (download separately)
|
+-- Documentation:
    SWITCH_VERSION.md            # Migration notes for SCT 7.2+/7.3
    requirements.txt             # Python dependencies
```

### Python script reference

| Script | Purpose | CLI |
|--------|---------|-----|
| `process_seg.py` | Extract binary cord, canal, and union masks from TotalSpineSeg multi-label output | `-i <multilabel> --cord <out> --canal <out> --combined <out>` |
| `process_spineps_seg.py` | Extract binary cord, canal, and union masks from SPINEPS multi-label output | `-i <multilabel> --cord <out> --canal <out> --combined <out>` |
| `relabel_vertebrae.py` | Remap TotalSpineSeg vertebral labels (11-50) to SCT convention (1-25) | `--mask <input> --out <output>` |
| `compute_ascor.py` | Compute aSCOR per vertebral level from cord and canal-only CSA CSVs | `--cord-csa <csv> --canal-csa <csv> -o <csv>` |
| `filter_disc_labels.py` | Remove disc labels outside PAM50-compatible range (keeps 1-21, 60) | `-i <input> -o <output>` |
| `fill_canal_holes.py` | Fill 2D holes slice-by-slice in binary canal masks (fixes warping artifacts) | `-i <input> -o <output>` |
| `generate_qc.py` | Generate multi-panel QC PNG comparing cord/canal overlays across methods | `-i <image> -o <png> --title <str> --interp <str> --<method>-cord/canal <nii>` |
| `parse_results.py` | Aggregate per-subject CSVs into summary statistics | `--directory <path> --info <metric>` |
