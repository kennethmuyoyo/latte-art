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
    tag_0.png, tag_1.png, tag_2.png   (cup, IDs 0/1/2 — single tag each)
    tag_10.png, tag_11.png            (pitcher spout/back, IDs 10/11 — single tag each)
    print_sheet.pdf / .png            (full A4 page, tiled with repeated copies of all 5)
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
    "pitcher_spout_10": 10, "pitcher_back_11": 11, "pitcher_opposite_12": 12,
}

# Physical size of the OUTER BLACK BORDER edge (the 8x8-cell core), matching
# `AprilTagRoles.cupTagSizeMeters` / `pitcherTagSizeMeters` in
# LatteArt/Sensor/AprilTagTracker.swift. Keep these in sync.
TAG_SIZE_MM = 14.0

# Rendering scale: chosen so TAG_SIZE_MM/8*PX_PER_MM (the per-cell pixel size)
# lands on a whole number — no antialiasing blur at tag edges, which hurts
# detection. 14mm tags -> 28px/cell at 16 px/mm.
PX_PER_MM = 16
CELL_PX = int(TAG_SIZE_MM / 8 * PX_PER_MM)
DPI = PX_PER_MM * 25.4                      # embedded so "print at 100%" is exact

A4_W_MM, A4_H_MM = 210.0, 297.0


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
    raw_tiles = {}    # bare tag+quiet-zone image, for the dense A4 grid
    for name, tag_id in TAG_IDS.items():
        grid = render_tag_grid(codes[tag_id], bit_x, bit_y)
        img = render_tag_image(grid, CELL_PX)
        raw_tiles[tag_id] = img

        if tag_id < 10:
            label = "CUP"
        elif tag_id == 10:
            label = "PITCHER SPOUT"
        elif tag_id == 11:
            label = "PITCHER SIDE (90°)"
        else:
            label = "PITCHER OPPOSITE (180°)"
        labeled = add_measure_guide(img, tag_id, label)
        path = out_dir / f"tag_{tag_id}.png"
        labeled.save(path, dpi=(DPI, DPI))
        print(f"  wrote {path.name}  ({labeled.width}x{labeled.height}px @ {DPI:.1f} DPI)")

    build_print_sheet(raw_tiles, out_dir)


