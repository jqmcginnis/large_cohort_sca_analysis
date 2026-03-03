#!/usr/bin/env python3
"""Fill 2D holes slice-by-slice in a binary canal mask."""
import argparse

import nibabel as nib
import numpy as np
from scipy.ndimage import binary_fill_holes


def main():
    parser = argparse.ArgumentParser(
        description="Fill 2D holes slice-by-slice in a binary canal mask."
    )
    parser.add_argument("-i", "--input", required=True, help="Input binary NIfTI mask.")
    parser.add_argument("-o", "--output", required=True, help="Output NIfTI mask.")
    args = parser.parse_args()

    img = nib.load(args.input)
    d = img.get_fdata()
    for z in range(d.shape[2]):
        d[:, :, z] = binary_fill_holes(d[:, :, z])
    nib.save(
        nib.Nifti1Image(d.astype(np.float32), img.affine, img.header), args.output
    )


if __name__ == "__main__":
    main()
