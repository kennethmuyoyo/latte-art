#!/usr/bin/env python3
"""
Generates print-ready tag36h11 AprilTag markers for this project's fixed
tag-ID scheme (see LatteArt/Sensor/AprilTagTracker.swift: AprilTagRoles).

Renders each tag's bit pattern DIRECTLY from the vendored AprilRobotics C
source (tag36h11.c) that SwiftAprilTag ships and links against, so the
printed marker is guaranteed to match what the on-device detector decodes —
no copied/hand-transcribed bit tables.

Usage:
    python3 generate_tags.py

Requires: Pillow (`pip3 install pillow`).
Outputs into this directory:
    tag_0.png, tag_1.png, tag_2.png   (cup, IDs 0/1/2)
    tag_10.png, tag_11.png            (pitcher spout/back, IDs 10/11)
    print_sheet.png                   (all 5 + a measurement ruler, one page)
"""
import re
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("Pillow is required: pip3 install pillow")

TAG_IDS = {
    "cup_0": 0, "cup_1": 1, "cup_2": 2,
    "pitcher_spout_10": 10, "pitcher_back_11": 11,
}

# Physical size of the OUTER BLACK BORDER edge (the 8x8-cell core), matching
# `AprilTagRoles.cupTagSizeMeters` / `pitcherTagSizeMeters` in
# LatteArt/Sensor/AprilTagTracker.swift. Keep these in sync.
TAG_SIZE_MM = 24.0

# Rendering scale: exact integer px/mm so cell boundaries land on whole
# pixels (no antialiasing blur at tag edges, which hurts detection).
PX_PER_MM = 12
CELL_PX = int(TAG_SIZE_MM / 8 * PX_PER_MM)  # 24/8*12 = 36 px/cell
DPI = PX_PER_MM * 25.4                      # embedded so "print at 100%" is exact


def find_vendored_source() -> Path:
    """Locate the vendored tag36h11.c SwiftAprilTag checked out via SPM."""
    result = subprocess.run(
        ["find", str(Path.home() / "Library/Developer/Xcode/DerivedData"),
         "-iname", "tag36h11.c"],
        capture_output=True, text=True, timeout=30,
    )
    paths = [p for p in result.stdout.splitlines() if "SourcePackages/checkouts/SwiftAprilTag" in p]
    if not paths:
        sys.exit("Could not find vendored tag36h11.c — build the Xcode project once "
                  "(so SPM checks out SwiftAprilTag) and re-run this script.")
    return Path(paths[0])


def load_family(src: Path):
    text = src.read_text()
    m = re.search(r"codedata\[\d+\]\s*=\s*\{(.*?)\};", text, re.S)
    codes = [int(x.strip().rstrip("UL"), 16) for x in m.group(1).split(",") if x.strip()]

    bit_x = [None] * 36
    bit_y = [None] * 36
    for mm in re.finditer(r"bit_x\[(\d+)\]\s*=\s*(\d+);", text):
        bit_x[int(mm.group(1))] = int(mm.group(2))
    for mm in re.finditer(r"bit_y\[(\d+)\]\s*=\s*(\d+);", text):
        bit_y[int(mm.group(1))] = int(mm.group(2))
    return codes, bit_x, bit_y


def render_tag_grid(code: int, bit_x, bit_y) -> list:
    """10x10 grid of bool (True = black): 1-cell white quiet zone, 1-cell
    black border, 6x6 data core, 1-cell black border, 1-cell white quiet zone
    — matches tag36h11's total_width=10 / width_at_border=8 layout."""
    grid = [[False] * 10 for _ in range(10)]
    for y in (1, 8):
        for x in range(1, 9):
            grid[y][x] = True
    for x in (1, 8):
        for y in range(1, 9):
            grid[y][x] = True
    for i in range(36):
        bitval = (code >> (35 - i)) & 1  # bit 0 = MSB of the 36-bit code
        # bit_x/bit_y are 0-indexed within the 8x8 border+data subgrid
        # (border ring = subgrid index 0/7); offset by +1 to land in the
        # full 10x10 grid (border ring = index 1/8, quiet zone = 0/9).
        grid[bit_y[i] + 1][bit_x[i] + 1] = (bitval == 0)  # 0 = black, 1 = white
    return grid


def render_tag_image(grid, cell_px: int) -> Image.Image:
    n = len(grid)
    img = Image.new("L", (n * cell_px, n * cell_px), 255)
    draw = ImageDraw.Draw(img)
    for y in range(n):
        for x in range(n):
            if grid[y][x]:
                draw.rectangle([x * cell_px, y * cell_px,
                                (x + 1) * cell_px - 1, (y + 1) * cell_px - 1], fill=0)
    return img


