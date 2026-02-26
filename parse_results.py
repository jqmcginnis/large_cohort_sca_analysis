import argparse
import os
import re
import pandas as pd


def extract_bids_fields(filename):
    """Extract subject and session from a BIDS-style filename."""
    sub_match = re.search(r"sub-([A-Za-z0-9]+)", filename)
    ses_match = re.search(r"ses-([A-Za-z0-9]+)", filename)
    subject_id = sub_match.group(1) if sub_match else ""
    session_id = ses_match.group(1) if ses_match else ""
    return subject_id, session_id


def parse_method_directory(method_dir, info_column, measure_type):
    """Parse all CSVs in a method directory for a given measure type (cord/canal/ratio).

    Returns a DataFrame with columns:
        subject_id, session_id, level2, level3, level4
    """
    rows = []
    pattern = f"_{measure_type}.csv"

    if not os.path.isdir(method_dir):
        print(f"WARNING: Directory not found: {method_dir}")
        return pd.DataFrame()

    for fname in sorted(os.listdir(method_dir)):
        if not fname.endswith(pattern):
            continue

        filepath = os.path.join(method_dir, fname)
        subject_id, session_id = extract_bids_fields(fname)

        try:
            df = pd.read_csv(filepath)
        except Exception as e:
            print(f"WARNING: Could not read {filepath}: {e}")
            continue

        if info_column not in df.columns:
            print(f"WARNING: Column '{info_column}' not found in {filepath}. "
                  f"Available: {list(df.columns)}")
            continue

        # Pivot levels into columns
        row = {"subject_id": subject_id, "session_id": session_id}
        for _, record in df.iterrows():
            level = int(record.get("VertLevel", record.get("vertLevel", -1)))
            if level > 0:
                row[f"level{level}"] = record[info_column]

        rows.append(row)

    if not rows:
        return pd.DataFrame()

    result = pd.DataFrame(rows)
    # Dynamically discover all level columns and sort numerically
    level_cols = sorted(
        [c for c in result.columns if c.startswith("level")],
        key=lambda x: int(x.replace("level", ""))
    )
    cols = ["subject_id", "session_id"] + level_cols
    for c in cols:
        if c not in result.columns:
            result[c] = ""
    return result[cols]


def main():
    parser = argparse.ArgumentParser(
        description="Aggregate per-subject CSA/aSCOR CSVs into summary tables."
    )
    parser.add_argument(
        "--directory", required=True,
        help="Path to the results/ directory containing method-* subdirectories."
    )
    parser.add_argument(
        "--info", default="MEAN(area)",
        help="Column name to extract from per-subject CSVs (default: 'MEAN(area)')."
    )
    parser.add_argument(
        "--output", default=None,
        help="Output directory for summary CSVs (default: same as --directory)."
    )

    args = parser.parse_args()

    results_dir = args.directory
    output_dir = args.output if args.output else results_dir
    info_column = args.info

    os.makedirs(output_dir, exist_ok=True)

    # Discover method directories
    method_dirs = sorted([
        d for d in os.listdir(results_dir)
        if os.path.isdir(os.path.join(results_dir, d)) and d.startswith("method-")
    ])

    if not method_dirs:
        print(f"No method-* directories found in {results_dir}")
        return

    for method in method_dirs:
        method_path = os.path.join(results_dir, method)
        print(f"\nProcessing: {method}")

        for measure_type in ("cord", "canal", "ratio"):
            df = parse_method_directory(method_path, info_column, measure_type)
            if df.empty:
                continue

            out_file = os.path.join(output_dir, f"{method}_{measure_type}.csv")
            df.to_csv(out_file, index=False)
            print(f"  {measure_type}: {len(df)} subjects -> {out_file}")


if __name__ == "__main__":
    main()
