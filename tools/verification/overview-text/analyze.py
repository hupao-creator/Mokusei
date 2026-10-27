"""Compare native-resolution PNG controls (requires Pillow and NumPy)."""
from pathlib import Path
import json
import re
import sys
import numpy as np
from PIL import Image, ImageDraw

folder = Path(sys.argv[1]).resolve()
records = {item["name"]: item for item in json.loads((folder / "captures.json").read_text())}
pairs = [("100-reference", "100"), ("125-reference", "125-transform"),
         ("170-reference", "170-transform"), ("125-window-reference", "125-window")]


def crop(name, title_only=False):
    record = records[name]
    x, y, width, height = map(float, re.findall(r"[\d.]+", record["cardFrame"]))
    scale = width / 360
    backing = record["backingScale"]
    left, top = (x + 18 * scale) * backing, (y + 18 * scale) * backing
    w, h = (250, 22) if title_only else (280, 110)
    box = tuple(round(v) for v in (left, top, left + w * scale * backing, top + h * scale * backing))
    return Image.open(folder / (name + ".png")).convert("RGB").crop(box)


def edge_concentration(image):
    # Contrast-normalized concentration of adjacent-pixel gradients. This is
    # a regression signal for these identical glyphs, not a general quality score.
    pixels = np.asarray(image.convert("L"), dtype=float)
    contrast = np.ptp(pixels)
    assert contrast > 100, "Missing title or invalid screenshot"
    edges = np.concatenate([np.abs(np.diff(pixels, axis=0)).ravel(),
                            np.abs(np.diff(pixels, axis=1)).ravel()]) / contrast
    return float((edges * edges).sum() / edges.sum())


report = []
rows = []
for before, after in pairs:
    a, b = crop(before), crop(after)
    assert a.size == b.size, "Text layout dimensions changed"
    scores = [edge_concentration(crop(name, title_only=True)) for name in (before, after)]
    if after == "100":
        assert np.array_equal(np.asarray(a), np.asarray(b)), "100% rendering changed"
    else:
        assert scores[1] > scores[0] * 1.25, f"No meaningful edge improvement: {after} {scores}"
    report.append({"case": after, "reference_edge_concentration": scores[0],
                   "optimized_edge_concentration": scores[1], "crop_pixels": list(a.size)})
    row = Image.new("RGB", (a.width * 2 + 40, a.height + 32), (24, 24, 26))
    draw = ImageDraw.Draw(row)
    draw.text((10, 8), before, fill="white")
    draw.text((a.width + 30, 8), after, fill="white")
    row.paste(a, (10, 28)); row.paste(b, (a.width + 30, 28))
    row.save(folder / ("comparison-" + after + ".png"))
    rows.append(row)

sheet = Image.new("RGB", (max(row.width for row in rows), sum(row.height for row in rows)), (24, 24, 26))
y = 0
for row in rows:
    sheet.paste(row, (0, y)); y += row.height
sheet.save(folder / "comparison.png")
(folder / "inspection.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
print("PASS: unchanged 100% pixels and improved camera/window zoom text")
