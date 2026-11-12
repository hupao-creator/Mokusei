"""Absolute-clock system inputs; preparation never counts as measured work."""

SCENARIOS = ("reading.first-open", "reading.reopen", "reading.scroll",
             "reading.history", "reading.output-scroll")


def click(point, at):
    return [{"kind": "move", "atSeconds": at - .05, **point},
            {"kind": "down", "atSeconds": at, **point},
            {"kind": "up", "atSeconds": at + .04, **point}]


def scroll(point, start, direction, viewport="document"):
    # The native control checks delivered pixel volume and optical travel.
    # AppKit may add settling movement after the supplied gesture ends.
    events = [{"kind": "move", "atSeconds": start - .05, **point}]
    for index in range(72):
        events.append({"kind": "scroll", "atSeconds": start + index / 60,
                       "deltaY": direction * 5, "phase": 1 if index == 0 else 2, **point})
    events.append({"kind": "scroll", "atSeconds": start + 1.2,
                   "deltaY": 0, "phase": 4, **point})
    segment = {"startSeconds": start, "endSeconds": start + 1.2,
               "direction": direction, "inputPixels": direction * 360,
               "minimumTravelPoints": 360, "viewport": viewport}
    return events, segment


def interaction(scenario, document_point, card_point=None, history_point=None, history_entry_point=None):
    if scenario not in SCENARIOS:
        raise ValueError("unknown reading scenario")
    events, segments = [], []
    trigger = None
    if scenario in ("reading.first-open", "reading.reopen"):
        if card_point is None:
            raise ValueError("entry requires the observed card position")
        events.extend(click(card_point, .2))
        trigger = {"kind": "up", "atSeconds": events[-1]["atSeconds"]}
        starts = ((4.0, -1), (5.8, 1), (7.6, -1))
    elif scenario == "reading.history":
        if history_point is None or history_entry_point is None:
            raise ValueError("history requires the observed directory and oldest-entry positions")
        # The same 1800-point input reaches the directory's beginning at both
        # declared history levels. The oldest mark's hit point was observed
        # externally during preparation, then the directory returned to its end.
        for start in (.4, 2.2, 4.0, 5.8, 7.6):
            motion, segment = scroll(history_point, start, 1, "history")
            events.extend(motion); segments.append(segment)
        events.extend(click(history_entry_point, 9.4))
        trigger = {"kind": "up", "atSeconds": events[-1]["atSeconds"]}
        starts = ((12.4, -1), (14.2, 1))
    else:
        starts = ((.4, -1), (2.2, 1), (4.0, -1), (5.8, 1), (7.6, -1))
    for start, direction in starts:
        motion, segment = scroll(document_point, start, direction)
        events.extend(motion); segments.append(segment)
    return {"events": sorted(events, key=lambda event: event["atSeconds"]),
            "segments": segments, "entryTrigger": trigger,
            "formalSeconds": 17.0 if scenario == "reading.history" else 10.0, "tailSeconds": 3.0}
