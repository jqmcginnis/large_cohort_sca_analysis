import argparse
import os
import sys
import numpy as np
import nibabel as nib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import ListedColormap


# Method colors: cord = filled overlay, canal = bold contour
METHOD_COLORS = {
    "totalspineseg": {"cord": "#e41a1c", "canal": "#ffff00"},  # red cord, yellow canal
    "spineps":       {"cord": "#377eb8", "canal": "#ffff00"},  # blue cord, yellow canal
    "custom-atlas":  {"cord": "#4daf4a", "canal": "#ffff00"},  # green cord, yellow canal
    "pam50":         {"cord": "#984ea3", "canal": "#ffff00"},  # purple cord, yellow canal
}


def load_nifti(path):
    """Load a NIfTI file and return data, affine, voxel sizes. Returns Nones if missing."""
    if path is None or not os.path.isfile(path):
        return None, None, None
    img = nib.load(path)
    zooms = img.header.get_zooms()[:3]
    return np.asanyarray(img.dataobj), img.affine, zooms


def get_mid_slice_indices(data_3d, vertfile_data=None):
    """Get the mid-sagittal, mid-coronal, and mid-axial slice indices."""
    if vertfile_data is not None:
        coords = np.argwhere(vertfile_data > 0)
        if len(coords) > 0:
            centroid = coords.mean(axis=0).astype(int)
            return centroid[0], centroid[1], centroid[2]
    return data_3d.shape[0] // 2, data_3d.shape[1] // 2, data_3d.shape[2] // 2


