# Spinal Cord & Canal CSA Analysis Pipeline

Publication-ready pipeline for computing spinal cord and canal cross-sectional area (CSA) and aSCOR (age-adjusted spinal cord occupation ratio) across all available vertebral levels, comparing four methods for cord/canal estimation across three MRI contrasts.

## Quick Start

```bash
# 1. Install dependencies
pip install -r requirements.txt

# 2. Download the custom canal atlas
mkdir -p atlas/
# Get PAM50_atlas_41.nii.gz from:
# https://github.com/neuroradiologyVH/Spinal-Cord-Canal-Template

# 3. Run the pipeline
./run_pipeline.sh \
    -t1w-data /path/to/t1w/dataset \
    -t2w-data /path/to/t2w/dataset \
    -stir-data /path/to/stir/dataset \
    -output /path/to/output \
    -jobs-gpu 4 \
    -jobs-cpu 16
```

## Methods

| # | Method | Source | Cord | Canal | aSCOR | Contrasts |
|---|--------|--------|------|-------|-------|-----------|
| 1 | **TotalSpineSeg** | `sct_deepseg totalspineseg` (SCT) | DL segmentation (label 1) | DL segmentation cord+canal union (labels 1+2) | cord / canal-only (label 2) | T1w, T2w, STIR |
| 2 | **SPINEPS** | [spineps](https://github.com/Hendrik-code/spineps) | DL segmentation (label 60) | DL segmentation cord+canal union (labels 60+61) | cord / canal-only (label 61) | T2w, STIR |
| 3 | **Atlas41** | [`PAM50_atlas_41.nii.gz`](https://github.com/neuroradiologyVH/Spinal-Cord-Canal-Template) warped to native | TotalSpineSeg cord | Warped atlas (includes cord) | cord / (atlas41 - cord) | T1w, T2w, STIR |
| 4 | **PAM50** | SCT built-in `PAM50_cord` + `PAM50_csf` warped to native | TotalSpineSeg cord | Warped PAM50_cord + PAM50_csf union | cord / (union - cord) | T1w, T2w, STIR |

> **Note:** SPINEPS (Method 2) is excluded for T1w -- its instance segmentation is unreliable on T1w data.

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

This separation avoids GPU contention while maximizing CPU throughput. The DL models use only a few GB of VRAM each, so 3-4 GPU jobs can run in parallel without issues on a typical 48GB GPU.

```bash
./run_pipeline.sh \
    -t1w-data /path/to/t1w/dataset \
    -t2w-data /path/to/t2w/dataset \
    -stir-data /path/to/stir/dataset \
    -output /path/to/output \
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

To run on a subset, create a text file with one subject per line:

```bash
# include_list.txt
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

### Monolithic single-contrast scripts

The original per-contrast scripts are preserved for standalone use (e.g., debugging a single subject). These run GPU + CPU together in one script:

```bash
sct_run_batch \
    -script process_csa_t2w.sh \
    -path-data /path/to/t2w/data \
    -path-output /path/to/t2w_out \
    -jobs 8 \
    -script-args /path/to/this/repo
```

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
|   +-- process_csa_t1w_gpu.sh   -> rsync + sct_deepseg totalspineseg
|   +-- process_csa_t2w_gpu.sh   -> rsync + sct_deepseg + SPINEPS
|   +-- process_csa_stir_gpu.sh  -> rsync + sct_deepseg + SPINEPS
|
+-- Phase 2: CPU processing (-jobs-cpu N, default nproc/4)
    +-- process_csa_t1w_cpu.sh   -> label parsing, registration, CSA, aSCOR, QC
    +-- process_csa_t2w_cpu.sh   -> same + SPINEPS CSA
    +-- process_csa_stir_cpu.sh  -> same + SPINEPS CSA
```

The GPU scripts copy subject data and run DL inference. The CPU scripts pick up
from `data_processed/`, verify GPU outputs exist, and run everything else. Both
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
  Branch C: SPINEPS CSA (if GPU output exists, T2w/STIR only)
              |
              v
QC overlay (after all branches complete)
```

### Error handling

- **GPU phase**: `sct_run_batch` continues past individual subject failures. The orchestrator tolerates non-zero exit codes and proceeds to the next contrast.
- **CPU phase**: Scripts verify GPU outputs exist before processing. Subjects with missing GPU outputs are skipped with an error message (logged by `sct_run_batch`).
- **SPINEPS**: Optional -- failures do not affect the main pipeline. If SPINEPS is not installed or fails, Method 2 is simply omitted.
- **File discovery**: Scripts gracefully handle sessions that lack the expected contrast file (e.g., a session with T2w but no STIR).

## Output Structure

```
<output>/<contrast>/
+-- data_processed/sub-XXX/ses-XXX/anat/  # Intermediate files
+-- results/
|   +-- method-totalspineseg/             # Cord, canal, ratio CSVs
|   +-- method-spineps/                   # Cord, canal, ratio CSVs (if SPINEPS)
|   +-- method-atlas41-warp-nn/           # NN interpolation
|   +-- method-atlas41-warp-linear/       # Linear interpolation
|   +-- method-atlas41-warp-spline/       # Spline interpolation
|   +-- method-pam50-warp-nn/
|   +-- method-pam50-warp-linear/
|   +-- method-pam50-warp-spline/
+-- log/                                  # Per-subject logs (err.* prefix = failed)
+-- qc/
    +-- custom_overlays/                  # Multi-panel QC PNGs per subject
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
+-- GPU scripts (Phase 1):
|   process_csa_t1w_gpu.sh     # T1w: rsync + sct_deepseg totalspineseg
|   process_csa_t2w_gpu.sh     # T2w: rsync + sct_deepseg + SPINEPS
|   process_csa_stir_gpu.sh    # STIR: rsync + sct_deepseg + SPINEPS
|
+-- CPU scripts (Phase 2):
|   process_csa_t1w_cpu.sh     # T1w: registration, CSA, aSCOR, QC
|   process_csa_t2w_cpu.sh     # T2w: same + SPINEPS CSA
|   process_csa_stir_cpu.sh    # STIR: same + SPINEPS CSA
|
+-- Monolithic scripts (standalone use):
|   process_csa_t1w.sh         # T1w: GPU + CPU in one script
|   process_csa_t2w.sh         # T2w: GPU + CPU in one script
|   process_csa_stir.sh        # STIR: GPU + CPU in one script
|
+-- Python utilities:
|   process_seg.py             # Parse TotalSpineSeg -> binary masks
|   process_spineps_seg.py     # Parse SPINEPS -> binary masks
|   relabel_vertebrae.py       # Remap TotalSpineSeg vert labels to SCT
|   compute_ascor.py           # aSCOR from cord + canal CSA CSVs
|   filter_disc_labels.py      # Filter disc labels to PAM50-compatible range
|   generate_qc.py             # Multi-panel QC overlay
|   parse_results.py           # Aggregate per-subject CSVs
|
+-- atlas/
|   PAM50_atlas_41.nii.gz     # Custom canal atlas (download separately)
|
+-- SWITCH_VERSION.md          # Migration notes for SCT 7.2+/7.3
+-- requirements.txt
```
