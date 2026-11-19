"""Check Dock geometry and responder acquisition in a --capture-collapse movie (2×, Chinese locale)."""
import argparse
import json
import subprocess
from pathlib import Path

import cv2
import numpy as np


def dock_frame(movie, phase_count):
    ok, frame = movie.read()
    if not ok:
        raise ValueError("Missing captured window frame")
    # Both markers occupy the same row. Locate it using the independent
    # responder tile; window decorations can change its vertical offset.
    strip = frame[:, 44:84].astype(np.int16)
    blue, green, red = cv2.split(strip)
    on = (green - red > 90) & (green - blue > 90)
    off = (red - green > 90) & (red - blue > 90)
    focused = np.count_nonzero(on) > 500
    if focused == (np.count_nonzero(off) > 500):
        raise ValueError("Missing or ambiguous first-responder marker")
    y = int(np.median(np.nonzero(on if focused else off)[0]))
    # In the 2× capture, each phase lane is 24px wide starting at x=128.
    # Sample the interior of each tile to avoid compressed edges.
    lanes = frame[y - 2:y + 3, 128:128 + 24 * phase_count].reshape(5, phase_count, 24, 3)
    blue, green, red = np.median(lanes[:, :, 4:12], axis=(0, 2)).T
    marked = np.flatnonzero((blue - green > 90) & (blue - red > 90))
    if marked.size != 1:
        raise ValueError("Missing or ambiguous capture phase marker")
    dock = cv2.cvtColor(frame[-176:], cv2.COLOR_BGR2GRAY)
    return dock, focused, int(marked[0])


def capture_phases(events, codes, times):
    names = [row["event"] for row in events]
    if not events or len(set(names)) != len(names) or [row["phase"] for row in events] != list(range(len(events))):
        raise ValueError("Invalid native phase sequence")
    starts = np.flatnonzero(np.r_[True, np.diff(codes) != 0])
    observed = [codes[i] for i in starts]
    if observed != list(range(len(events))):
        raise ValueError(f"Missing or out-of-order movie phases: {observed} for {names}")
    mapping = [dict(event=row["event"], phase=row["phase"], frame=int(i), moviePTS=times[i],
                    nativeSeconds=row["seconds"]) for row, i in zip(events, starts)]
    return {row["event"]: row["frame"] for row in mapping}, mapping


def glass_edges(frame):
    # The same horizontal band crosses the middle of both capsules. Compare it
    # with the actual backdrop on the left, which brightens during panel return.
    band = frame[76:82, 20:-20]
    dark = np.flatnonzero(band.min(axis=0) < np.median(band[:, :40]) * 0.67)
    if not dark.size:
        raise ValueError("Capsule silhouette is missing")
    return int(dark[0]) + 20, int(dark[-1]) + 20


