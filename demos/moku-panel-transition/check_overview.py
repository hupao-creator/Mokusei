"""Measure the moving Stop in a 720 × 260pt Overview system-input replay."""
import argparse
import itertools
import json
import re
import subprocess
from pathlib import Path


def read_frames(folder):
    movie = str(folder / "window.mp4")
    info = subprocess.check_output(["ffprobe", "-v", "error", "-show_entries",
                                    "frame=best_effort_timestamp_time", "-of", "json", movie])
    # Use movie presentation timestamps for evidence. Assign consecutive output
    # timestamps to the raw decoder so it emits each variable-rate frame once.
    pixels = subprocess.check_output(["ffmpeg", "-loglevel", "error", "-i", movie, "-vf",
        "scale=720:260,format=gray,setpts=N/60/TB", "-enc_time_base", "1:1000000",
        "-fps_mode", "passthrough", "-f", "rawvideo", "-"])
    frames = json.loads(info)["frames"]
    size = 720 * 260
    if len(pixels) != len(frames) * size:
        raise ValueError("Movie timestamps and decoded frames differ")
    return [measure(float(frame["best_effort_timestamp_time"]), pixels[i * size:(i + 1) * size])
            for i, frame in enumerate(frames)]


def measure(pts, image):
    # The middle band crosses the full dark silhouette in both seats.
    rows = [image[y * 720:(y + 1) * 720] for y in range(198, 219)]
    dark = [x for x in range(720) if any(row[x] < 96 for row in rows)]
    if not dark:
        raise ValueError(f"Missing capsule at {pts}s")
    left, right = dark[0], dark[-1]
    # The running empty draft leaves only the 10pt square on the right.
    # A fading square remains measurable while its bright interior spans
    # at least seven samples on five scanlines. Ignore the rounded shell edge.
    centers = []
    for row in rows:
        for run in re.finditer(rb"[\x96-\xff]+", row[376:right - 8]):
            if 7 <= len(run[0]) <= 12:
                center = 376 + (run.start() + run.end()) // 2
                centers.append(center)
    # A square between pixels can round to adjacent centers on different
    # scanlines. Group those rows before counting physical marks.
    clusters = []
    for center in sorted(centers):
        if not clusters or center - clusters[-1][0] > 1:
            clusters.append([])
        clusters[-1].append(center)
    stops = [cluster[len(cluster) // 2] for cluster in clusters if len(cluster) >= 5]
    if len(stops) > 1:
        raise ValueError(f"Multiple Stop marks at {pts}s")
    return {"pts": pts, "width": right - left + 1, "stopInset": right - stops[0] if stops else None}


def check(folder):
    receipt = json.loads((folder / "observations.json").read_text())
    if receipt["inputChanges"] != [True, False, True] or receipt["running"]:
        raise ValueError("Requires a completed mouse and AXPress Overview replay")
    frames = read_frames(folder)
    def phase(frame):
        if frame["width"] < 174:
            return "compact"
        return "open" if frame["width"] > 554 else "travel"
    phases = [(kind, list(group)) for kind, group in itertools.groupby(frames, phase)]
    expected = ["compact", "travel", "open", "travel", "compact", "travel", "open"]
    if [kind for kind, _ in phases] != expected:
        raise ValueError("Missing or out-of-order input transitions")

    # Read the visible seats from the rendered endpoints, allowing two
    # points for the antialiased silhouette and square center in the movie.
    def settled_inset(phase_index, width):
        values = [f["stopInset"] for f in phases[phase_index][1]
                  if f["width"] == width and f["stopInset"] is not None]
        if not values:
            raise ValueError(f"No settled Stop at {width}pt")
        return sorted(values)[len(values) // 2]
    compact = settled_inset(0, 168)
    expanded = settled_inset(2, 560)
    if not (0 < compact < expanded < 84):
        raise ValueError(f"Stop outside its trailing seats: {compact}, {expanded}")
    for index, (kind, group) in enumerate(phases):
        if kind != "travel":
            continue
        if len({f["width"] for f in group}) < 3:
            raise ValueError("Insufficient intermediate widths")
        for frame in group:
            inset = frame["stopInset"]
            if inset is None and index == 3:
                continue  # Outside press retires hover ink on the return.
            if inset is None or not compact - 2 <= inset <= expanded + 2:
                raise ValueError(f"Stop left its trailing seats ({compact}, {expanded}) at {frame}")
    return dict(locale=receipt["locale"], frames=len(frames),
                compactInset=compact, expandedInset=expanded,
                phases=[dict(phase=kind, first=group[0]["pts"], last=group[-1]["pts"],
                             distinctWidths=len({f["width"] for f in group}),
                             visibleStopFrames=sum(f["stopInset"] is not None for f in group)) for kind, group in phases])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    print(json.dumps(check(parser.parse_args().capture), indent=2))