def build_print_sheet(tiles, out_dir: Path):
    """A full A4 page (210x297mm), tiled edge-to-edge with repeated copies of
    all 5 tags — one ID per row, cycling — so cutting out a whole row gives a
    stack of identical, ready-to-mount spares instead of one single copy."""
    def mm(x):
        return round(x * PX_PER_MM)

    margin_mm = 8.0
    tile_core_mm = TAG_SIZE_MM * 10 / 8       # quiet-zone-inclusive tag width
    label_h_mm = 5.0
    tile_h_mm = tile_core_mm + label_h_mm
    gap_mm = 4.0

    header_h_mm = 8.0
    ruler_h_mm = 16.0
    section_gap_mm = 4.0
    grid_top_mm = margin_mm + header_h_mm + ruler_h_mm + section_gap_mm

    usable_w_mm = A4_W_MM - 2 * margin_mm
    usable_h_mm = A4_H_MM - grid_top_mm - margin_mm

    cols = int((usable_w_mm + gap_mm) // (tile_core_mm + gap_mm))
    rows = int((usable_h_mm + gap_mm) // (tile_h_mm + gap_mm))

    grid_w_mm = cols * tile_core_mm + (cols - 1) * gap_mm
    grid_h_mm = rows * tile_h_mm + (rows - 1) * gap_mm
    grid_left_mm = margin_mm + (usable_w_mm - grid_w_mm) / 2
    grid_top_mm += (usable_h_mm - grid_h_mm) / 2

    ids_cycle = [0, 1, 2, 10, 11, 12]
    role = {0: "CUP", 1: "CUP", 2: "CUP", 10: "SPOUT", 11: "SIDE90", 12: "OPP180"}

    sheet = Image.new("RGB", (mm(A4_W_MM), mm(A4_H_MM)), "white")
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 24)
        font_small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 16)
        font_tiny = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 13)
    except OSError:
        font = font_small = font_tiny = ImageFont.load_default()

    draw.text((mm(margin_mm), mm(margin_mm) - 6),
              f"Latte Art — AprilTag print sheet (A4, tag36h11, {TAG_SIZE_MM:.0f} mm). "
              f"Print print_sheet.pdf at 100% / Actual Size (no “fit to page”).",
              fill="black", font=font_small)

    # Measurement ruler: 0-60mm, 1mm ticks, 10mm labeled.
    ruler_len_mm = 60
    x0 = mm(margin_mm)
    y0 = mm(margin_mm + header_h_mm + 10)
    draw.text((x0, mm(margin_mm + header_h_mm)),
              f"Verification ruler — must measure exactly 60 mm after printing (if not: "
              f"measured_mm / 60 × {TAG_SIZE_MM:.0f} mm = true tag size). Cross-check against "
              f"the magenta-outlined tile below, top-left — that square should also be "
              f"{TAG_SIZE_MM:.0f} mm/side.",
              fill="black", font=font_small)
    draw.line([(x0, y0), (x0 + ruler_len_mm * PX_PER_MM, y0)], fill="black", width=3)
    for t in range(0, ruler_len_mm + 1):
        x = x0 + t * PX_PER_MM
        if t % 10 == 0:
            draw.line([(x, y0), (x, y0 + 18)], fill="black", width=2)
            draw.text((x - 6, y0 + 21), str(t), fill="black", font=font_small)
        elif t % 5 == 0:
            draw.line([(x, y0), (x, y0 + 12)], fill="black", width=2)
        else:
            draw.line([(x, y0), (x, y0 + 6)], fill="black", width=1)

    # Grid: one tag ID per row, repeated across every column in that row. The
    # very first tile gets a magenta measurement border + callout (the one
    # spot to check with a ruler); every other tile gets a plain gray
    # cut-guide at the same edge so scissors have a line to follow.
    quiet_px = 1 * (tiles[ids_cycle[0]].width // 10)
    core_px = 8 * (tiles[ids_cycle[0]].width // 10)

    def cut_guide(x0, y0, x1, y1, color, width, dashed):
        if not dashed:
            draw.rectangle([x0, y0, x1, y1], outline=color, width=width)
            return
        dash = 8
        for x in range(x0, x1, dash * 2):
            draw.line([(x, y0), (min(x + dash, x1), y0)], fill=color, width=width)
            draw.line([(x, y1), (min(x + dash, x1), y1)], fill=color, width=width)
        for y in range(y0, y1, dash * 2):
            draw.line([(x0, y), (x0, min(y + dash, y1))], fill=color, width=width)
            draw.line([(x1, y), (x1, min(y + dash, y1))], fill=color, width=width)

    for r in range(rows):
        tag_id = ids_cycle[r % len(ids_cycle)]
        tile = tiles[tag_id]
        y = mm(grid_top_mm + r * (tile_h_mm + gap_mm))
        for c in range(cols):
            x = mm(grid_left_mm + c * (tile_core_mm + gap_mm))
            sheet.paste(tile, (x, y))
            draw.text((x + mm(tile_core_mm) // 2, y + mm(tile_core_mm) + 2),
                      f"ID {tag_id} · {role[tag_id]}", fill=(90, 90, 90),
                      font=font_tiny, anchor="ma")
            gx0, gy0 = x + quiet_px - 1, y + quiet_px - 1
            gx1, gy1 = x + quiet_px + core_px, y + quiet_px + core_px
            if r == 0 and c == 0:
                cut_guide(gx0, gy0, gx1, gy1, (220, 0, 220), 2, dashed=True)
            else:
                cut_guide(gx0, gy0, gx1, gy1, (210, 210, 210), 1, dashed=True)

    print(f"  grid: {cols} cols x {rows} rows = {cols*rows} tags "
          f"({', '.join(f'{ids_cycle[r % len(ids_cycle)]}×{cols}' for r in range(rows))})")

    path = out_dir / "print_sheet.png"
    sheet.save(path, dpi=(DPI, DPI))
    print(f"  wrote {path.name}  ({sheet.width}x{sheet.height}px @ {DPI:.1f} DPI, "
          f"{sheet.width / DPI * 25.4:.0f}x{sheet.height / DPI * 25.4:.0f} mm)")

    # PDF is the more reliable "actual size" format: the page's MediaBox is
    # set directly from resolution (pixels / DPI), so the physical size is
    # part of the page geometry itself, not metadata a print dialog can
    # ignore the way it can with a PNG's DPI tag.
    pdf_path = out_dir / "print_sheet.pdf"
    sheet.save(pdf_path, "PDF", resolution=DPI)
    pdf_w_mm = sheet.width / DPI * 25.4
    pdf_h_mm = sheet.height / DPI * 25.4
    print(f"  wrote {pdf_path.name}  (page {pdf_w_mm:.0f}x{pdf_h_mm:.0f} mm — "
          f"fits both A4 [210x297mm] and US Letter [216x279mm] with margin to spare)")


if __name__ == "__main__":
    main()
