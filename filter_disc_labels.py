import argparse
import numpy as np
import nibabel as nib


def filter_disc_labels(input_path, output_path, max_label=21):
    """Remove disc labels outside PAM50 template range (keep 1-max_label and 60)."""
    img = nib.load(input_path)
    data = np.round(img.get_fdata()).astype(np.int16)

    valid = set(range(1, max_label + 1)) | {60}
    removed = set(np.unique(data)) - valid - {0}

    if removed:
        print(f"Removing out-of-range disc labels: {sorted(removed)}")
        for label in removed:
            data[data == label] = 0

    out_img = nib.Nifti1Image(data, img.affine, img.header)
    nib.save(out_img, output_path)
    print(f"Filtered disc labels saved: {output_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Filter disc labels to PAM50-compatible range (1-21, 60)."
    )
    parser.add_argument("-i", "--input", required=True)
    parser.add_argument("-o", "--output", required=True)
    parser.add_argument("--max-label", type=int, default=21)
    args = parser.parse_args()
    filter_disc_labels(args.input, args.output, args.max_label)
