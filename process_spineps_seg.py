import argparse
import sys
import numpy as np
import nibabel as nib


def process_spineps_segmentation(input_file, cord_out=None, canal_out=None, combined_out=None):
    """Parse SPINEPS semantic segmentation into binary masks.

    SPINEPS labels:
        60 = spinal cord
        61 = spinal canal
    """
    print(f"Loading: {input_file}")

    try:
        img = nib.load(input_file)
        data = img.get_fdata()
        header = img.header.copy()
        affine = img.affine

        data_int = np.round(data).astype(np.int16)

        unique_labels = np.unique(data_int)
        print(f"Labels found in input: {unique_labels}")

        # Validate expected SPINEPS labels
        if 60 not in unique_labels:
            print("WARNING: Label 60 (spinal cord) not found in SPINEPS segmentation.")
        if 61 not in unique_labels:
            print("WARNING: Label 61 (spinal canal) not found in SPINEPS segmentation.")

        # Z-range intersection: restrict to slices where both cord and canal exist
        if 60 in unique_labels and 61 in unique_labels:
            print("Ensuring Cord and Canal occupy the same Z-range...")

            slices_with_cord = np.any(data_int == 60, axis=(0, 1))
            slices_with_canal = np.any(data_int == 61, axis=(0, 1))

            valid_z_slices = slices_with_cord & slices_with_canal

            n_cord = np.sum(slices_with_cord)
            n_canal = np.sum(slices_with_canal)
            n_shared = np.sum(valid_z_slices)

            print(f"  - Cord defined in: {n_cord} slices")
            print(f"  - Canal defined in: {n_canal} slices")
            print(f"  - Intersection: {n_shared} slices")

            if n_shared == 0:
                print("WARNING: Cord and Canal share NO Z-slices! All outputs will be empty.")

            data_int[:, :, ~valid_z_slices] = 0
        else:
            print("Note: Input does not contain both Label 60 and Label 61. Skipping Z-range intersection.")

        def save_mask(mask_data, output_filename, desc):
            if output_filename is None:
                return
            binary_data = (mask_data > 0).astype(np.int16)
            if np.sum(binary_data) == 0:
                print(f"WARNING: Output mask for {desc} is empty!")
            else:
                print(f"Saving {desc}: {output_filename} (voxels: {np.sum(binary_data)})")
            header.set_data_dtype(np.int16)
            new_img = nib.Nifti1Image(binary_data, affine, header)
            nib.save(new_img, output_filename)

        # Cord (Label 60)
        if cord_out:
            mask = (data_int == 60)
            save_mask(mask, cord_out, "Cord (Label 60)")

        # Canal (Label 61)
        if canal_out:
            mask = (data_int == 61)
            save_mask(mask, canal_out, "Canal (Label 61)")

        # Combined (Labels 60 + 61)
        if combined_out:
            mask = np.isin(data_int, [60, 61])
            save_mask(mask, combined_out, "Cord+Canal (Labels 60+61)")

    except Exception as e:
        print(f"Error processing file: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Parse SPINEPS semantic segmentation into binary masks (labels 60/61)."
    )
    parser.add_argument("-i", "--segmentation", required=True,
                        help="Input SPINEPS semantic segmentation file (_seg-spine.nii.gz).")
    parser.add_argument("--cord", help="Output filename for Cord mask (Label 60)")
    parser.add_argument("--canal", help="Output filename for Canal mask (Label 61)")
    parser.add_argument("--combined", help="Output filename for Combined mask (Labels 60+61)")

    args = parser.parse_args()

    process_spineps_segmentation(
        args.segmentation,
        cord_out=args.cord,
        canal_out=args.canal,
        combined_out=args.combined,
    )
