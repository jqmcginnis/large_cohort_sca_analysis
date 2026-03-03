# Upgrading from SCT 7.1 to SCT 7.2+ (7.3)

This pipeline currently targets **SCT 7.1**. When SCT 7.3 ships with cord computation fixes,
apply the changes below to adopt the 7.2+ API.

## 1. Segmentation command

**All 3 scripts** (`process_csa_t1w.sh`, `process_csa_t2w.sh`, `process_csa_stir.sh`):

```diff
- sct_deepseg totalspineseg -i "${file}.nii.gz" -qc "${PATH_QC}"
+ sct_deepseg spine -i "${file}.nii.gz" -label-vert 1 -qc "${PATH_QC}"
```

The `-label-vert 1` flag produces vertebral labels directly (no separate `relabel_vertebrae.py` step needed for PAM50-based methods, though TSS vert labels still use it).

## 2. Output file naming

```diff
- file_totalseg_all="${file}_step2_output"
- file_totalseg_discs="${file}_step1_levels"
+ file_totalseg_all="${file}_totalspineseg_all"
+ file_totalseg_discs="${file}_totalspineseg_discs"
```

## 3. Replace `compute_ascor.py` with `sct_compute_ascor`

In all 3 scripts, each aSCOR block currently does:

```bash
# Current (7.1): two-step approach
sct_process_segmentation -i "${canal_only}" -vertfile "${vertfile}" \
    -o "${canal_only_csa}" -vert 1:25 -perlevel 1
# ... wait ...
python3 "${SCRIPT_DIR}/compute_ascor.py" \
    --cord-csa "${cord_csv}" --canal-csa "${canal_only_csa}" -o "${ratio_csv}"
```

Replace with the single native call:

```bash
sct_compute_ascor -i-SC "${cord_mask}" -i-canal "${canal_only_mask}" \
    -vertfile "${vertfile}" -vert 1:25 \
    -o "${ratio_csv}" -perlevel 1
```

This applies to **4 locations per script** (Method 1 TSS, Method 2 SPINEPS, Method 3 Atlas41, Method 4 PAM50).

## 4. Check if `-vert` is still required with `-perlevel`

In SCT 7.1, `-perlevel 1` silently produces a single aggregate row unless `-vert` is also specified.
Test whether 7.2+/7.3 still requires this:

```bash
sct_process_segmentation -i cord.nii.gz -vertfile vert.nii.gz -perlevel 1 -o test.csv
# Check: does test.csv have one row per vertebral level, or just one aggregate row?
```

If per-level output works without `-vert`, you can remove all `-vert 1:25` flags.

## 5. Check `-vertfile` deprecation

SCT 7.1 warns that `-vertfile` is deprecated in favor of `-discfile`. If 7.3 removes `-vertfile`,
switch all calls:

```diff
- -vertfile "${file_tss_vert}.nii.gz"
+ -discfile "${file_totalseg_discs}.nii.gz"
```

Note: `-discfile` expects **disc labels** (single-voxel intervertebral disc markers), not
**vertebral level masks**. The TotalSpineSeg `_discs` / `_step1_levels` output provides these.
You would no longer need `relabel_vertebrae.py` for the vertfile, but you may still need
`filter_disc_labels.py` to ensure disc labels are in PAM50-compatible range.

## 6. Update dependency comments

In each script header:

```diff
- #   - SCT >= 7.1
+ #   - SCT >= 7.3
```

## 7. Files that can be removed after switch

| File | Reason |
|------|--------|
| `compute_ascor.py` | Replaced by native `sct_compute_ascor` |
| `SWITCH_VERSION.md` | This file — no longer needed |

`relabel_vertebrae.py` is still needed for TSS vertebral level masks used by Methods 1 & 2.

## Quick validation after switching

```bash
# Run on one subject
sct_run_batch -script process_csa_t1w.sh -path-data /path/to/data \
    -path-output /tmp/test_7.3 -jobs 1 -script-args /path/to/repo \
    -include "sub-XXXX"

# Check: per-level output exists
head results/method-totalspineseg/*_cord.csv
# Should show multiple rows with different VertLevel values

# Check: ratio files exist for all methods
ls results/method-*/sub-*_ratio.csv

# Compare cord CSA values against 7.1 run to confirm bug is fixed
```
