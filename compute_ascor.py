#!/usr/bin/env python3
"""
Compute aSCOR (adapted Spinal Cord Occupation Ratio) from CSA CSVs.

Drop-in replacement for sct_compute_ascor (SCT >= 7.2) for use with SCT 7.1.

aSCOR = MEAN(area)_cord / MEAN(area)_canal_only per vertebral level.

Usage:
    python3 compute_ascor.py \
        --cord-csa cord_csa.csv \
        --canal-csa canal_only_csa.csv \
        -o ratio.csv
"""

import argparse
import pandas as pd
import numpy as np


def compute_ascor(cord_csv, canal_csv, output):
    """Compute aSCOR from pre-computed cord and canal-only CSA CSVs."""
    df_sc = pd.read_csv(cord_csv)
    df_canal = pd.read_csv(canal_csv)

    # Determine merge columns present in both DataFrames
    merge_cols = []
    for col in ['Slice (I->S)', 'VertLevel', 'DistancePMJ']:
        if col in df_sc.columns and col in df_canal.columns:
            merge_cols.append(col)

    if not merge_cols:
        raise ValueError("No common merge columns found between cord and canal CSVs")

    df_merged = pd.merge(
        df_sc[merge_cols + ['MEAN(area)']].rename(columns={'MEAN(area)': 'MEAN(area)_sc'}),
        df_canal[merge_cols + ['MEAN(area)']].rename(columns={'MEAN(area)': 'MEAN(area)_canal'}),
        on=merge_cols
    )

    df_merged['aSCOR'] = df_merged['MEAN(area)_sc'] / df_merged['MEAN(area)_canal']
    df_merged['aSCOR'] = df_merged['aSCOR'].replace([np.inf, -np.inf], np.nan)

    # Output in compatible format
    out_df = df_merged[merge_cols + ['aSCOR']]
    out_df.to_csv(output, index=False)
    print(f"aSCOR computed: {output}")


def main():
    parser = argparse.ArgumentParser(
        description='Compute aSCOR from cord and canal-only CSA CSVs.'
    )
    parser.add_argument('--cord-csa', required=True,
                        help='Path to cord CSA CSV (from sct_process_segmentation)')
    parser.add_argument('--canal-csa', required=True,
                        help='Path to canal-only CSA CSV (from sct_process_segmentation)')
    parser.add_argument('-o', '--output', required=True,
                        help='Output aSCOR CSV path')
    args = parser.parse_args()

    compute_ascor(args.cord_csa, args.canal_csa, args.output)


if __name__ == '__main__':
    main()