def check_visit(frames, times, phases, index, next_visit, reference_index):
    first = phases[f"agent-enter-{index}"]
    expanding = phases[f"agent-expanding-{index}"]
    closing = phases[f"agent-close-{index}"]
    idle_end = phases[next_visit]
    reference = frames[reference_index]
    left, right = glass_edges(reference)
    open_width = right - left + 1
    # Sample the first three Chinese placeholder glyphs in the empty editor.
    # Matching the settled movie's ink tolerates font rasterization and fading.
    x, y = left + 180, 69
    glyphs = reference[y:y + 36, x:x + 85]
    if glyphs.std() < 20:
        raise ValueError("Settled placeholder is unreadable")

    opening_widths, closing_widths, matches = [], [], []
    retiring_ink = []
    for frame_index in range(first, idle_end):
        timestamp = times[frame_index]
        frame = frames[frame_index]
        l_edge, r_edge = glass_edges(frame)
        width = r_edge - l_edge + 1
        # Follow ink anywhere in the window, including a displaced title
        # carried by the returning shell. The fixture backdrop contains no text.
        area = frame[35:145]
        scores = cv2.matchTemplate(area, glyphs, cv2.TM_CCOEFF_NORMED)
        _, score, _, (mx, my) = cv2.minMaxLoc(scores)
        if frame_index >= closing:
            closing_widths.append((width, timestamp))
            if score >= 0.8 and width < open_width - 16:
                retiring_ink.append(timestamp)
        else:
            if frame_index >= expanding:
                opening_widths.append(width)
            if score >= 0.8:
                matches.append((max(abs(mx - x), abs(my + 35 - y)), timestamp, width))

    # Require moving frames in both directions. Static endpoints alone would
    # also satisfy a maximum-width and displacement check.
    idle_width = 168 * 2

    def intermediate(width):
        return idle_width + 16 < width < open_width - 16

    opening_steps = len({width for width in opening_widths if intermediate(width)})
    closing_steps = len({width for width, _ in closing_widths if intermediate(width)})
    moving_matches = [(pts, width) for _, pts, width in matches if pts >= times[expanding] and width < open_width - 4]
    if min(opening_steps, closing_steps) < 3 or len(matches) < 3 or not moving_matches:
        raise ValueError(f"Visit {index}: {opening_steps} opening and {closing_steps} closing intermediate widths, "
                         f"{len(matches)} readable frames, {len(moving_matches)} readable below {open_width - 4}px")
    displacement, moved_at, _ = max(matches)
    peak_width, widest_at = max(closing_widths)
    widths = np.array([width for width, _ in closing_widths])
    regrowth = widths - np.minimum.accumulate(widths)
    regrowth_index = int(np.argmax(regrowth))
    max_regrowth = int(regrowth[regrowth_index])
    # The movie begins on the same idle Overview seat that each visit returns to.
    idle_left, idle_right = glass_edges(frames[phases["agent-enter-0"] - 1])
    idle_width_error = abs(closing_widths[-1][0] - (idle_right - idle_left + 1))
    return dict(visit=index, referenceFrame=reference_index, referenceAt=times[reference_index],
                openingFrames=len(opening_widths), closingFrames=len(closing_widths),
                openingIntermediate=opening_steps, closingIntermediate=closing_steps,
                movingReadableFrames=len(moving_matches),
                movingReadableWidthsPx=sorted({width for _, width in moving_matches}),
                firstMovingInkAt=moving_matches[0][0], lastMovingInkAt=moving_matches[-1][0],
                readableFrames=len(matches), maxGlyphShiftPx=displacement, shiftedAt=moved_at,
                openWidthPx=open_width, maxReturnWidthPx=peak_width, widestAt=widest_at,
                maxReturnRegrowthPx=max_regrowth, regrowthAt=closing_widths[regrowth_index][1],
                idleWidthErrorPx=idle_width_error, retiringInkAt=retiring_ink,
                passed=(displacement <= 2 and peak_width <= open_width + 4 and max_regrowth <= 4
                        and idle_width_error <= 4 and not retiring_ink))


