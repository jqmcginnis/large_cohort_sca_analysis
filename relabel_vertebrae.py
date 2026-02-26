import argparse
import nibabel as nib
import numpy as np
import os

def relabel_nifti(input_path, output_path):
    print(f"Loading: {input_path}")
    
    # 1. Load the NIfTI file
    img = nib.load(input_path)
    
    # Get data as integer (labels are discrete integers)
    # get_fdata() returns float64 by default, so we cast to int for safe comparison
    data = img.get_fdata().astype(np.int32)
    
    # 2. Define the mapping (Old Label -> New Label)
    # Everything else will implicitly become 0 (background)
    label_mapping = {
        # Cervical: TotalSpineSeg 11-17 → SCT 1-7
        11: 1, 12: 2, 13: 3, 14: 4, 15: 5, 16: 6, 17: 7,
        # Thoracic: TotalSpineSeg 21-32 → SCT 8-19
        21: 8, 22: 9, 23: 10, 24: 11, 25: 12, 26: 13,
        27: 14, 28: 15, 29: 16, 30: 17, 31: 18, 32: 19,
        # Lumbar: TotalSpineSeg 41-45 → SCT 20-24
        41: 20, 42: 21, 43: 22, 44: 23, 45: 24,
        # Sacrum: TotalSpineSeg 50 → SCT 25
        50: 25,
    }
    
    # 3. Create a new empty array of zeros with the same shape as the input
    new_data = np.zeros_like(data)
    
    # 4. Perform the relabeling
    print("Relabeling...")
    for old_label, new_label in label_mapping.items():
        # Find where data equals the old label and assign the new label
        mask = (data == old_label)
        count = np.sum(mask)
        
        if count > 0:
            new_data[mask] = new_label
            print(f"  - Mapped {old_label} -> {new_label} ({count} voxels)")
        else:
            print(f"  - Warning: Label {old_label} not found in image.")

    # 5. Save the result
    # We use the affine and header from the original image to preserve spatial info
    new_img = nib.Nifti1Image(new_data.astype(np.int16), img.affine, img.header)
    
    nib.save(new_img, output_path)
    print(f"Saved relabeled file to: {output_path}")

if __name__ == "__main__":
    # Set up argument parsing
    parser = argparse.ArgumentParser(description="Relabel TotalSpineSeg vertebral levels (C1-C7, T1-T12, L1-L5, S1) to SCT convention.")
    
    # Required argument: --label
    parser.add_argument("--mask", type=str, required=True, help="Path to the input segmentation/label file (nii or nii.gz)")
    
    # Optional argument: --output (if not provided, appends _relabeled to filename)
    parser.add_argument("--out", type=str, help="Path to save the output file. Defaults to input_relabeled.nii.gz")

    args = parser.parse_args()

    # Determine output path if not provided
    if args.out:
        out_path = args.out
    else:
        # Create default name: input.nii.gz -> input_relabeled.nii.gz
        base, ext = os.path.splitext(args.mask)
        if ext == ".gz": # Handle .nii.gz case
            base, _ = os.path.splitext(base)
            out_path = f"{base}_relabeled.nii.gz"
        else:
            out_path = f"{base}_relabeled{ext}"

    relabel_nifti(args.mask, out_path)
