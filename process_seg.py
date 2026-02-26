import argparse
import sys
import numpy as np
import nibabel as nib

def process_segmentation(input_file, cord_out=None, canal_out=None, combined_out=None):
    print(f"Loading: {input_file}")
    
    try:
        # 1. Load the NIfTI file
        img = nib.load(input_file)
        data = img.get_fdata()
        header = img.header.copy()
        affine = img.affine

        # 2. Round data to handle potential float issues (e.g. 1.0001 -> 1)
        data_int = np.round(data).astype(np.int16)
        
        # Check what labels are actually in the file
        unique_labels = np.unique(data_int)
        print(f"Labels found in input: {unique_labels}")

        # Warn if expected labels (1 or 2) are missing but 50/51 (SCT standard) exist
        if (1 not in unique_labels) and (50 in unique_labels):
            print("WARNING: Label 1 not found, but 50 found. Did you mean to use the SCT default (50=Cord)?")

        # ---------------------------------------------------------
        # NEW LOGIC: Intersection of Z-Range
        # ---------------------------------------------------------
        # Only perform this check if both labels exist.
        if 1 in unique_labels and 2 in unique_labels:
            print("Ensuring Cord and Canal occupy the same Z-range...")

            # Assume 3D volume (X, Y, Z). Check for presence in Z slices.
            # axis=(0, 1) collapses the axial slice to a single boolean (True if label exists in that slice)
            slices_with_cord = np.any(data_int == 1, axis=(0, 1))
            slices_with_canal = np.any(data_int == 2, axis=(0, 1))

            # Find the intersection: Slices where BOTH are defined
            valid_z_slices = slices_with_cord & slices_with_canal
            
            n_cord = np.sum(slices_with_cord)
            n_canal = np.sum(slices_with_canal)
            n_shared = np.sum(valid_z_slices)

            print(f"  - Cord defined in: {n_cord} slices")
            print(f"  - Canal defined in: {n_canal} slices")
            print(f"  - Intersection: {n_shared} slices")

            if n_shared == 0:
                print("WARNING: Cord and Canal share NO Z-slices! All outputs will be empty.")

            # Zero out any data in slices that are NOT in the valid set
            # ~valid_z_slices gives the indices of slices to remove
            data_int[:, :, ~valid_z_slices] = 0
            
        else:
            print("Note: Input does not contain both Label 1 and Label 2. Skipping Z-range intersection.")
        # ---------------------------------------------------------

        # --- Function to save a mask ---
        def save_mask(mask_data, output_filename, desc):
            if output_filename is None:
                return
            
            # Binarize: ensure anything selected is 1, background is 0
            binary_data = (mask_data > 0).astype(np.int16)
            
            if np.sum(binary_data) == 0:
                print(f"WARNING: Output mask for {desc} is empty!")
            else:
                print(f"Saving {desc}: {output_filename} (voxels: {np.sum(binary_data)})")

            # Update header for integer type to save space
            header.set_data_dtype(np.int16)
            new_img = nib.Nifti1Image(binary_data, affine, header)
            nib.save(new_img, output_filename)

        # 3. Process Cord (Label 1)
        if cord_out:
            mask = (data_int == 1)
            save_mask(mask, cord_out, "Cord (Label 1)")

        # 4. Process Canal (Label 2)
        if canal_out:
            mask = (data_int == 2)
            save_mask(mask, canal_out, "Canal (Label 2)")

        # 5. Process Combined (Label 1 + 2)
        if combined_out:
            # Select where label is 1 OR 2
            mask = np.isin(data_int, [1, 2])
            save_mask(mask, combined_out, "Cord+Canal (Labels 1+2)")

    except Exception as e:
        print(f"Error processing file: {e}")
        # Print full traceback for easier debugging if needed
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Split multi-label segmentation into binary masks with Z-range intersection.")
    
    # Input file
    parser.add_argument("-i", "--segmentation", required=True, help="Input multi-label segmentation file.")
    
    # Output files (optional - only generate what is requested)
    parser.add_argument("--cord", help="Output filename for Cord mask (Label 1)")
    parser.add_argument("--canal", help="Output filename for Canal mask (Label 2)")
    parser.add_argument("--combined", help="Output filename for Combined mask (Labels 1+2)")

    args = parser.parse_args()

    process_segmentation(
        args.segmentation, 
        cord_out=args.cord, 
        canal_out=args.canal, 
        combined_out=args.combined
    )