def check_focus(frames, focus, times, start, end, x, y, name, *, reference_index=None, explicit=False):
    # The bottom seat moves vertically during an Overview reversal. Locate
    # the settled strokes near that seat, then measure their contrast relative
    # to the reference. Compression noise alone is not visible input feedback.
    def strokes(index):
        patch = frames[index][max(0, y - 32):y + 68, x - 12:x + 67]
        return cv2.subtract(patch, cv2.GaussianBlur(patch, (0, 0), 2)).astype(np.float32)

    top = min(y, 32)
    reference = strokes(end if reference_index is None else reference_index)[top:top + 36, 12:67]
    if reference.std() < 5:
        raise ValueError(f"Missing settled glyphs for {name}")
    pattern = reference - reference.mean()
    scale = np.sum(pattern * pattern)

    def ink_contrast(index):
        area = strokes(index)
        _, match, _, (mx, my) = cv2.minMaxLoc(cv2.matchTemplate(area, reference, cv2.TM_CCOEFF_NORMED))
        if match < 0.60:
            return 0.0
        return np.sum(area[my:my + 36, mx:mx + 55] * pattern) / scale

    contrast = np.array([ink_contrast(i) for i in range(start, end + 1)])
    focused = np.array(focus[start:end + 1])
    visible = contrast >= 0.10
    if focused[0] or not focused[-1] or not visible.any():
        raise ValueError(f"Missing responder transition for {name}")
    first_focus = int(np.argmax(focused))
    first_visible = int(np.argmax(visible))
    hidden = int(np.count_nonzero(focused & ~visible))
    lag = first_focus - first_visible
    # The explicit command is driven at admission, before the automatic grant.
    timely = lag < 0 if explicit else hidden == 0 and lag <= 1
    return dict(visit=name, focusAt=times[start + first_focus], visibleAt=times[start + first_visible],
                focusLagFrames=lag, hiddenFocusedFrames=hidden,
                contrastAtFocus=round(float(contrast[first_focus]), 3),
                passed=timely and bool(focused[first_focus:].all()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="directory containing window.mp4 and observations.json")
    folder = parser.parse_args().capture
    receipt = json.loads((folder / "observations.json").read_text())
    if receipt["failure"] is not None or not receipt["foregroundUnchanged"]:
        raise ValueError("Native capture did not complete successfully")
    phase_events = [row for row in receipt["events"] if "phase" in row]
    if not phase_events:
        raise ValueError("Capture has no native phase markers")
    path = str(folder / "window.mp4")
    output = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", path])
    times = np.array([float(frame["best_effort_timestamp_time"]) for frame in json.loads(output)["frames"]])
    if times.size == 0:
        raise ValueError("Movie has no presentation frames")
    movie = cv2.VideoCapture(path)
    try:
        # ScreenCaptureKit omits identical frames. Decode in presentation
        # order and use only the phase carried by each recorded frame.
        frames, focus, codes = [], [], []
        for i, pts in enumerate(times):
            try:
                frame, focused, phase = dock_frame(movie, len(phase_events))
            except ValueError as error:
                raise ValueError(f"Frame {i} at {pts}s: {error}") from error
            frames.append(frame)
            focus.append(focused)
            codes.append(phase)
    finally:
        movie.release()
    phases, mapping = capture_phases(phase_events, codes, times)
    visits, acquisitions, realtime = [], [], []
    for phase, focus_results in [("agent", acquisitions), ("realtime", realtime)]:
        for index in range(2):
            start = phases[f"{phase}-enter-{index}"]
            end = phases[f"{phase}-close-{index}"] - 1
            # Select the template independently of clock origin and the pixels under test.
            reference = (phases[f"{phase}-open-{index}"] + end) // 2
            if phase == "agent":
                next_visit = ["agent-enter-1", "interrupted-open"][index]
                visits.append(check_visit(frames, times, phases, index, next_visit, reference))
            left, _ = glass_edges(frames[reference])
            focus_results.append(check_focus(frames, focus, times, start, end, left + 181, 69,
                                             f"{phase}-{index}", reference_index=reference))
    # The empty Overview placeholder and the second line of its retained
    # draft share this seat, clear of the caret and selected emoji.
    x = frames[0].shape[1] // 2 - 560 + 205
    for name, start_phase, next_phase in [
        ("interrupted-entrance", "interrupted-open", "overview-edit"),
        ("retained-draft", "draft-reopen", "close-to-talk"),
    ]:
        acquisitions.append(check_focus(frames, focus, times, phases[start_phase], phases[next_phase] - 1,
                                        x, 35, name))
    end = phases["explicit-settled"]
    left, _ = glass_edges(frames[end])
    command = check_focus(frames, focus, times, phases["explicit-enter"], end, left + 181, 69, "compose",
                          explicit=True)
    print(json.dumps(dict(phases=mapping, geometry=visits, autofocus=acquisitions, realtimeAutofocus=realtime,
                          explicitCompose=command), indent=2))
    return all(visit["passed"] for visit in visits + acquisitions + realtime) and command["passed"]


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