def add_measure_guide(img: Image.Image, tag_id: int, label: str) -> Image.Image:
    """Pad with a labeled margin and a dashed line marking exactly the outer
    black-border edge (the 8-cell core) — that square, not the whole image
    with its white quiet zone, is the `tagSize` to measure and set in code."""
    pad_top, pad_bottom, pad_side = 56, 40, 20
    n = 10
    core_px = 8 * (img.width // n)
    quiet_px = 1 * (img.width // n)

    out = Image.new("RGB", (img.width + pad_side * 2, img.height + pad_top + pad_bottom), "white")
    out.paste(img.convert("RGB"), (pad_side, pad_top))
    draw = ImageDraw.Draw(out)

    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
        font_small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 15)
    except OSError:
        font = font_small = ImageFont.load_default()

    draw.text((pad_side, 8), f"{label}  (tag36h11, ID {tag_id})", fill="black", font=font)

    # Dashed square exactly at the outer black-border edge.
    x0 = pad_side + quiet_px - 1
    y0 = pad_top + quiet_px - 1
    x1 = pad_side + quiet_px + core_px
    y1 = pad_top + quiet_px + core_px
    dash = 8
    for x in range(x0, x1, dash * 2):
        draw.line([(x, y0), (min(x + dash, x1), y0)], fill=(220, 0, 220), width=2)
        draw.line([(x, y1), (min(x + dash, x1), y1)], fill=(220, 0, 220), width=2)
    for y in range(y0, y1, dash * 2):
        draw.line([(x0, y), (x0, min(y + dash, y1))], fill=(220, 0, 220), width=2)
        draw.line([(x1, y), (x1, min(y + dash, y1))], fill=(220, 0, 220), width=2)

    draw.text((pad_side, pad_top + img.height + 6),
              f"Magenta square = {TAG_SIZE_MM:.0f} mm per side",
              fill=(220, 0, 220), font=font_small)
    return out


def main():
    src = find_vendored_source()
    print(f"Reading tag36h11 bit codes from: {src}")
    codes, bit_x, bit_y = load_family(src)

    out_dir = Path(__file__).parent
    tiles = {}
    for name, tag_id in TAG_IDS.items():
        grid = render_tag_grid(codes[tag_id], bit_x, bit_y)
        img = render_tag_image(grid, CELL_PX)
        label = "CUP" if tag_id < 10 else ("PITCHER SPOUT" if tag_id == 10 else "PITCHER BACK")
        tile = add_measure_guide(img, tag_id, label)
        path = out_dir / f"tag_{tag_id}.png"
        tile.save(path, dpi=(DPI, DPI))
        tiles[tag_id] = tile
        print(f"  wrote {path.name}  ({tile.width}x{tile.height}px @ {DPI:.1f} DPI)")

    build_print_sheet(tiles, out_dir)


def build_print_sheet(tiles, out_dir: Path):
    """One portrait sheet: 3 cup tags, a measurement ruler, 2 pitcher tags.
    Sized to print at 100% on both A4 and US Letter without clipping."""
    margin = int(10 * PX_PER_MM)
    gap = int(8 * PX_PER_MM)
    tile_w = tiles[0].width
    row_h = tiles[0].height

    title_h = int(14 * PX_PER_MM)
    ruler_h = int(28 * PX_PER_MM)   # text + line + ticks + number labels, fits comfortably

    sheet_w = margin * 2 + tile_w * 3 + gap * 2
    sheet_h = margin + title_h + row_h + gap + ruler_h + gap + row_h + margin

    sheet = Image.new("RGB", (sheet_w, sheet_h), "white")
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 24)
        font_small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 16)
    except OSError:
        font = font_small = ImageFont.load_default()

    draw.text((margin, margin),
              "Latte Art — AprilTag print sheet. Print at 100% / Actual Size (no “fit to page”).",
              fill="black", font=font_small)

    y = margin + title_h
    for i, tid in enumerate([0, 1, 2]):
        x = margin + i * (tile_w + gap)
        sheet.paste(tiles[tid], (x, y))

    # Measurement ruler: 0-60mm, 1mm ticks, 10mm labeled. Line sits near the
    # top of its band; ticks + number labels hang below it.
    y_ruler = y + row_h + gap
    ruler_len_mm = 60
    x0 = margin
    y0 = y_ruler + int(6 * PX_PER_MM)
    draw.text((x0, y_ruler),
              "Verification ruler — if this does not measure exactly 60 mm after printing, "
              "your printer rescaled the page: measured_mm / 60 × 24 mm = your true tag size.",
              fill="black", font=font_small)
    draw.line([(x0, y0), (x0 + ruler_len_mm * PX_PER_MM, y0)], fill="black", width=3)
    for mm in range(0, ruler_len_mm + 1):
        x = x0 + mm * PX_PER_MM
        if mm % 10 == 0:
            draw.line([(x, y0), (x, y0 + 22)], fill="black", width=2)
            draw.text((x - 6, y0 + 26), str(mm), fill="black", font=font_small)
        elif mm % 5 == 0:
            draw.line([(x, y0), (x, y0 + 14)], fill="black", width=2)
        else:
            draw.line([(x, y0), (x, y0 + 8)], fill="black", width=1)

    y2 = y_ruler + ruler_h
    for i, tid in enumerate([10, 11]):
        x = margin + i * (tile_w + gap)
        sheet.paste(tiles[tid], (x, y2))

    path = out_dir / "print_sheet.png"
    sheet.save(path, dpi=(DPI, DPI))
    print(f"  wrote {path.name}  ({sheet.width}x{sheet.height}px @ {DPI:.1f} DPI, "
          f"{sheet.width / DPI * 25.4:.0f}x{sheet.height / DPI * 25.4:.0f} mm)")


if __name__ == "__main__":
    main()