def get_axial_slices_per_level(vertfile_data, levels=(2, 3, 4)):
    """Return the mid-axial slice index for each vertebral level.

    Returns list of (label_str, z_index) tuples.
    """
    if vertfile_data is None:
        return []
    slices = []
    for lev in levels:
        z_indices = np.where(np.any(vertfile_data == lev, axis=(0, 1)))[0]
        if len(z_indices) > 0:
            mid_z = z_indices[len(z_indices) // 2]
            slices.append((f"Axial C{lev}", mid_z))
    return slices


def overlay_mask(ax, mask_slice, color, alpha=0.4, label=None, contour=False,
                 aspect_ratio=None):
    """Overlay a binary mask on an axes with the given color."""
    if mask_slice is None:
        return
    asp = aspect_ratio if aspect_ratio else "auto"
    if contour:
        ax.contour(mask_slice.astype(float), levels=[0.5], colors=[color],
                   linewidths=2, alpha=min(alpha + 0.3, 1.0))
    else:
        rgba = np.zeros((*mask_slice.shape, 4))
        r, g, b = matplotlib.colors.to_rgb(color)
        rgba[mask_slice > 0] = [r, g, b, alpha]
        ax.imshow(rgba, aspect=asp, interpolation="bilinear")
    if label:
        ax.plot([], [], color=color, linewidth=3, label=label)


def generate_qc_figure(
    native_path,
    method_files,
    output_path,
    vertfile_path=None,
    title="",
):
    """Generate a multi-panel QC figure comparing segmentations across methods.

    Layout: rows = (native + methods), columns = (sagittal, coronal, 4× axial at C-levels).
    """
    native_data, _, voxel_zooms = load_nifti(native_path)
    if native_data is None:
        print(f"ERROR: Cannot load native image: {native_path}")
        return

    vert_data, _, _ = load_nifti(vertfile_path)

    # Compute aspect ratios per view from voxel spacing (dx, dy, dz)
    if voxel_zooms is not None:
        dx, dy, dz = voxel_zooms
        aspect_sag = dz / dy
        aspect_cor = dz / dx
        aspect_ax  = dy / dx
    else:
        aspect_sag = aspect_cor = aspect_ax = 1.0

    # Get center slices for sagittal/coronal
    si, ci, ai = get_mid_slice_indices(native_data, vert_data)
    si = min(si, native_data.shape[0] - 1)
    ci = min(ci, native_data.shape[1] - 1)
    ai = min(ai, native_data.shape[2] - 1)

    sag_slice = np.rot90(native_data[si, :, :])
    cor_slice = np.rot90(native_data[:, ci, :])

    # Get 4 axial slices at vertebral level midpoints
    axial_levels = get_axial_slices_per_level(vert_data, levels=(1, 2, 3, 4))
    if not axial_levels:
        # Fallback: evenly spaced around the centroid
        spread = native_data.shape[2] // 8
        axial_levels = [
            ("Axial sup", max(0, ai - 3 * spread)),
            ("Axial mid-sup", max(0, ai - spread)),
            ("Axial mid-inf", min(native_data.shape[2] - 1, ai + spread)),
            ("Axial inf", min(native_data.shape[2] - 1, ai + 3 * spread)),
        ]
    # Pad to 4 if fewer levels found
    while len(axial_levels) < 4:
        axial_levels.append(("Axial", ai))

    axial_slices = []
    for label_str, z_idx in axial_levels[:4]:
        z_idx = min(z_idx, native_data.shape[2] - 1)
        axial_slices.append((label_str, z_idx, np.rot90(native_data[:, :, z_idx])))

    # Determine which methods have data
    active_methods = []
    for mname in ["totalspineseg", "spineps", "custom-atlas", "pam50"]:
        if mname in method_files:
            mf = method_files[mname]
            cord_data, _, _ = load_nifti(mf.get("cord"))
            canal_data, _, _ = load_nifti(mf.get("canal"))
            if cord_data is not None or canal_data is not None:
                active_methods.append((mname, cord_data, canal_data))

    if not active_methods:
        print("WARNING: No segmentation data found for QC overlay.")
        return

    n_methods = len(active_methods)
    n_rows = n_methods + 1  # +1 for reference row
    n_cols = 6  # sagittal, coronal, 4× axial

    fig, axes = plt.subplots(n_rows, n_cols, figsize=(24, 4 * n_rows))

    vmin = np.percentile(native_data, 1)
    vmax = np.percentile(native_data, 99)

    # Build column definitions: (label, slice_2d, aspect, dim_type, slice_idx)
    # dim_type: 0=sagittal, 1=coronal, 2=axial
    col_defs = [
        ("Sagittal", sag_slice, aspect_sag, 0, si),
        ("Coronal", cor_slice, aspect_cor, 1, ci),
    ]
    for label_str, z_idx, ax_slice in axial_slices:
        col_defs.append((label_str, ax_slice, aspect_ax, 2, z_idx))

    # Row 0: Reference image (no overlays)
    for col, (dim_label, slice_2d, asp, _, _) in enumerate(col_defs):
        ax = axes[0, col]
        ax.imshow(slice_2d, cmap="gray", vmin=vmin, vmax=vmax, aspect=asp)
        ax.set_title(dim_label, fontsize=12, fontweight="bold")
        ax.axis("off")
        if col == 0:
            ax.set_ylabel("native", fontsize=12, fontweight="bold",
                          rotation=0, labelpad=100, va="center")
            ax.axis("on")
            ax.set_xticks([])
            ax.set_yticks([])

    # Method rows
    for row, (mname, cord_data, canal_data) in enumerate(active_methods, start=1):
        colors = METHOD_COLORS.get(mname, {"cord": "red", "canal": "orange"})

        for col, (dim_label, slice_2d, asp, dim_type, idx) in enumerate(col_defs):
            ax = axes[row, col]
            ax.imshow(slice_2d, cmap="gray", vmin=vmin, vmax=vmax, aspect=asp)

            # Extract the matching segmentation slice
            if canal_data is not None:
                if dim_type == 0:
                    seg_slice = np.rot90(canal_data[idx, :, :])
                elif dim_type == 1:
                    seg_slice = np.rot90(canal_data[:, idx, :])
                else:
                    seg_slice = np.rot90(canal_data[:, :, idx])
                overlay_mask(ax, seg_slice, colors["canal"], alpha=0.7,
                             label=f"{mname} canal" if col == 0 else None,
                             contour=True, aspect_ratio=asp)

            if cord_data is not None:
                if dim_type == 0:
                    seg_slice = np.rot90(cord_data[idx, :, :])
                elif dim_type == 1:
                    seg_slice = np.rot90(cord_data[:, idx, :])
                else:
                    seg_slice = np.rot90(cord_data[:, :, idx])
                overlay_mask(ax, seg_slice, colors["cord"], alpha=0.5,
                             label=f"{mname} cord" if col == 0 else None,
                             aspect_ratio=asp)

            ax.axis("off")
            if col == 0:
                ax.set_ylabel(mname, fontsize=12, fontweight="bold",
                              rotation=0, labelpad=100, va="center")
                ax.axis("on")
                ax.set_xticks([])
                ax.set_yticks([])
                ax.legend(loc="upper left", fontsize=7, framealpha=0.7)

    fig.suptitle(title, fontsize=16, fontweight="bold", y=1.01)
    fig.tight_layout()

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    fig.savefig(output_path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"QC figure saved: {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Generate QC overlay PNGs comparing cord/canal segmentations across methods."
    )
    parser.add_argument("-i", "--image", required=True,
                        help="Native image (NIfTI).")
    parser.add_argument("--vertfile", default=None,
                        help="Vertebral label file for centering the view.")
    parser.add_argument("-o", "--output", required=True,
                        help="Output PNG path.")
    parser.add_argument("--title", default="",
                        help="Figure title.")

    for method in ["totalspineseg", "spineps", "custom-atlas", "pam50"]:
        parser.add_argument(f"--{method}-cord", default=None,
                            help=f"Cord segmentation for {method}.")
        parser.add_argument(f"--{method}-canal", default=None,
                            help=f"Canal segmentation for {method}.")

    args = parser.parse_args()

    method_files = {}
    for method in ["totalspineseg", "spineps", "custom-atlas", "pam50"]:
        cord_key = method.replace("-", "_") + "_cord"
        canal_key = method.replace("-", "_") + "_canal"
        cord_path = getattr(args, cord_key, None)
        canal_path = getattr(args, canal_key, None)
        if cord_path or canal_path:
            method_files[method] = {"cord": cord_path, "canal": canal_path}

    generate_qc_figure(
        native_path=args.image,
        method_files=method_files,
        output_path=args.output,
        vertfile_path=args.vertfile,
        title=args.title,
    )


if __name__ == "__main__":
    main()
