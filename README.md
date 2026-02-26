# Spinal Cord & Canal CSA Analysis Pipeline

Publication-ready pipeline for computing spinal cord and canal cross-sectional area (CSA) at vertebral levels C2–C4, comparing four methods for cord/canal estimation across three MRI contrasts.

## Methods

| # | Method | Source | Cord | Canal | Contrasts |
|---|--------|--------|------|-------|-----------|
| 1 | **TotalSpineSeg** | `sct_deepseg spine` (SCT) | DL segmentation (label 1) | DL segmentation cord+canal union (labels 1+2) | T1w, T2w, STIR |
| 2 | **SPINEPS** | [spineps](https://github.com/Hendrik-code/spineps) | DL segmentation (label 60) | DL segmentation cord+canal union (labels 60+61) | T1w, T2w, STIR |
| 3 | **Atlas41** | [`PAM50_atlas_41.nii.gz`](https://github.com/neuroradiologyVH/Spinal-Cord-Canal-Template) warped to native | TotalSpineSeg cord | Warped atlas (includes cord) | T1w, T2w, STIR |
| 4 | **PAM50** | SCT built-in `PAM50_cord` + `PAM50_csf` warped to native | Warped PAM50_cord | Warped PAM50_cord + PAM50_csf union | T1w, T2w, STIR |

### Key differences between canal definitions

- **Atlas41** (`PAM50_atlas_41`): A single template that represents the **full spinal canal** (cord + CSF). When warped and binarized, it directly gives the canal mask.
- **PAM50**: Uses two separate SCT templates — `PAM50_cord` (cord only) and `PAM50_csf` (CSF only, does NOT include cord). These are warped individually and then unioned to form the canal mask.

### Interpolation ablation

Methods 3 and 4 involve warping probabilistic templates from PAM50 space to native space. The choice of interpolation method affects the resulting masks. Each pipeline runs an ablation over three interpolation modes:

| Interpolation | Flag | Behavior |
|---------------|------|----------|
| **Nearest-neighbor** | `-x nn` | Binary output, may produce holes/artifacts |
| **Linear** | `-x linear` | Smooth output, moderate quality |
| **Spline** | `-x spline` | Smoothest output, best quality (default) |

This replaces the previous use of `sct_warp_template` (which hardcodes NN interpolation) with explicit `sct_apply_transfo -x <mode>` calls for full control. PAM50_levels (vertebral labels) always use NN since they are discrete labels.

### Vertebral level reference

- Methods 1 & 2: TotalSpineSeg-derived vertebral labels (`_seg-totalspineseg-vertlevels`)
- Methods 3 & 4: Warped `PAM50_levels` (always NN interpolation)

## Dependencies

- [Spinal Cord Toolbox (SCT)](https://spinalcordtoolbox.com/) >= 7.2.0
- [SPINEPS](https://github.com/Hendrik-code/spineps) (optional — skipped gracefully if not installed)
- Python packages: `pip install -r requirements.txt`

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

### Full pipeline

```bash
./run_pipeline.sh \
    --t1w-data /path/to/t1w/dataset \
    --t2w-data /path/to/t2w/dataset \
    --output /path/to/output \
    --jobs 8
```

### Individual contrast

```bash
sct_run_batch \
    -script process_csa_t2w.sh \
    -path-data /path/to/t2w/data \
    -path-output /path/to/t2w_out \
    -jobs 8 \
    -script-args /path/to/this/repo
```

### Aggregate results

```bash
python3 parse_results.py --directory /path/to/t2w_out/results --info "MEAN(area)"
```

## Output Structure

```
<contrast>_out/
├── data_processed/sub-XXX/ses-XXX/anat/   # Intermediate files
├── results/
│   ├── method-totalspineseg/              # Cord, canal, ratio CSVs
│   ├── method-spineps/                    # Cord, canal, ratio CSVs (if SPINEPS installed)
│   ├── method-atlas41-warp-nn/            # Canal from atlas41 (NN interpolation)
│   ├── method-atlas41-warp-linear/        # Canal from atlas41 (linear interpolation)
│   ├── method-atlas41-warp-spline/        # Canal from atlas41 (spline interpolation)
│   ├── method-pam50-warp-nn/              # Cord+canal from PAM50 (NN interpolation)
│   ├── method-pam50-warp-linear/          # Cord+canal from PAM50 (linear interpolation)
│   └── method-pam50-warp-spline/          # Cord+canal from PAM50 (spline interpolation)
├── log/
└── qc/
    └── custom_overlays/                   # Multi-panel QC PNGs per subject
```

### Intermediate file naming convention

Files in `data_processed/` use the pattern `<original>_seg-<method>-<structure>` for clear provenance:

| File | Description |
|------|-------------|
| `*_seg-totalspineseg-cord.nii.gz` | Binary cord mask from TotalSpineSeg (label 1) |
| `*_seg-totalspineseg-canal.nii.gz` | Binary canal mask from TotalSpineSeg (label 2) |
| `*_seg-totalspineseg-cord-canal-union.nii.gz` | Cord+canal union from TotalSpineSeg |
| `*_seg-totalspineseg-vertlevels.nii.gz` | Vertebral levels from TotalSpineSeg (remapped 11–17 → 1–7) |
| `*_seg-spineps-cord.nii.gz` | Binary cord mask from SPINEPS (label 60) |
| `*_seg-spineps-canal.nii.gz` | Binary canal mask from SPINEPS (label 61) |
| `*_seg-spineps-cord-canal-union.nii.gz` | Cord+canal union from SPINEPS |
| `PAM50_cord_warped_<interp>.nii.gz` | PAM50 cord warped with specified interpolation |
| `PAM50_csf_warped_<interp>.nii.gz` | PAM50 CSF warped with specified interpolation |
| `PAM50_canal_warped_<interp>_bin.nii.gz` | Binarized PAM50 cord+CSF canal union |
| `PAM50_atlas41_warped_<interp>_bin.nii.gz` | Binarized custom canal atlas (full canal) |
| `PAM50_levels_warped_nn.nii.gz` | PAM50 vertebral levels (always NN) |

## Repository Structure

```
├── run_pipeline.sh              # Master orchestration script
├── process_csa_t1w.sh           # T1w pipeline (Methods 1–4)
├── process_csa_t2w.sh           # T2w pipeline (Methods 1–4)
├── process_csa_stir.sh          # STIR pipeline (Methods 1–4)
├── process_seg.py               # Parse TotalSpineSeg → binary masks (labels 1, 2)
├── process_spineps_seg.py       # Parse SPINEPS → binary masks (labels 60, 61)
├── relabel_vertebrae.py         # Remap TotalSpineSeg vert labels (11–17 → 1–7)
├── generate_qc.py               # Multi-panel QC overlay comparing all methods
├── parse_results.py             # Aggregate per-subject CSVs into summary tables
├── atlas/
│   └── PAM50_atlas_41.nii.gz   # Custom canal atlas (download separately)
└── requirements.txt
```
