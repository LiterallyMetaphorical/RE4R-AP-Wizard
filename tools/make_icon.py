#!/usr/bin/env python3
"""Build the launcher's app.ico and Assets/wizard.png from the wizard art.

Successor to the dead scratchpad make_icon.ps1, durable this time, and
SVG-aware: given a vector source every icon size is rendered natively from
the vector instead of downscaled from one PNG, which is the whole point of
having the .svg. A PNG source still works (crop + square + resize).

The recipe matches the original: find the art's tight content box (alpha
bounding box with a small margin), square it, then emit the 7 icon sizes
plus the in-app art PNG. The .ico is written by hand with PNG-compressed
entries (valid on Windows Vista+ and what modern icons ship as) so each
size keeps its own native render.

Usage:
  python tools/make_icon.py "C:\\path\\to\\wizard.svg"
  python tools/make_icon.py art.png --out-ico src/RE4R.AP.Launcher/app.ico
"""

from __future__ import annotations

import argparse
import io
import struct
import sys
from pathlib import Path

from PIL import Image

ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)
ART_SIZE = 1067  # matches the shipped Assets/wizard.png
MARGIN_FRACTION = 0.02  # breathing room around the tight content box

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ICO = REPO_ROOT / "src" / "RE4R.AP.Launcher" / "app.ico"
DEFAULT_ART = REPO_ROOT / "src" / "RE4R.AP.Launcher" / "Assets" / "wizard.png"


def render_svg(svg_path: Path, size: int, viewbox: tuple[float, float, float, float] | None) -> Image.Image:
    import resvg_py

    svg_text = svg_path.read_text(encoding="utf-8")
    if viewbox is not None:
        svg_text = override_viewbox(svg_text, viewbox)
    png = resvg_py.svg_to_bytes(svg_string=svg_text, width=size, height=size)
    return Image.open(io.BytesIO(bytes(png))).convert("RGBA")


def override_viewbox(svg_text: str, viewbox: tuple[float, float, float, float]) -> str:
    import re

    replacement = 'viewBox="%g %g %g %g"' % viewbox
    new_text, count = re.subn(r'viewBox="[^"]*"', replacement, svg_text, count=1)
    if count != 1:
        raise SystemExit("could not find a viewBox attribute to override")
    return new_text


def parse_viewbox(svg_text: str) -> tuple[float, float, float, float]:
    import re

    match = re.search(r'viewBox="([^"]*)"', svg_text)
    if not match:
        raise SystemExit("the SVG has no viewBox; add one or rasterize manually")
    x, y, w, h = (float(v) for v in match.group(1).replace(",", " ").split())
    return x, y, w, h


def tight_square_viewbox(svg_path: Path) -> tuple[float, float, float, float]:
    """Render large, find the alpha bbox, map it back to a square in viewBox units."""
    probe_size = 1024
    x0, y0, vw, vh = parse_viewbox(svg_path.read_text(encoding="utf-8"))
    probe = render_svg(svg_path, probe_size, None)
    bbox = probe.getbbox()
    if bbox is None:
        raise SystemExit("the SVG rendered fully transparent")

    # Pixel bbox -> viewBox units. The probe render maps the whole viewBox
    # onto probe_size x probe_size (resvg letterboxes non-square, but the
    # source viewBox here is square; the math holds either way per-axis).
    sx = vw / probe_size
    sy = vh / probe_size
    left = x0 + bbox[0] * sx
    top = y0 + bbox[1] * sy
    right = x0 + bbox[2] * sx
    bottom = y0 + bbox[3] * sy

    width = right - left
    height = bottom - top
    side = max(width, height)
    side *= 1 + MARGIN_FRACTION * 2
    cx = (left + right) / 2
    cy = (top + bottom) / 2
    return (cx - side / 2, cy - side / 2, side, side)


def load_png_square(path: Path) -> Image.Image:
    art = Image.open(path).convert("RGBA")
    bbox = art.getbbox()
    if bbox:
        art = art.crop(bbox)
    side = max(art.size)
    margin = int(side * MARGIN_FRACTION)
    side += margin * 2
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(art, ((side - art.width) // 2, (side - art.height) // 2))
    return square


def write_ico(images: list[Image.Image], out_path: Path) -> None:
    """ICONDIR + PNG-compressed entries, one per size."""
    blobs = []
    for image in images:
        buf = io.BytesIO()
        image.save(buf, format="PNG")
        blobs.append(buf.getvalue())

    header = struct.pack("<HHH", 0, 1, len(images))
    entries = b""
    offset = len(header) + 16 * len(images)
    for image, blob in zip(images, blobs):
        width = image.width if image.width < 256 else 0
        height = image.height if image.height < 256 else 0
        entries += struct.pack(
            "<BBBBHHII", width, height, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)

    out_path.write_bytes(header + entries + b"".join(blobs))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path, help=".svg (preferred) or .png art")
    ap.add_argument("--out-ico", type=Path, default=DEFAULT_ICO)
    ap.add_argument("--out-art", type=Path, default=DEFAULT_ART)
    ap.add_argument("--art-size", type=int, default=ART_SIZE)
    args = ap.parse_args()

    is_svg = args.source.suffix.lower() == ".svg"
    if is_svg:
        viewbox = tight_square_viewbox(args.source)
        print(f"tight square viewBox: {viewbox[0]:.1f} {viewbox[1]:.1f} {viewbox[2]:.1f} {viewbox[3]:.1f}")
        sizes = [render_svg(args.source, size, viewbox) for size in ICO_SIZES]
        art = render_svg(args.source, args.art_size, viewbox)
    else:
        square = load_png_square(args.source)
        sizes = [square.resize((size, size), Image.LANCZOS) for size in ICO_SIZES]
        art = square.resize((args.art_size, args.art_size), Image.LANCZOS)

    write_ico(sizes, args.out_ico)
    art.save(args.out_art)
    print(f"wrote {args.out_ico} ({args.out_ico.stat().st_size} bytes, {len(ICO_SIZES)} sizes, PNG entries)")
    print(f"wrote {args.out_art} ({art.width}x{art.height})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
